# Tests and checks of the local tooling

This page lists each test and check of the files that this fork adds to upstream OpenViking.
The upstream Python tests are described in `tests/README.md`. That file is upstream text, so this page is separate.

Run each command at the top of a checkout. The tests make temporary directories under `$TMPDIR` (default `/tmp`) and remove them at the end.

Run the tests in a clean worktree, not in a checkout that holds live `data/`. `tests/test_compose.sh` starts its service in its own copy under its own project name.

## Tests

| Test | Command | Needs | What it checks |
| --- | --- | --- | --- |
| Remotes | `sh tests/test_setup_remotes.sh` | Git | `scripts/setup-remotes.sh` and `scripts/fetch-upstream.sh` against a local bare repository. `TEST_NETWORK=1` also fetches one tag from GitHub. |
| Scan | `sh tests/test_scan.sh` | Docker, the scanner image | `scripts/scan.sh`, the hooks and `scripts/install-hooks.sh` in temporary repositories, with negative controls. No network. It takes several minutes. |
| Public check | `sh tests/test_public_check.sh` | Git, POSIX `sh`, Python 3 | Word classes, document references, freshness, pins, tree rules, upstream maps and pushed-object hook checks in temporary repositories. No network or container. |
| Promotion | `sh tests/test_promotion.sh` | Git, POSIX `sh`, Python 3 | The commit definition and `scripts/promote.sh` in temporary repositories with local bare remotes. Scanner stubs check the order and history ranges. One fixture uses the real public check and pre-push hook; its scanner stays stubbed. Checks cover commits, tags, refusals, pinned pushes, plans and remote audits. No network or container. |
| Workflows | `sh tests/test_workflows.sh` | Git, POSIX `sh`, Python 3 | The strict YAML subset, run lines, pinned actions and build conditions, with negative controls. No YAML package, network or job execution. |
| Updates | `python3 -m unittest tests.test_upstream_update -v` | Python 3, Git, the upstream base commit | Detection, merge conflicts, deletion rules, qualification, bundles and caller isolation. Network and build commands are injected; no network or container runs. Run in a development checkout with the base commit, not a clone of `portable`; see [updates](update.md#local-tests). |
| Update proposals | `python3 -m unittest tests.test_update_propose -v` | Python 3 | Candidate selection, duplicate control, candidate-only publication, failure evidence and credential isolation. Process and API calls are injected; no network or container runs. |
| Build version | `sh tests/test_build_version.sh` | Git | The version step of `scripts/build.sh` in a repository with one parentless commit, with a stub `docker` that prints its arguments: the fallback to the `tag` line of `scripts/upstream-base`, `OPENVIKING_VERSION` wins, a `portable-v*` tag, an ancestor tag wins, a missing tag line stops the build. No image is built. |
| Image | `sh tests/test_image.sh <image>` | Docker, a built image | Labels, user, empty state directory, no configuration in the image, `/health`, version, 401 without a key and 200 with the key, 30 s of health with failing model endpoints. No network. |
| Compose | `OPENVIKING_IMAGE=<image> sh tests/test_compose.sh` | Docker Compose, a built image | `compose.yaml` in a temporary copy: `config`, `up -d` without a pull, health, `scripts/verify.py`, loopback port only, `down -v`. |
| Tests in the image | `sh scripts/build.sh test` | Docker with Buildx, network for the build | The upstream lite test set (`tests/vectordb/`, four files) in the built image, with `--network=none`. The build fails when a test fails. |

The Compose test runs verification inside the service container, so runners that use the Docker socket do not need the published port.

Environment of the tests:

| Test | Variable | Default |
| --- | --- | --- |
| `tests/test_image.sh` | `TEST_NAME_PREFIX`, `EXPECTED_VERSION`, `EXPECTED_USER`, `HEALTH_TIMEOUT` | `openviking-image-test`, none, `root`, 240 |
| `tests/test_compose.sh` | `OPENVIKING_IMAGE`, `COMPOSE_TEST_PROJECT`, `COMPOSE_TEST_DIR`, `HEALTH_TIMEOUT` | `openviking:local`, `openviking-compose-test`, a new temporary directory, 240 |
| `tests/test_setup_remotes.sh` | `TEST_NETWORK` | off |

The scanner image for `tests/test_scan.sh` and `scripts/scan.sh`:

```sh
docker pull "$(sed -n 's/^GITLEAKS_IMAGE=${GITLEAKS_IMAGE:-\(.*\)}$/\1/p' scripts/scan.sh)"
```

A full image test:

```sh
GATEWAY_IMAGE=openviking:test sh scripts/build.sh gateway
sh tests/test_image.sh openviking:test
OPENVIKING_IMAGE=openviking:test sh tests/test_compose.sh
```

## Checks

Run the public check and the tracked-file scan before each commit and release.
The public check reads tracked working-tree content; the push hook checks the pushed object.
See [public check](public-check.md) for the rules and limits.

| Check | Command | Result |
| --- | --- | --- |
| Public tree | `sh scripts/public-check.sh` | Exit 0: no finding. Exit 1: at least one finding. Exit 2: invalid arguments, missing tools, missing inputs or invalid rule data. |
| Scan of the tracked files | `sh scripts/scan.sh --level fail tree` | Exit 0: no secret, no host value, no policy finding. |
| Scan of the local history | `sh scripts/scan.sh history` | Exit 0 at the default level of the branch. |
| Scan negative control | `sh scripts/scan.sh selftest` | Exit 0: the scan finds a synthetic token and each deny pattern, and a synthetic image layer gives the expected third-party exceptions and findings. |
| Remote configuration | `sh scripts/setup-remotes.sh --check` | Exit 0 when `upstream` is fetch-only as [remotes.md](remotes.md) says. |
| Hooks | `sh scripts/install-hooks.sh --check` | Exit 0 when the hooks are installed and current. |
| Started server | `python3 scripts/verify.py <base URL>` | Exit 0: `/health` is healthy and a call without a key gets 401 or 403. |
| Shell scripts | `shellcheck -s sh <file>` | No finding. Without a local `shellcheck`, use the image: `docker run --rm --network none -v "$PWD:/w:ro" -w /w koalaman/shellcheck:stable -s sh <file>`. |
| Compose file | `docker compose config --quiet` | Exit 0 when `.env` is valid and the key is set. |

The shell files that `shellcheck` checks: `scripts/build.sh`, `scripts/scan.sh`, `scripts/public-check.sh`, `scripts/promote.sh`, `scripts/setup-remotes.sh`, `scripts/fetch-upstream.sh`, `scripts/install-hooks.sh`, the files in `scripts/git-hooks/`, and each `tests/test_*.sh`.

## Pi extension tests

The install kit requires Node 24 or later on developer machines and CI runners.
The Pi extension tests import TypeScript files (`*.ts`) with the type stripping of Node, which removes the type annotations.
On an older Node, these imports fail.
`nvm` is one Node version manager; any Node 24 installation works.
If you use `nvm`, `nvm use` reads the root `.nvmrc` and selects Node 24.

Run the same version check as the workflows before you prepare the extension:

```sh
test "$(node -p 'Number(process.versions.node.split(".")[0]) >= 24')" = true
```

The directory `shared/` of the extension is generated and not tracked. Prepare it once, and again after each change of `examples/memory-plugin-shared/`:

```sh
npm ci --prefix examples/pi-coding-agent-extension --ignore-scripts
node examples/memory-plugin-shared/sync.mjs
```

Then run the tests:

```sh
node --test examples/pi-coding-agent-extension/tests/*.test.mjs
node --test examples/memory-plugin-shared/*.test.mjs
```

Tests that need a Pi install can skip when its session or transcript helpers are unavailable.
The skip messages include `pi SessionManager not resolvable` and `pi @earendil-works/pi-ai transcript helpers not resolvable`.
The shared tests `release-marketplace.test.mjs` and `install-opencode-jsonc.test.mjs` need `zip`.
Install `zip` in the test environment before you run those tests.
Use the two commands above for current pass, failure and skip counts.
Not verified: the shared suite with `zip` installed.

## Upstream tests

The upstream Python, Rust and Node tests are unchanged. [tests/README.md](../tests/README.md) describes them.
`sh scripts/build.sh test` runs four files in `tests/vectordb/` in the image.
The list comes from the [upstream lite workflow](https://github.com/volcengine/OpenViking/blob/main/.github/workflows/_test_lite.yml).
That workflow is absent from this tree. `docker-bake.hcl` holds the local test command.
