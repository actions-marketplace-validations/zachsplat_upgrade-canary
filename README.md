# Upgrade canary

A scheduled check for container images that build green and then do not start.

`canary.sh` builds a Dockerfile the way a fresh release runner would, checks that every executable in the image can load its libraries, starts the image, and tells you which packages moved since the last green run. A preview mode rebuilds on the next value of floating base tags (`node:lts`, `ubuntu:latest`, `python:3`) before the tag moves. It needs Docker with buildx and jq, and ships as a CLI and a composite GitHub Action.

## What it checks

1. **Clean build.** Each run creates its own BuildKit builder (docker-container driver), builds with `--no-cache --pull`, and removes the builder afterwards. Nothing carries over between runs: no layer cache, no `RUN --mount=type=cache` contents, base images resolved again from the registry. With `--builder NAME` it builds on your builder instead and prunes that builder's exec cache mounts first (`docker buildx prune --filter type=exec.cachemount`).
2. **Shared libraries.** Every ELF file under the paths you choose (the whole image by default) is listed with the image's own dynamic loader: glibc's `ld-linux` in trace mode (what `ldd` does) or musl's `ld-musl --list`. An executable fails the check when a library or a symbol version is not found, or when the interpreter it names is missing, as with a musl binary in a glibc image. A static busybox is copied into the container for the scan, so images without a shell work too.
3. **Start.** Runs the image with a smoke command and checks the exit code, or waits for a log line or for a URL to answer 2xx, under a timeout. The URL is fetched from inside the container's network namespace, so no host port is published. With `--compose` it starts your compose file with the new image and checks one service.
4. **Packages.** Writes the runtime package list (syft in a container, or the image's dpkg, apk or rpm database), the packages each build stage installed (from the apk, apt and pip lines in the build log) and the digest each base image resolved to, then diffs them against the last green run. Names are compared with version numbers taken out, so `openssl-3.6-dev 3.6.5-r1` to `openssl-4.0-dev 4.0.3-r6` shows as one change.
5. **Flip preview.** Copies the Dockerfile, moves floating base tags to their next value and runs the same checks on the copy: `node:lts` to `node:26` (variants kept, so `node:lts-slim` becomes `node:26-slim`), `ubuntu:latest` to `ubuntu:26.04`, and `python:3` to the newest `3.x` tag that exists (the `3.N-rc` tag until `3.N` is published). `--flip FROM=TO` adds your own. A tag that already points at the target image is reported and not rebuilt.

The summary is Markdown on stdout, and is appended to `$GITHUB_STEP_SUMMARY` when that is set.

## Why

### OpenSSL 4 in Wolfi (October 2026)

On 2026-10-06 at 13:42 UTC, Wolfi's `openssl-dev` began to resolve to `openssl-4.0-dev`. A Dockerfile that installs `openssl-dev` in a Chainguard builder stage and copies `libssl.so.3` into its runtime stage still builds without an error; the binary then cannot start.

- **OpenZeppelin Relayer.** On 2026-10-10 I built `main` at d7f151f with its unmodified `Dockerfile.production`. The build exited 0. The binary exited 127: `libssl.so.4: cannot open shared object file`. The runtime stage copies only `libssl.so.3` and `libcrypto.so.3`. The fix I proposed pins `openssl-3.6-dev` ([OpenZeppelin/openzeppelin-relayer#919](https://github.com/OpenZeppelin/openzeppelin-relayer/pull/919)). The release workflow builds on a cold cache and never starts the image, so a release built from that commit would ship an image that cannot start.
- **LiteLLM.** [BerriAI/litellm#44991](https://github.com/BerriAI/litellm/pull/44991) pinned `openssl-3.6-dev` for the pgbouncer build stage on 2026-10-07. [#44997](https://github.com/BerriAI/litellm/pull/44997) reverted it 98 minutes later: with the pin, pgbouncer links `libssl.so.3`, no runtime stage installs it, and the current `wolfi-base` ships only `libssl.so.4`, so "the next digest bump makes pgbouncer exit 127 while the build stays green".

Build caches make this harder to see. `RUN --mount=type=cache` keeps cargo's target directory between builds, and cargo does not relink when only a system library changes, so a rebuild on a warm builder can reuse a binary linked against the previous OpenSSL. My first rebuild of the Relayer fix did exactly that and finished in 4.7 seconds with the old binary. In my tests (BuildKit 0.12.5, 0.26.2 and 0.33.1, each on a docker-container builder) `--no-cache` did start each `RUN` with an empty cache mount, and later builds kept what that run wrote; ordinary rebuilds kept the old contents even when the step itself re-ran because something before it changed. The canary does not depend on either behaviour: every run gets a builder of its own.

### pnpm 12

`npm install -g pnpm` now installs pnpm 12. The Relayer's `main` pins `pnpm@10` with the comment "pnpm 12 ships a preinstall script that newer npm blocks by default, which leaves a broken pnpm shim". When I built the branch of OpenZeppelin/openzeppelin-relayer#862 on 2026-10-10, which predates that pin, `pnpm install` failed with `ERR_PNPM_IGNORED_BUILDS` on esbuild until I pinned `pnpm@10`. Nothing in the branch had changed; the package manager had. A scheduled clean build shows this on the day it happens, and the package diff names the version that moved when the build still passes.

### Tags that move on a date

- `node:lts` becomes Node 26 on 2026-10-28. Node 26 images ship without yarn ([nodejs/docker-node#2422](https://github.com/nodejs/docker-node/pull/2422)) and without corepack, and `node:26-slim` is built on Debian 13 where `node:lts-slim` is on Debian 12. The fixture in `tests/fixtures/node-corepack` passes on today's `node:lts-slim` (Node 24.21.0) and fails in the preview with `corepack: not found`. `Dockerfile.fixed` next to it installs corepack from npm and passes on both.
- The Docker tag `ubuntu:latest` already has the same digest as `ubuntu:26.04` (checked 2026-10-11), so the preview reports it as the same image and builds nothing. An image still pinned to the previous release can preview the move with `--flip ubuntu:24.04=ubuntu:26.04`: on the Ubuntu fixture both builds pass, and curl goes from 8.5.0 to 8.18.0 and OpenSSL from 3.0.13 to 3.5.5 among 124 changed, 30 added and 4 removed packages. The GitHub runner label `ubuntu-latest` moves to Ubuntu 26.04 between 2026-10-19 and 2026-11-19 ([actions/runner-images#14748](https://github.com/actions/runner-images/issues/14748)); a container cannot preview that, so the example workflow below runs on `ubuntu-26.04` as well.
- `python:3` still points at 3.14 (3.14.8). Python 3.15.0 was released on 2026-10-09 and on 2026-10-11 there was no `python:3.15` tag yet, so the preview uses `python:3.15-rc`, which still carries 3.15.0rc3.

## Usage

```sh
./canary.sh [options] [CONTEXT]
```

Build the current directory's `Dockerfile`, check libraries, check that the default command does not crash in its first 10 seconds:

```sh
./canary.sh .
```

A service with a health URL and a preview on the next base tags:

```sh
./canary.sh --ready-url http://localhost:3000/health --flip-preview tests/fixtures/node-corepack
```

A service that needs other containers. The compose file uses `image: ${CANARY_IMAGE}` for the service under test (see `examples/openzeppelin-relayer`):

```sh
./canary.sh -f Dockerfile.production \
  --compose /path/to/canary/examples/openzeppelin-relayer/compose.yml --service relayer \
  --ready-url http://localhost:8080/api/v1/health --timeout 120 .
```

A command that must exit 0, and an image that is already built or published:

```sh
./canary.sh --smoke "--version" .
./canary.sh --image openzeppelin/openzeppelin-relayer:v1.8.0 --no-start
```

This is the summary for the Relayer at d7f151f on 2026-10-11, abridged (paths and the package source line removed). The previous package list it diffs against came from a run of the pinned branch (30b32b1) a few minutes earlier:

```markdown
## Upgrade canary: openzeppelin-relayer main d7f151f (unmodified): FAIL

| Check | Result | Detail |
|---|---|---|
| Clean build | pass | 6 min 30 s, nw-relayer:canary-main-d7f151f, 646MB |
| Shared libraries | **FAIL** | 1 of 47 ELF files cannot load |
| Start | **FAIL** | exited 127 before http://localhost:8080/api/v1/health answered |
| Packages | info | 1 changed, 4 added, 0 removed since 20261011-043606-233134 |

### Shared libraries

47 ELF files under `/`, loader `/lib64/ld-linux-x86-64.so.2`: 41 resolve, 3 static, 1 executable with missing libraries, 2 built for the other C library (skipped).

Cannot load:

- `/app/openzeppelin-relayer`: libssl.so.4 libcrypto.so.4

### Start

Last log lines:

/app/openzeppelin-relayer: error while loading shared libraries: libssl.so.4: cannot open shared object file: No such file or directory

### Package changes since run 20261011-043606-233134

| Where | Package | Change | Before | After |
|---|---|---|---|---|
| build, stage `base`, apk | openssl-dev | changed | openssl-3.6-dev 3.6.5-r1, openssl-dev 3.6.5-r2 | openssl-4.0-dev 4.0.3-r6 |
| build, stage `base`, apk | libbrotlienc | added | - | libbrotlienc1 1.2.0-r5 |
| build, stage `base`, apk | openssl-libcrypto | added | - | openssl-4.0-libcrypto 4.0.3-r6 |
| build, stage `base`, apk | openssl-libssl | added | - | openssl-4.0-libssl 4.0.3-r6 |
| build, stage `base`, apk | openssl-provider-legacy-allowed | added | - | openssl-provider-legacy-allowed 4.0.3-r1 |
```

Run again at 19:20 UTC the same day, the pinned branch still passed, and its diff against the 04:36 run named the one thing Wolfi had moved in between, brotli: `libbrotlicommon1`, `libbrotlidec1` and `libbrotlienc1` from 1.2.0-r5 to 1.2.0-r6.

Only print what the preview would substitute:

```sh
./canary.sh --flip-plan -f Dockerfile .
```

`./canary.sh --help` lists every option. The ones you will want most:

| Option | What it does |
|---|---|
| `-f FILE`, `--target`, `--build-arg K=V` | what to build |
| `--elf-paths "P ..."`, `--elf-exclude REGEX`, `--strict-libs` | where to look for ELF files; `--strict-libs` also fails shared objects with missing libraries |
| `--smoke "ARGS"`, `--entrypoint`, `--expect-exit N` | run a command and check its exit code |
| `--ready-log REGEX`, `--ready-url URL`, `--timeout SEC` | wait for the service instead |
| `--compose FILE --service NAME` | start a compose file with the new image |
| `--flip-preview`, `--flip FROM=TO`, `--flip-warn-only` | the preview |
| `--state-dir DIR`, `--previous FILE`, `--fail-on-change` | where the last green package list lives |
| `--registry-mirror HOST`, `--cpus N`, `--memory SIZE` | for rate limits and shared machines |

Exit status: 0 pass, 1 a check failed, 2 usage or setup error, 3 the preview failed while the current build passed, 4 packages changed (with `--fail-on-change`).

Each run writes `.canary/runs/<run>/` (the summary, the build log, the library scan, the start log, the package lists and the diffs as JSON) and, when the current build passes, `.canary/last-green.json` for the next run to diff against.

## GitHub Action

`action.yml` wraps the CLI. It restores the last green package list from the Actions cache, runs the checks, saves the list again and uploads the run directory as an artifact. Until this has a repository of its own, copy this directory to `.github/actions/canary` in your repository.

```yaml
name: upgrade canary

on:
  schedule:
    - cron: "23 5 * * *"
  workflow_dispatch:

permissions:
  contents: read

jobs:
  canary:
    strategy:
      fail-fast: false
      matrix:
        runner: [ubuntu-latest, ubuntu-26.04]
    runs-on: ${{ matrix.runner }}
    steps:
      - uses: actions/checkout@v7
      - uses: ./.github/actions/canary
        with:
          name: app-${{ matrix.runner }}
          dockerfile: Dockerfile
          ready-url: http://localhost:8080/health
          timeout: "90"
          flip-preview: "true"
```

Inputs mirror the CLI options (`dockerfile`, `context`, `target`, `build-args` one per line, `image`, `elf-paths`, `elf-exclude`, `strict-libs`, `smoke`, `entrypoint`, `expect-exit`, `ready-log`, `ready-url`, `run-args` one per line, `compose`, `service`, `timeout`, `settle`, `sbom`, `flip-preview`, `flips` one per line, `flip-warn-only`, `fail-on-change`, `registry-mirror`, `cpus`, `name`, `upload-artifact`). Outputs: `result` (pass, fail, flip-fail or changed), `summary`, `image`, `changed`. Give each matrix entry its own `name`, since the cache key and the artifact name come from it. Scheduled workflows run on the default branch, and the Actions cache is evicted after 7 days without use, so a daily or weekly schedule keeps the baseline.

## Requirements

Linux, Docker with buildx and the docker-container driver, bash 4.4 or later, jq, awk, xargs and coreutils. syft runs from its own image (`ghcr.io/anchore/syft`, pinned by digest) and needs the local Docker socket; the scan helper is `busybox:1.38.0-musl`, also pinned by digest.

## Limits

- One platform per run, the host's architecture. Images for another CPU are not emulated.
- The library check lists what the loader resolves at start. Libraries a program opens later with `dlopen` are not seen, and glibc's trace mode checks symbol versions but not every symbol (musl's `--list` does report missing symbols).
- Shared objects with missing libraries, such as plugins and language extension modules, are notes rather than failures unless you pass `--strict-libs`. The official `python:3.12-slim` image, for example, ships a `_tkinter` module whose Tk libraries are not installed.
- The preview knows `node:lts`, `ubuntu:latest` and `python:3` tags (with their variants). FROM lines set by a build argument or pinned by digest are not substituted; pass `--build-arg` or `--flip` for those.
- Every run is a cold build, by design. The Relayer's took between 5 min 27 s and 6 min 51 s on 6 CPUs.
- Docker Hub limits anonymous pulls per address (100 an hour when I hit it on 2026-10-11), and a cold builder pulls every base image on every run. Log in first, or pass `--registry-mirror mirror.gcr.io`.
- syft needs the local Docker socket. With a remote `DOCKER_HOST` the runtime list comes from the image's package database.
- Package families are matched by name with version numbers removed. A package that was renamed outright shows as one removal and one addition, and two different packages whose names differ only by a number are paired: Ubuntu 26.04's curl links libssh2 where 24.04's linked libssh, and the diff shows that as `libssh-4` changing to `libssh2-1t64`.
- `--builder NAME` prunes every exec cache mount on that builder, including other projects' ones.
- The start check is a smoke test, not your test suite.

## Tests

`tests/run.sh` builds the fixtures in `tests/fixtures` and checks the verdicts: a passing Alpine image, a binary copied without its library (glibc and musl), a musl binary in a glibc image, the cache mount behaviour, every start check mode, the package diff and build log parsers, the flip planner, and the node and ubuntu previews. `tests/run.sh --list` names them; pass names to run a subset.

## License

MIT, see `LICENSE`.

If you would rather I run it on a schedule for you and send the fix as a pull request: $99 per image a month, or $299 for five. https://nonceworks.com
