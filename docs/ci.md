# Continuous integration checks

Continuous integration (CI) runs repository checks on a runner after an event.
The workflow files call the existing scripts; they do not contain a second build definition.
No workflow promotes, creates a release tag, publishes an image or moves `portable`.
Promotion stays manual, with separate approval for creation and publication; see [promotion](branches.md#promotion).

## Workflows

| File | Events | Jobs |
| --- | --- | --- |
| `.gitea/workflows/checks.yml` | Pushes and pull requests targeting `local-dev`, `topic/*` and `sync/*`, including nested branch names | Fast checks; builds on `local-dev` and `sync/*` pushes and every pull request |
| `.github/workflows/checks.yml` | Push of `portable`, push of a portable release tag, any pull request, or manual dispatch | Fast checks; the build runs only on manual dispatch |
| `.gitea/workflows/upstream-update.yml` | Daily at 03:17 UTC and manual dispatch on `local-dev` | Detect candidates, then qualify and propose one unhandled value |

Neither checks workflow has a schedule. The update workflow is the only scheduled workflow.

After successful fast checks, the development build runs for pushes of `local-dev` and `sync/*`, including nested sync branches.
It also runs for every pull request accepted by the workflow.
A push of `topic/*` runs only fast checks; its pull request supplies the build coverage.
This ref filter avoids duplicate builds when a topic branch has an open pull request.
No path filter applies, so generated files, packaging, test fixtures and the Docker build context retain coverage.
The public build is manual to keep routine public pushes and fork pull requests free of build costs.

A workflow file does not enable Actions or register a runner.
Enable Actions and register a runner on your server. Without a runner, no job starts.

## Runner needs

Use a disposable Linux runner on `amd64` with the label `kit-amd64` for the Gitea workflows.
The GitHub workflow uses the hosted `ubuntu-latest` Linux runner.
The Gitea workflows use their own label because an instance may have an `ubuntu-latest` runner without the required tools.
Provide these tools in the job environment:

- Git, POSIX `sh`, Python 3.9 or later, and common Linux tools such as `awk`, `sed`, `tar` and `od`.
- Docker with Compose v2 and Buildx 0.19 or later, with permission to use the daemon.
- Node 24 or later for the install kit, including developer machines and CI runners.
- Support for the action runtimes below; build and qualification jobs install Node 24 for extension tests.
- `zip` for the shared extension tests.
- About 10 GB of free builder disk space per checks job, plus checkout and temporary scanner space.
- At least 20 GB of free disk for update qualification, including clone, build cache, images and scan exports.

The pinned actions declare these runtimes in `runs.using` of their action.yml files:

| Pinned action | `runs.using` |
| --- | --- |
| [checkout v4.3.1](https://raw.githubusercontent.com/actions/checkout/34e114876b0b11c390a56381ad16ebd13914f8d5/action.yml) | `node20` |
| [setup-node v4.4.0](https://raw.githubusercontent.com/actions/setup-node/49933ea5288caeca8642d1e84afbd3f7d6820020/action.yml) | `node20` |
| [upload-artifact v3.2.2](https://raw.githubusercontent.com/actions/upload-artifact/c6a366c94c3e0affe28c06c8df20a878f24da3cf/action.yml) | `node24` |
| [download-artifact v3.0.2](https://raw.githubusercontent.com/actions/download-artifact/9bc31d5ccc31df68ecc42ccf4149144866c47d8a/action.yml) | `node16` |

The runner (`act_runner` or the GitHub runner) must execute `node24` actions.
The Node setup action selects the test runtime; it does not add action-runtime support to the runner.
Version 0.2.11 of `act_runner` refuses a job with a `node24` action before its first step.
Version 0.6.1 of `act_runner` executes the four pinned actions.
Not verified: the `act_runner` versions between these two.

Allow up to 15 minutes for the fast job and 60 minutes for the build job.
The update workflow allows 15 minutes for detection and 90 minutes for qualification, notes and publication.
Estimated qualification time for an upstream tag is 25 to 45 minutes; conflicts stop before builds.
These times are from one `amd64` runner with `act_runner` 0.6.1, without queue time:

| Job or stage | Measured time |
| --- | --- |
| Detection job | 8 to 14 seconds |
| Fast job | About five minutes |
| Qualification job for one base image pin, without extension tests | About 15 to 18 minutes |
| Qualification job with no unhandled candidate | Less than 10 seconds |
| Scanner controls | About two minutes |
| Test image and gateway image builds | Six to nine minutes |
| Build job from its start to the end of the Compose test | About 10 minutes |

The measured build job reused cached build layers.
On a development host, the scanner controls took about 17 minutes.
Not verified: the cause of that difference.
Not verified: the time of a cold or complete build job, of an upstream tag qualification, and of each job on other hardware.

The Docker daemon must see the checkout and temporary directories at the same absolute paths as the job.
This includes a Docker-in-Docker setup; the scanner and runtime tests use bind mounts.
The Compose test runs verification inside the service container, so runners that use the Docker socket do not need the published port.
A working `act_runner` 0.6.1 setup enables `bind_workdir`, puts the workspace parent on the host and binds the temporary directory at the same path.
That version mounts its Unix `docker_host` socket into the job container itself.
A second socket bind in the container options stops the job with a duplicate mount point error.
Use a fresh workspace and dedicated Docker state for each job.
The jobs remove their temporary runtime containers, their tagged test image and the temporary base image tag; Buildx caches remain for runner cleanup.

Warning: a Docker socket gives repository code control of the daemon. Never run untrusted pull requests beside production services.

Fork pull requests use the ordinary pull-request event, not the privileged pull-request-target event.
They receive no configured secret, provider key or registry login.
The checkout action uses the runner's repository token only for checkout and does not persist credentials.
Use repository approval controls and disposable runners for untrusted contributions.

### Network access

| Endpoint | Purpose |
| --- | --- |
| The runner's Git server | Checkout and full history |
| `github.com`, `api.github.com`, GitHub action and release download endpoints | Pinned actions, source-defined upstream tags, update release notes and the Node runtime when the runner cache lacks it |
| Docker Hub | The source-defined scanner image, base images and Dockerfile frontend |
| `deb.debian.org` | Debian packages during image build |
| `registry.npmjs.org` | Studio and extension dependencies |
| `pypi.org`, `files.pythonhosted.org` | Python dependencies and uv |
| `index.crates.io`, `static.crates.io` | Rust dependencies |
| `nodejs.org` | Fallback source of the Node runtime |

The runtime tests use placeholder model endpoints and do not need a provider service.
See [image build](image.md#network-endpoints-of-the-build) for mirrors and remaining network limits.

## Compatibility and Actions

The checks files use push and pull-request events, branch filters, jobs, dependencies, literal shell blocks and job timeouts.
The development build condition uses event names, ref equality and the `startsWith` function.
The public file also uses manual dispatch and a job condition on the event name.
All action references use full commit hashes and version comments.
Checks use only checkout and Node setup; the update workflow also uses artifact upload and download.
Artifact actions use the v3 protocol for Gitea compatibility, not GitHub's v4 artifact service.
Update jobs also use job outputs, `always()` for evidence, standard-library Python scripts and a concurrency group.
Confirm these features on your server before you enable the schedule.

| Feature | Gitea | GitHub |
| --- | --- | --- |
| Workflow directory | Reads the Gitea directory first and ignores the GitHub directory when it exists | Reads the GitHub directory only |
| Context | Explicit Gitea server, repository, ref and run values | GitHub server, repository, ref and run values |
| Action source | Absolute public GitHub action URL avoids the server's default action-host setting | Standard action repository syntax |
| Pull-request ref | Head ref, not a preview merge commit | Preview merge ref |
| Permissions | Support and token scope depend on the server and runner version | Top-level contents-read permission disables other token scopes |
| Runner label | `kit-amd64` selects the required Linux environment | `ubuntu-latest` selects the hosted Linux environment |

The development checkout passes the server URL, repository name and event commit from the Gitea context.
Both checkouts set full history and disable persistent credentials.
Each scan receives `SCAN_REF` from the runner ref stored in `CI_REF`; the shell test suites do not inherit it.
Host values warn on private refs, while secret and policy findings fail.
The public scanner explicitly uses fail level for both tree and complete checked-out history.
A public pull request scans its preview merge history; portable pushes scan the complete portable chain.
The public checker runs immediately after the scans and stops the job on a finding.
On a portable clone it reads the generated upstream blob map without fetching upstream objects.

See the [Gitea comparison](https://docs.gitea.com/usage/actions/comparison/) and [Gitea FAQ](https://docs.gitea.com/usage/actions/faq/).
Gitea 1.26.1 with `act_runner` 0.6.1 runs these features of the Gitea workflows: checkout, job conditions, job outputs, the schedule, manual dispatch and the artifact actions.
Not verified: permission enforcement, pull-request events from a person and the concurrency group on that server.
Not verified: these features on other server and runner versions.

## Development update workflow

The update workflow never runs from a pull request or a push.
Gitea schedules read the repository's default branch, which must be `local-dev` to use this file.
If another default branch is required, leave the schedule disabled and dispatch manually from `local-dev`.
Both jobs refuse other refs. Changing the default branch needs your server's approval process.

| Job | Stages | Token and evidence |
| --- | --- | --- |
| `detect` | Read public candidate sources; treat exit 10 as proposals and exit 0 as no update | Read-only checkout token; upload `update-detection` and set the boolean job output |
| `qualify` | Download detection; run `scripts/update-propose.py` to qualify, read notes and publish one unhandled candidate | Publication token only in the dispatcher; upload `update-evidence` even on failure |

The detection artifact carries the complete JSON result between jobs.
The job output carries only whether complete detection proposes an update.
A detection error fails the job and prevents qualification, even when other sources propose updates.
The qualification job uses a directory under the runner's temporary directory, outside every checkout.
It prepares the local `local-dev` ref from the event checkout when checkout leaves a detached `HEAD`.
The update command clones that ref and exports only new commits as a prerequisite-bound bundle.
See [update command](update.md) for bundle, cleanup and exit-code contracts.

Each run processes at most one unhandled proposal in detection order.
Before qualification, the dispatcher skips candidates with an open proposal or an existing remote candidate branch.
Later runs can process other values while earlier proposals remain open.
It runs `notes` only after an upstream-tag qualification passes.
A notes failure prevents a pull request, even when qualification passed.

On success, the dispatcher verifies the bundle prerequisite, verifies the bundle, and imports its one candidate branch.
It pushes one explicit branch refspec without force or automatic tag following.
Upstream branches use `sync/<tag>`; pins use `topic/pin-<kind>`.
The pull request targets `local-dev`, never `portable`.
On Gitea 1.26.1, a branch push or a pull request that the runner token makes starts no run of the checks workflow.
The qualification is the check of that pull request; the push run of `local-dev` after the merge builds it again.
Its body contains step records, manual steps, changed-path notes, configuration changes and upstream release bodies when available.
An `[attention]` title marks any attention flag or nonempty manual steps.
Review these records and complete every manual step before accepting the pull request.
Scanner updates need the rule review described in [update command](update.md#pin-targets).

A failed qualification creates an issue with conflicts and step records; it never pushes its branch or creates a pull request.
If the API fails, the job fails instead. Inspect the evidence artifact and correct permissions or the candidate manually.
The dispatcher writes dispatch.json with the selected candidate and publication status.
Its `error` field retains a fixed refusal reason or another exception's class name, never its message.
API errors retain only the HTTP status or a fixed failure reason, not a response body.
Authenticated Git logs retain only the exit code.
Successful proposals also retain evidence for review.
Artifacts expire after seven days; keep needed evidence in your private review records before expiry.
On Gitea 1.26.1, the artifact list of the REST API stays empty after these uploads succeed.
A later job of the same run still downloads the artifact.
Not verified: artifact download from the run page.
With a temporary directory bound from the host, the update work directory stays on the host after the job.
Remove it in runner cleanup.
Bundles and logs contain development history and must not become public release artifacts.

### Token and publication rights

Gitea supplies the repository job token through `secrets.GITEA_TOKEN`.
The dispatcher uses `secrets.UPDATE_TOKEN || secrets.GITEA_TOKEN`, so a named secret overrides the runner token without step changes.
Detection requests only contents-read permission.
Qualification requests contents-write, pull-requests-write and issues-write permissions for branch pushes and proposal API calls.
No package, administration or provider permission is requested.

On Gitea 1.26.1, the runner token reads the open proposals and creates the failure issue.
With no `UPDATE_TOKEN` secret on that version, it also pushes the candidate branch and opens the pull request.
Not verified: the runner-token rights on other Gitea versions.
If necessary, create `UPDATE_TOKEN` with write access only to this development repository's code, pull requests and issues.
Keep the token in the repository secret store, not in a file or URL.
The dispatcher passes it only to API calls and the authenticated Git push.
Checkout does not persist it; qualification and notes child processes receive no publication token.
The push uses an environment-only authorization header, suppresses server output and refuses redirects.
No provider key or registry login is needed.

Warning: server permissions can restrict the runner token. Confirm the named secret cannot access other repositories or administration APIs.

### Duplicate control and refresh

All update runs use one concurrency group and do not cancel a run that must finish cleanup.
API lookups paginate all open pull requests and issues before qualification and again before publication.
They match the candidate branch, the exact title without the attention mark, or a stable value marker in the body.
An existing remote candidate branch also prevents replacement.

Confirm workflow serialization before enabling scheduled runs. Do not run another proposal writer concurrently.
If your Gitea version ignores concurrency, use a dedicated single-job runner and prevent overlapping dispatches.
These controls require one serialized writer; the API does not enforce unique issue titles.
Manual duplicate proposals and unsupported runner concurrency can bypass that boundary.

To keep a proposal, leave it open. The next run skips that value or occupied pin branch.
To retry, close the pull request or issue and remove its obsolete candidate branch after approval.
Then dispatch again. The workflow does not delete branches or force-refresh an open proposal.
A failed push or API call can leave an occupied branch; inspect it before removal and retry.

### Run update actions by hand

Use a clean development checkout with full history and disposable Docker state.
The command actions need no publication token.

1. Detect candidates. Exit 10 means complete proposals; exit 2 means an error.

   ```sh
   python3 scripts/upstream-update.py detect
   ```

2. Qualify one selected kind and target outside every checkout. A passed result names its branch and bundle.

   ```sh
   python3 scripts/upstream-update.py qualify --kind upstream-tag --to v<X.Y.Z> --workdir /tmp/openviking-update --branch-out /tmp/openviking-update/bundles
   ```

   For pins, use the kind and target formats in [update command](update.md#pin-targets).

3. Read notes for an upstream tag. Read the current tag from its source instead of copying it.

   ```sh
   python3 scripts/upstream-update.py notes --from "$(awk -F '\t' '$1 == "tag" { print $2 }' scripts/upstream-base)" --to v<X.Y.Z> --workdir /tmp/openviking-update
   ```

Review the result before importing a bundle or publishing a development proposal.
The workflow calls `python3 scripts/update-propose.py` for API lookups, bundle import and candidate-only publication.
These actions do not approve a merge or a portable promotion.

You can run the same script against a test development repository with four environment variables.
Use its clean, full-history checkout, matching `HEAD` and `local-dev`, and a detection result with exit code 10.
Provide the qualification tools, disposable Docker state, disk space and network access listed in [runner needs](#runner-needs).

| Variable | Input |
| --- | --- |
| `UPDATE_WORK` | Existing directory outside every checkout, containing detect.json |
| `UPDATE_SERVER` | HTTPS Git server URL without credentials, query or fragment |
| `UPDATE_REPOSITORY` | Test repository in owner/repository format |
| `UPDATE_TOKEN` | Repository-scoped token with code, pull-request and issue write access |

Set the variables in your shell and export them; load the token from your secret store.
The script takes no command-line options.

```sh
export UPDATE_WORK UPDATE_SERVER UPDATE_REPOSITORY UPDATE_TOKEN
python3 scripts/update-propose.py
```

Exit 0 means successful processing or no unhandled candidate; exit 1 means a failed candidate or processing error.
Inspect dispatch.json and the qualification records before reviewing the proposal.

Warning: this script pushes a candidate branch and creates a pull request or issue. Use a disposable test repository.

To turn the schedule off, remove the schedule event and keep `workflow_dispatch`.
Manual dispatch still requires the `local-dev` ref and a registered runner.

## Run the fast stages by hand

Run these commands at the top of a separate clean checkout with full history.
Do not use a checkout that holds a live service's state.

1. Verify the clone depth.

   ```sh
   test "$(git rev-parse --is-shallow-repository)" = false
   ```

2. Download the scanner selected by the source file.

   ```sh
   docker pull "$(sed -n 's/^GITLEAKS_IMAGE=${GITLEAKS_IMAGE:-\(.*\)}$/\1/p' scripts/scan.sh)"
   ```

3. Set the scan ref from the branch or tag under test. The runner supplies this value automatically.

   ```sh
   CI_REF=refs/heads/local-dev
   SCAN_NAME_PREFIX=openviking-ci-
   export SCAN_NAME_PREFIX
   SCAN_REF="$CI_REF" sh scripts/scan.sh tree
   SCAN_REF="$CI_REF" sh scripts/scan.sh history
   ```

   For the public checks, use these scan commands instead:

   ```sh
   CI_REF=refs/heads/portable
   SCAN_REF="$CI_REF" sh scripts/scan.sh --level fail tree
   SCAN_REF="$CI_REF" SCAN_EXCLUDE_UPSTREAM=0 sh scripts/scan.sh --level fail history HEAD
   ```

4. Run the public check. A nonzero exit stops the workflow.

   ```sh
   sh scripts/public-check.sh
   ```

5. Run the offline shell suites. They use temporary repositories and no service secrets.

   ```sh
   sh tests/test_setup_remotes.sh
   sh tests/test_promotion.sh
   sh tests/test_build_version.sh
   sh tests/test_public_check.sh
   sh tests/test_workflows.sh
   ```

For development only, also run the update unit tests:

```sh
python3 -m unittest tests.test_upstream_update
python3 -m unittest tests.test_update_propose
```

The upstream update tests need the upstream base commit, which the public portable history does not contain.
The proposal tests inject the process and API boundaries and need no network or Docker.
A fresh runner has no local host deny list, so the scanner uses the tracked generic rules only.
A managed runner can supply its ignored local deny list; never commit it or expose it to untrusted jobs.

## Run the build stages by hand

The development workflow first prepares the upstream ref. The public workflow skips this step.

```sh
sh scripts/setup-remotes.sh
sh scripts/fetch-upstream.sh "$(awk -F '\t' '$1 == "tag" { print $2 }' scripts/upstream-base)"
```

Download the scanner with the fast-stage command, then run its longer controls:

```sh
sh tests/test_scan.sh
```

Set `CI_RUN` and `CI_ATTEMPT` to numeric values unique to your test.
The runner supplies these values in a workflow.
Set `SOURCE_URL` to the repository URL if you want the image label to name your copy.
The workflow reads that URL from its server and repository context.

```sh
set -eu
CI_RUN=1 CI_ATTEMPT=1
export CI_RUN CI_ATTEMPT
image="openviking-ci:${CI_RUN}-${CI_ATTEMPT}"
base_image="${image}-base"
base_context=$(mktemp -d)
trap 'docker image rm "$image" "$base_image" >/dev/null 2>&1 || true; rm -rf "$base_context"' EXIT
sh scripts/build.sh test
GATEWAY_IMAGE="$image" sh scripts/build.sh gateway
TEST_NAME_PREFIX="openviking-ci-image-${CI_RUN}-${CI_ATTEMPT}" sh tests/test_image.sh "$image"
OPENVIKING_IMAGE="$image" COMPOSE_TEST_PROJECT="openviking-ci-${CI_RUN}-${CI_ATTEMPT}" sh tests/test_compose.sh
base=$(awk -F= '/^ARG PYTHON_IMAGE=/ { image=$2 } /^ARG PYTHON_DIGEST=/ { digest=$2 } END { print image "@" digest }' Dockerfile)
printf 'FROM %s\n' "$base" > "$base_context/Dockerfile"
docker buildx build --load -t "$base_image" "$base_context"
sh scripts/scan.sh --level fail image "$image" "$base_image"
```

The image scan checks only the layers added above the base image read from `Dockerfile`.
The Buildx build keeps that base image in its cache, so the step loads it into the Docker image store under a temporary tag.
The tests create temporary state and random test keys, never a provider key.
No step publishes the test image, creates a release tag or runs a multi-platform build.

Use Node 24 or later for the extension stage. The workflow installs it with its pinned Node setup action.

```sh
test "$(node -p 'Number(process.versions.node.split(".")[0]) >= 24')" = true
npm ci --prefix examples/pi-coding-agent-extension --ignore-scripts
node examples/memory-plugin-shared/sync.mjs
node --test examples/pi-coding-agent-extension/tests/*.test.mjs
node --test examples/memory-plugin-shared/*.test.mjs
```

## Release build by hand

No workflow builds or publishes a release. Build the `release` target only from a checked-out `portable-v*` release tag.
Follow [image build](image.md#build) for the builder, platforms and OCI archive or approved registry output.
Scan the added layers from the tag's checkout as [image mode](secret-handling.md#image-mode) describes.
Record the index digest as [image selection](operations.md#select-the-image-for-a-deployment) describes.
For an OCI archive, record its SHA-256 instead.

Warning: an image push must start from a `portable-v*` release tag only. Other refs can contain host values.

## Workflow test limits

`sh tests/test_workflows.sh` needs Git, POSIX `sh` and Python 3 with its standard library.
It reads a strict YAML subset: two-space maps, scalar lists, step maps, quoted or simple scalars and literal run blocks.
It refuses anchors, aliases, flow collections, folded blocks, duplicate keys, extra documents and unknown syntax.
A successful parse proves valid YAML within that subset, not general YAML support or the runner's complete schema.
It checks the job contract, event filters, build conditions, full history, exact permissions and hashed action references.
Event/ref controls cover build inclusion and exclusion within the condition's supported expression subset.
It checks every run line against explicit shell forms and tracked paths, then checks POSIX shell syntax without execution.
It rejects copied pins, missing paths, unsafe release mutations and privilege expansion through negative controls.
The update workflow contract permits only `python3 scripts/update-propose.py` in the publication step.
`python3 -m unittest tests.test_update_propose -v` tests the tracked dispatcher separately through injected process and API boundaries.
Offline fixtures test candidate mapping, explicit refspecs, duplicate lookup, failure issues, attention marking and credential isolation.
They check safe refusal reasons and exception class names in failure evidence without retaining tokens or response bodies.
No live API or push runs in these fixtures.
It does not prove runner availability, action execution, network access, Docker access or successful builds.
The public tree check separately permits exactly the one public checks workflow.

## If a public check fails

1. Stop the release. A failed public check makes the fast job fail before any build.
2. Correct the source or documentation on the development branch. Never edit `portable` directly.
3. Run the public check, scan and relevant tests again. Require clean results.
4. Create a new approved promotion and increasing release tag. See [promotion](branches.md#promotion).
5. Show its push plan and obtain approval before publication. Do not replace an existing release tag.

## Open questions

- Which server and runner versions support these workflows, and which isolation method will you use?
- Will you use repository or instance runners, and who approves their registration and Actions settings?
- What disk limit, cache cleanup policy and execution budget fit your runners?
- Which network mirrors and certificate configuration do your runners need? See [image build](image.md).
- Which approved registry and namespace will receive releases, or where will you keep OCI archives and their hashes?
- Does your Gitea version enforce update concurrency and the requested runner-token rights?
- Do the pinned artifact actions and job outputs work with your runner's artifact service?
