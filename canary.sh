#!/usr/bin/env bash
# Upgrade canary: builds a Dockerfile the way a fresh release runner would,
# checks that every ELF file in the image can load its libraries, starts the
# image, lists its packages and diffs them against the last green run, and can
# preview the build on the next value of floating base image tags.
#
# Needs Docker with buildx, jq and coreutils. See README.md.

set -uo pipefail

CANARY_VERSION=1.0.1
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
LIB=$HERE/lib

HELPER_IMAGE_DEFAULT='busybox:1.38.0-musl@sha256:ea2b9914a16a4ac1981994af97b318f7c7d4db76b580c56177f08bf76f4a0be8'
SYFT_IMAGE_DEFAULT='ghcr.io/anchore/syft:v1.54.1@sha256:3eb5379ba7b409c3f4069b686110527af0c47df993fa5c10d13e7cf34f49b1aa'

usage() {
	cat <<'EOF'
usage: canary.sh [options] [CONTEXT]

Builds CONTEXT (default .) with a Dockerfile on a buildx builder created for
this run and removed afterwards, so nothing is reused: no layer cache, no
RUN --mount=type=cache contents, base images pulled fresh. Then checks the
image and writes a Markdown summary to stdout (and to $GITHUB_STEP_SUMMARY).

Build
  -f, --file FILE          Dockerfile (default CONTEXT/Dockerfile)
  --target STAGE           build this stage
  --build-arg K=V          repeatable
  --platform PLATFORM      single platform; must run on this host
  --tag IMAGE              name for the built image (default canary/NAME:RUN)
  --image IMAGE            skip the build and check an existing image
  --builder NAME           build on this existing builder instead, after
                           pruning its exec cache mounts (type=exec.cachemount)
  --buildkit-image IMAGE   BuildKit image for the per-run builder
  --cpus N, --memory SIZE  limits for the per-run builder
  --registry-mirror HOST   pull Docker Hub images through HOST (for example
                           mirror.gcr.io) on the per-run builder and for tag
                           lookups; also CANARY_REGISTRY_MIRROR
  --build-timeout SEC      default 3600

Shared libraries
  --elf-paths "P ..."      where to look for ELF files in the image (default /)
  --elf-exclude REGEX      skip files whose path matches (extended regex)
  --strict-libs            also fail on shared objects (plugins, extension
                           modules) with unresolved libraries, not only on
                           executables
  --no-elf                 skip this check

Start
  --smoke "ARGS"           arguments for the image (the entrypoint is kept);
                           without --ready-* the check is the exit code
  --entrypoint PATH        override the entrypoint
  --expect-exit N          exit code the smoke command must return (default 0)
  --ready-log REGEX        ready when a log line matches
  --ready-url URL          ready when URL answers 2xx, fetched from inside the
                           container's network namespace (no host ports)
  --run-arg ARG            extra docker run argument, repeatable
  --compose FILE           start this compose file instead; the service under
                           test uses image: ${CANARY_IMAGE}
  --service NAME           compose service to check (required with --compose)
  --project NAME           compose project name prefix (default canary-RUN;
                           CANARY_PREFIX replaces "canary" in every name a
                           run creates)
  --timeout SEC            default 60
  --settle SEC             with no smoke or ready option, pass if the default
                           command is still running after SEC (default 10)
  --no-start               skip this check

Packages
  --sbom syft|db|none      runtime package list from syft (default) or from the
                           image's dpkg, apk or rpm database
  --syft-image IMAGE
  --state-dir DIR          default .canary; holds last-green.json and runs/
  --previous FILE          package list to diff against
                           (default STATE_DIR/last-green.json)
  --fail-on-change         exit 4 when packages changed since the previous list

Flip preview
  --flip-preview           also build a copy with floating base tags moved to
                           their next value: node:lts to node:26, ubuntu:latest
                           to ubuntu:26.04, python:3 to the newest 3.x tag
  --flip FROM=TO           your own substitution, repeatable (implies
                           --flip-preview); overrides the built-in ones
  --flip-plan              print the substitutions and exit (2 when a registry
                           lookup failed)
  --flip-warn-only         exit 0 when only the preview fails

Other
  --name NAME              label for the summary
  --keep-work              keep the temporary directory
  -h, --help, --version

Exit status: 0 pass, 1 a check failed, 2 usage or setup error (also when a
registry lookup for the flip preview fails), 3 the preview failed while the
current build passed, 4 packages changed (--fail-on-change).
EOF
}

say() { printf '[canary] %s\n' "$*" >&2; }
die() { say "error: $*"; exit 2; }

# ----------------------------------------------------------------- options

CONTEXT=.
DOCKERFILE=
TARGET=
BUILD_ARGS=()
PLATFORM=
TAG=
USE_IMAGE=
BUILDER=
BUILDKIT_IMAGE=
CPUS=
MEMORY=
MIRROR=${CANARY_REGISTRY_MIRROR:-}
BUILD_TIMEOUT=3600
SCAN_TIMEOUT=900
ELF_PATHS=/
ELF_EXCLUDE=
STRICT_LIBS=0
DO_ELF=1
SMOKE=
SMOKE_SET=0
ENTRYPOINT=
EXPECT_EXIT=0
READY_LOG=
READY_URL=
RUN_ARGS=()
COMPOSE=
SERVICE=
PROJECT=
TIMEOUT=60
SETTLE=10
DO_START=1
SBOM=syft
SYFT_IMAGE=$SYFT_IMAGE_DEFAULT
HELPER_IMAGE=${CANARY_HELPER_IMAGE:-$HELPER_IMAGE_DEFAULT}
# prefix for the builders, containers and compose projects a run creates
PREFIX=${CANARY_PREFIX:-canary}
STATE_DIR=.canary
PREVIOUS=
FAIL_ON_CHANGE=0
FLIP=0
FLIPS=()
FLIP_PLAN_ONLY=0
FLIP_WARN_ONLY=0
NAME=
KEEP_WORK=0

need() { [ "$1" -ge 2 ] || die "$2 needs a value"; }

while [ $# -gt 0 ]; do
	case $1 in
		--*=*) opt=${1%%=*}; val=${1#*=}; shift; set -- "$opt" "$val" "$@" ;;
	esac
	case $1 in
		-f|--file) need $# "$1"; DOCKERFILE=$2; shift 2 ;;
		--context) need $# "$1"; CONTEXT=$2; shift 2 ;;
		--target) need $# "$1"; TARGET=$2; shift 2 ;;
		--build-arg) need $# "$1"; BUILD_ARGS+=("$2"); shift 2 ;;
		--platform) need $# "$1"; PLATFORM=$2; shift 2 ;;
		--tag) need $# "$1"; TAG=$2; shift 2 ;;
		--image) need $# "$1"; USE_IMAGE=$2; shift 2 ;;
		--builder) need $# "$1"; BUILDER=$2; shift 2 ;;
		--buildkit-image) need $# "$1"; BUILDKIT_IMAGE=$2; shift 2 ;;
		--cpus) need $# "$1"; CPUS=$2; shift 2 ;;
		--memory) need $# "$1"; MEMORY=$2; shift 2 ;;
		--registry-mirror) need $# "$1"; MIRROR=$2; shift 2 ;;
		--build-timeout) need $# "$1"; BUILD_TIMEOUT=$2; shift 2 ;;
		--elf-paths) need $# "$1"; ELF_PATHS=$2; shift 2 ;;
		--elf-exclude) need $# "$1"; ELF_EXCLUDE=$2; shift 2 ;;
		--strict-libs) STRICT_LIBS=1; shift ;;
		--no-elf) DO_ELF=0; shift ;;
		--smoke) need $# "$1"; SMOKE=$2; SMOKE_SET=1; shift 2 ;;
		--entrypoint) need $# "$1"; ENTRYPOINT=$2; shift 2 ;;
		--expect-exit) need $# "$1"; EXPECT_EXIT=$2; shift 2 ;;
		--ready-log) need $# "$1"; READY_LOG=$2; shift 2 ;;
		--ready-url) need $# "$1"; READY_URL=$2; shift 2 ;;
		--run-arg) need $# "$1"; RUN_ARGS+=("$2"); shift 2 ;;
		--compose) need $# "$1"; COMPOSE=$2; shift 2 ;;
		--service) need $# "$1"; SERVICE=$2; shift 2 ;;
		--project) need $# "$1"; PROJECT=$2; shift 2 ;;
		--timeout) need $# "$1"; TIMEOUT=$2; shift 2 ;;
		--settle) need $# "$1"; SETTLE=$2; shift 2 ;;
		--no-start) DO_START=0; shift ;;
		--sbom) need $# "$1"; SBOM=$2; shift 2 ;;
		--syft-image) need $# "$1"; SYFT_IMAGE=$2; shift 2 ;;
		--state-dir) need $# "$1"; STATE_DIR=$2; shift 2 ;;
		--previous) need $# "$1"; PREVIOUS=$2; shift 2 ;;
		--fail-on-change) FAIL_ON_CHANGE=1; shift ;;
		--flip-preview) FLIP=1; shift ;;
		--flip) need $# "$1"; FLIPS+=("$2"); FLIP=1; shift 2 ;;
		--flip-plan) FLIP_PLAN_ONLY=1; shift ;;
		--flip-warn-only) FLIP_WARN_ONLY=1; shift ;;
		--name) need $# "$1"; NAME=$2; shift 2 ;;
		--keep-work) KEEP_WORK=1; shift ;;
		-h|--help) usage; exit 0 ;;
		--version) echo "canary $CANARY_VERSION"; exit 0 ;;
		--) shift; break ;;
		-*) die "unknown option $1 (see --help)" ;;
		*) CONTEXT=$1; shift ;;
	esac
done

case $SBOM in syft|db|none) ;; *) die "--sbom must be syft, db or none" ;; esac
for n in "$BUILD_TIMEOUT" "$TIMEOUT" "$SETTLE" "$EXPECT_EXIT"; do
	[[ $n =~ ^[0-9]+$ ]] || die "expected a whole number, got '$n'"
done
[ -n "$COMPOSE" ] && [ -z "$SERVICE" ] && die "--compose needs --service"
[ -n "$COMPOSE" ] && [ ! -f "$COMPOSE" ] && die "compose file $COMPOSE not found"

command -v docker >/dev/null || die "docker is not installed"
command -v jq >/dev/null || die "jq is not installed"
docker info >/dev/null 2>&1 || die "cannot reach the Docker daemon"

if [ -z "$USE_IMAGE" ]; then
	[ -d "$CONTEXT" ] || die "build context $CONTEXT is not a directory"
	[ -n "$DOCKERFILE" ] || DOCKERFILE=$CONTEXT/Dockerfile
	[ -f "$DOCKERFILE" ] || die "Dockerfile $DOCKERFILE not found"
	docker buildx version >/dev/null 2>&1 || die "docker buildx is not available"
elif [ "$FLIP" = 1 ] || [ "$FLIP_PLAN_ONLY" = 1 ]; then
	[ -n "$DOCKERFILE" ] && [ -f "$DOCKERFILE" ] || die "the flip preview needs a Dockerfile (-f), it rebuilds"
fi

if [ -z "$NAME" ]; then
	if [ -n "$USE_IMAGE" ]; then
		NAME=$USE_IMAGE
	else
		NAME=$(basename "$(cd "$CONTEXT" && pwd)")
		[ "$(basename "$DOCKERFILE")" = Dockerfile ] || NAME="$NAME/$(basename "$DOCKERFILE")"
	fi
fi
SLUG=$(printf '%s' "$NAME" | tr 'A-Z' 'a-z' | tr -c 'a-z0-9' '-' | tr -s '-' | sed 's/^-*//; s/-*$//' | cut -c 1-60 | sed 's/-*$//')
[ -n "$SLUG" ] || SLUG=image
RUN_ID=$(date -u +%Y%m%d-%H%M%S)-$$
STARTED_AT=$(date -u '+%Y-%m-%d %H:%M UTC')
HOST_PLATFORM=$(docker version -f '{{.Server.Os}}/{{.Server.Arch}}' 2>/dev/null || echo linux/amd64)

mkdir -p "$STATE_DIR" || die "cannot create $STATE_DIR"
STATE_DIR=$(cd "$STATE_DIR" && pwd)
OUT=$STATE_DIR/runs/$RUN_ID
mkdir -p "$OUT"
WORK=$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/canary.XXXXXX") || die "cannot create a temporary directory"
[ -n "$PREVIOUS" ] || PREVIOUS=$STATE_DIR/last-green.json

CREATED_BUILDERS=()
COMPOSE_PROJECTS=()

cleanup() {
	local ids b p
	ids=$(docker ps -aq --filter "label=canary.run=$RUN_ID" 2>/dev/null)
	[ -n "$ids" ] && docker rm -f $ids >/dev/null 2>&1
	for p in ${COMPOSE_PROJECTS[@]+"${COMPOSE_PROJECTS[@]}"}; do
		CANARY_IMAGE=${CANARY_IMAGE:-unused} docker compose -f "$COMPOSE" -p "$p" down -v --remove-orphans >/dev/null 2>&1
	done
	for b in ${CREATED_BUILDERS[@]+"${CREATED_BUILDERS[@]}"}; do
		docker buildx rm "$b" >/dev/null 2>&1
	done
	if [ "$KEEP_WORK" = 1 ]; then say "kept $WORK"; else rm -rf "$WORK"; fi
}
trap cleanup EXIT
trap 'exit 130' INT TERM

# ----------------------------------------------------------------- helpers

fmt_secs() {
	local s=$1
	if [ "$s" -ge 60 ]; then printf '%d min %d s' $((s / 60)) $((s % 60)); else printf '%d s' "$s"; fi
}

# Table cells and inline code: no pipes, no backticks, one line.
cell() { printf '%s' "$1" | tr '\n\t' '  ' | sed 's/|/\\|/g; s/`/'"'"'/g'; }

put() { printf '%s\t%s\n' "$3" "$4" > "$1/$2.result"; }
status_of() { [ -f "$1/$2.result" ] && cut -f1 "$1/$2.result" | head -n 1 || echo skip; }
detail_of() { [ -f "$1/$2.result" ] && cut -f2- "$1/$2.result" | head -n 1 || true; }

variant_failed() {
	local c
	for c in build elf start; do
		[ "$(status_of "$1" "$c")" = fail ] && return 0
	done
	return 1
}

prepare_helper() {
	mkdir -p "$WORK/helper"
	if ! docker image inspect "$HELPER_IMAGE" >/dev/null 2>&1; then
		say "pulling $HELPER_IMAGE"
		docker pull -q "$HELPER_IMAGE" >/dev/null 2>&1 || die "cannot pull $HELPER_IMAGE"
	fi
	local cid
	cid=$(docker create "$HELPER_IMAGE" 2>/dev/null) || die "cannot create a container from $HELPER_IMAGE"
	docker cp -q "$cid:/bin/busybox" "$WORK/helper/busybox" >/dev/null 2>&1 || { docker rm -f "$cid" >/dev/null; die "cannot copy busybox out of $HELPER_IMAGE"; }
	docker rm -f "$cid" >/dev/null
	chmod 755 "$WORK/helper/busybox"
	cp "$LIB/inspect.sh" "$WORK/helper/inspect.sh"
}

# ----------------------------------------------------------------- build

build_image() {
	local dir=$1 df=$2 tag=$3 b start rc a
	local -a dopts=() args=()
	if [ -n "$BUILDER" ]; then
		b=$BUILDER
		say "pruning exec cache mounts on builder $b"
		if docker buildx prune --builder "$b" --filter type=exec.cachemount --force >"$dir/prune.log" 2>&1; then
			echo "builder $b (existing; its RUN --mount=type=cache contents were pruned first)" >"$dir/builder.txt"
		else
			echo "builder $b (existing; pruning its cache mounts FAILED, see prune.log)" >"$dir/builder.txt"
		fi
	else
		b="$PREFIX-$RUN_ID-$(basename "$dir")"
		if [ -n "$CPUS" ]; then
			dopts+=(--driver-opt cpu-period=100000 --driver-opt "cpu-quota=$(awk -v c="$CPUS" 'BEGIN { printf "%d", c * 100000 }')")
		fi
		[ -n "$MEMORY" ] && dopts+=(--driver-opt "memory=$MEMORY")
		[ -n "$BUILDKIT_IMAGE" ] && dopts+=(--driver-opt "image=$BUILDKIT_IMAGE")
		if [ -n "$MIRROR" ]; then
			printf '[registry."docker.io"]\n  mirrors = ["%s"]\n' "$MIRROR" >"$WORK/buildkitd.toml"
			dopts+=(--buildkitd-config "$WORK/buildkitd.toml")
		fi
		say "creating builder $b"
		if ! docker buildx create --name "$b" --driver docker-container ${dopts[@]+"${dopts[@]}"} --bootstrap >"$dir/builder.log" 2>&1; then
			cat "$dir/builder.log" >&2
			die "cannot create a buildx builder"
		fi
		CREATED_BUILDERS+=("$b")
		echo "new builder $b, BuildKit $(docker buildx inspect "$b" 2>/dev/null | awk '/BuildKit version/ { print $NF; exit }')${MIRROR:+, Docker Hub through $MIRROR}, removed after the build" >"$dir/builder.txt"
	fi
	args=(buildx build --builder "$b" --no-cache --pull --progress=plain --load -t "$tag" -f "$df")
	[ -n "$TARGET" ] && args+=(--target "$TARGET")
	[ -n "$PLATFORM" ] && args+=(--platform "$PLATFORM")
	for a in ${BUILD_ARGS[@]+"${BUILD_ARGS[@]}"}; do args+=(--build-arg "$a"); done
	args+=("$CONTEXT")
	say "building $df as $tag"
	start=$(date +%s)
	timeout "$BUILD_TIMEOUT" docker "${args[@]}" >"$dir/build.log" 2>&1
	rc=$?
	echo $(($(date +%s) - start)) >"$dir/build.secs"
	if [ -z "$BUILDER" ]; then
		docker buildx rm "$b" >/dev/null 2>&1
		local keep=() x
		for x in "${CREATED_BUILDERS[@]}"; do [ "$x" = "$b" ] || keep+=("$x"); done
		CREATED_BUILDERS=(${keep[@]+"${keep[@]}"})
	fi
	return $rc
}

# The failing step and its output, from BuildKit's plain progress log.
build_failure() {
	awk '
		/^------$/ { if (inblk) { last = blk; blk = ""; inblk = 0 } else { inblk = 1; blk = "" }; next }
		inblk { blk = blk $0 "\n"; next }
		/^ERROR: / { err = $0 }
		END { printf "%s", last; if (err != "") print err }' "$1" | tail -n 25
}

# ----------------------------------------------------------------- shared libraries

inspect_image() {
	local dir=$1 image=$2 cid rc modes=elf,pkg
	[ "$DO_ELF" = 1 ] || modes=pkg
	# shellcheck disable=SC2086
	cid=$(docker create --network none --user 0:0 --label "canary.run=$RUN_ID" \
		--entrypoint /.canary/busybox "$image" sh /.canary/inspect.sh "$modes" "$ELF_EXCLUDE" $ELF_PATHS 2>"$dir/inspect.err") || return 2
	if ! docker cp -q "$WORK/helper/." "$cid:/.canary" >>"$dir/inspect.err" 2>&1; then
		docker rm -f "$cid" >/dev/null 2>&1
		return 2
	fi
	timeout "$SCAN_TIMEOUT" docker start -a "$cid" >"$dir/inspect.tsv" 2>>"$dir/inspect.err"
	rc=$?
	docker rm -f "$cid" >/dev/null 2>&1
	grep '^ELF' "$dir/inspect.tsv" | cut -f2- >"$dir/elf.tsv"
	return $rc
}

elf_check() {
	local dir=$1 image=$2 n fails warns loader rc
	if [ "$DO_ELF" != 1 ]; then
		inspect_image "$dir" "$image" >/dev/null 2>&1
		put "$dir" elf skip "not run (--no-elf)"
		return
	fi
	say "checking shared libraries in $image"
	inspect_image "$dir" "$image"
	rc=$?
	if [ "$rc" -ne 0 ] || ! grep -q '^DONE' "$dir/inspect.tsv"; then
		put "$dir" elf fail "the scan did not finish (exit $rc): $(head -n 1 "$dir/inspect.err" 2>/dev/null)"
		return
	fi
	n=$(awk -F'\t' '$1 == "DONE" { print $2 }' "$dir/inspect.tsv")
	loader=$(awk -F'\t' '$1 == "LOADER" { printf "%s%s", (s ? ", " : ""), $3; s = 1 }' "$dir/inspect.tsv")
	echo "${loader:-none}" >"$dir/loader.txt"
	local fail_re='^(missing|nointerp)$'
	[ "$STRICT_LIBS" = 1 ] && fail_re='^(missing|nointerp|libmissing|noloader)$'
	fails=$(awk -F'\t' -v re="$fail_re" '$1 ~ re' "$dir/elf.tsv" | wc -l)
	warns=$(awk -F'\t' -v re="$fail_re" '$1 !~ re && $1 ~ /^(libmissing|noloader|unchecked)$/' "$dir/elf.tsv" | wc -l)
	if [ "$fails" -gt 0 ]; then
		if [ "$fails" = 1 ]; then put "$dir" elf fail "1 of $n ELF files cannot load"
		else put "$dir" elf fail "$fails of $n ELF files cannot load"; fi
	elif [ "$warns" -gt 0 ]; then
		put "$dir" elf pass "$n ELF files, executables resolve; $warns shared objects with notes"
	else
		put "$dir" elf pass "$n ELF files resolve"
	fi
}

# ----------------------------------------------------------------- start

url_ready() {
	docker run --rm --label "canary.run=$RUN_ID" --network "container:$1" "$HELPER_IMAGE" \
		wget -q -T 3 -O /dev/null "$READY_URL" >/dev/null 2>"$2/url.err"
}

start_check() {
	local dir=$1 image=$2 label mode cid name started now state code proj
	local -a args=() smoke=()
	label=$(basename "$dir")
	if [ "$DO_START" != 1 ]; then put "$dir" start skip "not run (--no-start)"; return; fi
	if [ -n "$READY_URL" ]; then mode=url
	elif [ -n "$READY_LOG" ]; then mode=log
	elif [ "$SMOKE_SET" = 1 ] && [ -z "$COMPOSE" ]; then mode=exit
	else mode=settle
	fi
	echo "$mode" >"$dir/start.mode"
	if [ "$SMOKE_SET" = 1 ] && [ -n "$SMOKE" ]; then
		# split like a shell would, without evaluating anything; the -- keeps
		# uutils printf from reading a leading --help or --version as an option
		mapfile -d '' smoke < <(printf '%s' "$SMOKE" | xargs printf -- '%s\0')
	fi
	if [ -n "$COMPOSE" ]; then
		proj=$(printf '%s' "${PROJECT:-$PREFIX-$RUN_ID}-$label" | tr 'A-Z' 'a-z' | tr -c 'a-z0-9_-' '-')
		COMPOSE_PROJECTS+=("$proj")
		say "starting compose project $proj"
		if ! CANARY_IMAGE=$image docker compose -f "$COMPOSE" -p "$proj" up -d >"$dir/compose-up.log" 2>&1; then
			put "$dir" start fail "docker compose up failed: $(tail -n 1 "$dir/compose-up.log")"
			CANARY_IMAGE=$image docker compose -f "$COMPOSE" -p "$proj" down -v --remove-orphans >/dev/null 2>&1
			return
		fi
		cid=$(CANARY_IMAGE=$image docker compose -f "$COMPOSE" -p "$proj" ps -a -q "$SERVICE" 2>/dev/null | head -n 1)
		[ -n "$cid" ] || { put "$dir" start fail "compose service $SERVICE has no container"; return; }
	else
		name="$PREFIX-$RUN_ID-$label"
		args=(run -d --name "$name" --label "canary.run=$RUN_ID")
		[ -n "$ENTRYPOINT" ] && args+=(--entrypoint "$ENTRYPOINT")
		args+=(${RUN_ARGS[@]+"${RUN_ARGS[@]}"} "$image" ${smoke[@]+"${smoke[@]}"})
		say "starting $image"
		if ! cid=$(docker "${args[@]}" 2>"$dir/start.err"); then
			put "$dir" start fail "docker run failed: $(head -n 1 "$dir/start.err")"
			return
		fi
	fi
	started=$(date +%s)
	local result="" detail=""
	while :; do
		now=$(date +%s)
		read -r state code < <(docker inspect -f '{{.State.Status}} {{.State.ExitCode}}' "$cid" 2>/dev/null || echo "gone 255")
		case $mode in
			url)
				if [ "$state" = running ] && url_ready "$cid" "$dir"; then
					result=pass; detail="$READY_URL answered after $(($(date +%s) - started)) s"
				fi ;;
			log)
				if docker logs "$cid" 2>&1 | grep -Eq -- "$READY_LOG"; then
					result=pass; detail="log line /$READY_LOG/ after $(($(date +%s) - started)) s"
				fi ;;
		esac
		[ -n "$result" ] && break
		if [ "$state" != running ] && [ "$state" != created ] && [ "$state" != restarting ]; then
			case $mode in
				exit)
					if [ "$code" = "$EXPECT_EXIT" ]; then result=pass; detail="exited $code"
					else result=fail; detail="exited $code, expected $EXPECT_EXIT"; fi ;;
				settle)
					if [ "$code" = 0 ]; then result=pass; detail="default command exited 0"
					else result=fail; detail="default command exited $code after $((now - started)) s"; fi ;;
				url) result=fail; detail="exited $code before $READY_URL answered" ;;
				log) result=fail; detail="exited $code before a line matched /$READY_LOG/" ;;
			esac
			break
		fi
		if [ "$mode" = settle ] && [ $((now - started)) -ge "$SETTLE" ]; then
			result=pass; detail="default command still running after $SETTLE s"
			break
		fi
		if [ $((now - started)) -ge "$TIMEOUT" ]; then
			result=fail
			case $mode in
				url) detail="$READY_URL did not answer 2xx within $TIMEOUT s ($(tail -n 1 "$dir/url.err" 2>/dev/null))" ;;
				log) detail="no line matched /$READY_LOG/ within $TIMEOUT s" ;;
				*) detail="still running after $TIMEOUT s" ;;
			esac
			break
		fi
		sleep 1
	done
	docker logs "$cid" >"$dir/start.log" 2>&1
	if [ -n "$COMPOSE" ]; then
		CANARY_IMAGE=$image docker compose -f "$COMPOSE" -p "$proj" logs --no-color >"$dir/compose.log" 2>&1
		CANARY_IMAGE=$image docker compose -f "$COMPOSE" -p "$proj" down -v --remove-orphans >/dev/null 2>&1
	else
		docker rm -f "$cid" >/dev/null 2>&1
	fi
	put "$dir" start "$result" "$detail"
}

# ----------------------------------------------------------------- packages

run_syft() {
	local image=$1 out=$2 sock=/var/run/docker.sock
	case ${DOCKER_HOST:-} in
		unix://*) sock=${DOCKER_HOST#unix://} ;;
		'') ;;
		*) return 1 ;;
	esac
	[ -S "$sock" ] || return 1
	timeout 900 docker run --rm --label "canary.run=$RUN_ID" -v "$sock:/var/run/docker.sock" \
		"$SYFT_IMAGE" "docker:$image" -o syft-json -q >"$out"
}

collect_packages() {
	local dir=$1 image=$2 src=none digest
	: >"$dir/runtime.tsv"
	if [ "$SBOM" = syft ]; then
		say "listing packages with syft"
		if run_syft "$image" "$dir/syft.json" 2>"$dir/syft.err" && jq -e '.artifacts' "$dir/syft.json" >/dev/null 2>&1; then
			jq -r '.artifacts[] | ["runtime", "", .type, .name, .version] | @tsv' "$dir/syft.json" | sort -u >"$dir/runtime.tsv"
			src="syft ($SYFT_IMAGE)"
		else
			say "syft did not run; using the image's package database"
		fi
	fi
	if [ "$src" = none ] && [ "$SBOM" != none ]; then
		awk -F'\t' '$1 == "PKG" { print "runtime\t\t" $2 "\t" $3 "\t" $4 }' "$dir/inspect.tsv" 2>/dev/null | sort -u >"$dir/runtime.tsv"
		src="package database in the image"
	fi
	: >"$dir/build-pkgs.tsv"
	[ -f "$dir/build.log" ] && awk -f "$LIB/buildlog.awk" "$dir/build.log" >"$dir/build-pkgs.tsv"
	digest=$(docker image inspect -f '{{.Id}}' "$image" 2>/dev/null)
	cat "$dir/build-pkgs.tsv" "$dir/runtime.tsv" | jq -R -s \
		--arg run "$RUN_ID" --arg image "$image" --arg digest "$digest" --arg src "$src" --arg name "$NAME" \
		--arg created "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '
		{schema: "canary-packages/1", name: $name, run: $run, created: $created, image: $image,
		 digest: $digest, source: $src,
		 packages: (split("\n") | map(select(length > 0) | split("\t")
			| {scope: .[0], stage: .[1], type: .[2], name: .[3], version: (.[4] // "")}
			| if .scope == "base" then . + {family: "from"} else . end))}' >"$dir/packages.json"
	echo "$src" >"$dir/packages.source"
}

pkg_diff() { jq -n --slurpfile old "$1" --slurpfile new "$2" -f "$LIB/pkgdiff.jq" >"$3"; }

# ----------------------------------------------------------------- one variant

check_variant() {
	local dir=$1 df=$2 tag=$3 secs size
	mkdir -p "$dir"
	if [ -n "$USE_IMAGE" ] && [ "$(basename "$dir")" = current ]; then
		tag=$USE_IMAGE
		docker image inspect "$tag" >/dev/null 2>&1 || docker pull -q "$tag" >/dev/null 2>&1 || die "cannot find or pull $tag"
		put "$dir" build skip "existing image $tag"
	else
		if build_image "$dir" "$df" "$tag"; then
			secs=$(cat "$dir/build.secs")
			size=$(docker image ls --format '{{.Size}}' "$tag" 2>/dev/null | head -n 1)
			put "$dir" build pass "$(fmt_secs "$secs"), $tag, $size"
		else
			secs=$(cat "$dir/build.secs")
			put "$dir" build fail "failed after $(fmt_secs "$secs")"
			build_failure "$dir/build.log" >"$dir/build.failure"
			put "$dir" elf skip "not run, the build failed"
			put "$dir" start skip "not run, the build failed"
			awk -f "$LIB/buildlog.awk" "$dir/build.log" >"$dir/build-pkgs.tsv"
			return
		fi
	fi
	echo "$tag" >"$dir/image.txt"
	elf_check "$dir" "$tag"
	start_check "$dir" "$tag"
	collect_packages "$dir" "$tag"
}

# ----------------------------------------------------------------- flip preview

# Where to look a reference up: Docker Hub references go to the mirror when
# one is set.
lookup_ref() {
	local r=$1 first
	if [ -n "$MIRROR" ]; then
		first=${r%%/*}
		if [[ $r != */* ]]; then
			r="$MIRROR/library/$r"
		elif [ "$first" = docker.io ] || [ "$first" = index.docker.io ]; then
			r=${r#*/}
			[[ $r == */* ]] || r="library/$r"
			r="$MIRROR/$r"
		elif [[ $first != *.* && $first != *:* && $first != localhost ]]; then
			r="$MIRROR/$r"
		fi
	fi
	printf '%s' "$r"
}

# A failed lookup gets a hint for what usually fixes it.
lookup_hint() {
	case ${1,,} in
		*429*|*toomanyrequests*|*'too many requests'*)
			if [ -n "$MIRROR" ]; then
				printf '%s (rate limited; run again later or log in)' "$1"
			else
				printf '%s (rate limited; log in with docker login, or pass --registry-mirror mirror.gcr.io for Docker Hub images)' "$1"
			fi ;;
		*401*|*403*|*unauthorized*|*denied*|*authorize*) printf '%s (log in to that registry with docker login)' "$1" ;;
		*) printf '%s' "$1" ;;
	esac
}

# Registry lookups go through imagetools and are cached; callers read REG_OUT,
# REG_STATE and REG_ERR (no subshell, so the cache survives). REG_STATE is ok,
# missing (the registry says the reference does not exist) or error (anything
# else: a rate limit, a login error, a network error), with the message in
# REG_ERR. Only missing may be read as "this tag does not exist".
declare -A REG_CACHE=() REG_CACHE_STATE=() REG_CACHE_ERR=()
REG_OUT=
REG_STATE=
REG_ERR=
registry_inspect() {
	local ref=$1 what=$2 key="$2 $1" out rc err
	if [ -z "${REG_CACHE_STATE[$key]+set}" ]; then
		out=$(docker buildx imagetools inspect --format "{{json .$what}}" "$(lookup_ref "$ref")" 2>"$WORK/imagetools.err")
		rc=$?
		err=$(sed -n 's/^ERROR: //p' "$WORK/imagetools.err" | head -n 1)
		[ -n "$err" ] || err=$(grep -v '^[[:space:]]*$' "$WORK/imagetools.err" | tail -n 1)
		err=$(printf '%s' "$err" | tr '\t\r' '  ' | cut -c 1-300)
		if [ "$rc" = 0 ] && [ -n "$out" ]; then
			REG_CACHE[$key]=$out
			REG_CACHE_STATE[$key]=ok
			REG_CACHE_ERR[$key]=
		elif printf '%s' "$err" | grep -qiE ': not found$|manifest unknown|name unknown'; then
			REG_CACHE[$key]=
			REG_CACHE_STATE[$key]=missing
			REG_CACHE_ERR[$key]=
		else
			REG_CACHE[$key]=
			REG_CACHE_STATE[$key]=error
			REG_CACHE_ERR[$key]=$(lookup_hint "${err:-docker buildx imagetools inspect exited $rc}")
		fi
	fi
	REG_OUT=${REG_CACHE[$key]}
	REG_STATE=${REG_CACHE_STATE[$key]}
	REG_ERR=${REG_CACHE_ERR[$key]}
}

registry_digest() {
	registry_inspect "$1" Manifest
	[ "$REG_STATE" = ok ] || return 0
	REG_OUT=$(printf '%s' "$REG_OUT" | jq -r '.digest // empty' 2>/dev/null)
	if [ -z "$REG_OUT" ]; then
		REG_STATE=error
		REG_ERR="the registry answer for $1 has no digest"
	fi
}

# PYTHON_VERSION in the image config of a python reference, for this host's
# platform; REG_OUT is empty when the image does not set it.
python_version() {
	registry_inspect "$1" Image
	[ "$REG_STATE" = ok ] || { REG_OUT=; return 0; }
	REG_OUT=$(printf '%s' "$REG_OUT" | jq -r --arg p "$HOST_PLATFORM" '
		(if has("config") then . else (.[$p] // (to_entries[0].value)) end)
		| .config.Env[]? | select(startswith("PYTHON_VERSION=")) | ltrimstr("PYTHON_VERSION=")' 2>/dev/null | head -n 1)
}

# Results of the flip rules: FLIP_TO (target reference) and FLIP_NOTE, or
# FLIP_ERR when a registry lookup failed.
FLIP_TO=
FLIP_NOTE=
FLIP_ERR=

# Newest python:3.N tag for a variant suffix ("" or "-slim" and so on). When
# the next minor is not tagged yet, its 3.(N+1)-rc tag is used only once it
# carries a release candidate: before that it holds an alpha or a beta, which
# few packages publish wheels for.
python_next() {
	local sfx=$1 cur minor n rc
	python_version "python:3$sfx"
	if [ "$REG_STATE" = error ]; then
		FLIP_ERR="python:3$sfx: $REG_ERR"
		return 1
	fi
	cur=$REG_OUT
	minor=$(printf '%s' "$cur" | cut -d. -f2)
	if ! [[ $minor =~ ^[0-9]+$ ]]; then
		FLIP_NOTE="could not read the Python version of python:3$sfx"
		return 1
	fi
	n=$minor
	while :; do
		registry_digest "python:3.$((n + 1))$sfx"
		case $REG_STATE in
			ok) n=$((n + 1)) ;;
			missing) break ;;
			*) FLIP_ERR="python:3.$((n + 1))$sfx: $REG_ERR"; return 1 ;;
		esac
	done
	if [ "$n" -gt "$minor" ]; then
		FLIP_TO="python:3.$n$sfx"
		return 0
	fi
	rc="python:3.$((n + 1))-rc$sfx"
	python_version "$rc"
	case $REG_STATE in
		error)
			FLIP_ERR="$rc: $REG_ERR"
			return 1 ;;
		ok)
			if [[ $REG_OUT == *rc* ]]; then
				FLIP_TO=$rc
				FLIP_NOTE="python:3.$((n + 1))$sfx is not tagged yet; using the release candidate tag ($REG_OUT)"
				return 0
			fi
			if [ -n "$REG_OUT" ]; then
				FLIP_NOTE="python:3$sfx is the newest 3.x release ($cur); $rc holds $REG_OUT, not a release candidate yet"
				return 1
			fi ;;
	esac
	FLIP_NOTE="python:3$sfx is already the newest 3.x ($cur)"
	return 1
}

# repo and tag of an image reference, with docker.io/library/ dropped
split_ref() {
	local r=$1
	r=${r#docker.io/}; r=${r#index.docker.io/}; r=${r#library/}
	REF_DIGEST=
	case $r in *@*) REF_DIGEST=${r#*@}; r=${r%%@*} ;; esac
	REF_REPO=$r; REF_TAG=
	local last=${r##*/}
	case $last in *:*) REF_TAG=${last##*:}; REF_REPO=${r%:*} ;; esac
}

builtin_flip() {
	local repo=$1 tag=$2
	FLIP_TO=
	FLIP_NOTE=
	FLIP_ERR=
	case $repo in
		node)
			case $tag in
				lts) FLIP_TO=node:26 ;;
				lts-*) FLIP_TO="node:26-${tag#lts-}" ;;
				*) return 1 ;;
			esac ;;
		ubuntu)
			case $tag in
				''|latest) FLIP_TO=ubuntu:26.04 ;;
				*) return 1 ;;
			esac ;;
		python)
			case $tag in
				''|latest|3) python_next "" ;;
				3-*) python_next "-${tag#3-}" ;;
				slim|alpine|alpine3*|bookworm|trixie|slim-*) python_next "-$tag" ;;
				*) return 1 ;;
			esac ;;
		*) return 1 ;;
	esac
}

custom_flip() {
	local ref=$1 f from want
	FLIP_TO=
	FLIP_NOTE=
	split_ref "$ref"
	want="$REF_REPO${REF_TAG:+:$REF_TAG}${REF_DIGEST:+@$REF_DIGEST}"
	for f in ${FLIPS[@]+"${FLIPS[@]}"}; do
		from=${f%%=*}
		split_ref "$from"
		if [ "$REF_REPO${REF_TAG:+:$REF_TAG}${REF_DIGEST:+@$REF_DIGEST}" = "$want" ]; then
			FLIP_TO=${f#*=}
			FLIP_NOTE="your --flip"
			return 0
		fi
	done
	return 1
}

# Writes flip-plan.tsv: line, FROM reference, preview reference, status, note.
# status: flip, same (already the same image), missing (target tag not found),
# error (a registry lookup failed), skip (stage, scratch, build argument or
# digest pin), none (no rule).
plan_flips() {
	local df=$1 plan=$2 ln=0 line ref to note status cur new i
	local -a tok=()
	local -A stages=()
	: >"$plan"
	while IFS= read -r line || [ -n "$line" ]; do
		ln=$((ln + 1))
		[[ $line =~ ^[[:space:]]*[Ff][Rr][Oo][Mm][[:space:]] ]] || continue
		read -r -a tok <<<"$line"
		i=1
		while [ "$i" -lt "${#tok[@]}" ] && [[ ${tok[$i]} == --* ]]; do i=$((i + 1)); done
		ref=${tok[$i]:-}
		[ -n "$ref" ] || continue
		to= note= status=
		if [ -n "${stages[${ref,,}]+set}" ]; then
			status=skip note="earlier build stage"
		elif [ "${ref,,}" = scratch ]; then
			status=skip note="scratch"
		elif [[ $ref == *'$'* ]]; then
			status=skip note="set by a build argument; pass --build-arg to preview it"
		elif custom_flip "$ref"; then
			status=flip to=$FLIP_TO note=$FLIP_NOTE
		else
			split_ref "$ref"
			if [ -n "$REF_DIGEST" ]; then
				status=skip note="pinned by digest; the tag moving does not reach it"
			elif builtin_flip "$REF_REPO" "$REF_TAG"; then
				status=flip to=$FLIP_TO note=$FLIP_NOTE
			elif [ -n "$FLIP_ERR" ]; then
				status=error note=$FLIP_ERR
			else
				status=none note=$FLIP_NOTE
			fi
		fi
		if [ $((i + 2)) -lt "${#tok[@]}" ] && [ "${tok[$((i + 1))],,}" = as ]; then
			stages[${tok[$((i + 2))],,}]=1
		fi
		if [ "$status" = flip ]; then
			registry_digest "$to"
			new=$REG_OUT
			if [ "$REG_STATE" = missing ] && [[ $to =~ -alpine3\.[0-9]+ ]]; then
				# a variant pinned to an Alpine release the new tag line does not have
				local alt=${to/${BASH_REMATCH[0]}/-alpine}
				registry_digest "$alt"
				case $REG_STATE in
					ok)
						note="$to does not exist; using $alt${note:+; $note}"
						to=$alt
						new=$REG_OUT ;;
					error) status=error note="$alt: $REG_ERR" ;;
					*) REG_STATE=missing ;;
				esac
			fi
			if [ "$status" = flip ]; then
				case $REG_STATE in
					missing) status=missing note="$to was not found in the registry${note:+; $note}" ;;
					error) status=error note="$to: $REG_ERR" ;;
					*)
						registry_digest "$ref"
						cur=$REG_OUT
						if [ "$REG_STATE" = ok ] && [ "$cur" = "$new" ]; then
							status=same note="already the same image (${new:7:12})${note:+; $note}"
						elif [ "$REG_STATE" = error ]; then
							note="${note:+$note; }could not compare with $ref: $REG_ERR"
						fi ;;
				esac
			fi
		fi
		[ "$status" = error ] && say "registry lookup failed: $note"
		printf '%s\t%s\t%s\t%s\t%s\n' "$ln" "$ref" "${to:--}" "$status" "${note:--}" >>"$plan"
	done <"$df"
}

write_flipped() {
	local df=$1 plan=$2 out=$3
	awk -F'\t' 'NR == FNR { if ($4 == "flip") { from[$1] = $2; to[$1] = $3 }; next }
		(FNR in from) { i = index($0, from[FNR]); if (i) $0 = substr($0, 1, i - 1) to[FNR] substr($0, i + length(from[FNR])) }
		{ print }' "$plan" "$df" >"$out"
	if [ -f "$df.dockerignore" ]; then cp "$df.dockerignore" "$out.dockerignore"; fi
}

print_plan() {
	local plan=$1
	echo "| Line | FROM | Preview | Status | Note |"
	echo "|---|---|---|---|---|"
	while IFS=$'\t' read -r ln from to status note; do
		printf '| %s | `%s` | %s | %s | %s |\n' "$ln" "$(cell "$from")" \
			"$([ "$to" = - ] && echo - || printf '`%s`' "$(cell "$to")")" "$status" "$(cell "${note/#-/}")"
	done <"$plan"
}

# ----------------------------------------------------------------- summary

check_row() {
	local dir=$1 check=$2 label=$3 s d
	s=$(status_of "$dir" "$check")
	d=$(detail_of "$dir" "$check")
	[ "$s" = fail ] && s="**FAIL**"
	printf '| %s | %s | %s |\n' "$label" "$s" "$(cell "$d")"
}

elf_section() {
	local dir=$1 title=$2 n fail_re loader
	[ -f "$dir/elf.tsv" ] || return 0
	[ "$(status_of "$dir" elf)" = skip ] && return 0
	n=$(awk -F'\t' '$1 == "DONE" { print $2 }' "$dir/inspect.tsv")
	loader=$(cat "$dir/loader.txt" 2>/dev/null)
	fail_re='^(missing|nointerp)$'
	[ "$STRICT_LIBS" = 1 ] && fail_re='^(missing|nointerp|libmissing|noloader)$'
	echo
	echo "### $title"
	echo
	printf '%s ELF files under `%s`, loader `%s`: %s.\n' "${n:-0}" "$(cell "$ELF_PATHS")" "$(cell "$loader")" \
		"$(awk -F'\t' '{ c[$1]++ } END { s = ""; split("ok static missing nointerp libmissing foreign otherarch object noloader unchecked", o, " ");
			one["ok"] = "resolves"; many["ok"] = "resolve"; one["static"] = many["static"] = "static";
			one["missing"] = "executable with missing libraries"; many["missing"] = "executables with missing libraries";
			one["nointerp"] = many["nointerp"] = "missing an interpreter";
			one["libmissing"] = "shared object with missing libraries"; many["libmissing"] = "shared objects with missing libraries";
			one["foreign"] = many["foreign"] = "built for the other C library (skipped)";
			one["otherarch"] = many["otherarch"] = "for another CPU (skipped)";
			one["object"] = "object file (skipped)"; many["object"] = "object files (skipped)";
			one["noloader"] = many["noloader"] = "dynamic, but the image has no loader";
			one["unchecked"] = many["unchecked"] = "could not be listed";
			for (i = 1; i <= 10; i++) if (c[o[i]]) s = s (s == "" ? "" : ", ") c[o[i]] " " (c[o[i]] == 1 ? one[o[i]] : many[o[i]]); print s }' "$dir/elf.tsv")"
	if awk -F'\t' -v re="$fail_re" '$1 ~ re { f = 1 } END { exit !f }' "$dir/elf.tsv"; then
		echo
		echo "Cannot load:"
		echo
		awk -F'\t' -v re="$fail_re" '$1 ~ re {
				if ($1 == "nointerp") printf "- `%s`: interpreter `%s` is not in the image\n", $2, $3
				else printf "- `%s`: %s\n", $2, $3
			}' "$dir/elf.tsv" | head -n 20
	fi
	if awk -F'\t' -v re="$fail_re" '$1 !~ re && $1 ~ /^(libmissing|noloader|unchecked)$/ { f = 1 } END { exit !f }' "$dir/elf.tsv"; then
		echo
		echo "<details><summary>Notes (do not fail the check without --strict-libs)</summary>"
		echo
		awk -F'\t' -v re="$fail_re" '$1 !~ re && $1 ~ /^(libmissing|noloader|unchecked)$/ { printf "- %s `%s`: %s\n", $1, $2, $3 }' "$dir/elf.tsv" | head -n 20
		echo
		echo "</details>"
	fi
}

start_section() {
	local dir=$1 title=$2 s
	s=$(status_of "$dir" start)
	[ "$s" = skip ] && return 0
	echo
	echo "### $title"
	echo
	case $(cat "$dir/start.mode" 2>/dev/null) in
		url) printf 'Ready check: `%s` answers 2xx (fetched inside the container), within %s s.' "$(cell "$READY_URL")" "$TIMEOUT" ;;
		log) printf 'Ready check: a log line matches `%s`, within %s s.' "$(cell "$READY_LOG")" "$TIMEOUT" ;;
		exit) printf 'Smoke command `%s` exits %s, within %s s.' "$(cell "$SMOKE")" "$EXPECT_EXIT" "$TIMEOUT" ;;
		*) printf 'No smoke command given: the default command must keep running for %s s or exit 0.' "$SETTLE" ;;
	esac
	[ -n "$COMPOSE" ] && printf ' Started with `%s`, service `%s`.' "$(cell "$COMPOSE")" "$(cell "$SERVICE")"
	echo " Result: $(detail_of "$dir" start)."
	if [ "$s" = fail ] && [ -s "$dir/start.log" ]; then
		echo
		echo "Last log lines:"
		echo
		echo '```'
		tail -n 15 "$dir/start.log" | sed 's/\x1b\[[0-9;]*m//g' | cut -c 1-300
		echo '```'
	fi
}

build_section() {
	local dir=$1 title=$2
	[ "$(status_of "$dir" build)" = fail ] || return 0
	echo
	echo "### $title"
	echo
	echo '```'
	if [ -s "$dir/build.failure" ]; then cat "$dir/build.failure"; else tail -n 20 "$dir/build.log"; fi
	echo '```'
}

diff_table() {
	local diff=$1 max=${2:-30}
	jq -r --argjson max "$max" '
		def where: if .scope == "base" then "base image" + (if .stage != "" then " of `" + .stage + "`" else "" end)
			elif .scope == "build" then "build" + (if .stage != "" then ", stage `" + .stage + "`" else "" end) + ", " + .type
			else "image, " + .type end;
		def c: if . == "" then "-" else gsub("\\|"; "\\|") end;
		.changes as $c
		| if ($c | length) == 0 then "No changes." else
			(["| Where | Package | Change | Before | After |", "|---|---|---|---|---|"]
			+ ($c[:$max] | map("| " + where + " | " + .family + " | " + .change + " | " + (.before | c) + " | " + (.after | c) + " |"))
			+ (if ($c | length) > $max then ["", "And \(($c | length) - $max) more in the JSON diff."] else [] end))
			| join("\n") end' "$diff"
}

counts_text() {
	jq -r '.counts | "\(.changed) changed, \(.added) added, \(.removed) removed"' "$1"
}

# ----------------------------------------------------------------- main

plan_failed() { awk -F'\t' '$4 == "error" { f = 1 } END { exit !f }' "$1"; }

if [ "$FLIP_PLAN_ONLY" = 1 ]; then
	plan_flips "$DOCKERFILE" "$OUT/flip-plan.tsv"
	print_plan "$OUT/flip-plan.tsv"
	plan_failed "$OUT/flip-plan.tsv" && exit 2
	exit 0
fi

prepare_helper
CUR=$OUT/current
DEFAULT_TAG="$(printf '%s' "$PREFIX" | tr 'A-Z' 'a-z')/$SLUG:$RUN_ID"
check_variant "$CUR" "$DOCKERFILE" "${TAG:-$DEFAULT_TAG}"

# packages against the previous green run
PREV_STATE=none
if [ -f "$CUR/packages.json" ]; then
	if [ -f "$PREVIOUS" ]; then
		if pkg_diff "$PREVIOUS" "$CUR/packages.json" "$OUT/diff-previous.json"; then
			PREV_STATE=diff
			put "$CUR" packages info "$(counts_text "$OUT/diff-previous.json") since $(jq -r '.run // "the previous run"' "$PREVIOUS")"
		else
			put "$CUR" packages info "could not read the previous list $PREVIOUS"
		fi
	else
		PREV_STATE=first
		put "$CUR" packages info "$(jq '.packages | length' "$CUR/packages.json") entries listed; no previous list to compare"
	fi
fi

# flip preview
FLIP_STATE=off
FLIPDIR=$OUT/flip
if [ "$FLIP" = 1 ]; then
	mkdir -p "$FLIPDIR"
	say "planning the flip preview"
	plan_flips "$DOCKERFILE" "$FLIPDIR/plan.tsv"
	if plan_failed "$FLIPDIR/plan.tsv"; then
		FLIP_STATE=error
	elif awk -F'\t' '$4 == "flip" { f = 1 } END { exit !f }' "$FLIPDIR/plan.tsv"; then
		mkdir -p "$WORK/flip"
		write_flipped "$DOCKERFILE" "$FLIPDIR/plan.tsv" "$WORK/flip/$(basename "$DOCKERFILE")"
		cp "$WORK/flip/$(basename "$DOCKERFILE")" "$FLIPDIR/Dockerfile.preview"
		FLIP_TAG="${TAG:-$DEFAULT_TAG}-flip"
		check_variant "$FLIPDIR" "$WORK/flip/$(basename "$DOCKERFILE")" "$FLIP_TAG"
		FLIP_STATE=built
		if [ -f "$CUR/packages.json" ] && [ -f "$FLIPDIR/packages.json" ]; then
			pkg_diff "$CUR/packages.json" "$FLIPDIR/packages.json" "$OUT/diff-flip.json"
		fi
	else
		FLIP_STATE=nothing
	fi
fi

# verdict
VERDICT=PASS
EXIT=0
if variant_failed "$CUR"; then
	VERDICT=FAIL
	EXIT=1
elif [ "$FLIP_STATE" = error ]; then
	VERDICT="PASS now, but the flip preview could not be planned"
	EXIT=2
elif [ "$FLIP_STATE" = built ] && variant_failed "$FLIPDIR"; then
	VERDICT="PASS now, FAIL in the flip preview"
	[ "$FLIP_WARN_ONLY" = 1 ] || EXIT=3
fi
CHANGED=0
[ -f "$OUT/diff-previous.json" ] && CHANGED=$(jq '.changes | length' "$OUT/diff-previous.json")
if [ "$EXIT" = 0 ] && [ "$FAIL_ON_CHANGE" = 1 ] && [ "$CHANGED" -gt 0 ]; then
	VERDICT="PASS, but packages changed"
	EXIT=4
fi

# summary
{
	echo "## Upgrade canary: $NAME: $VERDICT"
	echo
	if [ -n "$USE_IMAGE" ]; then
		printf 'Image `%s`, run %s, %s.\n' "$(cell "$USE_IMAGE")" "$RUN_ID" "$STARTED_AT"
	else
		printf '`%s` (context `%s`), run %s, %s. Built with `--no-cache --pull` on a %s.\n' \
			"$(cell "$DOCKERFILE")" "$(cell "$CONTEXT")" "$RUN_ID" "$STARTED_AT" "$(cat "$CUR/builder.txt" 2>/dev/null)"
	fi
	echo
	echo "| Check | Result | Detail |"
	echo "|---|---|---|"
	check_row "$CUR" build "Clean build"
	check_row "$CUR" elf "Shared libraries"
	check_row "$CUR" start "Start"
	[ -f "$CUR/packages.result" ] && check_row "$CUR" packages "Packages"
	build_section "$CUR" "Build failure"
	elf_section "$CUR" "Shared libraries"
	start_section "$CUR" "Start"
	if [ "$PREV_STATE" = diff ]; then
		echo
		printf '### Package changes since run %s\n\n' "$(jq -r '.old.run' "$OUT/diff-previous.json")"
		printf 'Previous image `%s`, now `%s`. Runtime list from %s; build stage packages from the build log.\n\n' \
			"$(cell "$(jq -r '.old.image' "$OUT/diff-previous.json")")" "$(cell "$(jq -r '.new.image' "$OUT/diff-previous.json")")" "$(cat "$CUR/packages.source" 2>/dev/null)"
		diff_table "$OUT/diff-previous.json"
	fi
	if [ "$FLIP" = 1 ]; then
		echo
		echo "### Flip preview"
		echo
		print_plan "$FLIPDIR/plan.tsv"
		if [ "$FLIP_STATE" = error ]; then
			echo
			echo "Preview not built: a registry lookup failed (see the notes), so it is not known which FROM lines move. The run exits 2 rather than passing without a preview."
		elif [ "$FLIP_STATE" = nothing ]; then
			echo
			echo "Nothing to preview: no FROM line moves to a different image."
		elif [ "$FLIP_STATE" = built ]; then
			echo
			echo "| Check | Now | Preview |"
			echo "|---|---|---|"
			for c in build:"Clean build" elf:"Shared libraries" start:"Start"; do
				k=${c%%:*}
				a=$(status_of "$CUR" "$k"); b=$(status_of "$FLIPDIR" "$k")
				[ "$a" = fail ] && a="**FAIL**"
				[ "$b" = fail ] && b="**FAIL**"
				printf '| %s | %s | %s: %s |\n' "${c#*:}" "$a" "$b" "$(cell "$(detail_of "$FLIPDIR" "$k")")"
			done
			build_section "$FLIPDIR" "Preview build failure"
			[ "$(status_of "$FLIPDIR" elf)" = fail ] && elf_section "$FLIPDIR" "Preview shared libraries"
			[ "$(status_of "$FLIPDIR" start)" = fail ] && start_section "$FLIPDIR" "Preview start"
			if [ -f "$OUT/diff-flip.json" ]; then
				echo
				printf '#### Packages, now against the preview: %s\n\n' "$(counts_text "$OUT/diff-flip.json")"
				diff_table "$OUT/diff-flip.json" 25
			elif [ -s "$FLIPDIR/build-pkgs.tsv" ] && [ -f "$CUR/packages.json" ]; then
				echo
				echo "Base images in the preview:"
				echo
				awk -F'\t' '$1 == "base" { printf "- `%s` %s\n", $4, substr($5, 1, 19) }' "$FLIPDIR/build-pkgs.tsv"
			fi
		fi
	fi
	echo
	printf 'Files: `%s`\n' "$(cell "$OUT")"
} >"$OUT/summary.md"

cat "$OUT/summary.md"
if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
	cat "$OUT/summary.md" >>"$GITHUB_STEP_SUMMARY"
fi

# state for the next run
if [ "$EXIT" != 1 ] && [ -f "$CUR/packages.json" ] && ! variant_failed "$CUR"; then
	cp "$CUR/packages.json" "$STATE_DIR/last-green.json"
fi
jq -n --arg verdict "$VERDICT" --argjson exit "$EXIT" --arg run "$RUN_ID" --arg name "$NAME" \
	--arg image "$(cat "$CUR/image.txt" 2>/dev/null)" --argjson changed "$CHANGED" --arg flip "$FLIP_STATE" \
	'{run: $run, name: $name, verdict: $verdict, exit: $exit, image: $image, packages_changed: $changed, flip: $flip}' >"$OUT/result.json"
cp "$OUT/result.json" "$STATE_DIR/last-run.json"

if [ -n "${GITHUB_OUTPUT:-}" ]; then
	result=pass
	[ "$EXIT" = 1 ] && result=fail
	[ "$EXIT" = 2 ] && result=error
	[ "$EXIT" = 3 ] && result=flip-fail
	[ "$EXIT" = 4 ] && result=changed
	[ "$EXIT" = 0 ] && [ "$FLIP_STATE" = built ] && variant_failed "$FLIPDIR" && result=flip-fail
	{
		echo "result=$result"
		echo "summary=$OUT/summary.md"
		echo "run-dir=$OUT"
		echo "image=$(cat "$CUR/image.txt" 2>/dev/null)"
		echo "changed=$CHANGED"
		echo "slug=$SLUG"
		[ -f "$STATE_DIR/last-green.json" ] && echo "last-green=$STATE_DIR/last-green.json"
	} >>"$GITHUB_OUTPUT"
fi
exit "$EXIT"
