# Run the stack on a Mac

This page builds the image and starts the stack on an Apple silicon Mac (`arm64`).
The kit is tested with Docker on Linux; on a Mac this page uses Podman only.

Not verified: the steps on a Mac. Each step is marked.
Tested platform: Linux `amd64`, except where a statement says otherwise.
Not verified: an `arm64` build and an `arm64` image at run time.
The tool statements come from the documentation and source code in the [Sources](#sources) table.

## What the repo needs

| Need | Why |
| --- | --- |
| Podman 5 or later with `podman machine` | On Apple silicon, Podman runs containers in a native `arm64` Linux virtual machine (VM). |
| Docker Compose v2 or later, from Homebrew `docker-compose` | It is the external provider of `podman compose`. It reads the top-level `name:` element of `compose.yaml`. |
| File sharing for the repository and `$TMPDIR` | Compose mounts `data/`. The scanner and tests mount temporary files. |
| Git 2.24 or later | Git runs the `pre-merge-commit` hook from 2.24. `core.hooksPath` needs 2.9; the scanner needs 2.5. |
| POSIX `sh` and `python3` | The scripts use `sh`. The verifier uses the Python standard library and Python 3.8 syntax. |
| Node 24 or later | Hard requirement of the kit, including the Pi extension and its tests ([testing.md](testing.md)). |
| Docker CLI, connected to the Podman socket | The image test, Compose test and scanner call `docker` directly. This installs no second container runtime. |
| 4 CPUs and 8 GiB of VM memory | Allocate these resources for the Rust and Python build stages. Not verified: this allocation on a Mac. |
| About 10 GB of free disk in the VM | A cold Docker build used 6.7 GB at its peak and 8.9 GB after two builds on Linux `amd64`. |

The Linux checks used Git 2.39.5 and Docker Compose 5.5.0.
Not verified: the minimum versions or the oldest Compose version that works with this kit.
Check the installed versions with `git --version`, `podman version`, `podman compose version` and `node --version`.

The Rust, Node and Python base image pins are multi-platform index digests with an `arm64` variant.
The `Dockerfile` also has the uv wheel hashes for `aarch64`.
Verified on Linux: the scanner image of `scripts/scan.sh` is a multi-platform index with `linux/arm64`.
That check used `docker buildx imagetools inspect`; it did not run the scanner on a Mac.

`scripts/build.sh` and `scripts/scan.sh` use POSIX `sh` with GNU and BSD tools.
Not verified: these scripts with the BSD tools of macOS.

## Container runtime

Podman is the recommended replacement for Docker Desktop.
`podman build` uses Buildah, not BuildKit.
The [Podman build path](image.md#build-with-podman) supports `gateway` and `smoke` without `docker buildx bake`.

### Packages

Each formula below has at least one macOS `arm64_*` bottle in the Homebrew API field `bottle.stable.files`.
A bottle is a pre-built package. Its macOS version must match a supported bottle target.
Not verified: installation of these packages on a Mac.

| Formula | Purpose | arm64 bottle |
| --- | --- | --- |
| `podman` | Container runtime, native Linux VM and image builder | yes |
| `docker-compose` | Docker Compose provider for `podman compose` | yes |
| `node@24` | Node 24 for the kit, the Pi extension and its tests | yes |
| `docker` | Docker CLI for the unchanged tests and scanner, against the Podman socket | yes |

### Install and start Podman

1. Install the runtime and the Compose provider. Not verified on a Mac.

   ```sh
   brew install podman docker-compose
   ```

2. Install Node and the Docker CLI. Not verified on a Mac.

   ```sh
   brew install node@24 docker
   export PATH="$(brew --prefix node@24)/bin:$PATH"
   ```

   The Docker formula supplies the CLI only. Podman remains the container runtime.
   The shell of macOS is `zsh`. Put each `export` line of this page into `~/.zshrc`, so that each new terminal has it.
   Do not use `~/.bashrc` or `~/.bash_profile` on a Mac.
3. Create the VM. Not verified on a Mac.

   ```sh
   podman machine init --cpus 4 --memory 8192 --disk-size 50
   ```

   `--memory` uses MiB; 8192 MiB is 8 GiB. `--disk-size` uses GiB.
   The Podman v5.6.2 source defaults to half the host's logical CPUs, with a minimum of one CPU.
   Its other defaults are 2048 MiB of memory and a 100 GiB disk.
   The Podman configuration file can override those defaults.
   This example allocates 4 CPUs, 8 GiB of memory and a 50 GiB disk.
   Keep about 10 GB free inside the VM for the build.
4. Start the VM. Not verified on a Mac.

   ```sh
   podman machine start
   ```

5. Select and check the Compose provider. Not verified on a Mac.

   ```sh
   export PODMAN_COMPOSE_PROVIDER="$(brew --prefix)/bin/docker-compose"
   podman compose version
   ```

   Podman passes the arguments to this provider and sets its connection to the Podman socket.
   No `DOCKER_HOST` setting is needed for `podman compose` itself.
6. Connect the Docker CLI for the unchanged tests and scanner. Not verified on a Mac.

   ```sh
   export DOCKER_HOST="unix://$(podman machine inspect --format '{{.ConnectionInfo.PodmanSocket.Path}}')"
   ```

   This selects the Docker-compatible API of the same Podman VM.
   The `podman machine start` documentation also prints this socket address and a `DOCKER_HOST` example.
   Add this line to `~/.zshrc` too; the socket path stays the same after a restart of the VM. Not verified: the path after a restart.
7. Configure the Compose plugin for `docker compose` in the Compose test. Not verified on a Mac.
   Add `cliPluginsExtraDirs` to `~/.docker/config.json`; keep the other keys.

   ```json
   {
     "cliPluginsExtraDirs": ["/opt/homebrew/lib/docker/cli-plugins"]
   }
   ```

   `/opt/homebrew` is the normal Homebrew prefix on Apple silicon. `brew --prefix` prints the installed prefix.
8. Keep the checkout and temporary files in shared paths. Not verified on a Mac.
   The macOS source defaults share `/Users`, `/private` and `/var/folders` at the same paths in the VM.
   These shares cover the normal home directory and macOS `$TMPDIR`.
   The manual describes configurable mounts; the macOS source defines these platform-specific defaults.
   For a checkout elsewhere, add `--volume <host path>:<same VM path>` to `podman machine init`.

### Repository commands

| Linux command | Mac command |
| --- | --- |
| `docker compose ...` | `podman compose ...`, with the same arguments |
| `sh scripts/build.sh gateway` | `BUILD_ENGINE=podman sh scripts/build.sh gateway` |
| `sh scripts/build.sh smoke` | `BUILD_ENGINE=podman sh scripts/build.sh smoke` |
| `python3 scripts/verify.py <URL>` | Unchanged |

The following scripts stay unchanged. Run them with the Docker CLI and `DOCKER_HOST` from the runtime steps.

| Script | Direct Docker calls | Podman status |
| --- | --- | --- |
| `tests/test_image.sh` | Image inspection, container start, execution, logs and removal | Not verified with Podman. It needs the Docker CLI against the Podman socket. |
| `tests/test_compose.sh` | `docker compose`, image and health inspection, ports and cleanup | Not verified with Podman. It needs the Docker CLI, the Compose plugin and the Podman socket. |
| `scripts/scan.sh` | Engine detection, scanner containers and image inspection or export | Not verified with Podman. This page uses the Docker scanner engine against the Podman socket. |

For the scanner's `image` mode, Docker image mounts may fail on the Podman API.
The script then tries `docker export`. Not verified with Podman: either method.

The Docker Compose documentation defines `pull_policy: never` and the `healthcheck` fields of `compose.yaml`.
`never` uses the local image and fails if it is absent.
The health check runs `openviking-entrypoint --healthcheck` with the configured interval, timeout, retries and startup grace period.
Not verified: these two features through the Podman socket. The Docker Compose documentation does not establish that compatibility.
Keep both settings; do not remove them to bypass a failing test.

## Steps

1. Get the source. Not verified on a Mac.

   ```sh
   git clone <url of the Git server> openviking
   cd openviking
   ```

   With a bundle of `portable`, use `git clone -b portable openviking-portable.bundle openviking`.
2. Create `upstream` and fetch the upstream tag of `scripts/upstream-base`. Not verified on a Mac.

   ```sh
   sh scripts/setup-remotes.sh
   sh scripts/fetch-upstream.sh "$(awk -F '\t' '$1 == "tag" { print $2 }' scripts/upstream-base)"
   ```

   A clone does not copy the remote configuration.
   On `portable`, no upstream tag is an ancestor; `scripts/build.sh` then reads the `tag` line of `scripts/upstream-base`.
   `OPENVIKING_VERSION` is an optional override ([image.md](image.md#version)).
3. Create `.env` and the server configuration. Not verified on a Mac.

   ```sh
   cp .env.example .env
   openssl rand -hex 32
   ```

   Put the output into `OPENVIKING_ROOT_API_KEY` in `.env`.
   Put the server configuration into `data/ov.conf`; [host-configuration.md](host-configuration.md) lists the other settings.

   Warning: `.env` and `data/ov.conf` hold keys. Do not commit them or print them in a shared log.
4. Build the image. Not verified on a Mac.
   The build uses native `linux/arm64`, tags `openviking:local`, then runs two checks without network.

   ```sh
   BUILD_ENGINE=podman sh scripts/build.sh gateway
   ```

   Without `SOURCE_URL`, `org.opencontainers.image.source` names upstream ([image.md](image.md#variables)).
5. Check the configuration and start. Not verified on a Mac.

   ```sh
   podman compose config --quiet
   podman compose up -d
   ```

   Warning: starting this project in a checkout with live `data/` can replace its container. Test in a separate copy.
6. Check the server. Not verified on a Mac.

   ```sh
   podman compose ps
   python3 scripts/verify.py http://127.0.0.1:1933
   ```

   The Python verifier is unchanged. A successful health check can mark the container healthy during the 60 s startup grace period.
   An isolated Linux Docker test first passed at 10.2 s; this is not a Mac timing guarantee.
   See [the startup check](operations.md#start) for the conditions.
7. Run the supported build checks and the unchanged tests. Not verified on a Mac.

   ```sh
   BUILD_ENGINE=podman sh scripts/build.sh smoke
   sh tests/test_image.sh openviking:local
   OPENVIKING_IMAGE=openviking:local sh tests/test_compose.sh
   ```

   `smoke` reuses the image if it exists; otherwise it builds first.
   The two test scripts use the Docker CLI against the Podman socket, not a Docker Engine.
   The build target `test` needs BuildKit and runs on Linux; [testing.md](testing.md) lists the other tests.
8. Run the scan. Not verified on a Mac.

   ```sh
   podman pull "$(sed -n 's/^GITLEAKS_IMAGE=${GITLEAKS_IMAGE:-\(.*\)}$/\1/p' scripts/scan.sh)"
   SCAN_ENGINE=docker sh scripts/scan.sh tree
   ```

   The pull uses Podman; the script uses the Docker CLI against the same Podman socket.
   Exit code 0 means no finding. [secret-handling.md](secret-handling.md) describes the modes and levels.
9. Run the public check before a commit or release. Not verified on a Mac.

   ```sh
   sh scripts/public-check.sh
   ```

   Exit code 0 means no finding; [public-check.md](public-check.md) describes the rules and other exit codes.
   The check needs Git, POSIX `sh` and Python 3. It uses no network or container.

To stop the stack:

Not verified on a Mac.

```sh
podman compose down
```

The state stays in `data/`. Compose uses no named volume.

## Release build

The `release` target needs BuildKit (`docker buildx bake`), which Podman does not provide.
`BUILD_ENGINE=podman` refuses `test` and `release`.
The release build is a Linux task of the continuous integration (CI) runner ([ci.md](ci.md)).
It builds `linux/amd64` and `linux/arm64` with the default Docker engine ([image.md](image.md#build)).
Not verified: a Podman release build; this path is not supported.

## Registry mirror and TLS inspection

`REGISTRY_PREFIX` selects a mirror for the base images ([image.md](image.md#network-endpoints-of-the-build)).
The Podman path passes it and the six base image variables as build arguments.
Buildah ignores the `# syntax=` directive, so `BUILDKIT_SYNTAX` does not select a Podman frontend.
The script does not pass `npm_config_registry`, `PIP_INDEX_URL` or `UV_DEFAULT_INDEX`.
Not verified: a Podman build through a mirror.

A network with TLS inspection needs its certificate authority (CA) in the VM and in each build stage that downloads.
The image build has no private CA support yet ([image.md](image.md#open-points)).
Not verified: private registry certificates or TLS inspection with this kit and Podman.

## Sources

| Statement | Source and version |
| --- | --- |
| Linux VM, init options and units | [Podman machine](https://docs.podman.io/en/v5.6.2/markdown/podman-machine.1.html) and [machine init](https://docs.podman.io/en/v5.6.2/markdown/podman-machine-init.1.html), Podman v5.6.2 |
| Native `arm64` VM image on Apple silicon | [VM image selection](https://github.com/podman-container-tools/podman/blob/v5.6.2/pkg/machine/ocipull/ociartifact.go), Podman v5.6.2: host `arm64` selects `aarch64`; VM OS is Linux |
| Default CPUs, memory and disk | [`defaultMachineConfig()`](https://github.com/podman-container-tools/podman/blob/v5.6.2/vendor/github.com/containers/common/pkg/config/default.go) and [init option defaults](https://github.com/podman-container-tools/podman/blob/v5.6.2/cmd/podman/machine/init.go), Podman v5.6.2 |
| macOS shares and provider search paths | [`default_darwin.go`](https://github.com/podman-container-tools/podman/blob/v5.6.2/vendor/github.com/containers/common/pkg/config/default_darwin.go), Podman v5.6.2 |
| Compose provider, socket environment and argument forwarding | [Podman compose](https://docs.podman.io/en/v5.6.2/markdown/podman-compose.1.html), Podman v5.6.2 |
| Docker-compatible socket and `DOCKER_HOST` | [Machine start](https://docs.podman.io/en/v5.6.2/markdown/podman-machine-start.1.html), [machine inspect](https://docs.podman.io/en/v5.6.2/markdown/podman-machine-inspect.1.html), [`ConnectionConfig`](https://github.com/podman-container-tools/podman/blob/v5.6.2/pkg/machine/config.go) and [`VMFile.Path`](https://github.com/podman-container-tools/podman/blob/v5.6.2/pkg/machine/define/vmfile.go), Podman v5.6.2 |
| Buildah builder, native platform and `.dockerignore` | [Podman build](https://docs.podman.io/en/v5.6.2/markdown/podman-build.1.html), Podman v5.6.2 |
| Cache mounts and `id` since Buildah 1.24.0 | [Release announcement](https://buildah.io/releases/2022/01/26/Buildah-version-v1.24.0.html) and [mount options](https://github.com/podman-container-tools/buildah/blob/v1.24.0/docs/buildah-run.1.md), Buildah v1.24.0 |
| `# syntax=` is ignored; automatic `TARGETPLATFORM` | [`parser.go`](https://github.com/podman-container-tools/podman/blob/v5.6.2/vendor/github.com/openshift/imagebuilder/dockerfile/parser/parser.go), [`builder.go`](https://github.com/podman-container-tools/podman/blob/v5.6.2/vendor/github.com/openshift/imagebuilder/builder.go) and [`dispatchers.go`](https://github.com/podman-container-tools/podman/blob/v5.6.2/vendor/github.com/openshift/imagebuilder/dispatchers.go), Podman's vendored image builder at v5.6.2 |
| `pull_policy: never` and `healthcheck`; not Podman socket compatibility | [Docker Compose services reference](https://docs.docker.com/reference/compose-file/services/), page version 2026-08-16 |
| macOS `arm64_*` bottles and Compose plugin caveat | Homebrew API: [podman](https://formulae.brew.sh/api/formula/podman.json) 6.1.3, [docker-compose](https://formulae.brew.sh/api/formula/docker-compose.json) 5.6.0, [node@24](https://formulae.brew.sh/api/formula/node@24.json) 24.21.0, [docker](https://formulae.brew.sh/api/formula/docker.json) 29.8.2; `bottle.stable.files` and `caveats` |

Not verified: these source instructions with this repository on a Mac.
