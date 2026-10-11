#!/usr/bin/env bash
# Runs the fixtures in tests/fixtures through canary.sh and checks the results.
#
# usage: tests/run.sh [TEST...]   (default: all; list them with --list)
#
# Needs what canary.sh needs (Docker with buildx, jq). The builds are small
# (busybox, Alpine, Debian slim, Node slim, Ubuntu); the node and ubuntu tests
# also build a flip preview. Set CANARY_REGISTRY_MIRROR=mirror.gcr.io if Docker
# Hub rate limits get in the way, and KEEP_IMAGES=1 to keep the test images.

set -uo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
CANARY=$HERE/../canary.sh
FX=$HERE/fixtures
LIB=$HERE/../lib
export CANARY_PREFIX=${CANARY_PREFIX:-canary-test}
P=$CANARY_PREFIX
T=$(mktemp -d "${TMPDIR:-/tmp}/canary-tests.XXXXXX")
PASSED=0
FAILED=0
FAILED_NAMES=()

ok() { PASSED=$((PASSED + 1)); printf '  ok    %s\n' "$*"; }
bad() { FAILED=$((FAILED + 1)); FAILED_NAMES+=("$CURRENT"); printf '  FAIL  %s\n' "$*"; }

cleanup() {
	docker buildx rm "$P-cachemount" >/dev/null 2>&1
	if [ "${KEEP_IMAGES:-0}" != 1 ]; then
		docker images --format '{{.Repository}}:{{.Tag}}' | grep "^$P/" | xargs -r docker rmi -f >/dev/null 2>&1
	fi
	rm -rf "$T"
}
trap cleanup EXIT

# run NAME WANT_EXIT ARGS...: runs canary.sh, keeps the summary in $T/NAME.md
run() {
	local name=$1 want=$2 got
	shift 2
	"$CANARY" --state-dir "$T/state-$name" "$@" >"$T/$name.md" 2>"$T/$name.err"
	got=$?
	if [ "$got" = "$want" ]; then
		ok "$name exits $got"
	else
		bad "$name exits $got, expected $want"
		sed 's/^/        /' "$T/$name.err" | tail -n 5
		sed 's/^/        /' "$T/$name.md" | head -n 20
	fi
}

# has NAME TEXT: the summary of NAME contains TEXT
has() {
	if grep -qF -- "$2" "$T/$1.md"; then ok "$1 says: $2"; else bad "$1 does not say: $2"; fi
}

lacks() {
	if grep -qF -- "$2" "$T/$1.md"; then bad "$1 should not say: $2"; else ok "$1 does not say: $2"; fi
}

t_pkgdiff() {
	jq -n --slurpfile old "$FX/pkgdiff/old.json" --slurpfile new "$FX/pkgdiff/new.json" -f "$LIB/pkgdiff.jq" >"$T/pkgdiff.json"
	local counts row
	counts=$(jq -c .counts "$T/pkgdiff.json")
	if [ "$counts" = '{"changed":4,"added":1,"removed":1}' ]; then ok "pkgdiff counts $counts"; else bad "pkgdiff counts $counts"; fi
	row=$(jq -r '.changes[] | select(.family == "openssl-dev") | "\(.change): \(.before) -> \(.after)"' "$T/pkgdiff.json")
	if [ "$row" = "changed: openssl-3.6-dev 3.6.5-r1 -> openssl-4.0-dev 4.0.3-r6" ]; then ok "pkgdiff pairs openssl-3.6-dev with openssl-4.0-dev"; else bad "pkgdiff openssl row: $row"; fi
	row=$(jq -r '.changes[] | select(.family == "libssl") | .after' "$T/pkgdiff.json")
	if [ "$row" = "libssl3t64 3.5.3-1ubuntu1" ]; then ok "pkgdiff keeps libssl3t64 as one package"; else bad "pkgdiff libssl row: $row"; fi
}

t_buildlog() {
	if awk -f "$LIB/buildlog.awk" "$FX/buildlog/sample.log" | diff -u "$FX/buildlog/expected.tsv" - >"$T/buildlog.diff"; then
		ok "build log parser output matches"
	else
		bad "build log parser output differs"
		sed 's/^/        /' "$T/buildlog.diff" | head -n 20
	fi
}

t_flip_plan() {
	run flip-plan 0 --flip-plan -f "$FX/flip-plan/Dockerfile" "$FX/flip-plan"
	has flip-plan '| 3 | `node:lts` | `node:26` | flip |'
	has flip-plan '| 4 | `node:lts-slim` | `node:26-slim` | flip |'
	has flip-plan '`ubuntu:26.04`'
	has flip-plan '| 7 | `python:3-slim` | `python:3.'
	has flip-plan '| 8 | `python:3.14` | - | none |'
	has flip-plan 'set by a build argument'
	has flip-plan 'pinned by digest'
	has flip-plan '| 11 | `deps` | - | skip | earlier build stage |'
	has flip-plan '| 12 | `scratch` | - | skip |'
	has flip-plan '| 13 | `alpine:3.22` | - | none |'
	has flip-plan 'node:26-alpine3.19 does not exist; using node:26-alpine'
}

t_ok_musl() {
	run ok-musl 0 --tag "$P/ok-musl:test" "$FX/ok-musl"
	has ok-musl "| Shared libraries | pass |"
	has ok-musl "| Start | pass | default command exited 0 |"
	# a second run diffs against the first
	run ok-musl-again 0 --state-dir "$T/state-ok-musl" --tag "$P/ok-musl:test2" "$FX/ok-musl"
	has ok-musl-again "### Package changes since run"
}

t_missing_lib() {
	run missing-lib-glibc 1 --tag "$P/missing-lib-glibc:test" "$FX/missing-lib-glibc"
	has missing-lib-glibc '- `/usr/local/bin/curl`: libcurl.so.4'
	has missing-lib-glibc "libcurl.so.4: cannot open shared object file"
	run missing-lib-musl 1 --tag "$P/missing-lib-musl:test" "$FX/missing-lib-musl"
	has missing-lib-musl '- `/usr/local/bin/curl`: libcurl.so.4'
}

t_wrong_libc() {
	run wrong-libc 1 --tag "$P/wrong-libc:test" "$FX/wrong-libc"
	has wrong-libc 'interpreter `/lib/ld-musl-x86_64.so.1` is not in the image'
}

t_cachemount() {
	local b=$P-cachemount out
	local -a opts=()
	if [ -n "${CANARY_REGISTRY_MIRROR:-}" ]; then
		printf '[registry."docker.io"]\n  mirrors = ["%s"]\n' "$CANARY_REGISTRY_MIRROR" >"$T/buildkitd.toml"
		opts=(--buildkitd-config "$T/buildkitd.toml")
	fi
	docker buildx rm "$b" >/dev/null 2>&1
	docker buildx create --name "$b" --driver docker-container ${opts[@]+"${opts[@]}"} --bootstrap >/dev/null 2>&1 || { bad "cannot create builder $b"; return; }
	docker buildx build --builder "$b" -q --load -t "$P/cachemount:warm" --build-arg MARK=first "$FX/cachemount" >/dev/null 2>&1
	docker buildx build --builder "$b" -q --load -t "$P/cachemount:warm" --build-arg MARK=second "$FX/cachemount" >/dev/null 2>&1
	out=$(docker run --rm "$P/cachemount:warm")
	if [ "$out" = first ]; then
		ok "a normal rebuild with MARK=second still carries the cache mount from MARK=first"
	else
		bad "expected the stale cache mount to print first, got '$out'"
	fi
	run cachemount-builder 0 --builder "$b" --tag "$P/cachemount:pruned" --build-arg MARK=third \
		--smoke "cat /mark" --ready-log '^third$' --no-elf --sbom none "$FX/cachemount"
	has cachemount-builder "were pruned first"
	run cachemount-fresh 0 --tag "$P/cachemount:fresh" --build-arg MARK=fourth \
		--smoke "cat /mark" --ready-log '^fourth$' --no-elf --sbom none "$FX/cachemount"
	has cachemount-fresh "removed after the build"
	docker buildx rm "$b" >/dev/null 2>&1
}

t_start_modes() {
	local img=$P/start-modes:test
	run start-settle 0 --tag "$img" --settle 4 "$FX/start-modes"
	has start-settle "default command still running after 4 s"
	run start-url 0 --image "$img" --ready-url http://localhost:8080/health --no-elf --sbom none
	has start-url "answered after"
	run start-url-404 1 --image "$img" --ready-url http://localhost:8080/nope --timeout 8 --no-elf --sbom none
	has start-url-404 "did not answer 2xx within 8 s"
	run start-log 0 --image "$img" --ready-log 'listening on 8080' --no-elf --sbom none
	run start-log-never 1 --image "$img" --ready-log 'never printed' --timeout 5 --no-elf --sbom none
	has start-log-never "no line matched"
	run start-exit 0 --image "$img" --smoke "sh -c 'exit 3'" --expect-exit 3 --no-elf --sbom none
	run start-exit-wrong 1 --image "$img" --smoke "sh -c 'exit 3'" --no-elf --sbom none
	has start-exit-wrong "exited 3, expected 0"
	run start-quotes 0 --image "$img" --smoke "sh -c 'echo \"two words\"'" --ready-log '^two words$' --no-elf --sbom none
	# a smoke string that starts with --version or --help reaches the container as written
	run start-dash-version 0 --image "$img" --entrypoint echo --smoke "--version" --ready-log '^--version$' --no-elf --sbom none
	run start-dash-help 0 --image "$img" --entrypoint echo --smoke "--help me" --ready-log '^--help me$' --no-elf --sbom none
	run start-db 0 --image "$img" --no-start --sbom db
	has start-db "| Start | skip |"
	run start-changed 4 --image "$img" --no-start --sbom db --previous "$FX/pkgdiff/old.json" --fail-on-change
	has start-changed "PASS, but packages changed"
}

# canary.sh splits --smoke with xargs and whatever printf comes first in PATH.
# uutils printf reads --version, --help or -- right after its format as its own
# option where GNU printf does not, so the same line also runs against the
# stand-in in tests/fixtures/uutils-printf.
t_smoke_split() {
	local line p c s want got
	local -a cases=(
		'--version|[--version]'
		'--help|[--help]'
		'--help me|[--help][me]'
		'-- --version|[--][--version]'
		'serve --version|[serve][--version]'
		"sh -c 'exit 3'|[sh][-c][exit 3]"
	)
	line=$(grep -m 1 "mapfile -d '' smoke < <(" "$CANARY")
	if [ -z "$line" ]; then bad "cannot find the line that splits --smoke in canary.sh"; return; fi
	for p in host uutils-stand-in; do
		for c in "${cases[@]}"; do
			s=${c%%|*} want=${c#*|}
			got=$(SMOKE=$s; [ "$p" = host ] || PATH=$FX/uutils-printf:$PATH; eval "$line"
				printf '[%s]' ${smoke[@]+"${smoke[@]}"} | tr '\n' ' ' | cut -c 1-80)
			if [ "$got" = "$want" ]; then ok "$p printf: --smoke \"$s\" splits into $got"
			else bad "$p printf: --smoke \"$s\" splits into $got, expected $want"; fi
		done
	done
}

t_node_flip() {
	run node-flip 3 --tag "$P/node-corepack:test" --flip-preview --ready-url http://localhost:3000/health "$FX/node-corepack"
	has node-flip "PASS now, FAIL in the flip preview"
	has node-flip '`node:lts-slim` | `node:26-slim` | flip'
	has node-flip "corepack: not found"
	run node-flip-warn 0 --tag "$P/node-corepack:test2" --flip-preview --flip-warn-only --ready-url http://localhost:3000/health "$FX/node-corepack"
}

t_ubuntu_flip() {
	run ubuntu-flip 0 --tag "$P/ubuntu-latest:test" --flip-preview "$FX/ubuntu-latest"
	has ubuntu-flip '`ubuntu:26.04`'
	run ubuntu-back 0 --tag "$P/ubuntu-latest:test2" --flip ubuntu:latest=ubuntu:24.04 "$FX/ubuntu-latest"
	has ubuntu-back "#### Packages, now against the preview"
}

ALL=(pkgdiff buildlog smoke_split flip_plan ok_musl missing_lib wrong_libc cachemount start_modes node_flip ubuntu_flip)
if [ "${1:-}" = --list ]; then printf '%s\n' "${ALL[@]}"; exit 0; fi
[ $# -gt 0 ] && ALL=("$@")

for t in "${ALL[@]}"; do
	CURRENT=$t
	echo "$t"
	if ! declare -F "t_$t" >/dev/null; then bad "no test named $t"; continue; fi
	"t_$t"
done

echo
echo "$PASSED passed, $FAILED failed"
[ "$FAILED" -eq 0 ] || { echo "failed in: $(printf '%s\n' "${FAILED_NAMES[@]}" | sort -u | tr '\n' ' ')"; exit 1; }
