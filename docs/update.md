# Check and qualify updates

`scripts/upstream-update.py` detects updates, qualifies one candidate, or reads release notes.
It uses Python 3 and its standard library. It prints one JSON result on standard output.
A qualification never changes the caller's checkout, pushes a branch, or promotes a release.

The [development update workflow](ci.md#development-update-workflow) runs `detect` daily and qualifies at most one unhandled candidate per run.
It opens a development pull request on success or an issue after failed qualification or notes.
`scripts/update-propose.py` publishes the proposal.
Run bundles and logs hold development content and stay private.
See [CI](ci.md#development-update-workflow) for the token, evidence and schedule requirements.

Warning: the proposal script can push a development branch. The qualification command never publishes a branch.

Warning: qualification executes fetched source and build definitions. Use a disposable runner for untrusted upstream releases.

## Inputs

| Kind | Pinned source | Candidate source |
| --- | --- | --- |
| `upstream-tag` | The `tag` line of `scripts/upstream-base` | Stable upstream Git tags |
| `base-digest` | Image names, digests, and frontend in `Dockerfile` | Current index digest of the same image tag |
| `scanner` | `GITLEAKS_IMAGE` in `scripts/scan.sh` | Stable scanner Git tags and the registry digest |
| `uv` | The hashed uv requirement in `Dockerfile` | PyPI version and Linux wheel hashes |

Python and npm dependency locks move only with an upstream tag.
Prerelease upstream tags appear in detection results but never become proposed updates.
Network operations accept injected command and JSON-fetch functions in the unit tests. Tests require no network.

## Detect

```sh
python3 scripts/upstream-update.py detect
```

Each input record gives its kind, name, pinned value, latest value, difference, and proposal state.
A network failure produces an error record, not a clean result.
Detection reads public sources without credentials. It uses temporary local metadata storage and removes it afterward.

## Qualify

```sh
python3 scripts/upstream-update.py qualify \
  --kind upstream-tag --to v<X.Y.Z> \
  --workdir /tmp/openviking-update \
  --branch-out /tmp/openviking-update/bundles
```

The work directory must be outside every Git checkout. It must not contain the caller checkout or use symlinks.
The command creates a unique run directory inside it. Existing files in the work directory remain unchanged.
A bundle directory must be inside the work directory.

The command clones `local-dev`, not the caller's uncommitted files or current topic branch.
An upstream update creates `sync/<tag>`. A pin update creates `topic/pin-<kind>`.
It never merges a qualification result into the caller's repository.

`scripts/upstream-removed` lists exact deleted paths and deleted directory prefixes.
Its stable format has one repository-relative path per line, with blank lines and full-line comments ignored.
A trailing slash matches directory descendants. Other lines match exact paths; no glob syntax applies.
Qualification deletes matching files only when the incoming upstream tree contains them.
It never deletes repository-owned workflows listed in the public rules.
It records skipped deletion rules and resolves only eligible modify/delete conflicts as deletions.
The result records each path and rule. Any other merge conflict stops qualification before builds and tests.
The sync-table check rejects unlisted local changes to upstream files.

After a clean merge, qualification updates the upstream tag and generates scan baseline entries.
It then regenerates the upstream blob map with the public-check command.
It runs the tree scan, five shell suites, and the update command unit tests.
The shell suites cover remote setup, promotion, build versions, scanner behavior, and the public check.
It then runs build tests, gateway build, image tests, Compose tests, and layer scan.
Qualification runs the cloned candidate's update tests. A missing test module fails that step.
It runs Pi and shared-library tests when their paths change. These tests need Node 24 or later and `zip`.
It runs the public check after the first tree scan and again at the end.
An early public-check failure stops the candidate before builds. A missing public check fails qualification.
Independent checks continue after a failed step. Checks that need a failed prerequisite record a skip.
A failed check prevents bundle export.

### Pin targets

| Kind | `--to` format | Example |
| --- | --- | --- |
| `upstream-tag` | Stable tag | `v<X.Y.Z>` |
| `base-digest` | Image key and digest | `python=sha256:<64 hexadecimal characters>` |
| `scanner` | Stable scanner tag | `v<version>` |
| `uv` | Stable uv version | `<version>` |

The image keys are `rust`, `node`, `python`, and `frontend`.
A digest update checks that the requested digest belongs to the current pinned image tag.
The command updates matching bake defaults when they exist.
A scanner update resolves its digest and runs the scanner suite.
It does not import the new default scanner rules into `.gitleaks.toml`.
Its JSON sets `attention` to true and lists the required review in `manual_steps`.
Follow [the scanner update instructions](secret-handling.md) before accepting that candidate.
Other pin kinds need no document pin changes.
A uv update requires four Linux wheel hashes for the two architectures and two C libraries.
Pin updates run the same qualification checks. They do not update upstream dependency locks independently.

### Options and results

| Option | Actions | Meaning |
| --- | --- | --- |
| `--kind` | `qualify` | Required input kind |
| `--to` | `qualify`, `notes` | Required target |
| `--from` | `notes` | Required starting upstream tag |
| `--workdir` | `qualify`, `notes` | Required directory outside Git checkouts |
| `--branch-out` | `qualify` | Optional bundle and log directory inside the work directory |
| `--keep` | `qualify`, `notes` | Keep the work clone and qualification Docker objects for inspection |
| `--step-timeout` | `qualify`, `notes` | Per-command timeout in seconds; default 3600 |
| `--help` | All | Print command help instead of JSON |

Each command step records its name, exit code, elapsed seconds, status, and log path.
A skipped step has a null exit code and an explicit reason.
A merge resolved by the removal rules retains Git's exit code with status `resolved`.
Logs and the generated result JSON remain in the run directory after cleanup.
Only a passed qualification exports a bundle. It contains only commits after the cloned `local-dev` commit.
The JSON result names that prerequisite commit. The receiving repository must already contain it.
New commits can still contain private development content; the bundle is not a portable release.

Import a reviewed bundle into a repository that has the prerequisite:

```sh
git bundle verify /tmp/openviking-update/bundles/<run>.bundle
git fetch /tmp/openviking-update/bundles/<run>.bundle sync/v<X.Y.Z>:refs/heads/review/v<X.Y.Z>
```

For a pin update, replace `sync/v<X.Y.Z>` with `topic/pin-<kind>` and choose a new review branch.
These commands do not merge the imported branch.

Warning: do not publish a qualification bundle. Use the reviewed promotion process before sharing a release.

## Read release notes

```sh
python3 scripts/upstream-update.py notes \
  --from v<OLD.X.Y> --to v<NEW.X.Y> --workdir /tmp/openviking-update
```

The starting tag is exclusive. The target tag is inclusive.
The result includes upstream release bodies, changed paths, relevant paths, and added or removed configuration keys.
Relevant paths include the sync table, Docker build inputs, dependency locks, container entrypoints, and the configuration example.
`attention` is true when relevant files change or release notes contain a breaking-change heading.
Missing target release notes cause an error rather than an incomplete success.

## Exit codes

| Code | Meaning |
| --- | --- |
| `0` | No proposed update for `detect`, or successful `qualify` or `notes` |
| `10` | `detect` proposes at least one update |
| `1` | Qualification fails, including conflicts or failed checks |
| `2` | Invalid arguments, input format, missing tools, or a detection or notes network error |

A qualification tool failure appears in its step record and returns `1` after run setup.
A command timeout has step exit code `124`; qualification then returns `1`.

## Safety and resources

Qualification gives child processes a minimal environment and an isolated home directory.
It does not forward provider keys, Docker credentials, proxy settings, or caller Git configuration.
State stays under the unique work directory. Tests use placeholder endpoints and generated test keys, not real model requests.
Docker images, containers, and Compose projects use the unique `openviking-update-` run prefix.
Each build uses its own Buildx builder. Cleanup removes that builder, its cache, run containers, and run image tags.
Without `--keep`, cleanup also removes the work clone and temporary test state.
Docker can retain shared content-addressed layers; cleanup does not prune the daemon's shared storage.

Requirements: Git, Python 3, Docker with Buildx and Compose, and public network access for source and package downloads.
Pi checks additionally need Node 24 or later, npm, and `zip`.
Allow at least 20 GB of free disk for the clone, build cache, loaded images, and scan exports.
A cold build takes about 9 minutes on 16 CPUs. The scanner suite takes about 17 minutes.
A merge conflict stops before those expensive steps.

Not verified: runtime and disk use on other machines, and qualification of every future upstream release.

## Local tests

```sh
python3 -m unittest tests.test_upstream_update -v
```

The tests inject network answers and build commands. Temporary Git repositories exercise merges, deletion rules, bundles, and caller isolation.
The deletion-list test compares the current tree with the upstream base commit.
Run these tests in a development checkout with that commit available, not an orphan portable checkout.
