# Git remotes

Use two remotes for development, and an optional third for releases:

| Remote | URL | Use |
| --- | --- | --- |
| `origin` | the Git server from which you clone | Fetch and push of this repo. |
| `upstream` | `https://github.com/volcengine/OpenViking.git` | Fetch only. Read upstream OpenViking release tags, to merge them and to compare files. |
| `shared` (optional) | your release repository on a shared Git server, for example GitHub | Push of `portable` and the tags `portable-v*` only. See [The remote `shared`](#the-remote-shared). |

Your private `local-dev` branch holds upstream history and merges upstream release tags.
The public `portable` branch holds source snapshots without that history.
The scripts below keep upstream refs apart from your release refs.

A clone does not copy the remote configuration. Run the setup script once in each new clone:

```sh
sh scripts/setup-remotes.sh          # create, convert or repair the remote upstream
sh scripts/setup-remotes.sh --check  # change nothing; exit 1 if the configuration is wrong
```

The script:

- Creates the remote `upstream` if it is absent.
- Converts an existing `upstream` in place. For each key that it changes, it prints the old and the new value.
- Prints `upstream: no change` when the configuration is already correct. A second run gives the same configuration and exits 0.
- Does not delete refs. Refs under `refs/remotes/upstream/` and upstream tags in `refs/tags/` from an older configuration stay. See [Remove the old upstream refs](#remove-the-old-upstream-refs).
- Does not change `origin`. It prints the `origin` URL without credentials, and it warns if `origin` is absent.

Both scripts remove the credential from each URL that they print: everything from `://` to the last `@` before the next `/` (for example `user:password@`, `token@`, also a password with a raw `@`). A password with a raw `/` cannot be told apart from the path, so a URL that still holds an `@` after `://` is printed as `<url hidden>`. This also hides a URL with an `@` in its path. An scp-style URL such as `git@host:path` holds no secret and is printed as it is.

To use a mirror, set `UPSTREAM_URL` for both scripts:

```sh
UPSTREAM_URL=https://mirror.example/OpenViking.git sh scripts/setup-remotes.sh
UPSTREAM_URL=https://mirror.example/OpenViking.git sh scripts/fetch-upstream.sh "$(awk -F '\t' '$1 == "tag" { print $2 }' scripts/upstream-base)"
```

## Configuration of `upstream`

```ini
[remote "upstream"]
	url = https://github.com/volcengine/OpenViking.git
	pushurl = DISABLED
	tagOpt = --no-tags
	fetch = +refs/upstream-none/*:refs/upstream/none/*
```

| Setting | Reason |
| --- | --- |
| `pushurl = DISABLED` | `git push upstream` fails, because `DISABLED` is not a valid repository. The value is a relative path. If the working directory holds a local directory with the name `DISABLED`, a push reaches that directory, never the upstream server. |
| `tagOpt = --no-tags` | Upstream tags do not enter `refs/tags/`. `refs/tags/` is for the tags of this repo: `pre-split-*` and `portable-v*`. Upstream has more than 100 tags, and some of them (for example `cli@*`, `python-sdk@*`) are not releases of the server. |
| `fetch = +refs/upstream-none/*:refs/upstream/none/*` | No upstream ref matches this pattern. A plain `git fetch upstream` lists the upstream refs and transfers no objects. |

`--check` also fails if `remote.upstream.mirror` is set to a value other than `false`.

## The remote `shared`

Send `portable` and its tags `portable-v*` to your release repository on a shared Git server.
The remote `shared` points to that repository, which can be public.
`portable` must hold no host values; keep other development branches private.

Warning: `local-dev`, `main`, `topic/*`, `sync/*`, `pre-split-*` and the upstream tags never go to `shared`. Their history holds host values.

Create or convert the remote with `SHARED_URL`:

```sh
SHARED_URL=https://github.com/<account>/<repo>.git sh scripts/setup-remotes.sh
sh scripts/setup-remotes.sh --check
```

| Variable | Use |
| --- | --- |
| `SHARED_URL` | The URL of your release repository. With it, the script creates the remote, or converts it in place, and prints each key that it changes. A second run prints `shared: no change`. |
| `SHARED_REMOTE` | The name of the remote. The default is `shared`. The script refuses `origin`, `upstream`, `portable` (the name of the branch), and a name with characters other than letters, digits, `.`, `_` and `-` (exit code 2). |

Without `SHARED_URL`, the script does not change the remote:

- The remote is absent: the script and `--check` print `shared: remote 'shared' is absent (not configured; set SHARED_URL to create it)` and pass.
- The remote exists: the script and `--check` check it. The URL is not compared with a value, but `pushurl` must be equal to `url`. A wrong setting gives exit code 1 with a message for each key.

With `SHARED_URL`, `--check` also compares the URL, and fails if the remote is absent. The script prints each URL without the credential, as for `upstream`.

### Configuration of `shared`

```ini
[remote "shared"]
	url = <SHARED_URL>
	pushurl = <SHARED_URL>
	fetch = +refs/heads/portable:refs/remotes/shared/portable
	tagOpt = --no-tags
	push = refs/heads/portable:refs/heads/portable
	push = refs/tags/portable-v*:refs/tags/portable-v*
```

| Setting | Reason |
| --- | --- |
| `pushurl` equal to `url` | A push goes to the same repository as the fetch. A `pushurl` from an older setting cannot send the push to another server. |
| `fetch = +refs/heads/portable:refs/remotes/shared/portable` | A plain `git fetch shared` reads `portable` only. No wildcard. |
| `tagOpt = --no-tags` | A fetch does not bring tags of the shared repository into `refs/tags/`. |
| `push` (two values) | The configured defaults name only `portable` and the local tags `portable-v*`. Use the promotion command below for a checked push. |

`--check` also fails if `remote.shared.mirror` is set to a value other than `false`.

### Push a release

Use an existing annotated `portable-vX.Y.Z` tag at the current `portable` tip.
Run from a clean checkout other than `portable`; no worktree may have `portable` checked out.
See [promotion](branches.md#promotion) for local release creation and the other checks.

1. Show the push plan. The command runs the checks and a Git push dry run without changing remote refs.

   ```sh
   sh scripts/promote.sh --tag portable-vX.Y.Z --push shared --dry-run
   ```

2. Get separate approval for the printed plan.
   Keep the same release tag, remote and audit option.
3. Push with the same call without `--dry-run`.
   Check that the printed plan still matches the approved plan.

   ```sh
   sh scripts/promote.sh --tag portable-vX.Y.Z --push shared
   ```

The command checks the fetch and push URLs and pins the commit and tag object IDs in its two refspecs.
After a push, it reports other remote refs without deleting them.
The default release audit fails for other refs; `--development-remote` counts them without printing their names or failing because of them.
Server pull refs appear only as a count and do not fail the audit.
Use `--development-remote` on both calls when the target also holds private development refs.
The remote name selects no policy; even `origin` uses the release audit unless you set that option.

Warning: if the objects or remote state change, show a new plan and get approval again.
The command does not store approval or enforce the same plan across separate calls.

### The push guard

The hook `pre-push` (installed with `scripts/install-hooks.sh`, see [secret-handling.md](secret-handling.md#hooks)) guards each remote other than `origin` and `upstream`: `shared`, a remote with another name, and a URL given on the command line. A push there may send or delete only `refs/heads/portable` and `refs/tags/portable-v*`. For each other ref the hook prints a line and refuses the whole push, before the scan:

```text
pre-push: refused: push of refs/heads/local-dev to 'shared'; this remote takes only refs/heads/portable and refs/tags/portable-v*
pre-push: push refused; local-dev, topic/*, sync/* and upstream tags hold host values (docs/remotes.md)
```

A delete is printed as `delete of <ref>`. The guard checks the name of the remote ref.
`git push shared local-dev:portable` passes the guard; the scan checks all history at level `fail` and refuses a host value.
After a successful scan, the hook runs the [public check](public-check.md#hook) on the pushed object for `portable` and `portable-v*`.

The guard has these limits:

- A remote named `origin` or `upstream` is exempt from the guard, not the checks. In a clone of the shared repository, `origin` is the shared server, so the guard does not protect it there. Portable refs still get a scan at level `fail` and the public check. Other refs use their existing scan level.
- A delete of `portable` itself passes the guard: `git push shared :portable` deletes the branch on the server.
- The guard reads the name of the remote ref only.

Warning: `git push --no-verify` skips the guard, the scan and the public check.
The hook runs only on a branch that has `scripts/git-hooks/pre-push`.
On a branch without it, such as `main`, the dispatcher runs no hook.

### Why the default fetch refspec matches nothing

- With the usual refspec `+refs/heads/*:refs/remotes/upstream/*`, a plain `git fetch upstream` downloads every upstream branch, also the work-in-progress branches.
- With no refspec at all, `git fetch upstream` fetches the upstream `HEAD` into `FETCH_HEAD`.
- A wildcard refspec that matches no ref is valid. Git exits with code 0 and transfers nothing.

This repo merges release tags, not upstream branches. A fetch of one named tag is the only upstream fetch that it needs.

The destination `refs/upstream/none/*` is under `refs/upstream/`. If a ref ever matches, it still cannot enter `refs/heads/`, `refs/tags/` or `refs/remotes/`. `git fetch --prune upstream` prunes only refs under the destination of the refspec, so it does not delete refs under `refs/remotes/upstream/` or `refs/upstream/tags/`.

## Fetch one upstream release

```sh
sh scripts/fetch-upstream.sh "$(awk -F '\t' '$1 == "tag" { print $2 }' scripts/upstream-base)"
sh scripts/fetch-upstream.sh cli@0.4.20
```

Start the script by its path, not through a symlink. The script finds `setup-remotes.sh` in the directory of the path that starts it.

The script:

1. Accepts only `v<digits>.<digits>.<digits>` with an optional suffix that starts with `-`, `.` or `+` (for example `v1.2.3`, `v1.2.3.dev02`), or `cli@<digits>.<digits>.<digits>`. It refuses every other name, a name with white space, a name with `..`, and a name that starts with `-`. The exit code is 2. The name goes into a refspec, so the script checks it before use.
2. Runs `scripts/setup-remotes.sh --check`, and stops with exit code 1 if the remote `upstream` is wrong.
3. Fetches the one tag with its full history into `refs/upstream/tags/<tag>`:
   `git fetch --no-tags upstream "+refs/tags/<tag>:refs/upstream/tags/<tag>"`
4. Prints the commit ID of the tag.

List the fetched releases:

```sh
git for-each-ref refs/upstream
```

### Why the default fetch is not shallow

The private `local-dev` branch holds upstream history.
A sync merges an upstream release tag into that branch.
A merge needs the common ancestor of the two sides.

A `--depth 1` fetch writes the commit IDs that it fetches to `.git/shallow`. Git then treats those commits as commits without parents. That is also true when the commit is already in the repo with its full history. In this repo the upstream tag commits are ancestors of the local branches, so a shallow fetch cuts the local history too: `git log`, `git merge-base` and `git merge` stop at the shallow commit. The repo stays like that until `git fetch --unshallow`.

So the default fetch has no `--depth` and no `--filter`. When the history is already in the repo, the fetch transfers only the new commits of the tag.

### `--shallow`, for a clone that only compares files

```sh
sh scripts/fetch-upstream.sh --shallow "$(awk -F '\t' '$1 == "tag" { print $2 }' scripts/upstream-base)"
```

`--shallow` adds `--depth 1 --filter=blob:none`. The fetch gets the tag commit and its trees, but no parents and no file contents. Git gets a file content from `upstream` the first time that a command needs it.

The script refuses `--shallow` with exit code 2, unless one of these is true:

- `git rev-parse --is-shallow-repository` prints `true`. The repo is already shallow, so its history is already cut.
- The repo is empty: it has no ref, `HEAD` is not a valid commit, and it has no second worktree. Then no local history can be cut.

This is a simple test. A full test would have to know which local commits the tag shares with the history of each branch, and that needs the upstream history that `--shallow` does not fetch. The simple test refuses some safe cases, for example a clone that has only unrelated local commits. Use a new empty repository for such work.
Run this block in an empty directory outside the source checkout.
Replace `<repo>` with the absolute checkout path and `v<X.Y.Z>` with an older upstream release tag.
Find an older tag on the [upstream releases page](https://github.com/volcengine/OpenViking/releases).

```sh
repo='<repo>'
older='v<X.Y.Z>'
upstream=$(awk -F '\t' '$1 == "tag" { print $2 }' "$repo/scripts/upstream-base")
git init compare && cd compare
sh "$repo/scripts/setup-remotes.sh"
sh "$repo/scripts/fetch-upstream.sh" --shallow "$older"
sh "$repo/scripts/fetch-upstream.sh" --shallow "$upstream"
```

The first filtered fetch changes the repository configuration. Git sets these values itself:

- `core.repositoryformatversion = 1`
- `remote.upstream.promisor = true`
- `remote.upstream.partialclonefilter = blob:none`

`setup-remotes.sh --check` ignores these values.

## Compare one upstream file between two versions

Replace `v<X.Y.Z>` with an older tag from `git for-each-ref refs/upstream/tags`.
The current tag comes from `scripts/upstream-base`.

```sh
older='v<X.Y.Z>'
upstream=$(awk -F '\t' '$1 == "tag" { print $2 }' scripts/upstream-base)
sh scripts/fetch-upstream.sh "$older"
sh scripts/fetch-upstream.sh "$upstream"
git diff "refs/upstream/tags/$older" "refs/upstream/tags/$upstream" -- Dockerfile

# Show the file at the current version:
git show "refs/upstream/tags/$upstream:Dockerfile"

# List the files that changed between the two versions:
git diff --stat "refs/upstream/tags/$older" "refs/upstream/tags/$upstream"
```

In a repo that used `--shallow`, `git diff` and `git show` need network access to the upstream server for each file content that is not yet in `.git`.

## Remove the old upstream refs

An older clone can have `refs/remotes/upstream/main` and upstream tags in `refs/tags/`.
`setup-remotes.sh` does not delete those refs.
If your clone has them, remove them only after a review, in this order.

Warning: the removal makes objects unreachable. Tags and commits that only the old refs hold (tags that no local branch reaches, and commits of `upstream/main` that no other ref holds) can be deleted by a later `git gc`. Only a new fetch from upstream gets them back.

While the upstream tags are in `refs/tags/`, push to `origin` by explicit ref name only, for example `git push origin local-dev`. Never use `git push --tags`, `--mirror` or `--follow-tags`: they send the upstream tags to `origin`.

1. Fetch each upstream release that you still need into `refs/upstream/tags/`, before the removal. Do this for each tag that you still need, also for a tag that no local branch reaches, for example an older release:

   ```sh
   sh scripts/fetch-upstream.sh "$(awk -F '\t' '$1 == "tag" { print $2 }' scripts/upstream-base)"
   sh scripts/fetch-upstream.sh v<X.Y.Z>
   ```

   The history stays reachable through `refs/upstream/tags/*` and through the local branches.

2. Make sure that no local branch tracks `upstream`. The command prints nothing when no branch does:

   ```sh
   git for-each-ref --format='%(refname:short) %(upstream)' refs/heads | grep ' refs/remotes/upstream/' || true
   ```

3. Delete the old remote-tracking refs. `refs/remotes/upstream/HEAD` can be a symbolic ref; `--no-deref` deletes the symbolic ref itself, not its target:

   ```sh
   git for-each-ref --format='%(refname)' refs/remotes/upstream | xargs -n 1 git update-ref --no-deref -d
   ```

4. List the tags in `refs/tags/` that are not tags of this repo. Read the list before the next step:

   ```sh
   git tag -l | grep -v -e '^pre-split-' -e '^portable-v'
   ```

5. Delete those tags locally:

   ```sh
   git tag -l | grep -v -e '^pre-split-' -e '^portable-v' | xargs -n 1 git tag -d
   ```

Warning: `git tag -d` deletes a local tag only. If `origin` has the same tags, a later `git fetch origin` brings them back. Delete them on `origin` in a separate, reviewed step, or fetch `origin` with `--no-tags`.

Objects stay in `.git` until `git gc` removes them. Objects that the local branches or `refs/upstream/tags/*` reach are never removed.

## Remove the remote `upstream`

Warning: delete the refs under `refs/upstream/` before `git remote remove upstream`. In a repo that used `--shallow`, the other order leaves missing objects: `git fsck` reports broken links and `git gc` fails.

```sh
git for-each-ref --format='%(refname)' refs/upstream | xargs -n 1 git update-ref -d
git remote remove upstream
```

`git remote remove` also deletes the `promisor` and `partialclonefilter` settings.
