# Operations

This document tells how to start, check and run the OpenViking stack of
`compose.yaml`: start, logs, image selection, backup, upgrade and rollback.
For the host values, see `docs/host-configuration.md`. For the image build,
see `docs/image.md`. For the branches and the upstream sync, see
`docs/branches.md`.

## Start

`compose.yaml` has no `build:` section and sets `pull_policy: never`.
Compose never builds and never pulls the application image. The image must
exist in the local Docker before `docker compose up`:

- `sh scripts/build.sh gateway` is the supported build. It computes the
  version and the OCI labels from Git. Compose cannot compute them. A plain
  `docker build` of the `Dockerfile` has no `OPENVIKING_VERSION` (the build
  context holds no `.git/` and no `openviking/_version.py`) and stops with
  "OPENVIKING_VERSION build arg is required".
- A missing image is an error, not a pull. `docker compose up -d` stops with
  `No such image: <image>`.

Warning: `docker compose up` in a checkout that holds the live `data/` replaces the live container.
The project name is `openviking` in every checkout. Start a test in a separate copy with its own `data/` and `docker compose -p <name>`.
`sh tests/test_compose.sh` does this for you.

### A new clone

1. Copy the example file: `cp .env.example .env`. Compose refuses to start without `.env`.
2. Set `OPENVIKING_ROOT_API_KEY` in `.env` to a new value, for example the output of `openssl rand -hex 32`.
   The server rejects API calls without this key.
3. Create the server configuration from the quick start file and put the key of `.env` into it:

   ```sh
   mkdir -p data
   sed "s/REPLACE_WITH_OPENVIKING_ROOT_API_KEY/$(sed -n 's/^OPENVIKING_ROOT_API_KEY=//p' .env)/" examples/ov.conf.quickstart > data/ov.conf
   ```

   Without `data/ov.conf`, `/health` answers 503 `pending_initialization` for ever, and `scripts/verify.py` exits 1.
   `examples/ov.conf.quickstart` is a minimal valid file: `server`, `storage`, and `embedding.dense` and `vlm` with placeholder endpoints (`http://127.0.0.1:9/v1`).
   It has no `bot` section. VikingBot, which `compose.yaml` starts with `--with-bot`, then connects to the server with `server.root_api_key`.
   With the placeholder endpoints and a set root key, the server starts, `/health` is healthy and `scripts/verify.py` exits 0.
   `tests/test_compose.sh` starts the same file.
   Not verified: that indexing and search then fail. They need a working embedding and VLM endpoint.
   Then set these values in `data/ov.conf`:

   | Key | Value |
   | --- | --- |
   | `server.root_api_key` | The same value as `OPENVIKING_ROOT_API_KEY` in `.env` (the `sed` line above sets it). The server reads the key from `ov.conf` only. |
   | `embedding.dense` | `provider`, `model`, `api_base`, `api_key` and `dimension` of your embedding endpoint. |
   | `vlm` | `provider`, `model`, `api_base` and `api_key` of your VLM (vision language model) endpoint. |

   `examples/ov.conf.example` is the full upstream reference with all sections, for example `rerank`, `bot` and `log`.
   Do not copy it as it is: it has trailing commas, which the server rejects as invalid JSON, and the container then restarts in a loop.
   Its `bot` section also sets `bot.gateway.token` and `bot.ov_server.api_key` to `null`, and `--with-bot` then fails.
   Take single sections from it into `data/ov.conf`, as valid JSON.

   Warning: `data/ov.conf` holds the root key and the endpoint keys. Do not commit it. `.gitignore` excludes `data/`.
4. Create the remote `upstream` and fetch the upstream tag of `scripts/upstream-base` (its `tag` line):
   `sh scripts/setup-remotes.sh`, then `sh scripts/fetch-upstream.sh "$(awk -F '\t' '$1 == "tag" { print $2 }' scripts/upstream-base)"`.
   The merge of the next upstream tag and the upstream comparisons of [remotes.md](remotes.md) use this tag.
   `scripts/scan.sh` does not need it: without the tag in the repository it uses the baseline lines of `scripts/upstream-base`.
   `scripts/build.sh` takes the upstream version from the nearest ancestor tag `v*`.
   On `portable`, which has no upstream history, it reads the `tag` line of `scripts/upstream-base` instead ([image.md](image.md), "Version").
5. Build the image: `sh scripts/build.sh gateway`.
   The image gets the tag `openviking:local`, the default of `OPENVIKING_IMAGE`.
6. Check the configuration: `docker compose config --quiet`.
   It exits 0 when the files are valid and the key is set. Do not print the full output: it holds the key.
7. Start: `docker compose up -d`.
   Do not add `--build` or `--pull`.
8. Wait until `docker compose ps` shows the service as `healthy`.
   The health check has a 30 s interval and a 60 s startup grace period.
   A successful check can mark the container healthy before the grace period ends.
   During startup, Docker can use its shorter startup check interval.
   Docker Engine 29.7.2 with this Compose configuration first passed at 10.2 s in an isolated Linux test.
   Startup time varies; wait for `healthy`, not a fixed delay.
9. Check from outside: `python3 scripts/verify.py http://127.0.0.1:1933`.
   Use the address of `OPENVIKING_BIND` and `OPENVIKING_PORT`. It exits 0 when `/health` is healthy and an API call without a key gets 401 or 403.

To test a built image in a temporary copy before you start it, run:

```sh
OPENVIKING_IMAGE=openviking:local sh tests/test_compose.sh
```

The test uses a random key, a free loopback port, `examples/ov.conf.quickstart`
and the project name `openviking-compose-test` (`COMPOSE_TEST_PROJECT`).
It removes its container, network and copy at the end.

### A deployment by digest

A deployment can run a released image from its own registry without a build.

1. Set `OPENVIKING_IMAGE=<registry>/<name>@sha256:<digest>` in `.env`.
   A digest reference fixes the exact image.
2. Pull the image: `docker pull "<registry>/<name>@sha256:<digest>"`.
   `pull_policy: never` stops Compose from doing it: `docker compose pull` skips the service.
3. Check and start: `docker compose config --quiet`, then `docker compose up -d`.
4. Check from outside with `scripts/verify.py`, as for a new clone.

`docker compose up -d --pull missing` also pulls the digest reference: the
command-line option overrides `pull_policy`. Do not use it with the default
`openviking:local`: Compose then tries to pull `openviking:local` from Docker
Hub.

Do not give `--build` with a digest reference. With the current file,
`--build` does nothing because there is no `build:` section. If a `build:`
section is added, `docker compose up -d --build` with a digest reference
stops with `refusing to create a tag with a digest reference`.

## Logs

```sh
docker compose logs --tail 200 openviking
docker compose ps
```

With the quick start configuration, VikingBot writes `/app/.openviking/data/bot/logs/vikingbot.log` in the container.
The state mount maps it to `data/data/bot/logs/vikingbot.log` on the host.
The log survives container replacement while you keep `data/`.
The default log directory is `<storage.workspace>/bot/logs/`; `--bot-log-dir` overrides it.

```sh
docker compose exec openviking tail -n 200 /app/.openviking/data/bot/logs/vikingbot.log
```

## Select the image for a deployment

A deployment names one exact image. Record it before each start, so that a rollback can return to it.

| Source of the image | Reference in `OPENVIKING_IMAGE` | Record |
| --- | --- | --- |
| Local build (`scripts/build.sh gateway`) | A tag that names the build, `openviking:<version label>` (set `GATEWAY_IMAGE`) | The image ID and the labels `version` and `revision` |
| Released image in a registry | `<registry>/<name>@sha256:<index digest>` | The index digest and the `portable-vX.Y.Z` tag |

A local build has no registry digest. Its image ID identifies it on this host only:

```sh
GATEWAY_IMAGE='openviking:<version label>' sh scripts/build.sh gateway
docker image inspect --format '{{.Id}}' 'openviking:<version label>'
docker image inspect --format '{{index .Config.Labels "org.opencontainers.image.version"}} {{index .Config.Labels "org.opencontainers.image.revision"}}' 'openviking:<version label>'
```

Replace `<version label>` with the version label that `scripts/build.sh` prints.
Keep that build-specific tag so a rollback can select the same image.
The tag `openviking:local` moves with each default build. Do not use it for a deployment that needs a rollback.

For a released image, read the index digest from the registry. Use the digest, not the tag:

```sh
docker buildx imagetools inspect <registry>/<name>:<tag>
```

Check the labels of the pulled image: `org.opencontainers.image.revision` must be the commit of the `portable-vX.Y.Z` tag, and `org.opencontainers.image.base.digest` must be the Python pin of [image.md](image.md).

After the start, check that the container runs the recorded image:

```sh
docker inspect --format '{{.Image}}' "$(docker compose ps -q openviking)"
```

## Backup

The state is the bind mount `data/` (container path `/app/.openviking`). It holds `ov.conf`, the client configuration files, the local storage and the SQLite databases.
Also back up `.env` (the root API key) and a copy of the Compose files and of `.local/compose.host.yaml`, if it exists.
A persistent directory is not a backup.

Warning: `data/` and `.env` hold secrets. Keep the backup directory outside the checkout, with mode 0700 for the directory and 0600 for each file.

### Hot copy

A hot copy runs while the service runs. It takes a list of hashes, the archive, and a second list of hashes. Run the commands in the checkout. `<backup>` is an absolute path outside the checkout.

```sh
b=<backup>
umask 077
mkdir -p "$b"
find data -type f -print0 | LC_ALL=C sort -z | xargs -0 sha256sum >"$b/data.sha256"
tar --create --gzip --file "$b/data-<version>-<date>.tgz" data
find data -type f -print0 | LC_ALL=C sort -z | xargs -0 sha256sum >"$b/data.sha256.after"
cmp "$b/data.sha256" "$b/data.sha256.after"
cp .env "$b/env"
```

When `cmp` reports a difference, a file changed while `tar` ran. Run the three commands again until the two lists are equal. On macOS, use `shasum -a 256` in place of `sha256sum`.

Limits of the hot copy:

- Equal lists show that no file changed during the copy. They do not show that each SQLite database is at a transaction boundary.
- A restore returns the state to the moment of the copy. The running service changes files a few minutes later.
- Check each SQLite file of an extracted copy with `sqlite3 <database> 'PRAGMA integrity_check;'`. Each file must return `ok`.
  A successful check does not prove that the application can use the restored state.

For a consistent copy, stop the service first (`docker compose stop openviking`), copy, then start it. This interrupts the service.

## Upgrade to a new upstream tag

The build side is in [branches.md](branches.md), "Sync to a new upstream release". This section is the deployment side.

1. Merge and test the new tag on `local-dev` (or promote it to `portable`) as [branches.md](branches.md) says.
2. Record the image that runs now (section "Select the image for a deployment").
3. Make a backup (section "Backup").
4. Build the new image with its own tag:

   ```sh
   GATEWAY_IMAGE=openviking:<new version label> sh scripts/build.sh gateway
   sh tests/test_image.sh openviking:<new version label>
   OPENVIKING_IMAGE=openviking:<new version label> sh tests/test_compose.sh
   ```

5. Set `OPENVIKING_IMAGE` in `.env` to the new tag. Check with `docker compose config --quiet`.
6. Start: `docker compose up -d`. Compose replaces the container.
7. Wait for `healthy`, then run `python3 scripts/verify.py <base URL>`.
8. Run one authenticated call and one search with a client, for example `ov`. `verify.py` checks only health and the refusal without a key.

Not verified: that a newer version keeps the state format of `data/` compatible with the older one. Read the upstream release notes for migrations before step 6.

## Rollback

A rollback returns to the recorded image and, when the state changed in an incompatible way, to the backup of `data/`.

Warning: a restore of `data/` replaces all state that the service wrote after the backup.

1. Stop the service: `docker compose stop openviking`.
2. Set `OPENVIKING_IMAGE` in `.env` back to the recorded image. For a local build, check that the image ID is the recorded one:

   ```sh
   docker image inspect --format '{{.Id}}' <recorded image>
   ```

3. If the state must go back too, keep the current state and extract the backup. Run the commands in the checkout:

   ```sh
   b=<backup>
   mv data "data.pre-restore-$(date +%Y%m%dT%H%M%S)"
   tar --extract --gzip --file "$b/data-<version>-<date>.tgz"
   chmod 700 data
   ```

4. Check the extracted files against the list of the backup, before the container starts. The service changes files after it starts, so this check holds only before the start:

   ```sh
   find data -type f -print0 | LC_ALL=C sort -z | xargs -0 sha256sum | cmp - "$b/data.sha256"
   ```

   `cmp` prints nothing when the files are equal. Do not start the container when it prints a difference.
5. Restore `.env` from the backup if it changed, and set `OPENVIKING_IMAGE` again as in step 2.
6. Start and check: `docker compose up -d`, then `python3 scripts/verify.py <base URL>`.
7. Check that the container runs the recorded image (section "Select the image for a deployment").

Not verified: a rollback on this layout (`compose.yaml`).
A hash comparison of extracted files does not verify a container start on restored state.

## Open points

These points come from [image.md](image.md). Review them before you choose a deployment configuration.

- Runtime user: the image runs as root, as the upstream image does. `tests/test_image.sh` asserts `root` (`EXPECTED_USER`). A non-root user changes the ownership of the files in `data/`.
- The build is not byte-reproducible. Two `release` builds of the same commit gave different digests. Thus a rebuild of a commit does not give the recorded digest; keep the image or the OCI archive of each deployed version for a rollback.
- The Debian packages of the image are not pinned. A later build of the same commit can have other package versions.
