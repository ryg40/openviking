# Branches, tags and remotes

This branch model separates private development from public releases of a modified OpenViking source tree.
Use `local-dev` to keep upstream history and merge upstream release tags.
Publish a clean copy of the files on `portable`, without the private history.
Send only `portable` and its release tags to the shared Git server.

## Model

| Name | Kind | Content | Rule |
| --- | --- | --- | --- |
| `upstream` | remote | Upstream OpenViking (`https://github.com/volcengine/OpenViking.git`). | Fetch only, one release tag at a time. `scripts/setup-remotes.sh` creates it; [remotes.md](remotes.md) describes it. |
| `origin` | remote | The Git server of your clone: a private development server or a shared release server. | Push by explicit ref name only. |
| `shared` | remote | The shared Git server of the target environment, for example GitHub. | Receives only `portable` and `portable-v*`. The pre-push hook refuses every other ref toward `shared`. |
| `main` | branch | An optional branch from before the split, with upstream and old deployment files. | Keep it private. Decide whether to retain it when you adopt this model. |
| `local-dev` | branch | Your private integration branch: upstream plus local changes. | Its history can contain host values. It never goes to a shared Git server. |
| `topic/*` | branch | One change each. | Starts at `local-dev`. Merges into `local-dev` after review. |
| `sync/*` | branch | The merge of one upstream release tag, for example `sync/vX.Y.Z`. | Starts at `local-dev`. Merges into `local-dev` after review. |
| `portable` | branch | The files of `local-dev` without history. | Orphan root: it shares no commit with `local-dev` or upstream. Moves only by promotion. |
| `portable-vX.Y.Z` | tag | A release of `portable`, for example `portable-v0.1.0`. | Annotated tag on a commit of `portable`. |
| `pre-split-*` | tag | The state before the split, for example `pre-split-backup`. | Never moves. |

Upstream tags go to `refs/upstream/tags/`, not to `refs/tags/`. `refs/tags/` is for the tags of this repo only.

## What goes where

| Remote | `main` | `local-dev` | `topic/*`, `sync/*` | `portable` | `portable-v*` | `pre-split-*` | upstream tags |
| --- | --- | --- | --- | --- | --- | --- | --- |
| Your private Git server (`origin` there) | yes | yes | optional | yes | yes | yes | no |
| Shared Git server of the target environment (`shared`) | no | no | no | yes | yes | no | no |
| `upstream` | no | no | no | no | no | no | no (push is disabled) |

Warning: do not push `main`, `local-dev`, a `topic/*` or a `sync/*` branch to a shared Git server. Their history contains host values.

Warning: do not use `git push --tags`, `--mirror` or `--follow-tags`. They send the upstream tags to `origin`.

## Sync to a new upstream release

`scripts/upstream-update.py qualify --kind upstream-tag` runs these steps in a separate clone ([updates](update.md#qualify)).
It stops at each conflict that `scripts/upstream-removed` does not resolve.
This section keeps the manual procedure for a person who must resolve such a conflict.
The list holds the deliberate upstream deletions named in the table below.
Directory rules cover new upstream files too; exact workflow paths in `scripts/public-rules.json` remain protected.

A sync merges one upstream release tag into `local-dev`.
Replace `v<X.Y.Z>` with the new release tag, then run the blocks in order in one shell.

1. Fetch the tag with its full history. The tag goes to `refs/upstream/tags/$tag`.

   ```sh
   tag='v<X.Y.Z>'
   current_tag=$(awk -F '\t' '$1 == "tag" { print $2 }' scripts/upstream-base)
   git diff --name-status --diff-filter=MD "refs/upstream/tags/$current_tag" local-dev
   sh scripts/fetch-upstream.sh "$tag"
   ```

2. Create the sync branch from `local-dev` and merge the tag. Stop before the commit, so that you can check the result.

   ```sh
   git switch -c "sync/$tag" local-dev
   git merge --no-ff --no-commit "refs/upstream/tags/$tag"
   ```

3. Resolve each conflict. Keep the known local changes to upstream files on top of the new upstream text:

   | Path | Local change | Source |
   | --- | --- | --- |
   | `CONTRIBUTING.md` | The kit section at the end stays; the upstream text above it follows upstream | this repo |
   | `Dockerfile` | Base image pins, `REGISTRY_PREFIX`, redirect arguments, uv from PyPI, base labels (six changes) | [image.md](image.md), "Changes against the upstream tag" |
   | `.dockerignore` | Allowlist of the `COPY` sources | [image.md](image.md), "Build context" |
   | `.github/dependabot.yml` | Deleted; do not restore during an upstream sync | this repo |
   | `.github/scripts/generate-channels-json.sh` | Deleted; its only caller is the deleted upstream release workflow | [public-check.md](public-check.md), "Rules" |
   | `.github/scripts/host-compat.mjs`, `.github/host-compat.json` | Deleted; only the removed upstream host-compatibility workflow uses them | [public-check.md](public-check.md), "Rules" |
   | `.github/workflows/` (all upstream files) | Deleted; delete new upstream workflow files after each sync. Keep only workflows written for this repo. | [ci.md](ci.md) |
   | `.github/ISSUE_TEMPLATE/` (all 4 upstream files), `.github/PULL_REQUEST_TEMPLATE.md` | Deleted; do not restore upstream templates during a sync | this repo |
   | `.gitignore` | Private ignore rules: `.local/`, `.env`, `.env.*` (except `.env.example`) and `data/` | [host-configuration.md](host-configuration.md), "Host values and where they live" |
   | `benchmark/locomo/openclaw/run_full_eval.sh` | `GATEWAY_TOKEN` comes from the environment | [secret-handling.md](secret-handling.md), "Local changes to upstream files for secrets" |
   | `README.md` | The section "Portable install kit and quick start" | this repo |
   | `SECURITY.md` | The kit section at the end stays; the upstream text above it follows upstream | this repo |
   | `docker-compose.yml` | Deleted; `compose.yaml` replaces it | [host-configuration.md](host-configuration.md) |
   | `Caddyfile` | Deleted; the kit does not use the upstream proxy or start OpenViking Gateway | [image.md](image.md), "OpenViking Gateway" |
   | `docs/repository/CONTRIBUTING_CN.md` | The kit section at the end stays; the upstream text above it follows upstream | this repo |
   | `docs/repository/CONTRIBUTING_JA.md` | The kit section at the end stays; the upstream text above it follows upstream | this repo |
   | `examples/pi-coding-agent-extension/`: `README.md`, `config.ts`, `index.ts`, `lib/capture-adapter.mjs`, `sync.ts`, `tests/capture-adapter.test.mjs`, `tests/config.test.mjs`, `tests/sync-barrier.test.mjs` | Local fork of the Pi extension: takeover off by default, tool result capture and credential redaction, keyword capture, sync watermark and `ensureSession` | [Pi extension README](../examples/pi-coding-agent-extension/README.md), "Local fork: differences and updating an installed copy" |
   | `examples/pi-coding-agent-extension/package.json`, `examples/pi-coding-agent-extension/package-lock.json` | The `engines` field (the Node.js version requirement of package.json) requires Node 24 or later | [testing.md](testing.md), "Pi extension tests" |
   | `examples/pi-coding-agent-extension/package.json`, `examples/pi-coding-agent-extension/package-lock.json` | Pin @modelcontextprotocol/client to exact `2.2.0` for [GHSA-6qxp-vccf-f47h](https://github.com/advisories/GHSA-6qxp-vccf-f47h) (an MCP client security advisory); upstream pins `2.0.0` | this repo |
   | `examples/pi-coding-agent-extension/tests/takeover-session-manager.test.mjs` | Confirm Working Memory in the mock commit response, as the upstream takeover guard requires | [testing.md](testing.md), "Pi extension tests" |
   | `examples/pi-coding-agent-extension/lib/capture-utils-local.mjs` | Local wrapper of shared filters; keep tool-output opt-in, credential redaction and keyword capture | [Pi extension README](../examples/pi-coding-agent-extension/README.md), "Local fork: differences and updating an installed copy" |
   | `openviking/session/session.py` | Model-error propagation now matches upstream; keep the retained regression test when upstream moves helpers | [Working-memory regression tests](../tests/unit/session/test_extraction_batch.py), `test_working_memory_propagates_model_errors` |
   | `tests/misc/test_abi3_packaging_config.py` | Keep workflow tests skipped when their workflow is absent after each sync | this repo |
   | `tests/misc/test_root_docker_image_packaging.py` | Keep workflow tests skipped when their workflow is absent after each sync | this repo |
   | `tests/misc/test_docker_workflow_native_multiarch.py` | Deleted; remove tests that only read deleted workflows after each sync | this repo |
   | `examples/openclaw-plugin/tests/ut/package-install-contract.test.ts` | Keep the workflow test skipped when its workflow is absent after each sync | this repo |

   The table must match the path list printed in step 1, before the merge.
   That command compares `local-dev` with the current baseline, not the new tag in `$tag`.
   When a path is in the output and not in the table, add a row with its source.

   The command gives the current path list. Files that `local-dev` adds (status `A`) are not upstream files, so the table does not list them.

   Also compare the files that both sides changed. A clean merge can still be wrong:

   ```sh
   base=$(git merge-base local-dev "refs/upstream/tags/$tag")
   git diff --name-only "$base" local-dev >/tmp/ours.txt
   git diff --name-only "$base" "refs/upstream/tags/$tag" >/tmp/theirs.txt
   sort /tmp/ours.txt /tmp/theirs.txt | uniq -d
   ```

4. Update the upstream base of the scan. Set the `tag` line of `scripts/upstream-base` to the new tag and its commit, then write new `hit` lines.

   ```sh
   git rev-parse "refs/upstream/tags/$tag^{commit}"
   sh scripts/scan.sh baseline >scripts/upstream-base.new
   mv scripts/upstream-base.new scripts/upstream-base
   ```

5. Write the upstream blob map from the new base commit.
   The command needs that commit locally. [public-check.md](public-check.md#upstream-refresh) describes the map and its checks.

   ```sh
   sh scripts/public-check.sh --write-upstream-map
   ```

6. Review independent pin candidates separately. Keep existing image, scanner and uv pins during the upstream sync.
   [Updates](update.md#inputs) lists their sources; [image.md](image.md), "Move to a new upstream tag", gives the review procedure.
7. Run the public check and the scan before the merge commit.
   Both checks must exit 0. Use a neutral commit message that names the upstream tag.

   ```sh
   sh scripts/public-check.sh
   sh scripts/scan.sh --level fail tree
   git commit
   ```

8. Run the tests. All must pass. [testing.md](testing.md) lists each command.

   ```sh
   sh scripts/build.sh test
   GATEWAY_IMAGE=openviking:sync-test sh scripts/build.sh gateway
   sh tests/test_image.sh openviking:sync-test
   OPENVIKING_IMAGE=openviking:sync-test sh tests/test_compose.sh
   sh tests/test_setup_remotes.sh
   sh tests/test_scan.sh
   sh tests/test_public_check.sh
   python3 -m unittest tests.test_upstream_update -v
   ```

   Also run the Pi extension tests when upstream changed `examples/pi-coding-agent-extension/` or `examples/memory-plugin-shared/`.
9. Run the scan. The exit code must be 0. Look at each new upstream finding: add an exact allowlist entry with its reason, or remove the value by a local change ([secret-handling.md](secret-handling.md), "A new upstream tag").

   ```sh
   sh scripts/scan.sh --level fail tree
   ```

10. Merge `sync/$tag` into `local-dev` after review.

## Promotion

A promotion copies the tree of `local-dev` to `portable` as one new commit.
The commit has the files of `local-dev` exactly: a file that `local-dev` deleted is not in it.
Its only parent is the previous commit of `portable`; the first promotion has no parent.
The message names the `local-dev` revision. No history of `local-dev` or of upstream goes to `portable`.
The commit and the annotated release tag use the generic identity `OpenViking portable <portable@example.invalid>`.

Use `sh scripts/promote.sh` for a dry run. It checks the tree and prints the source, identity and ref names.
It reports whether the source and portable trees differ. An absent portable branch counts as a different tree.
It writes no Git object, ref or remote configuration.
Use a clean checkout other than `portable`; another worktree must not have `portable` checked out either.
A topic checkout is permitted, but the source of a new release is always the local branch `local-dev`.

Warning: require separate release approval before you create or move `portable`, and before you push.

The command does not ask for approval. It does not grant approval.

1. Run the dry run. Check the source revision and the previous `portable` commit.

   ```sh
   sh scripts/promote.sh
   git diff --stat portable local-dev
   ```

2. Get release approval and choose an increasing release version.
3. Create the local commit and annotated tag. Replace `X.Y.Z` with the chosen version.

   ```sh
   sh scripts/promote.sh --version X.Y.Z
   ```

4. Show the push plan without a push. The command runs all checks and stops after the Git push dry run.

   ```sh
   sh scripts/promote.sh --tag portable-vX.Y.Z --push shared --dry-run
   ```

5. Get separate approval for the printed plan. Keep the same release tag, remote and audit option.
6. Push the approved release. Check that the printed plan matches the approved plan.

   ```sh
   sh scripts/promote.sh --tag portable-vX.Y.Z --push shared
   ```

If the objects or remote state change, show a new plan and get approval again.
The command does not store approval or enforce equality across separate calls.
The command prints the push plan and runs a push dry run first.
The history scan of a push covers only the commits that the remote does not have.
The first push to a remote without `portable` scans the whole chain.
It sends only the explicit branch ref and the one release tag ref. It never forces a push.
The refspec sources are the checked object IDs, so a concurrent local ref change cannot substitute another object.
Use `--version X.Y.Z --push shared` only when both local creation and the push have approval.

| Option | Rule |
| --- | --- |
| No option | Dry run; no object, ref or remote changes. |
| `--version X.Y.Z` | Create the commit and annotated tag locally. Each decimal part has no leading zero, except zero itself. |
| `--tag portable-vX.Y.Z` | Push an existing annotated local tag with `--push`. It must name the current `portable` tip. |
| `--push REMOTE` | Push with `--version` or `--tag`. The fetch and push URLs must match. |
| `--dry-run` | With `--tag` and `--push`, print the plan and run the push dry run, then stop. |
| `--development-remote` | With `--push`, count other remote refs without printing their names or failing because of them. |
| `--root` | With `--version`, create a parentless snapshot instead of extending the chain. |
| `--host-deny-required` | Require a nonempty regular local host deny list with at least one pattern. |
| `--help` | Print usage and exit with 0. |

The push dry-run option refuses `--version`; create the approved local release first, then show its push plan.
This option does not create release objects or change remote refs. Git still runs the installed pre-push hook.

The command refuses a dirty index or tree, a shallow repository, duplicate tags and versions that do not increase.
Without `--root`, it refuses `--version` with "nothing to promote" when the source and portable tip have identical trees.
This refusal occurs before any commit object is written.
With `--root`, an unchanged tree remains valid for a first public snapshot with a separate history.
A version must exceed every local tag matching the portable release prefix, by numeric comparison of its three parts.
It refuses malformed local release versions rather than ignoring them.
It refuses `upstream`, a disabled push URL, mirror remotes, multiple URLs and remote helper URLs.
It refuses URL user information, query data and whitespace without printing the URL.
Use a credential helper instead of credentials or user information in a URL.

The host deny list is required by default when any local or remote-tracking branch has the exact name `local-dev`.
It is also required when the source commit named by the `portable` tip message remains in the object database.
These checks define a repository that retains local development history; they do not inspect every unreachable object.
A portable-only clone without those refs or that source object does not require the list unless the option is set.
No option disables a required list. A comment-only list does not meet the requirement.

The checks run in this order: fail-level tree scan, public check, source-object public check, then fail-level history scan.
The source-object check verifies the exact `local-dev` tree before creation, even from a different checkout.
The new history range is the old `portable` commit through the new commit, excluding the old commit.
For a root snapshot, the history scan checks only the new commit.
The scanner needs its configured image locally or its supported binary; this command does not download either.
The local refs change together only after all checks pass. A failed history scan can leave unreferenced objects.
The command prints the new commit author, committer and tagger.

With `--root --push`, the target must have neither `portable` nor a portable release tag.
This rule prevents a new root from dropping a published chain, even when only its tags remain on the target.
A later push of a root tag refuses a target whose portable branch or release tags name another commit.
A repeated push of the same root is permitted. Every push still needs a normal, non-forced push dry run.

An existing tag push checks the tag's committed tree and all reachable portable history.
An older snapshot without the public rule file is refused with a request to create a new checked release.
The command does not weaken or skip the pre-push hook.
After the push, it prints the remote refs and reports server pull refs as a count.
Without `--development-remote`, it exits with 1 for another ref or a remote HEAD that names another commit.
It deletes nothing.
A remote HEAD that names `portable` is an alias, not a foreign branch.

Use `--development-remote` explicitly when the target also holds private development branches and other tags.
Use the same option when you show the plan and when you push; the plan prints the audit mode.
The audit prints portable refs, a count of other refs and a count of server pull refs.
It hides other ref names and the remote HEAD, and it does not fail because of those refs.
This option changes no check before the push, no refspec and no root rule.
The remote name selects no policy: `origin` remains a release target unless you set this option.

| Exit code | Meaning |
| --- | --- |
| 0 | Dry run, local creation or push succeeds under the selected audit mode. |
| 1 | Safety refusal, check finding, push failure or foreign remote ref. |
| 2 | Invalid arguments, missing tools or a required check input error. |

After a push failure, inspect the remote before retrying; a server can accept one ref and refuse the other.
Local release refs remain available after a push failure.

### Commit definition

The following block defines the default commit, its parent, tree, message and identity.
The promotion tests run it only in a temporary repository and compare its commit with the command.
The command adds checks, a tag and a transactional ref update around this definition.
Do not run the block as a substitute for the command's checks.

   <!-- promotion:begin (tests/test_promotion.sh runs this block) -->
   ```sh
   GIT_AUTHOR_NAME='OpenViking portable' GIT_AUTHOR_EMAIL=portable@example.invalid
   GIT_COMMITTER_NAME='OpenViking portable' GIT_COMMITTER_EMAIL=portable@example.invalid
   export GIT_AUTHOR_NAME GIT_AUTHOR_EMAIL GIT_COMMITTER_NAME GIT_COMMITTER_EMAIL
   rev=$(git rev-parse --verify 'local-dev^{commit}')
   if old=$(git rev-parse --verify --quiet refs/heads/portable); then parent="-p $old"; else old=; parent=; fi
   new=$(git commit-tree $parent -m "Promote local-dev $rev" "$rev^{tree}")
   git update-ref -m "promote local-dev $rev" refs/heads/portable "$new" "$old"
   git log -1 --format='%H %an <%ae> %s' portable
   ```
   <!-- promotion:end -->

`git commit-tree` writes a commit with the tree of `local-dev` and, when `portable` exists, one parent.
`git update-ref` moves `portable` only when it still points to `$old`; an empty `$old` requires an absent branch.
The four identity variables stay set if you run this definition in your shell.
The command sets them in its own process, so your shell identity stays unchanged.

`git merge --squash` does not work here: on the first promotion it stops with
`Squash commit into empty head not supported yet`, and later it refuses unrelated histories.

The commit dates keep your machine's time zone.
Not verified: whether that time zone meets your release policy.

## Tags

`sh scripts/promote.sh --version X.Y.Z` creates the annotated release tag with the generic identity after its checks ([promotion](#promotion)).
The version must exceed every local portable release tag, by numeric comparison of its three parts.
Without `--root`, the command refuses an equal source and portable tree as "nothing to promote".

| Tag | Meaning |
| --- | --- |
| `portable-vX.Y.Z` | A release of `portable`, for example `portable-v0.1.0`. Release images build from this tag only. |
| `pre-split-*` | The state before the repo split. |

`scripts/build.sh` uses `X.Y.Z` as the portable version, for example `0.4.22+p0.1.0` (label `0.4.22-p0.1.0`). [image.md](image.md), "Version", describes the version string.

`portable` has no upstream history, so `scripts/build.sh` finds no upstream tag there.
It then reads the `tag` line of `scripts/upstream-base` and prints
`build: upstream version <tag> from scripts/upstream-base (no upstream tag in the history)`.
On the tag `portable-vX.Y.Z`, the version is `<upstream version>+pX.Y.Z`.
To set the version yourself is optional; `OPENVIKING_VERSION` in the environment wins:

```sh
upstream=$(awk -F '\t' '$1 == "tag" { print $2 }' scripts/upstream-base)
OPENVIKING_VERSION="${upstream#v}+p0.1.0" sh scripts/build.sh gateway
```

To move `portable` without a network connection, use a Git bundle:

```sh
git bundle create openviking-portable.bundle portable portable-v0.1.0
```

Replace `portable-v0.1.0` with the name of the release tag.
After a successful scan, the pre-push hook runs the [public check](public-check.md#hook) on each pushed `portable-v*` tag object.

## Checks

- Run `sh scripts/public-check.sh` before each commit and release. Exit 0 means no finding; [public-check.md](public-check.md) gives the other exit codes.
- The pre-push hook scans each pushed ref. The level is `fail` for `portable` and `portable-v*` ([secret-handling.md](secret-handling.md)). After a successful scan, the public check reads the pushed object of each portable ref. The hooks run only where `scripts/install-hooks.sh` ran.
- A CI job runs the scan and the public check independently ([secret-handling.md](secret-handling.md#ci)). See [ci.md](ci.md) for the pipeline.
- A failed public check on `portable` stops the release. Correct the development branch, then promote again; see [CI recovery](ci.md#if-a-public-check-fails).
- `sh tests/test_public_check.sh` checks the public tree rules and pushed-object hook behavior in temporary repositories.
- `sh tests/test_workflows.sh` checks the strict YAML subset, run lines, pinned actions and build conditions without executing jobs.
- `python3 -m unittest tests.test_upstream_update -v` checks update detection, qualification, deletion rules and caller isolation. These tests need Python 3, Git and the upstream base commit. Use a development checkout, not a clone of `portable` ([updates](update.md#local-tests)).
- `sh tests/test_promotion.sh` checks the commit definition and `scripts/promote.sh` in temporary repositories with local bare remotes. It covers check order, history ranges, tags, push plans and audits; one fixture uses the real public check and pre-push hook.
