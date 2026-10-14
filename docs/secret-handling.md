# Secret handling

`scripts/scan.sh` stops a secret or a host value before it goes to a remote or into an image. It runs the same way on a Linux host, on a Mac and in a CI system.

This repository is a source fork: it holds the full upstream source tree and a few local files. The scan is strict for local files. It accepts the public upstream content that section "Upstream content" names.

## What the scan finds

| Finding | Source | Result |
| --- | --- | --- |
| Secret | The rules in `.gitleaks.toml` (the gitleaks ruleset named in that file) | Always fails. Content allowlists accept the exact fixture values of the upstream tree. |
| Host value | One literal pattern for each line of `scripts/host-values.deny` and of the untracked `.local/host-values.deny`, and one regular expression for each line of `scripts/host-values.regex` | Fails at level `fail`. Prints a warning at level `warn`. A finding of a tracked rule in upstream content is accepted. |
| Policy | A tracked file named `.gitleaksignore` or `.gitleaksbaseline`; a tracked file in `.local/`; a tracked archive, database dump or Git bundle | Always fails. An upstream archive with an exact entry in `scripts/upstream-base` is accepted. |

A host value is text that identifies a private host: its private network, its host name and its state directories. Keep development history that contains host values on your private `local-dev` branch. A portable branch, a portable tag and an image must not contain them.

The output gives the file, the line, the rule and, in history mode, the commit. It does not give the secret value (`--redact`). A finding in a commit message shows as `(commit message):<line>`. A finding in a file name shows as `(file names):<n>`: line `<n>` of `git ls-files` (tree), of `git diff --cached --name-only` (staged), or of the files that the commit changes (history).

### Deny lists

The literal patterns come from two files with the same format:

| File | Tracked | Content |
| --- | --- | --- |
| `scripts/host-values.deny` | yes | Generic patterns only. It holds no pattern now, only its header. |
| `.local/host-values.deny` | no (`.local/` must be ignored by `.gitignore` or `.git/info/exclude`) | The values of one host: its domain, its private network, its host name and its paths outside the repository. |

A pattern of a real host in a tracked file puts that host value into the tree that the scan forbids. So the values of a host are only in `.local/host-values.deny` of each checkout on that host. Create the file on each host that works on `local-dev`.

The scan reads `scripts/host-values.deny` and the local file of the checkout that holds `scripts/scan.sh`. The local file is optional: a clone in the target environment, a CI job, the branch `portable`, a tag `portable-v*` and the mode `image` need no local file. Without it, the scan uses the tracked list and `scripts/host-values.regex`. The deny lists and the regex list together must give at least one rule, else the scan stops with exit 2.

The rule ids are `host-value-<n>` for the tracked list and `host-value-local-<n>` for the local list. The output gives the pattern of a finding. Thus a finding of a local rule prints a host value on the screen of that host; it does not go into a file.

### Private addresses

`scripts/host-values.regex` finds addresses of the private ranges 10/8, 172.16/12 and 192.168/16, of the shared range 100.64/10, and IPv6 unique local addresses (prefix fc00 with length 7). Loopback and documentation addresses give no finding. This document writes the ranges in this short form, because the scan reports a range in address form.

A version number can look like an address. Thus an IPv4 address gives a finding only when the character before it is not a letter, a digit or one of `_ . - + : = < > ~ ^ !` (a single `=`, as in `host=`, is permitted), and the character after it is not a letter, a digit, `_`, `-`, or `.` followed by a letter or a digit. So `pkg==10.2.3.4`, `pkg>=10.2.3.4`, `image:10.2.3.4`, `v10.2.3.4` and `10.2.3.4.dev0` give no finding; an address in a URL, after a blank, a quote, `@` or `=` gives one. Use `sh scripts/scan.sh --level fail tree` to check your local files against these rules.

### Policy findings

The scan refuses what it cannot read or what switches it off:

| Policy | Modes | Why |
| --- | --- | --- |
| A tracked file named `.gitleaksignore` or `.gitleaksbaseline` (any directory, any case) | all repository modes | A `.gitleaksignore` with `<commit>:<file>:<rule>:<line>` hides a finding. |
| A tracked file in `.local/` at the root | all repository modes | `.local/` holds values of one host. The scan does not report host values in `.local/host-values.deny`, so a tracked copy of it must not pass. |
| A tracked archive, database dump or Git bundle | all repository modes | The content is compressed or binary. |

An archive, a dump or a bundle is known by its extension or by its first bytes:

- Extensions: `zip jar war ear whl egg apk aab ipa nupkg tar tgz taz tbz tbz2 tb2 txz tlz tzst gz bz2 xz zst lz lz4 lzma lzo z 7z rar cab cpio ar deb rpm iso dmg sql dump pgdump backup db sqlite sqlite3 db3 mdb accdb rdb bundle pack` (any case).
- Content: gzip, compress, zip, bzip2, xz, zstd, 7z, rar, ar and deb, lz4, lzip, rpm, cab, tar (`ustar` at byte 257), PostgreSQL custom dump (`PGDMP`), SQLite, Git bundle v2 and v3, Git pack, Redis dump, and a text dump with the header of `pg_dump`, `mysqldump` or `mariadb-dump` in the first 264 bytes.

Content does not switch the scan off. A "gitleaks:allow" comment does not hide a finding (`--ignore-gitleaks-allow`), also not a host value. gitleaks reads a `.gitleaksignore` from the scanned directory; the scan gives it the Git directory (modes `staged`, `history`) or a directory of its own (`tree`), so a `.gitleaksignore` in the working tree does not apply, also when it is not tracked.

## Upstream content

The baseline records findings in the upstream tree named by its `tag` line.
They are public example and test content. Local files get no exception.

### Upstream base

`scripts/upstream-base` names the upstream base: the upstream release tag of the last merge into `local-dev` and its commit.

```text
tag<TAB><upstream tag><TAB><upstream commit>
```

The scan uses the commit object, not only the ref. A full clone of `local-dev` has this commit, because `local-dev` merges the tag; it needs no `scripts/fetch-upstream.sh`. When `refs/upstream/tags/<tag>` exists, it must point to the same commit, else the scan stops with exit 2. When the ref does not exist, `scripts/upstream-base` must be the version of `HEAD`: if the working tree or the index differs from `HEAD` (`git diff --quiet HEAD -- scripts/upstream-base`), or `HEAD` has no such file, the scan stops with exit 2 and names `sh scripts/fetch-upstream.sh <tag>`. The check reads the checkout that holds `scripts/scan.sh`. A checkout without `HEAD` (an empty repository) or outside a Git repository has no committed version; there the check does not apply. The mode `selftest` does not read the base.

### Host values in upstream files

A host-value finding of a tracked rule (`scripts/host-values.regex`, `scripts/host-values.deny`) is accepted when the scanned file is equal to the file at the same path in the base commit:

| Mode | The scanned file | Compared with |
| --- | --- | --- |
| `tree` | the working tree copy and, if it differs, the staged copy (`git hash-object`) | the blob of the path in the base commit |
| `staged` | the staged blob (`:<path>`) | the same |
| `history` | the blob of the commit (`<commit>:<path>`) | the same |

Without the base commit (a shallow clone, or a branch without the upstream history), the scan uses the `hit` lines of `scripts/upstream-base`: a finding is accepted when its path and the Git blob id of its line (`git hash-object` of the line with its newline) are a `hit` line. `scripts/scan.sh baseline` writes these lines from the base tree. The file holds hashes and upstream paths, no address and no home value: the baseline uses the tracked rules only.

A rule of `.local/host-values.deny` (`host-value-local-<n>`) has no exception. A home value gives a finding in each file, upstream or local.

Limits:

- A local change to an upstream file makes the whole file local content: each upstream address in it is then reported.
- A local file that is a byte-equal copy of an upstream file at the same path is accepted. A copy at another path is reported.
- Somebody who can write refs and `scripts/upstream-base` can declare local content to be upstream content. Review each change of `scripts/upstream-base`. Without the ref, only a committed change of the file takes effect.
- The fallback accepts a line in the same path with the same text, also in a later version of the file.
- The mode `image` has no exception.

Negative controls (`tests/test_scan.sh`, section "upstream content"): an address in an upstream file is accepted; the same address in a local file fails; a changed upstream file fails; a home pattern in an upstream file fails; a copy of the upstream archive at another path fails; a changed archive fails; a tag ref with another commit is an error; an edited `tag` line without the ref is an error (`tree`, `history`), with the ref it is used as before (`tree`, `baseline`); a repository without `HEAD` runs `tree` and `staged`; the same checks without the base commit use the `hit` lines.

### Upstream history

`scripts/scan.sh history` without a range scans `^<base commit> HEAD`: the local commits and the merge commits, not the upstream commits. Without the base commit in the repository, it scans `HEAD`. An explicit range is scanned as given, unless `SCAN_EXCLUDE_UPSTREAM=1` is set. The hook `pre-push` sets it for each ref except `portable` and `portable-v*`. For a portable ref, the hook scans the commits that the remote does not have, upstream commits included. The first push of a chain scans all of it. The hook knows the remote commits from the other refs of the same push and from the remote-tracking refs of a remote name.

gitleaks shows no diff for a merge commit. Thus the upstream files that a merge brings are not in the history scan; the modes `tree` and `staged` (hook `pre-merge-commit`) scan them.

### Secret allowlists

The allowlists in `.gitleaks.toml` match exact values, or the exact form of one family. There is no path allowlist. The counts below describe the upstream tag at the last update of this table.
Run `sh scripts/scan.sh --level fail tree` for the current checkout.
The output line `scan: <n> finding(s) in upstream content accepted (...)` gives the current accepted count, not only secret findings.

| Family | Values | Findings | Reason |
| --- | --- | --- | --- |
| Documentation placeholders, `docs/en`, `docs/zh` | `your-admin-key`, `your-secret-root-key`, `YOUR_ROOT_API_KEY`, `ADMIN_API_KEY` | 26 + 13 + 1 + 2 | curl examples with a placeholder key |
| Authentication placeholder, `docs/zh/guides/04-authentication.md` | `your-secret-root-key-here` | 3 | Exact synthetic root-key value; anchors reject extra text and other values |
| `examples/cloud/GUIDE.md` | `my-strong-secret-key-2024`, `abcdef1234567890...`, `fedcba0987654321...` | 3 + 1 + 1 | example configuration and a shortened key |
| `docs/en/guides/04-authentication.md` | `eyJhbGciOiJSUzI1NiIs...` | 1 | a shortened JWT header |
| `docs/*/guides/02-volcengine-purchase-guide.md` | `sk-1234567890abcdef1234567890abcdef` | 4 | a sequence of digits and letters |
| Test fixtures, `tests/` | `INVALID_KEY_XYZ_123`, `invalid-key-12345`, `env-key-1234567890`, `test-submission-123` | 1 + 1 + 3 + 1 | invalid or synthetic keys |
| Test root keys, `tests/server`, `tests/integration` | three `test-root-key-...` values | 4 | test constants |
| `examples/memory-plugin-shared/input-filters.test.mjs` | `sk_live_ABCDEFGHIJ` | 1 | a fake Stripe key of a filter test |
| Code, `crates/ragfs/src/git/backends/s3.rs` | `acct1/refs/heads/main`, `git/acct1/refs/heads/main` | 3 | object keys, not secrets |
| Code, `benchmark/`, `bot/tests/`, `tests/misc/` | `approx_chars_div_4`, `dimension=1536`, `skip_heartbeat=True` | 1 + 1 + 3 | call arguments, not secrets |
| [Upstream community template](https://github.com/volcengine/OpenViking/blob/main/.github/ISSUE_TEMPLATE/config.yml), absent from this tree | the Lark invitation URL form (line allowlist, UUID token) | 1 | the public join link of the upstream community group |

The additional authentication placeholder belongs to the documentation placeholder family.
The earlier family counts remain historical; the current scan output gives the accepted upstream count.
The Lark invitation allowlist remains in `.gitleaks.toml`, but its source template is absent from this tree.
One more family holds a local file:

| Family | Values | Findings | Reason |
| --- | --- | --- | --- |
| Local test fixture, dummy value, present in history: `examples/pi-coding-agent-extension/tests/capture-adapter.test.mjs` | `bearer-value` | 1 | Dummy `Authorization: Bearer` value of a redaction test. The exact allowlist entry permits this fixture in tree and history scans. `sh tests/test_scan.sh` checks that a different bearer value still fails. |

The upstream finding `benchmark/locomo/openclaw/run_full_eval.sh:22` (`generic-api-key`, a hardcoded `GATEWAY_TOKEN`) has no allowlist entry: the literal is removed from the tree (section "Local changes to upstream files for secrets").

### Local changes to upstream files for secrets

A hardcoded secret in an upstream file gets no allowlist entry. It is removed from the tree by a local change to the upstream file. Each later sync must keep the local change.

| Path | Change and reason | History | Sync |
| --- | --- | --- | --- |
| `benchmark/locomo/openclaw/run_full_eval.sh` | `GATEWAY_TOKEN` comes from the environment; the script stops when it is empty. The header shows its use. No hardcoded token remains in the file. | Upstream history still holds the value. Keep that history on the private development branch, not `portable`. | When the file conflicts, keep the local line. |

### Upstream archive

| Blob | Path | Reason |
| --- | --- | --- |
| `7110648c` | `examples/pi-experimental-context-management/demo-evidence/pi-ctxwin-demo.zip` | upstream demo evidence: 74 text files; the mode `tree` reads into it and finds nothing |

An `archive` line of `scripts/upstream-base` names the exact blob and path. A changed zip or a copy at another path is a policy finding.

### A new upstream tag

In the merge of a new upstream tag into `local-dev`:

1. Run `sh scripts/fetch-upstream.sh <tag>`, then set the `tag` line of `scripts/upstream-base` to the new tag and its commit. Until the change is committed, the scan needs the ref `refs/upstream/tags/<tag>` (section "Upstream base").
2. Run `scripts/scan.sh baseline >scripts/upstream-base.new` and replace the file with it. The command keeps the other lines and writes new `hit` lines.
3. Run `scripts/scan.sh --level fail tree`. Look at each new secret or policy finding in the upstream files; add an exact entry with its reason, or report it.

## Modes

```sh
scripts/scan.sh tree                   # tracked files (working tree) and the staged content
scripts/scan.sh staged                 # the staged changes only (pre-commit, pre-merge-commit)
scripts/scan.sh history [<range>]      # commits in <range>, git log syntax; default HEAD without the upstream commits
scripts/scan.sh image <ref> [<base>]   # the file system of a local image
scripts/scan.sh all                    # tree and history (default range)
scripts/scan.sh selftest               # negative control
scripts/scan.sh baseline               # print scripts/upstream-base with new hit lines
```

Exit code: `0` clean, `1` finding, `2` usage or tool error.

Untracked and ignored files (`.env`, `data/`, `.local/`) are not in the scan of `tree`. They cannot go to a remote. The `.gitignore` rules keep them out of the index.

What each mode reads:

| Content | `tree` | `staged` | `history` |
| --- | --- | --- | --- |
| File content | working tree and index | staged changes | each commit |
| Content of an archive | yes, 3 levels deep (`--max-archive-depth 3`) | no | no |
| Target text of a symlink | yes | yes | yes |
| File names | tracked files | staged files | changed files of each commit |
| Commit messages | no | no | yes |
| Policy checks | tracked files | new or changed files of the index | new files of each commit |

`all` is `tree` and `history` with the default range.

A file that Git treats as binary (a NUL byte in the first 8000 bytes, for example a PNG header, or the attribute `-diff`) has no content in `git diff` and `git log -p`, only "Binary files differ". `history` gives gitleaks `--log-opts="--text <range>"`, so the diff shows the content, also of a file that a later commit deletes. gitleaks `--pre-commit --staged` runs its own `git diff --staged` and takes no Git option. Thus `staged` finds these files in `git diff --cached --numstat` (`-` for the line counts) and scans their staged blobs in `dir` mode with the file names. `tree` reads each file.

### Blind spots

- `staged` and `history` do not read into an archive. The policy check stops a tracked archive by its extension or its content in each mode, so it cannot enter unseen through a hook or a CI scan. An archive of a format that is not on the list, with a name that is not on the list, is not found; a binary blob of an unknown format is scanned as text only.
- A secret that is encoded (base64 of a token, split over lines, encrypted) is not found, unless a gitleaks rule matches the encoded form.
- The author and committer names and e-mail addresses, tag messages and notes are not scanned. A private domain in an author e-mail gives no finding.
- A home value that is in no deny list gives no finding. The tracked lists have generic rules only; each host needs its `.local/host-values.deny`.
- `staged` checks the policy of the new and changed files only. A file that a commit with `--no-verify` added is found by `history` (hook `pre-push`) and by `tree`.
- A pin with a blank after the operator (`pkg >= <version>`) of a version that is also a private address gives a false finding. An IPv4 address directly after `:`, `-` or a letter (`host:10.1.2.3`) gives no finding.
- The hooks run only where `scripts/install-hooks.sh` ran, and `--no-verify` skips them (section "Hooks").

### Levels for host values

| Where | Default level |
| --- | --- |
| Branch `portable` | `fail` |
| A tag `portable-v*` at `HEAD` | `fail` |
| Mode `image` | `fail` |
| Other branches | `warn` |

`--level warn` or `--level fail` sets the level. `SCAN_REF=<ref>` sets the ref that gives the default level, for example `SCAN_REF=refs/tags/portable-v0.1.0` in a CI job with a detached `HEAD`.

### Image mode

`scripts/scan.sh image <ref>` scans the whole file system of the image. Docker 28 or later mounts the image read-only (`--mount type=image`) and starts no container of it. An older Docker uses `docker create` and `docker export`.

A whole-image scan can report test keys and example addresses from installed Python packages and base image files.
The upstream exceptions of the repository modes do not apply to an image.
Use `sh scripts/scan.sh image <image>` to check the complete image, including third-party examples.

To scan only the layers that a build adds on top of a base image:

```sh
scripts/scan.sh image <image> <base image>
```

The script compares `RootFS.Layers` of the two images. The base layers must be the first layers of the image, else the script stops. It then reads only the add-on layers from `docker save`.

In this form the scan accepts third-party content. The layer `COPY /app/.venv` is an add-on layer, and the packages in it hold test keys, example addresses and documentation of their own. A finding is dropped when the file comes unchanged from a package that the build installed, and the package is not the project:

| Content | Check |
| --- | --- |
| A file of a Python package | `<site-packages>/<name>-<version>.dist-info/RECORD` lists the file with its SHA-256, the hash matches, and `uv.lock` of the checkout has the package at that version from a `registry`, `git` or `url` source. A package from an `editable`, `directory`, `virtual` or `path` source is the project or a local copy and gets no exception. |
| A `__pycache__/<module>.cpython-*.pyc` file | `RECORD` has no hash for it. It is accepted when `<module>.py` next to `__pycache__` is accepted, or when `<module>.py` is in the base image and in no add-on layer (Python wrote the cache when a build step ran it). |
| A file of a Debian package | `/var/lib/dpkg/info/<package>.md5sums` lists the file and the MD5 matches. Debian packages are not pinned, so this accepts what `apt-get` installed. |

A `uv.lock` that lists no package prevents the venv and pyc exceptions that require a locked package.
Run `sh scripts/scan.sh image <image> <base image>` from the source checkout to check your image.
Exit code 0 means no finding remains after the content checks.

A finding of a rule of `.local/host-values.deny` is never dropped. The check reads only the files that the findings name, `RECORD` and `md5sums` lists; it does not unpack the layers. It reads `uv.lock` of the checkout that holds `scripts/scan.sh`, so scan an image from the commit that built it. The summary line `scan: N finding(s) in third-party packages accepted (venv N, pyc N, dpkg N, base image N)` gives the count by check. Limits: a build step that rewrites a package file and its `RECORD` line passes the check (the same trust as `uv sync --locked`); the whole-image form has no exception.

## Rules for changes

1. Allowlist by content only: `regexes` or `stopwords` in `.gitleaks.toml`. Do not add `paths`. A path allowlist hides each future secret in that path.
2. Keep each allowlist entry narrow. Write the reason in a comment above it.
3. Do not set `targetRules`. `scripts/scan.sh` limits each allowlist to the secret rules, so that no allowlist hides a host value.
4. After each change of `.gitleaks.toml`, `scripts/host-values.deny`, `.local/host-values.deny`, `scripts/host-values.regex`, `scripts/upstream-base` or `scripts/scan.sh`, run `sh tests/test_scan.sh`. `tests/test_scan.sh` uses a copy of the scan with a local deny list of its own, so the local file of the checkout does not change its result. After a change of `.local/host-values.deny`, also run `scripts/scan.sh selftest`. Its negative control puts a synthetic token in a temporary file and requires a finding. The pre-commit hook runs `scripts/scan.sh selftest` when one of the tracked files is staged.
5. A deny pattern is a literal string, case-insensitive. Quotes and backslashes are not allowed. `scripts/scan.sh selftest` requires a finding for each pattern of both deny lists. Do not add a value of a real host to `scripts/host-values.deny`; add it to `.local/host-values.deny`.
6. A regex rule in `scripts/host-values.regex` has a name, a sample and a regular expression (format in the file). `scripts/scan.sh selftest` requires a finding for each sample. The file must not contain an address.
7. Do not write a token or a host value into a tracked file, also not into a test. Build it at run time from parts, as `tests/test_scan.sh` does.
8. Do not use `gitleaks:allow`, `.gitleaksignore` or a baseline to accept a finding. The scan ignores the comment and refuses the files. Correct the content, or add a narrow content allowlist (rules 1 and 2).
9. An allowlist entry for upstream content matches the exact value. Add the family and the count to section "Secret allowlists". Do not allowlist a value that looks like a real credential; report it. A local file gets no allowlist entry, except the exact values of the family "Local test fixture, dummy value, present in history".

A deny list contains the patterns that it forbids. The scan does not report host values in `scripts/host-values.deny` and in `.local/host-values.deny`. This exception is for host-value rules and these two paths only: the secret rules scan the files, and a copy at another path is reported. The mode `tree` reads tracked files only, so it does not read the untracked local file. A tracked file in `.local/` is a policy finding. The mode `image` has no exception.

`.gitleaks.toml` derives from the gitleaks version named in its header with the differences that its header lists: each path allowlist is removed, and the global allowlist entry `(?i)^true|false|null$` is replaced with `^(?i:true|false|null)$`. The default configuration skips `lib/python3.*`, `*.dist-info`, `node_modules` and more by path; with it, an image scan does not read the Python packages. The default entry for `true|false|null` has no group, so it hides each secret that contains `false` or `null`. To update gitleaks, take `config/gitleaks.toml` of the new version, apply the differences again, and change the pinned digest in `scripts/scan.sh`.

## Scanner

The scanner is `gitleaks` in the image pinned by `GITLEAKS_IMAGE` in `scripts/scan.sh`. Each run uses `--network none`, read-only mounts and `--redact`. With the image present, the scan needs no network.

| Variable | Use |
| --- | --- |
| `GITLEAKS_IMAGE` | Another image reference, for example a mirror. Pin it by digest. |
| `SCAN_ENGINE` | `auto` (default: the container, else a `gitleaks` binary matching `GITLEAKS_VERSION` in `scripts/scan.sh`), `docker` or `binary`. |
| `SCAN_NAME_PREFIX` | Name prefix of the helper containers. |
| `SCAN_IMAGE_METHOD` | For `image <image>`: `mount` (default) scans the whole image through a Docker mount. Any other value selects `docker export`. |

A failed mount or the binary engine also uses `docker export`.
`SCAN_IMAGE_METHOD` has no effect on `image <image> <base image>`, which scans saved layers.

To get the image once:

```sh
docker pull "$(sed -n 's/^GITLEAKS_IMAGE=${GITLEAKS_IMAGE:-\(.*\)}$/\1/p' scripts/scan.sh)"
```

On a Mac, the temporary directory (`$TMPDIR`) and the repository must be in a path that Docker shares. Docker Desktop shares `/Users` and `/var/folders` by default. For Colima or another runtime, check the shared paths.

Host needs: a POSIX shell with `od` and `readlink`, and Git 2.5 or later (`git worktree`, `--git-common-dir`; tested with Git 2.39.5). The script does not use `git rev-parse --path-format=absolute` (Git 2.31). A path with a blank, a comma or a colon works for the repository and for `$TMPDIR` (tested); a path with a double quote is not tested.

## Release checks

The [promotion command](branches.md#promotion), `scripts/promote.sh`, requires `.local/host-values.deny` when the repository retains local development history.
The file must be a nonempty regular file with at least one pattern; a comment-only list is not sufficient.
For local release creation, the command runs these checks before any release ref changes:

1. Scan the tracked tree at level `fail`.
   The scan finds secrets, host values and policy findings.
2. Run the public check on the working tree and the exact `local-dev` source object.
   The source-object check also applies when the current checkout differs from `local-dev`.
3. Scan the new portable history range at level `fail`.
   The range excludes the old portable commit; a root snapshot checks only the new commit.

The commit and tag refs change together only after all checks pass.
A failed history scan can leave unreferenced objects, but it changes no release ref.
An existing tag push checks its committed tree and all reachable portable history.
The push needs a plan with `--dry-run` and separate approval; the command does not skip the pre-push hook.

## Hooks

```sh
scripts/install-hooks.sh           # install the dispatcher, set core.hooksPath
scripts/install-hooks.sh --check   # exit 0 if installed and current
scripts/install-hooks.sh --uninstall
```

| Hook | Checks |
| --- | --- |
| `pre-commit` | `scripts/scan.sh staged`. The level follows the current branch. |
| `pre-merge-commit` | The same as `pre-commit`. `git merge` runs this hook, not `pre-commit`, when it records a merge commit without a conflict. |
| `pre-push` | First the guard: a push to a remote other than `origin` and `upstream` (the remote `shared`, another remote, a URL) that sends or deletes a ref other than `refs/heads/portable` or `refs/tags/portable-v*` is refused, with no scan. Then `scripts/scan.sh history` for the commits of each pushed ref, without the upstream commits. The level follows the remote ref. For a new `portable` branch or `portable-v*` tag, the scan covers the commits that the remote does not have, upstream commits included. The first push of a chain scans all of it. |

After a successful scan, `pre-push` runs `sh scripts/public-check.sh --ref <object ID>` for `portable` and the tags `portable-v*`.
It checks the pushed object, not the working tree. Other refs keep the scan-only behavior.
The scan finds secrets and host values; the public check finds word classes, broken document references, stale document values and tree rules.
See [public check](public-check.md#hook) for the pushed-object checks and fail-closed behavior.

The install script copies `scripts/git-hooks/dispatch` to `<git-common-dir>/scan-hooks/`, once for each hook, and sets `core.hooksPath` to that absolute directory. Git stores this in the shared configuration, so it applies to the main checkout and to each worktree. The dispatcher runs `scripts/git-hooks/<hook>` of the working tree where the hook runs. Thus each worktree uses the hooks and `scripts/scan.sh` of its own branch. Each worktree also uses its own `.local/host-values.deny` at the top of the worktree. A worktree without that file scans with the tracked rules only; copy the file into each worktree on the host.

| State of the branch | Result |
| --- | --- |
| The hook and `scripts/scan.sh` are in the working tree | The scan runs. |
| The hook or `scripts/scan.sh` is missing from the working tree, but is in the index or in `HEAD` | The commit, merge or push stops (fail closed). This includes the commit that deletes `scripts/scan.sh`. |
| The branch never had them (for example a branch from before you installed the scan) | No scan. The hook prints `this branch has no scripts/git-hooks/<hook> and no scripts/scan.sh; no scan`. |
| A branch from before `pre-merge-commit` existed | The dispatcher runs its `pre-commit` for a merge. |

The guard of `pre-push` prints one line for each refused ref, then the reason, and exits 1. Git then sends no ref of that push:

```text
pre-push: refused: push of refs/heads/local-dev to 'shared'; this remote takes only refs/heads/portable and refs/tags/portable-v*
pre-push: push refused; local-dev, topic/*, sync/* and upstream tags hold host values (docs/remotes.md)
```

A delete is printed as `delete of <ref>`. A URL in place of a remote name is printed without its credential, or as `<url hidden>`. The guard reads the remote name, the URL and the refs only from the hook arguments and stdin. See [The remote `shared`](remotes.md#the-remote-shared).

A hook fails closed when the required scanner engine or image is unavailable.
A missing public check also refuses a portable push once the command exists in the checkout, index, current commit or pushed tree.

After a change of `scripts/git-hooks/dispatch`, or after the repository moves to another path, run `scripts/install-hooks.sh` again. `--check` reports both cases. If the path in `core.hooksPath` does not exist, Git runs no hook and prints nothing.

Warning: `git commit --no-verify` and `git push --no-verify` skip the hooks.
A CI job must run the scan and the public check independently.

## CI

The [checks workflows](ci.md#workflows) run the scanner and public check independently of installed hooks.
Both require a checkout with full history and refuse a shallow clone.
The development history scan uses the default range, which excludes upstream commits.
The public workflow scans the tracked tree and the whole history of `portable` at level `fail`:

```sh
docker pull "$(sed -n 's/^GITLEAKS_IMAGE=${GITLEAKS_IMAGE:-\(.*\)}$/\1/p' scripts/scan.sh)"
SCAN_REF="$CI_REF" sh scripts/scan.sh --level fail tree
SCAN_REF="$CI_REF" SCAN_EXCLUDE_UPSTREAM=0 sh scripts/scan.sh --level fail history HEAD
sh scripts/public-check.sh
```

A public pull request scans its preview merge history too.
The public scans and public check need no configured secret, provider key or registry login.
The checkout action uses a read-only repository token without persistent credentials.
The optional build job also scans the image layers added above the base image.
See [CI](ci.md) for runner requirements, build conditions and recovery from a failed public check.

Warning: repository code with a Docker socket controls the daemon. Use a disposable runner for pull requests from strangers.

## Test

```sh
sh tests/test_scan.sh
sh tests/test_public_check.sh
```

The scan test uses temporary repositories and a temporary bare remote.
The public check test uses a temporary checkout and checks the pushed-object hook behavior.
Neither test changes the configuration of this repository.
