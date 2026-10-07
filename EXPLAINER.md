---
type: "Installation Explainer"
title: "OpenViking install explainer"
description: "Each command of the portable install of OpenViking: what it does, and which files, Git refs and container objects it touches."
tags: [install, docker, podman, compose, portable]
---
# OpenViking install explainer

This file explains the install of OpenViking from the branch `portable`.
The install follows [README.md](README.md#portable-install-kit-and-quick-start), section "Portable install kit and quick start".
For each command, this file tells what the command does.
It also tells which files, Git refs and Docker objects the command touches.

How to read this file:

- [Terms](#terms) gives the meaning of the special words.
- [Footprint](#footprint) lists all that the install puts on the machine.
- [Components](#components) shows what the image holds and which processes run.
- Each of the [steps](#steps) has a command, a short explanation and the expected result.
- A collapsed block "Details" follows each step. Open it to see each part that the step touches.
- The [reference](#reference) at the end lists each file and each variable of the install kit.

The install kit is the set of files that this repository adds to upstream OpenViking: scripts, tests, the Compose file and the build files.

This file is not an operations manual.
For backup, upgrade, rollback and problems, see [operations](docs/operations.md).

## Terms

| Term | Meaning |
| --- | --- |
| Clone | The copy of the repository on the machine, made with `git clone`. |
| Remote | A named URL of another Git repository, kept in the configuration of the clone. |
| Upstream | The public OpenViking project that this repository is based on. |
| Root API key | The secret that gives full access to the API of the server. |
| Host value | A value that is true on one machine only, for example a private address or a host name. |
| State directory | The directory `data/` of the clone. The server keeps its configuration and its data there. |
| Bind mount | A directory of the host that Docker makes visible inside a container. |
| Loopback | The address `127.0.0.1`. Only programs on the same machine can reach it. |
| Digest | The hash of an image. A reference with a digest always gives the same image. |
| Label | A name with a value in the metadata of an image. |
| Buildx builder | The part of Docker that runs an image build and keeps the build cache. |
| Compose project | The group of Docker objects that Docker Compose makes from one Compose file. |
| VikingBot | The agent framework that comes with OpenViking. It runs in the same container as the server. |
| Web Studio | The browser user interface of OpenViking. |

## Footprint

The install writes to three places: the clone, the local Docker and the temporary directory `$TMPDIR`.
The install kit makes no named Docker volume and writes no file in your home directory.

| Item | Location | Made in | Content |
| --- | --- | --- | --- |
| Clone | `openviking/` | Step 1 | The working tree and the Git directory `.git/`. |
| Remote `origin` | `.git/config` | Step 1 | The URL of your Git server. No script changes it. |
| Remote `upstream` | `.git/config`, the keys `remote.upstream.url`, `remote.upstream.pushurl`, `remote.upstream.tagOpt` and `remote.upstream.fetch` | Step 2 | Upstream OpenViking, fetch only. |
| Upstream tag | The ref `refs/upstream/tags/<tag>` and its objects in `.git/` | Step 3 | The history of one upstream release. |
| `.env` | The root of the clone | Steps 4 and 5 | The values of this machine for Docker Compose. It holds the root API key. Git ignores it. |
| `data/ov.conf` | `data/` in the clone | Step 6 | The server configuration. It holds the root API key. Git ignores `data/`. |
| Image `openviking:local` | The local Docker | Step 7 | The OpenViking image, built from the clone. |
| Build cache | The Buildx builder | Step 7 | The base image layers, the build layers and the cache mounts. |
| Container `openviking-openviking-1` | The local Docker, Compose project `openviking` | Step 9 | The running service. |
| Network `openviking_default` | The local Docker | Step 9 | The default network of the Compose project. |
| Published port | `127.0.0.1:1933` on the host | Step 9 | It maps to port 1933 of the container. Loopback only. |
| Server state | `data/data/` in the clone | Step 9 | The workspace that the server writes (`storage.workspace`). |
| Scanner image | The local Docker | Step 13 | `gitleaks`, pinned by digest. |
| Temporary files | `$TMPDIR` (default `/tmp`) | Steps 12 and 14 | Each script removes its files when it ends. |
| Git hooks (optional) | `.git/scan-hooks/` and the key `core.hooksPath` | [Install the Git hooks](#install-the-git-hooks) | Three hook files. |
| Host override (optional) | `.local/compose.host.yaml` and the line `COMPOSE_FILE` in `.env` | [Add a host override file](#add-a-host-override-file) | Compose settings of one machine. Git ignores `.local/`. |

### What is different on `portable`

Use `local-dev` for private development with upstream history.
`portable` holds the same files as commits without that history.
Only `portable` and its tags `portable-v*` go to a shared Git server ([branches](docs/branches.md)).
`sh scripts/promote.sh --version X.Y.Z` creates the portable commit and annotated tag after its checks ([promotion](docs/branches.md#promotion)).
A push needs a plan with `--dry-run` and separate approval.

| Subject | In a clone of `portable` |
| --- | --- |
| History | One commit for each promotion. A promotion copies the files of the private branch to `portable`. No upstream commit is an ancestor of `HEAD`. |
| Release tags | A tag `portable-vX.Y.Z` marks a release. `X.Y.Z` is the portable version. |
| Upstream version | No upstream tag is in the history. `scripts/build.sh` reads the upstream version from the `tag` line of `scripts/upstream-base`. |
| Image version | `<upstream version>+p<portable version>`, for example `0.4.22+p0.1.0`. The version label is then `0.4.22-p0.1.0`. |
| Label `source` | The image label `org.opencontainers.image.source` names upstream, unless you set `SOURCE_URL` for the build. |
| Scan | A host value is an error (level `fail`). Without the upstream base commit, the scan uses the `hit` lines of `scripts/upstream-base`. |
| Remotes | `origin` is the shared Git server. The remote `upstream` is absent until step 2. |

## Components

### What the image holds

`scripts/build.sh` builds one image from the `Dockerfile`.
The `Dockerfile` has four stages. Only the last stage is in the image.

| Stage | Base image | What the stage gives |
| --- | --- | --- |
| `rust-toolchain` | `RUST_IMAGE` (`rust:1.91.1-trixie`) | The Rust toolchain. The stage `py-builder` copies `/usr/local/cargo` and `/usr/local/rustup` from it. |
| `web-studio-builder` | `NODE_IMAGE` (`node:24-trixie-slim`) | The Web Studio bundle: `npm ci`, then `npm run build -- --base=/studio/` in `web-studio/`. |
| `py-builder` | `PYTHON_IMAGE` (`python:3.13-slim-trixie`) | The virtual environment `/app/.venv`. `uv sync --locked` installs the project with the extras `bot`, `gemini` and `opengauss`. The install compiles the Rust CLI and the native extensions. |
| Runtime (the last stage, no name) | `PYTHON_IMAGE` | The Debian packages `ca-certificates`, `curl`, `git` and `libstdc++6`, the directory `/app/.venv` and the two files of `deploy/docker/`. |

Each base image is pinned by digest in the `ARG` lines at the top of the `Dockerfile`.
The [update command](docs/update.md) detects new upstream releases and pin values, then qualifies one candidate in a separate clone.
It never changes the caller checkout or a running service.
The image holds no configuration, no key and no state: `/app/.openviking` is empty in the image.

The commands in the image:

| Command | Source | Function |
| --- | --- | --- |
| `openviking-entrypoint` | `deploy/docker/openviking-entrypoint.sh` | The entrypoint of the image. It waits for `ov.conf`, starts the server and answers the health check. |
| `openviking-pending-health` | `deploy/docker/pending_health_server.py` | A small HTTP server that answers each request with status 503 while `ov.conf` is absent. |
| `openviking-server` | `[project.scripts]` in `pyproject.toml` | The HTTP server: the API, the Web Studio at `/studio`, the MCP (Model Context Protocol) endpoint at `/mcp` and `/health`. |
| `vikingbot` | `[project.scripts]` in `pyproject.toml` | VikingBot. The server starts `vikingbot gateway` as a child process. |
| `ov`, `openviking` | `[project.scripts]` in `pyproject.toml` | The command-line client, a Rust program in the Python package. |

### Processes, ports and configuration files

| Process | Started by | Listens on | Reads |
| --- | --- | --- | --- |
| `openviking-entrypoint --with-bot` | Docker (`command` in `compose.yaml`) | No port | The environment and the path in `OPENVIKING_CONFIG_FILE` (`/app/.openviking/ov.conf`). |
| `openviking-server --host 0.0.0.0 --port 1933 --with-bot` | The entrypoint | `0.0.0.0:1933` in the container | `/app/.openviking/ov.conf` and `OPENVIKING_PUBLIC_BASE_URL`. |
| `vikingbot gateway --host 127.0.0.1 --port 18790` | The server | `127.0.0.1:18790` in the container. Compose does not publish this port. | The same `ov.conf`. |
| `openviking-pending-health` | The entrypoint, only while `ov.conf` is absent | The server port | Nothing. |
| `openviking-entrypoint --healthcheck` | Docker, every 30 s | No port | It runs `curl -fsS http://127.0.0.1:1933/health`. |

```text
host                                   container openviking-openviking-1
                                       image openviking:local

127.0.0.1:1933  ---------------------> 0.0.0.0:1933     openviking-server
(OPENVIKING_BIND:OPENVIKING_PORT)                        API, /studio, /mcp, /health
                                                              |
                                                              | Bot API proxy
                                                              v
                                       127.0.0.1:18790  vikingbot gateway

data/           <--- bind mount ---->  /app/.openviking/
  ov.conf                                ov.conf   (OPENVIKING_CONFIG_FILE)
  data/                                  data/     (storage.workspace)

.env  --->  docker compose  --->  container environment
network openviking_default (made by Compose)
```

## Prerequisites

| Tool | Version | Used by |
| --- | --- | --- |
| Git | 2.24 or later | Steps 1 to 3, `scripts/build.sh`, `scripts/scan.sh` and `scripts/public-check.sh`. |
| Docker | A version with Compose v2 and Buildx | Steps 7 to 10 and 12 to 14. |
| Docker Compose | v2 | Steps 8 to 10. |
| Docker Buildx | 0.19 or later | Step 7. |
| Node | 24 or later | The extension tests in [testing](docs/testing.md#pi-extension-tests) and the version check in `scripts/upstream-update.py`. |
| `sh` | A POSIX shell | Each script. |
| `python3` | Python 3 | `scripts/verify.py`, `scripts/public_check.py`, `scripts/upstream-update.py` and `scripts/update-propose.py` use the standard library only. |
| `openssl` | Any | Step 5, to make the root API key. Another source of 64 hex characters also works. |

Tested with Git 2.39.5, Compose 5.5.0 and Buildx 0.36.1.
Not verified: the minimum versions.

Check the installed versions:

```sh
git --version
docker compose version
docker buildx version
node --version
```

The build needs network access to Docker Hub, the Debian package servers, the npm registry, PyPI and crates.io.
It also needs disk space for the builder. [Image build](docs/image.md) gives the endpoints, the build times and the disk use.

[Mac specifics](#mac-specifics) lists the differences for the Podman install on an Apple silicon Mac.

## Steps

Run each command of steps 2 to 14 in the root of the clone.

Warning: `docker compose up` in a clone that holds live `data/` replaces the live container. Use a new clone for a test.

### Step 1. Clone the repository

```sh
git clone <url of the repo> openviking && cd openviking
```

You copy the repository from your Git server to the machine.
`<url of the repo>` is the URL of the repository on that server.
The clone holds the install kit and the source tree that the image build compiles.

Expected result: `git branch --show-current` prints `portable`.

<details>
<summary>Details: what the clone holds</summary>

- Git writes the working tree to `openviking/` and the history to `openviking/.git/`.
- Git sets the remote `origin` to `<url of the repo>`.
- Git fetches the branches and the tags of the server. A shared Git server holds only `portable` and the tags `portable-v*`.
- If the server has another default branch, add `-b portable` to `git clone`.
- To install a release, add `-b portable-vX.Y.Z`. Git then checks out the tag, and `git branch --show-current` prints nothing.
- A clone does not copy the remote `upstream` and does not install Git hooks. Step 2 and [Install the Git hooks](#install-the-git-hooks) do that.
- `.gitignore` excludes `.env`, `.env.*` (except `.env.example`), `data/` and `.local/`. The files of the later steps do not show in `git status`.

</details>

### Step 2. Create the remote `upstream`

```sh
sh scripts/setup-remotes.sh
```

The script adds a remote with the name `upstream` to the clone.
The remote points to upstream OpenViking and is fetch-only: a push to it fails.
Step 3 needs this remote.
Steps 2 and 3 serve comparisons with upstream and the next upstream sync. The build and the scan work without them.

Expected result:

```text
changed remote.upstream.url: '' -> 'https://github.com/volcengine/OpenViking.git'
changed remote.upstream.pushurl: '' -> 'DISABLED'
changed remote.upstream.tagOpt: '' -> '--no-tags'
changed remote.upstream.fetch: '' -> '+refs/upstream-none/*:refs/upstream/none/*'
origin: <url of the repo> (not changed)
upstream: https://github.com/volcengine/OpenViking.git (fetch only, push DISABLED, tagOpt --no-tags)
shared: remote 'shared' is absent (not configured; set SHARED_URL to create it)
```

<details>
<summary>Details: what <code>scripts/setup-remotes.sh</code> does</summary>

The script does these actions in this order:

1. It checks its argument, the value of `SHARED_REMOTE` and that the directory is in a Git repository.
2. It sets four keys in `.git/config`. It writes a key only when the value differs.
3. It removes `remote.upstream.mirror`, unless the key is unset or `false`.
4. It prints the URL of `origin` without a credential. It does not change `origin`.
5. It checks the keys of `upstream` again and prints the result.
6. With `SHARED_URL`, it creates or converts the remote `shared`. Without it, the script only reports that remote.

| Key | Value | Effect |
| --- | --- | --- |
| `remote.upstream.url` | `https://github.com/volcengine/OpenViking.git` | The fetch source. `UPSTREAM_URL` replaces it, for a mirror. |
| `remote.upstream.pushurl` | `DISABLED` | `git push upstream` fails. `DISABLED` is not a repository. |
| `remote.upstream.tagOpt` | `--no-tags` | A fetch puts no upstream tag into `refs/tags/`. |
| `remote.upstream.fetch` | `+refs/upstream-none/*:refs/upstream/none/*` | No upstream ref matches. A plain `git fetch upstream` transfers nothing. |

- The script uses no network and deletes no ref.
- A second run prints `upstream: no change`.
- `sh scripts/setup-remotes.sh --check` changes nothing. It exits 0 when the configuration is correct, and 1 when it is not.
- The remote `shared` accepts only `portable` and `portable-v*`. In a clone of the shared repository, `origin` is that server, so you do not need `shared`.
- Variables: `UPSTREAM_URL`, `SHARED_URL`, `SHARED_REMOTE` ([reference](#environment-variables-and-build-arguments)).
- [Remotes](docs/remotes.md) gives the reason for each setting.

</details>

### Step 3. Fetch the upstream release tag

```sh
sh scripts/fetch-upstream.sh "$(awk -F '\t' '$1 == "tag" { print $2 }' scripts/upstream-base)"
```

The script downloads one upstream release tag with its history into the clone.
The `awk` command reads the tag name from the `tag` line of `scripts/upstream-base`. This tag is the upstream release that the clone is based on.
You need the tag to compare a file with upstream and to merge the next upstream release.

Expected result: the script prints one commit ID. It is equal to the third field of the `tag` line of `scripts/upstream-base`.

<details>
<summary>Details: what <code>scripts/fetch-upstream.sh</code> does</summary>

The script does these actions in this order:

1. It checks the tag name: `v<digits>.<digits>.<digits>` with an optional suffix, or `cli@<digits>.<digits>.<digits>`. Another name gives exit code 2.
2. It runs `scripts/setup-remotes.sh --check`. A wrong remote `upstream` gives exit code 1.
3. It runs `git fetch --quiet --no-tags upstream "+refs/tags/<tag>:refs/upstream/tags/<tag>"`.
4. It prints the commit ID of `refs/upstream/tags/<tag>`.

- The script writes the ref `refs/upstream/tags/<tag>` and the objects of the tag into `.git/`. It never writes into `refs/tags/`.
- The fetch reads the URL of `remote.upstream.url`. By default that is GitHub.
- The fetch has the full history of the tag. Not verified: the download size and the time of this fetch.
- `git for-each-ref refs/upstream` lists the fetched tags.
- The option `--shallow` is refused in a clone that has commits. [Remotes](docs/remotes.md) tells how to use it in a new empty repository.
- On `portable` the tag is not an ancestor of `HEAD`. Thus `scripts/build.sh` still reads `scripts/upstream-base`.
- After the fetch, the scan compares files with the tag commit. The ref must point to the commit of the `tag` line, else the scan stops with exit code 2.

</details>

### Step 4. Create `.env`

```sh
cp .env.example .env
```

`.env` holds the values of this machine for Docker Compose.
Compose refuses to start without this file.
Git ignores `.env`, so it never goes into a commit.

Expected result: the file `.env` exists, and `git status --porcelain` prints nothing.

<details>
<summary>Details: the variables in <code>.env</code></summary>

| Variable | Value in `.env.example` | Effect |
| --- | --- | --- |
| `OPENVIKING_ROOT_API_KEY` | Empty | The root API key. Compose stops when it is empty. Step 5 sets it. |
| `OPENVIKING_IMAGE` | `openviking:local` | The image that Compose starts. |
| `OPENVIKING_PUBLIC_BASE_URL` | `http://127.0.0.1:1933` | The base URL that the server reports to clients (OAuth, MCP). |
| `OPENVIKING_BIND` | `127.0.0.1` | The host address of the published port. |
| `OPENVIKING_PORT` | `1933` | The host port that maps to port 1933 of the container. |

Compose uses `.env` in two ways:

- It replaces each `${NAME}` in `compose.yaml` with the value of `.env`.
- The line `env_file: .env` of `compose.yaml` passes each line of `.env` into the environment of the container.

For the last four variables, `compose.yaml` has the same default. Compose uses it when the line is absent from `.env`.

</details>

### Step 5. Set the root API key

```sh
openssl rand -hex 32
```

Open `.env` in an editor. Put the output of the command after `OPENVIKING_ROOT_API_KEY=`, with no blank and no quote.
The root API key gives full access to the API of the server. The server refuses an API call without a valid key.
Use hex characters only: step 6 puts the key into a `sed` command.

Expected result: the line `OPENVIKING_ROOT_API_KEY=` of `.env` has 64 hex characters. Step 8 fails when the value is empty.

Warning: `.env` holds the root API key. Do not commit the file, and do not show the key in a shared terminal or log.

<details>
<summary>Details: where the key goes</summary>

- `openssl rand -hex 32` prints 32 random bytes as 64 hex characters. It writes no file.
- `compose.yaml` reads the key as `${OPENVIKING_ROOT_API_KEY:?is empty; see .env.example}`. An empty value stops Compose with that message.
- Compose passes the key into the environment of the container.
- The server takes the key from `server.root_api_key` in `data/ov.conf`, not from the environment. Step 6 copies the key into that file.
- The key must have the same value in `.env` and in `data/ov.conf`.

</details>

### Step 6. Create `data/ov.conf`

```sh
mkdir -p data
sed "s/REPLACE_WITH_OPENVIKING_ROOT_API_KEY/$(sed -n 's/^OPENVIKING_ROOT_API_KEY=//p' .env)/" examples/ov.conf.quickstart > data/ov.conf
```

`data/ov.conf` is the configuration file of the server, in JSON.
The second command copies the quick start file and replaces its placeholder with the key of `.env`.
`data/` is the state directory: Compose mounts it into the container, and the server keeps all its data there.

Expected result: `data/ov.conf` exists and does not contain the text `REPLACE_WITH_OPENVIKING_ROOT_API_KEY`.

Warning: `data/ov.conf` holds the root API key and, later, the keys of your model endpoints. Do not commit it. `.gitignore` excludes `data/`.

<details>
<summary>Details: the content of the quick start configuration</summary>

The inner `sed` prints the key of `.env`. The outer `sed` puts it in place of the placeholder and writes `data/ov.conf`.

| Section of `examples/ov.conf.quickstart` | Value | Effect |
| --- | --- | --- |
| `server` | `host` `0.0.0.0`, `port` `1933`, `root_api_key` | The address in the container and the root API key. |
| `storage.workspace` | `/app/.openviking/data` | The server writes its data there. On the host this is `data/data/`. |
| `embedding.dense` | `provider` `openai`, `api_base` `http://127.0.0.1:9/v1`, a placeholder `model` and `api_key`, `dimension` `1024` | A placeholder embedding endpoint. Nothing listens on that address. |
| `vlm` | `provider` `openai`, `api_base` `http://127.0.0.1:9/v1`, a placeholder `model` and `api_key` | A placeholder VLM (vision language model) endpoint. |

- With the placeholder endpoints, the server starts and `/health` is healthy.
- Set real endpoints before you add content: [Set real embedding and VLM endpoints](#set-real-embedding-and-vlm-endpoints).
- Not verified: that indexing and search fail with the placeholder endpoints.
- The file has no `bot` section. VikingBot then takes its key from `server.root_api_key`.
- Without `data/ov.conf`, the container answers each request with status 503 and waits for the file.
- `examples/ov.conf.example` is the full upstream reference. It has trailing commas, which the server rejects. Do not copy it as it is.
- The retrieval example no longer includes `hotness_alpha` or `score_propagation_alpha`. Do not add these removed keys to a new configuration.

</details>

### Step 7. Build the image

```sh
sh scripts/build.sh gateway
```

On a Mac, use `BUILD_ENGINE=podman sh scripts/build.sh gateway` ([Mac specifics](#mac-specifics)).

The script builds the OpenViking image from the source tree of the clone.
It loads the image into the local Docker with the tag `openviking:local`.
No application image comes from a registry. Only the base images do, and each one is pinned by digest.
The first build takes several minutes.

To make the image label `org.opencontainers.image.source` name your repository, set `SOURCE_URL`:

```sh
SOURCE_URL=<url of the repo> sh scripts/build.sh gateway
```

Expected result: the script prints these two lines before the build output, and the build ends without an error.

```text
build: upstream version <tag> from scripts/upstream-base (no upstream tag in the history)
openviking build: target=gateway version=<upstream>+p<portable> label=<upstream>-p<portable> revision=<commit> epoch=<seconds>
```

Then `docker image inspect --format '{{.Id}}' openviking:local` prints the ID of the image.

<details>
<summary>Details: what <code>scripts/build.sh</code> does</summary>

The script does these actions in this order:

1. It reads the target (`smoke`, `gateway`, `test` or `release`) and changes to the root of the clone.
2. It stops when `docker-bake.hcl` is absent or the clone has no commit.
3. It compares the six base image pins of the `Dockerfile` with those of `docker-bake.hcl`. It stops when they differ.
4. It runs `git status --porcelain`. The tree is dirty when the command prints a line.
5. It computes the Git values of the table below.
6. It prints the line `openviking build: ...`.
7. It runs `docker buildx bake -f docker-bake.hcl smoke`.
8. It runs `docker buildx bake -f docker-bake.hcl gateway`.

The script does not push. A push needs the target `release` with `--push`.

The Git values:

| Variable | Source | Example |
| --- | --- | --- |
| `REVISION` | `git rev-parse HEAD` | A commit ID of 40 hex digits. |
| `SOURCE_DATE_EPOCH` | The commit time of `HEAD` | Seconds since 1970. |
| `PORTABLE_VERSION` | `git describe --tags --abbrev=8 --match 'portable-v*' HEAD` without `portable-v`. Without such a tag: `0-g<8 hex digits of the commit>`. A dirty tree adds `-dirty`. | `0.1.0` |
| `UPSTREAM_VERSION` | The nearest ancestor tag `v*`. On `portable` there is none: the `tag` line of `scripts/upstream-base`, without the `v`. | `<upstream version>` |
| `OPENVIKING_VERSION` | `<UPSTREAM_VERSION>+p<PORTABLE_VERSION>`, in lower case and with each `-` as `.` | `<upstream version>+p<portable version>` |

Each of `REVISION`, `SOURCE_DATE_EPOCH`, `PORTABLE_VERSION` and `OPENVIKING_VERSION` can be set in the environment. The script then uses your value.
`/health`, the Python package and `ov` report `OPENVIKING_VERSION`.

`docker-bake.hcl` is the build definition for `docker buildx bake`. A bake target is one named build in that file.

| Bake target | What it does | Output |
| --- | --- | --- |
| `image` | The definition of the runtime image: context `.`, the `Dockerfile`, the build arguments and the labels. | None of its own. |
| `smoke` | It builds `image` and runs one command without network. The command imports `openviking` and finds `ov`, `openviking-server` and `openviking-entrypoint`. | Build cache only. |
| `gateway` | `image` with the tag of `GATEWAY_IMAGE`. | `type=docker`: the image goes into the local Docker. |
| `builder` | The stage `py-builder`. The target `test` copies `uv` from it. | None of its own. |
| `test` | The upstream lite test set in the image. Not a part of the install. | Build cache only. |
| `release` | A build for `RELEASE_PLATFORMS`. It needs a clean tree and `--oci FILE` or `--push`. Not a part of the install. | An OCI (Open Container Initiative image format) archive or a pushed image. |

The stages of the `Dockerfile` are in [What the image holds](#what-the-image-holds).

The labels of the image:

| Label | Value | Set in |
| --- | --- | --- |
| `org.opencontainers.image.source` | `SOURCE_URL` | `docker-bake.hcl` |
| `org.opencontainers.image.revision` | `REVISION` | `docker-bake.hcl` |
| `org.opencontainers.image.version` | `<UPSTREAM_VERSION>-p<PORTABLE_VERSION>` | `docker-bake.hcl` |
| `org.opencontainers.image.created` | The time of `SOURCE_DATE_EPOCH` | `docker-bake.hcl` |
| `org.opencontainers.image.title` | `OpenViking` | `docker-bake.hcl` |
| `org.opencontainers.image.licenses` | `AGPL-3.0` | `docker-bake.hcl` |
| `org.opencontainers.image.base.name` | `PYTHON_IMAGE` | `Dockerfile` |
| `org.opencontainers.image.base.digest` | `PYTHON_DIGEST` | `Dockerfile` |

Other facts of the build:

- The build context is the clone, limited by `.dockerignore`. That file excludes all paths, then permits the sources of the `COPY` lines.
- `.env`, `data/`, `.local/` and `.git/` never reach the builder.
- The bake file passes `UV_LOCK_STRATEGY=locked`. The build fails when `uv.lock` is stale.
- The provenance and SBOM (list of software components and versions) attestations are off, unless `PROVENANCE=true`.
- The `Dockerfile` uses cache mounts for npm, uv, Cargo and ccache. They stay in the Buildx builder and make the next build shorter.
- A plain `docker build` of the `Dockerfile` stops with `OPENVIKING_VERSION build arg is required`. Use the script.
- `GATEWAY_IMAGE=<name>:<tag> sh scripts/build.sh gateway` gives the image another tag. Then set `OPENVIKING_IMAGE` in `.env` to the same value.
- [Image build](docs/image.md) gives the pins, the network endpoints, the build times and the disk use.

</details>

### Step 8. Check the Compose configuration

```sh
docker compose config --quiet
```

Compose reads `compose.yaml` and `.env` and checks them. It starts nothing and changes nothing.
Run this check after each change of `.env`.

Expected result: no output and exit code 0.
With an empty key, the command fails with a message that ends with `is empty; see .env.example`.

Warning: do not run the command without `--quiet` in a shared terminal. The full output holds the root API key.

<details>
<summary>Details: what <code>compose.yaml</code> defines</summary>

| Key | Value | Effect |
| --- | --- | --- |
| `name` | `openviking` | The Compose project name. It is the prefix of the container name and the network name. |
| Service | `openviking` | The one service of the file. |
| `image` | `${OPENVIKING_IMAGE:-openviking:local}` | The image of step 7. |
| `pull_policy` | `never` | Compose never pulls the image. A missing image is an error. |
| `build` | Absent | Compose never builds the image. Only `scripts/build.sh` computes the version and the labels. |
| `restart` | `unless-stopped` | Docker starts the container again after a failure and after a restart of Docker. |
| `command` | `--with-bot` | The entrypoint starts the server with VikingBot. |
| `env_file` | `.env` | Each line of `.env` goes into the environment of the container. |
| `environment` | `OPENVIKING_ROOT_API_KEY`, `OPENVIKING_PUBLIC_BASE_URL`, `OPENVIKING_SERVER_HOST=0.0.0.0`, `OPENVIKING_SERVER_PORT=1933` | The entrypoint starts the server on this address and port. |
| `ports` | `${OPENVIKING_BIND:-127.0.0.1}:${OPENVIKING_PORT:-1933}:1933` | The published port. The default is loopback only. |
| `volumes` | `./data:/app/.openviking` | A bind mount of the state directory. The file uses no named volume. |
| `healthcheck` | `openviking-entrypoint --healthcheck`, interval 30 s, timeout 5 s, 5 retries, start period 60 s | Docker marks the container as `healthy` or `unhealthy`. |

Compose also reads the variable `COMPOSE_FILE` of `.env`: [Add a host override file](#add-a-host-override-file).

</details>

### Step 9. Start the service

```sh
docker compose up -d
```

Compose makes the network and the container of the project `openviking` and starts the container in the background.
Do not add `--build` or `--pull`: the image of step 7 is the one to run.

Expected result: Compose reports the network `openviking_default` and the container `openviking-openviking-1`. The command exits with code 0.

Warning: the project name is `openviking` in each clone. In a clone that holds live `data/`, this command replaces the live container.

<details>
<summary>Details: what starts and what it writes</summary>

Docker objects:

| Object | Name | Notes |
| --- | --- | --- |
| Network | `openviking_default` | The default network of the project. The container joins only this network. |
| Container | `openviking-openviking-1` | From the image in `OPENVIKING_IMAGE`. |
| Published port | `127.0.0.1:1933` to container port 1933 | From `OPENVIKING_BIND` and `OPENVIKING_PORT`. |
| Bind mount | `data/` to `/app/.openviking` | Read and write. |

The start in the container:

1. Docker runs `openviking-entrypoint --with-bot`.
2. The entrypoint looks for `/app/.openviking/ov.conf`. Without the file, it starts `openviking-pending-health` and waits until the file exists.
3. The entrypoint reads the port from `OPENVIKING_SERVER_PORT`. Without that variable, it reads `server.port` of `ov.conf`.
4. The entrypoint starts `openviking-server --host 0.0.0.0 --port 1933 --with-bot`.
5. The server reads `ov.conf` and starts `vikingbot gateway` on `127.0.0.1:18790`. It waits until VikingBot is ready.
6. The server listens on port 1933.
7. The entrypoint calls `/health` each second until the answer is good. After 120 attempts without a good answer, it stops the server and exits with code 1.

What the container writes into `data/`:

- The server writes its workspace to `data/data/`, the value of `storage.workspace`.
- VikingBot keeps its data in `data/data/bot/`. The server writes the output of VikingBot to `data/data/bot/logs/vikingbot.log`.
- The container path is `/app/.openviking/data/bot/logs/vikingbot.log`, inside the state mount. An isolated Compose test confirms both paths.
- The log survives container replacement while you keep `data/`.
- Not verified: the names of the other files below `data/data/`.
- The image runs as root. On a Linux host, the files that the container writes belong to root.
- Not verified: the owner of these files with a rootless Docker or on a Mac.

Other facts:

- A missing image stops the command with `No such image`. Run step 7 first.
- If port 1933 is in use on the host, set `OPENVIKING_PORT` in `.env` to a free port. Set the same port in `OPENVIKING_PUBLIC_BASE_URL`.
- `docker compose logs --tail 200 openviking` shows the output of the entrypoint and the server.

</details>

### Step 10. Wait until the service is healthy

```sh
docker compose ps
```

The command lists the container of the project with its state.
The health check has a 30 s interval; Docker can use a shorter interval during startup.
Run the command again until the state is good.

Expected result: the column `STATUS` shows `healthy` for the service `openviking`.

<details>
<summary>Details: the health check</summary>

- The check runs `openviking-entrypoint --healthcheck` in the container. That command runs `curl -fsS http://127.0.0.1:1933/health`.
- Before the first success, failed checks during the first 60 s (`start_period`) do not count toward `unhealthy`.
- The first successful check marks the container healthy, even during that grace period. Later failures count normally.
- Five counted failures in sequence give the state `unhealthy`.
- Docker Engine 29.7.2 first passed at 10.2 s in an isolated Linux Compose test. Startup time varies.
- `/health` needs no key. It answers with `"healthy": true` and the version.
- A health check does not prove that an authenticated call works. Step 11 and step 12 check more.

</details>

### Step 11. Check the server from outside

```sh
python3 scripts/verify.py http://127.0.0.1:1933
```

The script calls the published port as a client does.
It checks that the server is healthy and that the server refuses a call without a key.
If you changed `OPENVIKING_BIND` or `OPENVIKING_PORT`, use that address in the URL.

Expected result: exit code 0 and these two lines. The status in the second line is 401 or 403.

```text
ok - /health returns 200 with healthy true, version <version>
ok - /api/v1/system/status without a key gives 401
```

<details>
<summary>Details: what <code>scripts/verify.py</code> does</summary>

1. It sends `GET <base URL>/health` until the answer has status 200 and `"healthy": true`, or until the timeout ends. It tries again every 3 s.
2. It sends `GET <base URL>/api/v1/system/status` without a key. Only status 401 or 403 passes.

- The script never sends an API key and never reads `.env`.
- It uses the Python standard library only.
- `--timeout SECONDS` sets the wait for a healthy answer. The default is 10.
- Exit codes: 0 pass, 1 fail, 2 usage error.
- The Web Studio is at `http://127.0.0.1:1933/studio/`. The address `/` redirects to it.

</details>

### Step 12. Test the image

```sh
sh tests/test_image.sh openviking:local
```

The test starts a second, temporary container of the image without network and checks it.
It does not use the service of step 9, `.env` or `data/`.
The test takes more than 30 s, because one check waits that long.

Expected result: each line starts with `ok - `, the last line is `all tests passed`, and the exit code is 0.

<details>
<summary>Details: what <code>tests/test_image.sh</code> checks and makes</summary>

What the test makes:

| Object | Name | Removed |
| --- | --- | --- |
| Container | `openviking-image-test-<process ID>`, with `--network none` and `--rm` | At the end of the test. |
| State directory | `$TMPDIR/openviking-image-test.XXXXXX`, mounted on `/app/.openviking` | At the end of the test. |
| Configuration | An `ov.conf` in that directory, with a random root API key and placeholder endpoints | With the directory. |

The test publishes no port. It calls the API with Python inside the container through `docker exec`.

What the test checks:

1. The labels `source`, `revision`, `version`, `created`, `base.name` and `base.digest` are set and have the correct form.
2. No label contains the host name of the machine.
3. The image user is `root` (`EXPECTED_USER`).
4. `/app/.openviking` is empty in the image, and the image holds no `ov.conf`, `ovcli.conf` or `.env` file.
5. `/health` answers with status 200 and `"healthy": true`.
6. The version of `/health` matches the version label.
7. A call without a key gets status 401. A call with the root API key gets status 200.
8. The server stays healthy for 30 s with model endpoints that it cannot reach.

Variables: `TEST_NAME_PREFIX`, `EXPECTED_VERSION`, `EXPECTED_USER`, `HEALTH_TIMEOUT` ([reference](#environment-variables-and-build-arguments)).

`sh tests/test_compose.sh` is a second test. It starts `compose.yaml` in a temporary copy with its own project name, port and `data/`.

</details>

### Step 13. Get the scanner image

```sh
docker pull "$(sed -n 's/^GITLEAKS_IMAGE=${GITLEAKS_IMAGE:-\(.*\)}$/\1/p' scripts/scan.sh)"
```

The scan of step 14 runs the program `gitleaks` from this image.
The reference has a digest, so Docker gets exactly the image that the scan expects.
You do this one time for each machine. After that, the scan needs no network.

Expected result: the pull ends without an error.

<details>
<summary>Details: the scanner image</summary>

- The quick start block of [README.md](README.md) pulls this image before the scan. [Secret handling](docs/secret-handling.md), section "Scanner", uses the same reference.
- The reference is the default of `GITLEAKS_IMAGE` in `scripts/scan.sh`. Use the reference of that line if it differs from the command above.
- Without the image, `scripts/scan.sh` stops with exit code 2 and prints the `docker pull` command.
- The scan never pulls the image itself.
- Without Docker, the scan requires the `GITLEAKS_VERSION` from `scripts/scan.sh` in `PATH`. `SCAN_ENGINE` selects the engine.

</details>

### Step 14. Scan the tracked files

```sh
sh scripts/scan.sh tree
```

The scan looks for secrets and host values in the tracked files of the clone.
On `portable`, a host value is an error.
The scan shows that the clone is clean before you change it.

Expected result: exit code 0.
The last word of the scan summary is `fail` on `portable` or a `portable-v*` tag, and `warn` on another branch.
The output block shows the `portable` form:

```text
scan: 0 secret finding(s), 0 host-value finding(s), 0 policy finding(s), level fail
scan: <n> finding(s) in upstream content accepted (<tag>, baseline of scripts/upstream-base)
```

`<n>` is the number of upstream example values that the scan accepted.
After step 3, the second line ends with `(<tag>, base commit)`.

<details>
<summary>Details: what <code>scripts/scan.sh tree</code> does</summary>

The script does these actions in this order:

1. It selects the engine. With Docker, the scanner image must be present.
2. It makes a work directory `$TMPDIR/scan.XXXXXX`. It removes the directory when it ends.
3. It builds the rule file from `.gitleaks.toml`, `scripts/host-values.deny` and `scripts/host-values.regex`. It adds `.local/host-values.deny` when that file exists.
4. It reads `scripts/upstream-base`.
5. It sets the level for host values: `fail` on the branch `portable` and on a tag `portable-v*`, else `warn`.
6. It copies the tracked files of the working tree into the work directory. It adds the staged content that differs.
7. It runs the policy checks on each file.
8. It runs `gitleaks` on the copy.
9. It drops the host-value findings in upstream content.
10. It prints one line for each finding, then the summary line.

The three kinds of finding:

| Finding | Source of the rules | Result |
| --- | --- | --- |
| Secret | `.gitleaks.toml` | Always fails. |
| Host value | `scripts/host-values.deny`, `scripts/host-values.regex` and the optional `.local/host-values.deny` | Fails at level `fail`. Prints a warning at level `warn`. |
| Policy | A tracked archive, database dump or Git bundle, a tracked file in `.local/`, a tracked file with the name `.gitleaksignore` or `.gitleaksbaseline` | Always fails. |

Other facts of the scan:

- With Docker, `gitleaks` runs in a container with the name `scan-gitleaks-<process ID>-<number>`. The container has no network, mounts the work directory read-only and is removed at the end.
- The output gives the file, the line and the rule. It does not give the secret value.
- The scan does not read untracked and ignored files: `.env`, `data/` and `.local/`.
- Upstream content: the upstream tree holds example keys and example addresses. The scan accepts a host-value finding in a file that is equal to the upstream file.
- Without the upstream base commit, the scan accepts a line that is a `hit` line of `scripts/upstream-base`.
- `--level warn` or `--level fail` sets the level.
- Exit codes: 0 clean, 1 finding, 2 usage or tool error.
- Other modes: `staged`, `history`, `image`, `all`, `selftest` and `baseline`. [Secret handling](docs/secret-handling.md) describes them.

</details>

## Optional steps

### Set real embedding and VLM endpoints

The server needs two model services before it can index and search content.
The embedding endpoint turns text into vectors for the search.
The VLM (vision language model) endpoint is the model that the server uses to process content.

1. Open `data/ov.conf` in an editor.
   The file must stay valid JSON, with no trailing comma.
2. Set `provider`, `model`, `api_base`, `api_key` and `dimension` in the section `embedding.dense`.
   These are the values of your embedding endpoint.
3. Set `provider`, `model`, `api_base` and `api_key` in the section `vlm`.
   These are the values of your VLM endpoint.
4. Stop the service: `docker compose stop openviking`.
   The server reads `ov.conf` when it starts.
5. Start the service: `docker compose up -d`.
   Then repeat steps 10 and 11.

Warning: `data/ov.conf` then holds the keys of your endpoints. Do not commit it and do not print it.

<details>
<summary>Details: endpoints and the container network</summary>

- The server calls the endpoints from inside the container. There, `127.0.0.1` is the container, not the host.
- Use an address that the container can reach.
- `examples/ov.conf.example` shows the other sections, for example `rerank`, `bot` and `log`. Take single sections from it, as valid JSON.
- [Operations](docs/operations.md), section "A new clone", has the table of the keys.

</details>

### Add a host override file

A host override file holds the Compose settings of one machine.
Examples are an external network, a fixed container name and a public URL.
The file stays out of Git, so the tracked `compose.yaml` stays the same on each machine.

1. Write the settings into the file `.local/compose.host.yaml`.
   [Host configuration](docs/host-configuration.md) has an example.
2. Add this line to `.env`:

   ```sh
   COMPOSE_FILE=compose.yaml:.local/compose.host.yaml
   ```

   Compose then reads the two files and merges them.
3. Check the result: `docker compose config --quiet`.
   The exit code must be 0.
4. Apply the change: `docker compose up -d`.
   Compose replaces the container when its settings changed.

<details>
<summary>Details: the override file</summary>

- `.gitignore` excludes `.local/`. A tracked file in `.local/` is a policy finding of the scan.
- `env_file: .env` also passes `COMPOSE_FILE` into the container. The server does not read it.
- A fixed `container_name` replaces the name `openviking-openviking-1`.

</details>

### Install the Git hooks

```sh
sh scripts/install-hooks.sh
```

A Git hook is a script that Git runs before a commit or a push.
The hooks of this repository run `scripts/scan.sh` to find secrets and host values before a commit or a push.
For `portable` and `portable-v*`, the pre-push hook then runs the [public check](docs/public-check.md) on the pushed object.
Install them before you commit in the clone.

The [continuous integration (CI) checks](docs/ci.md) read pins from their source files and need a runner.
A workflow file registers no runner and does not enable Actions on any server.

Expected result: the script prints `core.hooksPath = <path of the clone>/.git/scan-hooks (main checkout and all worktrees)`.
Then `sh scripts/install-hooks.sh --check` prints a line that starts with `ok:`.

<details>
<summary>Details: what <code>scripts/install-hooks.sh</code> does</summary>

1. It stops when `core.hooksPath` already has another value.
2. It makes the directory `.git/scan-hooks/`.
3. It copies `scripts/git-hooks/dispatch` there three times: as `pre-commit`, `pre-merge-commit` and `pre-push`.
4. It sets the Git key `core.hooksPath` to the absolute path of that directory.

| Hook | When Git runs it | What it does |
| --- | --- | --- |
| `pre-commit` | Before a commit | `scripts/scan.sh staged`. When a rule file or `scripts/scan.sh` is staged, `scripts/scan.sh selftest` runs first. |
| `pre-merge-commit` | Before a merge commit without a conflict | The same as `pre-commit`. |
| `pre-push` | Before a push | First the push guard, then `scripts/scan.sh history` for each pushed ref. After a successful scan, `scripts/public-check.sh --ref <object ID>` checks `portable` and `portable-v*`. |

- The copy in `.git/scan-hooks/` is the dispatcher. It runs `scripts/git-hooks/<hook>` of the working tree where the hook runs.
- The push guard applies to each remote other than `origin` and `upstream`. Such a remote takes only `portable` and `portable-v*`.
- With the Docker scanner engine, the commit or the push stops without Docker or the scanner image.
- The public check needs Git, POSIX `sh` and Python 3.
- `git commit --no-verify` and `git push --no-verify` skip the hooks.
- Run the script again after the clone moves to another path. `--check` reports that case.
- `sh scripts/install-hooks.sh --uninstall` removes the key and the three files.
- [Secret handling](docs/secret-handling.md), section "Hooks", gives the full rules.

</details>

### Remove the install

These steps return the machine to the state before step 1.
Run steps 1 to 4 in the root of the clone.

Warning: step 5 deletes `data/` and `.env`: all stored content, the server configuration and the root API key. There is no undo. Make a backup first if you need the data ([operations](docs/operations.md), section "Backup").

1. Stop and remove the service: `docker compose down`.
   Compose removes the container and the network `openviking_default`. `data/` stays.
2. Remove the image: `docker image rm openviking:local`.
   Use the value of `OPENVIKING_IMAGE` if you changed it.
3. Remove the scanner image: `docker image rm <reference of step 13>`.
   Skip this step if another repository uses the same image.
4. Remove the build cache: `docker buildx prune`.
   Skip this step if you build other projects on this machine.
5. Delete the clone: `cd .. && rm -rf openviking`.
   This also removes the remotes, the fetched upstream tag and the Git hooks, because they are in `.git/`.

Warning: `docker buildx prune` removes the unused build cache of each project on the builder, not only of this repository.

<details>
<summary>Details: what stays and what needs more rights</summary>

- The install kit leaves nothing outside the clone, the local Docker and `$TMPDIR`. After the five steps, no file and no Docker object of the install stays.
- On a Linux host, the files that the container wrote into `data/` belong to root. If `rm` refuses, run the `rm` command with `sudo`.
- To keep the clone and remove only the hooks, run `sh scripts/install-hooks.sh --uninstall`.
- To keep the clone and remove only the remote `upstream`, see [remotes](docs/remotes.md), section "Remove the remote `upstream`".
- To keep the data, move `data/` and `.env` out of the clone before step 5.

</details>

## Mac specifics

Not verified: these steps on a Mac. [Mac](docs/mac.md) has the full steps and the sources.
The steps are the same as on Linux. The table gives the differences.

| Step | Difference on a Mac |
| --- | --- |
| Prerequisites | Use an Apple silicon Mac (`arm64`) with Podman 5 or later. Docker Compose v2 or later supplies the provider. Podman is the only runtime of [Mac](docs/mac.md). Homebrew formulas `podman`, `docker-compose`, `node@24` and `docker` each have an `arm64` bottle. A bottle is a pre-built package. The Docker formula supplies the command-line client (CLI) only. Put `$(brew --prefix node@24)/bin` first on `PATH`. The shell of macOS is `zsh`: keep each `export` line in `~/.zshrc`, not in a bash file. Not verified: installation of these packages on a Mac. |
| Prerequisites | Create the virtual machine (VM) with `podman machine init --cpus 4 --memory 8192 --disk-size 50`. Start it with `podman machine start`. The example allocates 4 CPUs, 8 GiB of memory and a 50 GiB disk. Not verified: this allocation and these commands on a Mac. |
| Prerequisites | Set `PODMAN_COMPOSE_PROVIDER` to `$(brew --prefix)/bin/docker-compose`. Podman passes the Compose arguments and selects its socket for the provider. `podman compose` needs no `DOCKER_HOST` setting. Set `DOCKER_HOST` to the Podman socket for the scripts that call `docker`. [Mac](docs/mac.md#install-and-start-podman) gives the socket command and the Docker Compose plugin setting. Not verified: these settings on a Mac. |
| 1 | Keep the checkout and `$TMPDIR` in shared paths. The Podman macOS defaults share `/Users`, `/private` and `/var/folders` at the same paths in the VM. Not verified: these shares on a Mac. |
| 7 | Build with `BUILD_ENGINE=podman sh scripts/build.sh gateway`. The build uses native `linux/arm64`. The `test` and `release` targets need BuildKit and run on Linux. `BUILD_ENGINE=podman` refuses both targets. Not verified: an `arm64` build, the `arm64` image at run time or the scripts with macOS BSD tools. |
| 8 to 10 | Use `podman compose config --quiet`, `podman compose up -d` and `podman compose ps`, with the same arguments. Keep `pull_policy: never` and the health check of `compose.yaml`. Not verified: these commands, the pull policy or the health check through the Podman socket. |
| 12 | Run `sh tests/test_image.sh openviking:local` with the Docker CLI against the Podman socket. `tests/test_compose.sh` also needs the Docker Compose plugin. Not verified: either test with Podman. |
| 13 and 14 | Use `podman pull` with the scanner reference of step 13. Run `SCAN_ENGINE=docker sh scripts/scan.sh tree`. The scanner uses the Docker CLI against the same Podman socket. Not verified: the scan with Podman. |

A successful health check can mark the container healthy during the 60 s startup grace period.
An isolated Linux Docker test first passed at 10.2 s; this is not a Mac timing guarantee.
Not verified: the health check timing on a Mac.

## Reference

### Files of the install kit

Scripts:

| File | Function |
| --- | --- |
| `scripts/setup-remotes.sh` | Creates or repairs the fetch-only remote `upstream`. With `SHARED_URL`, also the remote `shared`. `--check` changes nothing. |
| `scripts/fetch-upstream.sh` | Fetches one upstream release tag into `refs/upstream/tags/<tag>`. |
| `scripts/upstream-update.py` | Detects updates, qualifies one candidate in a separate clone, or reads release notes. See [updates](docs/update.md). |
| `scripts/update-propose.py` | Publishes one qualified development pull request or failure issue; see [CI](docs/ci.md#development-update-workflow). |
| `scripts/build.sh` | Computes the version values from Git and runs `docker buildx bake` for `smoke`, `gateway`, `test` or `release`. |
| `scripts/verify.py` | Checks `/health` of a started server and that a call without a key is refused. |
| `scripts/scan.sh` | Scans for secrets, host values and policy findings. Modes: `tree`, `staged`, `history`, `image`, `all`, `selftest`, `baseline`. |
| `scripts/public-check.sh` | Runs the offline public tree check. `--ref OBJECT` checks a committed tree; `--write-upstream-map` writes the upstream blob map. |
| `scripts/public_check.py` | Checks word classes, document references, document values, source pins and tree rules with the Python standard library. |
| `scripts/promote.sh` | With no option, checks and prints a dry run. `--version X.Y.Z` creates the portable commit and annotated tag after checks. A push needs a plan with `--dry-run` and separate approval; see [promotion](docs/branches.md#promotion). |
| `scripts/install-hooks.sh` | Installs the hook dispatcher and sets `core.hooksPath`. Options: `--check`, `--uninstall`. |
| `scripts/git-hooks/dispatch` | The file that Git runs for each hook. It runs the hook of the current working tree. |
| `scripts/git-hooks/pre-commit` | Runs `scripts/scan.sh staged` before a commit. |
| `scripts/git-hooks/pre-merge-commit` | Runs `pre-commit` before a merge commit. |
| `scripts/git-hooks/pre-push` | The push guard, then `scripts/scan.sh history` for each pushed ref. After a successful scan, the public check reads the pushed object for `portable` and `portable-v*`. |

Checks workflows:

| File | Function |
| --- | --- |
| `.gitea/workflows/checks.yml` | Calls development checks; builds on `local-dev` and `sync/*` pushes and pull requests. |
| `.github/workflows/checks.yml` | Calls portable checks; builds only on manual dispatch. |
| `.gitea/workflows/upstream-update.yml` | Detects updates daily or manually and qualifies at most one candidate per run for a development proposal without changing `portable`. |

Tests:

| File | Command | Needs | What it checks |
| --- | --- | --- | --- |
| `tests/test_image.sh` | `sh tests/test_image.sh <image>` | Docker, a built image | The image: labels, user, no state, `/health`, version, refusal without a key. |
| `tests/test_compose.sh` | `OPENVIKING_IMAGE=<image> sh tests/test_compose.sh` | Docker Compose, a built image | `compose.yaml` in a temporary copy: `config`, `up -d` without a pull, health, `scripts/verify.py`, loopback port. |
| `tests/test_setup_remotes.sh` | `sh tests/test_setup_remotes.sh` | Git | `scripts/setup-remotes.sh` and `scripts/fetch-upstream.sh` against a local bare repository. |
| `tests/test_scan.sh` | `sh tests/test_scan.sh` | Docker, the scanner image | `scripts/scan.sh`, the hooks and `scripts/install-hooks.sh` in temporary repositories. |
| `tests/test_public_check.sh` | `sh tests/test_public_check.sh` | Git, POSIX `sh`, Python 3 | Word classes, document references, freshness, pins, tree rules, upstream maps and pushed-object hook checks. No network or container. |
| `tests/test_workflows.sh` | `sh tests/test_workflows.sh` | Git, POSIX `sh`, Python 3 | The strict YAML subset, run lines, pinned actions and build conditions. Uses the standard library; no YAML package, network or job execution. |
| `tests/test_build_version.sh` | `sh tests/test_build_version.sh` | Git | The version step of `scripts/build.sh` on a branch without upstream history. It builds no image. |
| `tests/test_promotion.sh` | `sh tests/test_promotion.sh` | Git, POSIX `sh`, Python 3 | The commit definition and `scripts/promote.sh` in temporary repositories with local bare remotes. Covers checks, tags, pinned pushes and audits; see [testing](docs/testing.md#tests). |
| `tests/test_upstream_update.py` | `python3 -m unittest tests.test_upstream_update -v` | Python 3, Git, the upstream base commit | Detection, merge conflicts, deletion rules, qualification, bundles and caller isolation. No network or container. |
| `tests/test_update_propose.py` | `python3 -m unittest tests.test_update_propose -v` | Python 3 | Candidate selection, duplicate control, candidate-only publication, failure evidence and credential isolation through injected process and API calls. No network or container. |
| Bake target `test` | `sh scripts/build.sh test` | Docker with Buildx, network | The upstream lite test set inside the built image. |

The upstream update tests compare deliberate deletions with the upstream base commit.
Run them in a development checkout with that commit available, not in a clone of `portable`.

Build and run files:

| File | Function |
| --- | --- |
| `Dockerfile` | The four build stages of the image. |
| `.dockerignore` | The allowlist of the paths that go into the build context. |
| `docker-bake.hcl` | The bake targets, the build variables and the image labels. |
| `compose.yaml` | The service `openviking` of the Compose project `openviking`. |
| `.env.example` | The template of `.env`, with each variable that `compose.yaml` reads. |
| `examples/ov.conf.quickstart` | A minimal valid server configuration with placeholder endpoints. |
| `examples/ov.conf.example` | The full upstream configuration reference. Not valid JSON as it is. |
| `deploy/docker/openviking-entrypoint.sh` | The entrypoint of the image. |
| `deploy/docker/pending_health_server.py` | The HTTP server that answers with status 503 while `ov.conf` is absent. |

Data files of the checks and the build:

| File | Function |
| --- | --- |
| `scripts/upstream-base` | The upstream tag and its commit (`tag` line), and the upstream content that the scan accepts (`archive` and `hit` lines). |
| `scripts/upstream-removed` | Deliberate upstream deletions: exact paths and directory prefixes. The update command applies them; the public check refuses returned paths. |
| `scripts/public-rules.json` | The public check rules: word patterns, document contracts, pin sources, tree rules and exact content exceptions. |
| `scripts/upstream-blobs.json` | The generated upstream path and blob map. The public check uses it when the upstream commit is absent. |
| `scripts/host-values.deny` | The tracked deny list: literal patterns of host values. It holds generic patterns only. |
| `scripts/host-values.regex` | Regular expressions for private network addresses. |
| `.gitleaks.toml` | The secret rules of `gitleaks` and the content allowlists for upstream example values. |
| `.local/host-values.deny` | Optional and not tracked: the host values of one machine. |

The directories `scripts/build_support/` and `scripts/maintenance/` are upstream files, not parts of the install kit.

### Environment variables and build arguments

Each variable is optional, unless the table says that it is required.

Docker Compose (`compose.yaml`, set in `.env`):

| Variable | Default | Effect |
| --- | --- | --- |
| `OPENVIKING_ROOT_API_KEY` | None; required | The root API key. An empty value stops Compose. |
| `OPENVIKING_IMAGE` | `openviking:local` | The image that Compose starts. |
| `OPENVIKING_PUBLIC_BASE_URL` | `http://127.0.0.1:1933` | The base URL that the server reports to clients. |
| `OPENVIKING_BIND` | `127.0.0.1` | The host address of the published port. |
| `OPENVIKING_PORT` | `1933` | The host port of the published port. |
| `COMPOSE_FILE` | Not set: Compose reads `compose.yaml` | The list of Compose files, with `:` between them. |

The container (`Dockerfile` and `deploy/docker/openviking-entrypoint.sh`):

| Variable | Default | Effect |
| --- | --- | --- |
| `OPENVIKING_CONFIG_FILE` | `/app/.openviking/ov.conf` | The path of the server configuration. |
| `OPENVIKING_CLI_CONFIG_FILE` | `/app/.openviking/ovcli.conf` | The path of the client configuration of `ov`. |
| `OPENVIKING_SERVER_HOST` | `0.0.0.0` | The address of the server in the container. `compose.yaml` sets the same value. |
| `OPENVIKING_SERVER_PORT` | `server.port` of `ov.conf`, else `1933` | The port of the server in the container. `compose.yaml` sets `1933`. |
| `OPENVIKING_WITH_BOT` | `1` | `1` starts VikingBot, `0` does not. The argument `--with-bot` of `compose.yaml` has the same effect as `1`. |
| `OPENVIKING_HEALTH_MAX_ATTEMPTS` | `120` | The number of `/health` calls, one each second, before the entrypoint stops a server that does not answer. |
| `OPENVIKING_CONF_CONTENT` | Not set | The full JSON of `ov.conf`. The entrypoint writes it to the file when the file is absent. |

`scripts/setup-remotes.sh` and `scripts/fetch-upstream.sh`:

| Variable | Default | Effect |
| --- | --- | --- |
| `UPSTREAM_URL` | `https://github.com/volcengine/OpenViking.git` | The URL of the remote `upstream`, for a mirror. Set it for the two scripts. |
| `SHARED_URL` | Empty | With a value, the script creates or converts the remote `shared` with this URL. |
| `SHARED_REMOTE` | `shared` | The name of that remote. |

`scripts/build.sh` and `docker-bake.hcl`:

| Variable | Default | Effect |
| --- | --- | --- |
| `GATEWAY_IMAGE` | `openviking:local` | The tag of the image that the target `gateway` loads. |
| `SOURCE_URL` | `https://github.com/volcengine/OpenViking` | The value of the label `org.opencontainers.image.source`. |
| `OPENVIKING_VERSION` | Computed: `<upstream>+p<portable>` | The version of the Python package and of `ov`. A value must have the PEP 440 format, the version format of Python packages. |
| `PORTABLE_VERSION` | Computed from the nearest tag `portable-v*`, else `0-g<8 hex digits>` | The portable part of the version and of the version label. |
| `REVISION` | Computed: `git rev-parse HEAD` | The value of the label `org.opencontainers.image.revision`. |
| `SOURCE_DATE_EPOCH` | Computed: the commit time of `HEAD` | The time of the label `org.opencontainers.image.created`. |
| `UV_LOCK_STRATEGY` | `locked` | `locked` fails on a stale `uv.lock`. `auto` updates the lock inside the build. |
| `REGISTRY_PREFIX` | Empty | A mirror registry for the base images, with a `/` at the end. |
| `PROVENANCE` | `false` | `true` adds a provenance attestation to the image. |
| `RELEASE_IMAGE` | `openviking` | The name of the image that `release --push` pushes. |
| `RELEASE_PLATFORMS` | `linux/amd64,linux/arm64` | The platforms of the target `release`. |
| `BUILDX_BUILDER` | Not set: the current builder | The Buildx builder. Docker Buildx reads this variable. |
| `BUILD_ENGINE` | `docker` | The build engine of `scripts/build.sh`. The value `podman` builds `gateway` and `smoke` with Podman ([Mac](docs/mac.md)). |

`scripts/build.sh` always sets `UPSTREAM_VERSION`, `RELEASE_OCI` and `RELEASE_PUSH` itself. A value from the environment has no effect.

Build arguments of the `Dockerfile`:

| Argument | Default in the `Dockerfile` | Effect |
| --- | --- | --- |
| `REGISTRY_PREFIX` | Empty | The prefix of each base image reference. |
| `RUST_IMAGE` | Its `ARG` value in `Dockerfile` | The base image of the stage `rust-toolchain`. |
| `NODE_IMAGE` | Its `ARG` value in `Dockerfile` | The base image of the stage `web-studio-builder`. |
| `PYTHON_IMAGE` | Its `ARG` value in `Dockerfile` | The base image of the stage `py-builder` and of the runtime stage. |
| `RUST_DIGEST`, `NODE_DIGEST`, `PYTHON_DIGEST` | The `ARG` lines at the top of the `Dockerfile` | The digest pin of each base image. |
| `OPENVIKING_VERSION` | Empty | The version of the package. `scripts/build.sh` sets it. Without a value and without the file `openviking/_version.py`, the build stops. |
| `UV_LOCK_STRATEGY` | `auto` | The bake file passes `locked`. |
| `npm_config_registry`, `PIP_INDEX_URL`, `UV_DEFAULT_INDEX` | None | Package index mirrors. The bake file does not pass them, so `scripts/build.sh` cannot set them. |

`docker-bake.hcl` repeats the three image names and the three digests as variables with the same defaults.

`scripts/scan.sh`:

| Variable | Default | Effect |
| --- | --- | --- |
| `GITLEAKS_IMAGE` | The pinned reference of step 13 | Another scanner image reference, for a mirror. |
| `SCAN_ENGINE` | `auto` | `auto` uses Docker when it is available, else a `gitleaks` binary. `docker` and `binary` select one engine. |
| `SCAN_REF` | Not set: the current branch and the tags at `HEAD` | The ref that sets the default level. |
| `SCAN_NAME_PREFIX` | `scan-` | The name prefix of the helper containers. |
| `SCAN_EXCLUDE_UPSTREAM` | Not set | `1` excludes the upstream commits from an explicit `history` range. The hook `pre-push` sets it. |
| `SCAN_IMAGE_METHOD` | `mount` | For `image <image>`: use a Docker image mount. Another value, a failed mount or the binary engine uses `docker export`. No effect with a base image. |
| `TMPDIR` | `/tmp` | The parent of the work directory. The tests also use it. |

Tests:

| Variable | Default | Effect |
| --- | --- | --- |
| `TEST_NAME_PREFIX` | `openviking-image-test` | `tests/test_image.sh`: the prefix of the container name. |
| `EXPECTED_VERSION` | Not set | `tests/test_image.sh`: the exact version that `/health` must report. |
| `EXPECTED_USER` | `root` | `tests/test_image.sh`: the user of the image and of the server process. |
| `HEALTH_TIMEOUT` | `240` | `tests/test_image.sh` and `tests/test_compose.sh`: the seconds to wait for a healthy answer. |
| `OPENVIKING_IMAGE` | `openviking:local` | `tests/test_compose.sh`: the image to start. |
| `COMPOSE_TEST_PROJECT` | `openviking-compose-test` | `tests/test_compose.sh`: the Compose project name. The name `openviking` is refused. |
| `COMPOSE_TEST_DIR` | Not set: a new temporary directory | `tests/test_compose.sh`: a new or empty directory for the copy. |
| `TEST_NETWORK` | `0` | `tests/test_setup_remotes.sh`: `1` also fetches one tag from GitHub. |

Arguments of `scripts/verify.py`: the base URL (required) and `--timeout SECONDS` (default `10`).

### Documents

| Document | Subject |
| --- | --- |
| [operations](docs/operations.md) | Start, logs, image selection, backup, upgrade and rollback. Go there first for a problem after the install. |
| [image build](docs/image.md) | The build targets, the version, the pins, the build context, the network endpoints and the build times. |
| [updates](docs/update.md) | Update detection, candidate qualification in a separate clone, release notes and deletion rules. |
| [host configuration](docs/host-configuration.md) | The host values, `.env` and the host override file. |
| [secret handling](docs/secret-handling.md) | The scan: rules, modes, levels and hooks. |
| [public check](docs/public-check.md) | The offline public tree check: rules, document contracts, pins, upstream maps and the push hook. |
| [remotes](docs/remotes.md) | The remotes `upstream` and `shared`, and the fetch of an upstream tag. |
| [branches](docs/branches.md) | The branches, the tags, the upstream sync and the promotion to `portable`. |
| [testing](docs/testing.md) | Each test and check of the install kit. |
| [Mac](docs/mac.md) | The differences on a Mac. |
| [CI](docs/ci.md) | What a pipeline for this repository runs. |

## How to update this file for a new portable release

Most values in this file are read from a file at run time or are written as a placeholder.
The table lists the facts that are written as text and can change with a release.

| Fact | Source | Place in this file | What the public check verifies |
| --- | --- | --- | --- |
| The tool versions | The lines "Tools:" and "Tested with" of [README.md](README.md) | [Prerequisites](#prerequisites) | No tool version check. |
| The Node 24 or later requirement | The line "Tools:" of [README.md](README.md) and [testing](docs/testing.md#pi-extension-tests) | [Prerequisites](#prerequisites), the installed version check and [Mac specifics](#mac-specifics) | Links and code paths only; no Node requirement check. |
| The Mac differences | [Mac](docs/mac.md) | [Mac specifics](#mac-specifics) | Links and code paths only; no Mac run check. |
| The frontmatter | `EXPLAINER.md` | Before the H1 | Nothing. Keep `type` a non-empty string and keep the four fields. |
| The list of quick start commands | The code block of [README.md](README.md), section "Portable install kit and quick start" | The 14 steps | Ordered commands, except the separate key generation command. |
| The upstream tag and computed version | The `awk` command reads `scripts/upstream-base`; `scripts/build.sh` computes the version | Step 3, step 7; the format example is illustrative only | Tag lookup and computed variable defaults. Copied upstream pins fail. |
| The base image names | The `ARG` lines `RUST_IMAGE`, `NODE_IMAGE` and `PYTHON_IMAGE` of the `Dockerfile` | [What the image holds](#what-the-image-holds); the build argument table keeps source pointers | Three stage cells and the build argument source pointers. |
| The base image digests | The `ARG` lines `RUST_DIGEST`, `NODE_DIGEST` and `PYTHON_DIGEST` of the `Dockerfile` | Not written in this file. Nothing to change. | No copied digest. Source and bake defaults must agree. |
| The scanner image reference | The `sed` command reads the default from `GITLEAKS_IMAGE=` in `scripts/scan.sh` | Step 13 and the README quick start | The scanner lookup command, not a copied reference. |
| The stages, the Debian packages and the extras | The `Dockerfile` | [What the image holds](#what-the-image-holds) | Base image names only. |
| The commands in the image | `[project.scripts]` in `pyproject.toml`, and the `COPY` lines of the runtime stage | [What the image holds](#what-the-image-holds) | No command inventory check. |
| The server port and the VikingBot port | `compose.yaml`, and `VIKINGBOT_DEFAULT_PORT` in `openviking/server/bootstrap.py` | [Processes, ports and configuration files](#processes-ports-and-configuration-files) | Container and Compose variable defaults, not the VikingBot port. |
| The health check times | `healthcheck` in `compose.yaml` | Steps 8 and 10 | No timing check. |
| The variables of `.env` and their defaults | `.env.example` and `compose.yaml` | Step 4, the Compose table | Step 4 and Compose variable defaults. |
| The bake targets, the labels and the build variables | `docker-bake.hcl` | Step 7, the build tables | Build variable defaults, not targets or labels. |
| The variables of each script | The header comment of each script and each test | [Environment variables and build arguments](#environment-variables-and-build-arguments) | Only the default contracts in `scripts/public-rules.json`. |
| The output texts of the scripts | The `printf` and `echo` lines of each script | The expected result of steps 2, 7, 11 and 14 | No output text check. |
| The sections of the quick start configuration | `examples/ov.conf.quickstart` | Step 6 | No configuration section check. |
| The list of scripts, workflows and tests | `git ls-files scripts .gitea/workflows .github/workflows 'tests/test_*.sh' tests/test_upstream_update.py tests/test_update_propose.py` | [Files of the install kit](#files-of-the-install-kit) | Paths and links, not a full inventory. |

The check compares the listed contracts by command; it does not execute the install steps.
See [Rules](docs/public-check.md#rules) when a contract fails.
Facts without a contract still need a source comparison.

To refresh the file:

1. Compare the quick start block of [README.md](README.md) with the 14 steps.
   Each command of the block must be in one step, including the scanner pull in step 13.
2. Compare each row of the table above with its source.
   Change the text of this file where the source changed.
3. Keep the frontmatter: a non-empty `type` and the four fields.
4. Check that each path in this file exists: `git ls-files`.
   A script or a document that moved needs a new path and a new link.
5. Run the public check after the refresh: `sh scripts/public-check.sh`.
   The exit code must be 0. See [Rules](docs/public-check.md#rules) when a contract fails.
6. Run the scan: `sh scripts/scan.sh --level fail tree`.
   The exit code must be 0.
