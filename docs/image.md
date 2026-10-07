# Local image build

This fork builds the OpenViking server image from its own source tree. The
deployment never pulls a pre-built application image. Only the base images
come from a registry, and each one is pinned by digest.

Files:

| File | Purpose |
| --- | --- |
| `Dockerfile` | The upstream `Dockerfile` with pins, a registry prefix and base labels (see "Changes against the upstream tag") |
| `.dockerignore` | Allowlist of the paths that the `COPY` lines read |
| `docker-bake.hcl` | Targets `image`, `builder`, `gateway`, `smoke`, `test`, `release` |
| `scripts/build.sh` | Computes the version, revision and time from Git; runs bake or the Podman build path |
| `tests/test_image.sh` | Starts a built image offline and checks it |

## Build

```sh
sh scripts/build.sh gateway                 # smoke, then load openviking:local
GATEWAY_IMAGE=openviking:test sh scripts/build.sh gateway
SOURCE_URL=<url of the shared repository> sh scripts/build.sh gateway   # source label names that repository
sh scripts/build.sh test                    # upstream lite test set in the image
sh scripts/build.sh --oci /tmp/ov.tar release   # clean tree only
sh tests/test_image.sh openviking:local
```

By default, `build.sh` needs POSIX `sh`, Git and Docker with buildx.
The [Podman path](#build-with-podman) uses Podman instead of Docker.
It works with GNU and BSD tools. It never pushes unless you give `--push`.

| Target | Platforms | Output |
| --- | --- | --- |
| `gateway` | host | `type=docker`, tag `$GATEWAY_IMAGE` (default `openviking:local`) |
| `smoke` | host | cache only; imports `openviking` and finds `ov`, `openviking-server`, `openviking-entrypoint` |
| `test` | host | cache only; runs the upstream lite test set (below) |
| `release` | `$RELEASE_PLATFORMS` (default `linux/amd64,linux/arm64`) | `--oci FILE` (OCI archive: Open Container Initiative image format) or `--push` (`$RELEASE_IMAGE`), `rewrite-timestamp=true`, provenance off unless `PROVENANCE=true` |

`build.sh` runs `smoke` before `gateway` and `release`. `release` refuses a
dirty tree. A multi-platform or OCI output needs a `docker-container` builder:

```sh
docker buildx create --name ov-builder --driver docker-container
BUILDX_BUILDER=ov-builder sh scripts/build.sh --oci /tmp/ov.tar release
```

The `linux/arm64` part of `release` needs a native arm64 builder or QEMU.

### Build with Podman

```sh
BUILD_ENGINE=podman sh scripts/build.sh gateway
BUILD_ENGINE=podman sh scripts/build.sh smoke
```

`BUILD_ENGINE` defaults to `docker`, which keeps the bake commands unchanged.
The Podman path keeps the version computation, base pin comparison and dirty check.
`gateway` always builds `Dockerfile` for the native platform, with no `--platform` override.
It passes each build argument and label of bake target `image`, then tags `$GATEWAY_IMAGE` (default `openviking:local`).
The `created` label uses `SOURCE_DATE_EPOCH` as RFC 3339 UTC, with GNU `date -u -d` or BSD `date -u -r`.
Two `podman run --rm --network none` checks import the package and find the three commands.
`smoke` runs these checks against an existing image; it builds first if the image is absent.

`test` and `release` refuse this engine; they need BuildKit (`docker buildx bake`) and `BUILD_ENGINE=docker`.
The Podman path skips bake's target contexts, inline Dockerfiles, cache-only output, multi-platform release output and attestations.
It does not change `Dockerfile`.

Podman uses Buildah to build images ([Podman build documentation](https://docs.podman.io/en/v5.6.2/markdown/podman-build.1.html), v5.6.2).
Buildah ignores the BuildKit `# syntax=` directive; it does not pull that frontend.
Buildah supports `RUN --mount=type=cache` with `id` since v1.24.0.
Its builder sets `TARGETPLATFORM` automatically; the `ARG TARGETPLATFORM` lines expose it within each stage.
The release announcement, mount documentation and vendored builder source are in the [Mac Sources table](mac.md#sources).

Not verified: a Podman build of this image.
[Mac instructions](mac.md) describe the VM, Compose provider and unchanged Docker CLI tests.

### Variables

| Variable | Default | Source |
| --- | --- | --- |
| `BUILD_ENGINE` | `docker` | `build.sh`; `podman` supports `gateway` and `smoke` only |
| `OPENVIKING_VERSION` | `<upstream>+p<portable, "-" as ".">` | nearest `v*` tag, else the `tag` line of `scripts/upstream-base` (see "Version") |
| `UPSTREAM_VERSION` | nearest `v*` tag without `v`, else the `tag` line of `scripts/upstream-base` | `build.sh` |
| `PORTABLE_VERSION` | `git describe --tags --abbrev=8 --match 'portable-v*'` without `portable-v`, else `0-g<sha8>`; `-dirty` on a dirty tree | `build.sh` |
| `REVISION` | `git rev-parse HEAD` | `build.sh` |
| `SOURCE_DATE_EPOCH` | commit time of `HEAD` | `build.sh` |
| `UV_LOCK_STRATEGY` | `locked` | bake and the Podman path; set `auto` only on purpose |
| `REGISTRY_PREFIX` | empty | bake and the Podman path |
| `SOURCE_URL` | `https://github.com/volcengine/OpenViking` | bake and the Podman path |
| `GATEWAY_IMAGE`, `RELEASE_IMAGE`, `RELEASE_PLATFORMS`, `PROVENANCE` | see `docker-bake.hcl` | bake |

Each variable can be set in the environment.

A release build sets `SOURCE_URL` to the URL of the shared repository that holds
`portable`. The label `org.opencontainers.image.source` then names that
repository, not upstream. `scripts/build.sh` passes `SOURCE_URL` from the
environment to the bake file. It does not check the value: without
`SOURCE_URL`, the label names upstream. This applies to each target that
makes an image: set `SOURCE_URL` for a `gateway` build too when the labels
`source`, `revision` and `version` of the image must agree with the tag.

```sh
SOURCE_URL=<url of the shared repository> sh scripts/build.sh --oci /tmp/ov.tar release
```

### Version

Upstream resolves the version with `resolve_openviking_version()` in
`scripts/build_support/versioning.py`: `setuptools_scm` with the tag pattern
`^v([0-9]+(\.[0-9]+)*)$`. On a tag push, the
[upstream image workflow](https://github.com/volcengine/OpenViking/blob/main/.github/workflows/build-docker-image.yml)
passes the release tag name. That workflow is absent from this tree. On a commit after a tag, `setuptools_scm` gives the next
development version in the form `<next version>.dev<commit count>`.

This fork builds upstream tags plus local commits. `build.sh` finds the
nearest ancestor tag that matches the upstream pattern in `refs/tags/` or in
`refs/upstream/tags/` (where `scripts/fetch-upstream.sh` puts it in a new
clone). It passes `OPENVIKING_VERSION=<tag without v>+p<portable version>`,
for example `0.4.22+p0.g429698f2` (label `0.4.22-p0-g429698f2`).

`portable` has no upstream history, so no upstream tag is an ancestor there.
When no ancestor tag exists and `OPENVIKING_VERSION` is not set, `build.sh`
reads the `tag` line of `scripts/upstream-base` and prints one line:

```text
build: upstream version <tag> from scripts/upstream-base (no upstream tag in the history)
```

It stops when the file has no valid `tag` line. `tests/test_build_version.sh`
checks this in a repository with one parentless commit. The version parts:

- The public part stays the upstream release from `scripts/upstream-base`.
  A next-release development version would claim a release that does not exist.
- The PEP 440 local label `+p...` marks a local build and names the commit.
  It sorts after that upstream version and before the next upstream release.
- `/health`, the Python package and `ov` report this string.

The version label is `<upstream>-p<portable>`. Set `OPENVIKING_VERSION=...` to override; `build.sh`
accepts a normalized PEP 440 version with an optional leading `v`.

## Pins

Each base image pin is a multi-platform index digest, not a single-platform digest.
Check a pin with `docker buildx imagetools inspect <reference>@<digest>`.
Read the reference and digest from the source named in the table below.

| Use | Reference | Digest |
| --- | --- | --- |
| Dockerfile frontend | `# syntax=` in `Dockerfile` | Digest in the same line |
| Rust toolchain stage | `ARG RUST_IMAGE` in `Dockerfile` | `ARG RUST_DIGEST` |
| Studio stage | `ARG NODE_IMAGE` in `Dockerfile` | `ARG NODE_DIGEST` |
| Python build stage and runtime | `ARG PYTHON_IMAGE` in `Dockerfile` | `ARG PYTHON_DIGEST` |
| uv in the Python build stage | `uv==` requirement in `Dockerfile` | Wheel hashes in the same requirement |

Print the current pins from their source:

```sh
awk '/^# syntax=/ || /^ARG (RUST|NODE|PYTHON)_(IMAGE|DIGEST)=/ || /uv==/ { print }' Dockerfile
```

The pins are in the `ARG` defaults of the `Dockerfile` and again in the
variables of `docker-bake.hcl`, so that `docker buildx bake --print` shows
them. `build.sh` refuses to build when the two copies differ.

Other inputs are pinned by lock files: npm (`web-studio/package-lock.json`,
`npm ci`), Python (`uv.lock`, `uv sync --locked`), Rust crates
(`Cargo.lock`). Not pinned: the Debian packages that `apt-get` installs in the
Python build stage and the runtime stage. They are the current trixie
packages at build time.

### Decisions

- uv source: the Python build stage was `ghcr.io/astral-sh/uv:python3.13-trixie-slim`.
  That image combines Python with the `uv` and `uvx` binaries.
  It is now the pinned `PYTHON_IMAGE` plus the `uv==` requirement from the `Dockerfile`
  with `--require-hashes --only-binary=:all:`.
  The build stage and runtime use the same Python digest.
  Run `sh scripts/build.sh gateway` and `sh tests/test_image.sh <image>` to check the result.
- Frontend: the `# syntax=` line stays, pinned by digest, because the
  `Dockerfile` uses cache mounts and `RUN` options that need a recent
  frontend. With a mirror, set the build argument
  `BUILDKIT_SYNTAX=<mirror>/<frontend image>@<digest>`: the
  `# syntax=` line cannot read `REGISTRY_PREFIX`.
- Lock strategy: the `Dockerfile` default stays `auto` (upstream). The bake
  targets pass `locked`.

## Changes against the upstream tag

Keep this list short: each sync must merge it. `git diff
refs/upstream/tags/<tag> -- Dockerfile` shows it.

1. The `# syntax=` frontend reference gets its digest.
2. New global `ARG` block: `REGISTRY_PREFIX` and `<NAME>_IMAGE` plus
   `<NAME>_DIGEST` for Rust, Node and Python.
3. The four `FROM` lines read `${REGISTRY_PREFIX}${<NAME>_IMAGE}@${<NAME>_DIGEST}`.
4. Studio stage: `ARG npm_config_registry` (no default, so unset unless given).
5. Python build stage: `FROM` the Python image in place of the uv image;
   `ARG PIP_INDEX_URL` and `ARG UV_DEFAULT_INDEX` (no default); one `RUN` that
   installs the pinned uv requirement with hashes.
6. Runtime stage: `LABEL org.opencontainers.image.base.name` and
   `.base.digest` from the Python `ARG`s.

No stage, `COPY`, cache mount or command of upstream changed.

## Build context

`.dockerignore` excludes everything, then permits the `COPY` sources:
`Cargo.toml`, `Cargo.lock`, `pyproject.toml`, `uv.lock`, `setup.py`,
`README.md`, `scripts/build_support/`, `bot/`, `crates/`, `openviking/`,
`openviking_cli/`, `src/`, `third_party/`, `web-studio/`, and the two files in
`deploy/docker/`. Inside these, local artifacts (`.env*`, `.venv`,
`__pycache__`, `node_modules`, `target/`, build output, logs) are excluded at
any depth. `data/`, `.env`, `.local/`, `.git/`, `examples/`, `docs/`,
`benchmark/` and the top-level `tests/` never reach the builder. When a
`COPY` line changes, change this list too.

The context size depends on the source tree and its generated files.
Check the `transferring context` line of `sh scripts/build.sh gateway`.

## Network endpoints of the build

| Endpoint | Used by | Redirect |
| --- | --- | --- |
| Docker Hub (`registry-1.docker.io`, `auth.docker.io`, its blob CDN) | base images and the frontend | `REGISTRY_PREFIX`; `BUILDKIT_SYNTAX` for the frontend |
| `deb.debian.org` | `apt-get` in the Python build stage and the runtime stage | no argument; an HTTP proxy (`HTTP_PROXY`, `HTTPS_PROXY`, `NO_PROXY` are predefined build arguments) or a mirror in the base image. Open point |
| `registry.npmjs.org` | `npm ci` in the Studio stage (and the npm update notice) | `--build-arg npm_config_registry=<url>` |
| `pypi.org`, `files.pythonhosted.org` | `pip install uv`; `uv sync` (locked packages and build dependencies) | `--build-arg PIP_INDEX_URL=<url>` for pip; `--build-arg UV_DEFAULT_INDEX=<url>` for uv |
| `index.crates.io`, `static.crates.io` | `cargo build` of `ov` and `ragfs-python` (RAGFS: Rust filesystem for content storage) | none that works through the environment (see below). Open point |

Not verified: that `uv sync --locked` accepts a different index. `uv.lock`
records the `pypi.org` and `files.pythonhosted.org` URLs of each package.

Verified: Cargo ignores `CARGO_SOURCE_CRATES_IO_REPLACE_WITH` and
`CARGO_SOURCE_<NAME>_REGISTRY` in the environment. A test with the pinned
Rust image still fetched from crates.io. A crates.io mirror needs a Cargo
`config.toml` with `[source]` replacement in `$CARGO_HOME` or a parent
directory of the build. That needs a `Dockerfile` change (a secret or a named
context mount), so it is an open point.

A private CA certificate for a proxy or a mirror is not supported yet. The
way to add it is a BuildKit secret (`RUN --mount=type=secret,id=ca`) in each
stage that downloads. That changes upstream `RUN` lines. Open point.

## Runtime content

The runtime image is the pinned `PYTHON_IMAGE` from `Dockerfile` plus Debian packages
(`ca-certificates`, `curl`, `git`, `libstdc++6`), the virtual environment
`/app/.venv` that the Python build stage produced from this source tree and
`uv.lock`, and the two entrypoint scripts from `deploy/docker/`. It holds no
configuration, key or state: `/app/.openviking` is empty, and no `ov.conf`,
`ovcli.conf` or `.env` file exists. To check this, compare
`docker history --no-trunc <image>` with the `Dockerfile`: each layer on top
of the base is one instruction of the runtime stage. Then compare
`org.opencontainers.image.base.digest` with the pin above, and
`org.opencontainers.image.revision` with the commit that you built.
`tests/test_image.sh` checks the file and label part.

## Runtime user and state

- The image runs as root, as the upstream image does (`Config.User` is
  empty). `tests/test_image.sh` asserts `root` (`EXPECTED_USER`). A non-root
  user needs a compatibility test before you change the deployment.
- Without `ov.conf` the entrypoint serves a 503 pending page for ever. Give
  `ov.conf` in the state mount or `OPENVIKING_CONF_CONTENT`.
- With the quick start configuration, VikingBot writes `/app/.openviking/data/bot/logs/vikingbot.log` inside the state mount.
  The host path is `data/data/bot/logs/vikingbot.log`. The log survives container replacement while you keep `data/`.
  The default log directory is `<storage.workspace>/bot/logs/`; `--bot-log-dir` overrides it.
- With unreachable embedding and VLM endpoints, the server logs connection
  retries and stays healthy.

## Tests

`tests/test_image.sh IMAGE` starts the image with `--network none`, a
temporary state directory, a random root API key and a placeholder `ov.conf`
(local storage, embedding and VLM at `http://127.0.0.1:9/v1`). It publishes
no port; it calls the API with Python through `docker exec`. It checks the
labels, the user, an empty `/app/.openviking`, no configuration files in the
image, a real `/health` (`healthy: true`, not the 503 page), the version,
401 without a key and 200 with the root key, and 30 s of health with failing
model endpoints. It removes the container and the directory on exit. Set
`TEST_NAME_PREFIX` for the container name (default `openviking-image-test`).

The `test` target runs four files in `tests/vectordb/` in the built image.
The list comes from the
[upstream lite workflow](https://github.com/volcengine/OpenViking/blob/main/.github/workflows/_test_lite.yml),
which is absent from this tree. `docker-bake.hcl` holds the local test command. It adds `pytest`, `pytest-asyncio`, `iniconfig`, `pluggy`,
`packaging`, `pygments` and `numpy` with the versions and hashes of
`uv.lock`, then runs the tests with `--network=none`. `numpy` comes from the
`test` extra: two cuVS tests import it, and the runtime image does not
contain it.

## Build times and cache

Reference timings for a 16-CPU `linux/amd64` host with a `docker-container` builder:
The first build starts with an empty cache. Later rows state their cache conditions.
Measure your build with `time sh scripts/build.sh gateway`.

| Build | Wall time |
| --- | --- |
| First `gateway`, cold cache | 526 s (image build only; smoke check failed in this measurement) |
| Second `gateway` after a commit (new version string, so the `uv sync` layer re-ran with warm cache mounts) | 451 s |
| `gateway` without a change | 14 s |
| `release` (`linux/amd64`, OCI archive, after a full prune), run 1 and run 2 | 561 s, 540 s |

The upstream cache mounts (ids per `TARGETPLATFORM`): `npm-` on `/root/.npm`,
`uv-` on `/root/.cache/uv`, `cargo-target-` on `/cargo-target`,
`cargo-registry-` and `cargo-git-` on `/usr/local/cargo/{registry,git}`,
`ccache-` on `/root/.ccache`. They help only on the same builder. The
version string is a build argument of the `uv sync` layer, so each new commit
re-runs that layer. Builder disk use: 6.7 GB peak during a cold build,
8.9 GB after two builds with different versions.

## Reproducibility

`release` sets `SOURCE_DATE_EPOCH` to the commit time and uses `rewrite-timestamp=true`.
Provenance and SBOM (list of software components and versions) attestations are off by default.
The image is not bit-for-bit reproducible yet. Two `linux/amd64`
release builds of the same commit, with a full builder prune between them,
gave different index digests. The file times are equal
(`SOURCE_DATE_EPOCH`). 10 of 12 layers are equal. The two layers that differ:

| Layer | Files that differ | Cause |
| --- | --- | --- |
| Runtime `apt-get install` | `var/log/apt/history.log`, `var/log/apt/term.log`, `var/log/dpkg.log`, `var/cache/ldconfig/aux-cache` | apt and dpkg write the wall-clock time into their logs |
| `COPY /app/.venv` | 41,456 `.pyc` files | only the 16-byte header differs: the source time stamp of the install; `uv sync` compiles with time-stamp based `.pyc` files |
| | 3 `.pyc` files: `vikingbot/config/__pycache__/loader.cpython-313.pyc`, `openviking_cli/utils/config/__pycache__/embedding_config.cpython-313.pyc`, `openviking/service/__pycache__/external_task_service.cpython-313.pyc` | the code body differs by a few bytes (not analyzed; probably the order of a set or frozenset constant under hash randomization) |
| | `openviking/lib/ragfs_python.abi3.so` and the `RECORD` of the `openviking` wheel | the OpenSSL vendored into the Rust build of `ragfs-python` embeds its build time (`built on: ...`); the GNU build ID differs as a result (same size, 52,516 bytes differ) |
| | `openviking-*.dist-info/uv_cache.json` | uv writes the build time |

Possible fixes, not applied because each one changes upstream lines:
`ARG SOURCE_DATE_EPOCH` in the Python build stage (Python then writes
hash-based `.pyc` files), removal of the apt and dpkg logs in the runtime
`RUN`, `SOURCE_DATE_EPOCH` in the Rust build stage (OpenSSL reads it for
the `built on` string; not verified), a fixed `PYTHONHASHSEED` for the 3
`.pyc` bodies (not verified), and removal of `uv_cache.json`. The Debian
packages are not pinned either, so a build on a later day can differ in the
apt layers.

## Move to a new upstream tag

1. `sh scripts/fetch-upstream.sh v<X.Y.Z>`. The tag goes to
   `refs/upstream/tags/`.
2. On a `sync/v<X.Y.Z>` branch from `local-dev`, run
   `git merge refs/upstream/tags/v<X.Y.Z>`. Resolve the `Dockerfile` by
   keeping the six changes above on top of the new upstream text.
3. Compare the `COPY` lines with `.dockerignore`.
4. Resolve new digests with `docker buildx imagetools inspect <ref>` for each
   base reference and the frontend. Update both the `Dockerfile` `ARG`s and
   `docker-bake.hcl`. If upstream changed the uv version, update the pinned uv
   version and its wheel hashes from `https://pypi.org/pypi/uv/<version>/json`.
5. `sh scripts/build.sh test`, `sh scripts/build.sh gateway`, then
   `sh tests/test_image.sh <image>`.

## Open points

- Runtime user root or non-root: choose after a state-permission compatibility test.
- Mirrors for crates.io and Debian packages, and a private CA file.
- Not verified: `linux/arm64`. Use a native arm64 builder or QEMU.
- CI: a CI job needs a `docker-container` builder, `BUILDX_BUILDER`, and the
  full Git history with the upstream tag (not a `--depth` clone), so that
  `build.sh` finds the version. On `portable`, `build.sh` reads the tag line
  of `scripts/upstream-base`, and a `--depth` clone is enough.
