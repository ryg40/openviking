# Public tree check

Run `sh scripts/public-check.sh` before each promotion and after each document change.
The command needs Git, POSIX `sh` and Python 3 with its standard library.
It uses no network and starts no container.

| Exit code | Meaning |
| --- | --- |
| 0 | No finding. |
| 1 | At least one finding. |
| 2 | Invalid arguments, missing tools, missing inputs or invalid rule data. |

Each finding has a quoted file name, a line number and a rule identifier.
The command never prints the matching source text.
A clean run prints nothing.
Line 1 identifies a whole-file finding.
An input error prints its fixed reason or the invalid rule key on standard error.
An unexpected error prints only its exception class and function name, never its source content.

## Scope and upstream data

The default command reads tracked paths from the index and content from the working tree.
It includes staged additions and unstaged edits of tracked files.
It does not read untracked files.
A missing tracked file gives a finding.
A symlink supplies its target text; the check does not read the target file.

Word and document rules apply to new or changed files against the upstream base.
In a clean checkout, this scope matches the added and modified paths against the upstream tag.
A rename to another path counts as a new file.
Unchanged upstream files are accepted by exact path and Git blob hash.
Tree rules and freshness rules always apply.

The check reads the `tag` line of `scripts/upstream-base`, as [the scanner](secret-handling.md#upstream-content) does.
A fetched upstream ref must point to that commit.
When the commit exists locally, the check reads its tree.
Without that ref, an uncommitted change of `scripts/upstream-base` is an error.

Without the commit, the check uses the generated upstream blob map in `scripts/upstream-blobs.json`.
The map has the same tag and commit as `scripts/upstream-base`.
It holds every upstream file path and its Git blob hash, not its content.
When that tree is available, the normal check compares the map byte-for-byte with the generator output.
The generator sorts paths and uses a stable JSON format.
Each record separates the path from its blob hash to avoid false secret findings.

The scanner's `archive` entries name only accepted archives.
Its `hit` entries name only lines with host-address findings.
Neither list can identify every unchanged upstream file or a later edit in an orphan clone.
The full blob map supplies that missing information without a network request.
It uses the same Git blob hashes, paths and base commit, rather than a second upstream version source.

Review changes to both baseline files.
A person who can change the rules can change the check's trust boundary.
The command is not a security boundary against a malicious repository contributor.

## Rules

The tracked rule file is `scripts/public-rules.json`.
The deliberate deletion list is `scripts/upstream-removed`.
The Python helper is `scripts/public_check.py`.

| Rule class | Source and check |
| --- | --- |
| `private-tracker` | Generic numbered tracker references in locally changed files. |
| `work-record` | A date together with work-record wording on the same line. A date alone is accepted. |
| `development-process` | Generic personal development roles and session wording. Git branch names alone are accepted. |
| `machine-path` | Home directories and deployment directories outside the repository. Standard build-cache paths are accepted. |
| `document-link`, `document-anchor`, `document-reference` | Relative Markdown links, reference definitions, HTML links and images, and Markdown heading or HTML anchors. |
| `document-code-path` | Standalone path spans in the install section of `README.md`, in `EXPLAINER.md` and in root-level Markdown documents under `docs/`. |
| `freshness-default`, `freshness-source` | Variable table cells against source expressions in Compose, the environment template, the bake file, the Dockerfile, scripts and tests. |
| `freshness-scanner`, `freshness-image` | Scanner lookup commands against the source assignment; the three stage image cells against Dockerfile defaults. |
| `pin-copy`, `pin-source`, `pin-consistency` | Current source values stay in their sources or approved lines; required copies must agree. |
| `freshness-steps` | Ordered quick start commands against the numbered steps in `EXPLAINER.md`. |
| `tree-private-state` | No tracked root environment file, local host directory or runtime data directory. |
| `tree-github-path`, `tree-upstream-helper` | Only pinned upstream helpers and the exact workflow allow list below the GitHub directory. |
| `tree-removed-path` | No tracked path matches the deliberate deletion list, except an exact path in the workflow allow list. |
| `tree-license`, `tree-modified-notice` | A nonempty tracked license and the modified-copy notice in `README.md`. |

Real host values belong in the ignored local deny list, never in the tracked rules.
The separate scanner checks secrets, private addresses and those host values.
Run `sh scripts/scan.sh --level fail tree` as well.

The `workflows` array lists exact repository-owned workflow paths.
It contains `.github/workflows/checks.yml`; each other path below `.github/workflows/` is refused.
The `github_scripts` map lists each retained upstream helper's path, Git mode and blob hash.
An empty map is an error.
Each listed helper must be tracked with its exact mode and blob hash.
No other GitHub path is accepted.
The current tree retains ten helpers used by the upstream plugin tests and their helper calls.
The channel generator is deleted because its only caller is a deleted upstream release workflow.

The deletion list has one repository-relative path per line.
The reader strips surrounding whitespace and ignores blank lines and lines that start with `#`.
A trailing slash matches each path below that directory. Other lines match one exact path.
The reader accepts only letters, digits, `_`, `.`, `/` and `-`.
Absolute paths, parent-directory parts and lines that start with `-` give exit code 2.
Globs, inline comments and escapes are not supported; their characters also give exit code 2.
An invalid line reports its fixed cause without printing its content.
A missing list gives exit code 2 because the check cannot establish the deletion policy.
Both checkout and pushed-object checks require the list, including when generating the upstream map.
With `--ref`, the check reads both the deletion list and public rules from that object.

The exact `workflows` allow list overrides a matching deletion rule only for its listed paths.
The `tree-github-path` rule reports GitHub paths outside the helper and workflow allow lists.
The `tree-removed-path` rule reports deliberate deletion paths, including paths outside the GitHub directory.
A forbidden GitHub path can report both rules; neither finding hides the other.

The [update command](update.md) deletes a listed path again when it returns in the incoming upstream tree after a sync.
Add a line to the list when a new upstream path must not remain in this copy.

A code span is a path only when it stands alone and has path or file-name syntax.
Commands, URLs, image references, absolute container paths and variable expressions are not repository paths.
A bare script name can resolve under `scripts/`; another bare name must have one tracked suffix match.
The `path_placeholders` array lists generated files, ref syntax and neutral examples, each with a reason.
A historical reference to a deleted file needs an exact content exception or an explicit upstream URL.

Freshness rules compare table defaults, not every explanatory sentence.
Computed defaults have source-expression checks and exact document descriptions.
A changed expression that the parser cannot recognize fails closed.
The quick start comparison requires the documented tag-line lookup. A literal upstream tag is not accepted.
It also accepts the optional source-label assignment on the build command.
The scanner check validates the read-only `sed` expression in README and EXPLAINER against the scanner assignment.
It does not execute document commands. A changed expression or incompatible source format fails.
The build argument table uses source pointers; only the three stage cells state the base image names.
Only the separate key-generation command is excluded from the comparison.
The scanner-download command must occur in both command lists at the same position.

## Single-source pins

The `pins` object in `scripts/public-rules.json` defines source extractors and permitted lines with reasons.
The check reads each current value at run time; it does not match arbitrary dependency versions.
It checks the upstream tag, version and commit, image names and digests, scanner reference and version, and uv version and hashes.
Digest checks also find the hexadecimal value without its algorithm prefix.

Allowed copies are limited to source annotations, matching bake defaults, three format examples, three stage cells and scanner provenance.
Format examples and provenance use exact line hashes as well as line patterns.
Changing such a line requires a fresh review; adding another value to it does not inherit permission.
Stage cells permit image names only, never digests.
The scanner binary-version declaration must equal the version in its image reference.
The generated upstream map is derived data, checked separately against the generator.
No test file receives a whole-file exception.

After a tag, digest or scanner pin change, change nothing in the documents.
Run `sh scripts/public-check.sh` and `sh tests/test_public_check.sh`.
Regenerate the upstream map when the upstream base changes, as described below.
If a base image name changes, update its one stage cell; the build argument table remains a source pointer.

## Content exceptions

Exceptions accept one exact line for one rule, wherever that same line occurs.
They never accept a whole file.
Each `exceptions` entry has `rule`, `line_blob` and a nonempty `reason`.
The hash includes the final newline, as the scanner's `hit` hashes do.
The retained upstream session comments and extension README reference use exact-line exceptions for `private-tracker`.
A changed line or an adjacent tracker reference still fails.

1. Read the finding and confirm that the content is a neutral example or a required technical reference.
   A real private value needs removal, not an exception.
2. Compute the Git blob hash of that one line, including its newline.
   Use `git hash-object --stdin` with only that line as input.
3. Add the hash, the rule identifier and the reason to `exceptions` in the rule file.
   Do not put the matched private text in the rule file.
4. Run `sh tests/test_public_check.sh` and `sh scripts/public-check.sh`.
   A changed line or an adjacent bad line must still give a finding.
5. Run the scanner and its tests after a rule or hook change.
   See [testing](testing.md) for the existing scanner checks.

## Upstream refresh

1. Fetch the intended upstream tag with `scripts/fetch-upstream.sh`.
   Review the tag and commit before changing either baseline.
2. Update `scripts/upstream-base` and its scanner baseline as [secret handling](secret-handling.md#a-new-upstream-tag) describes.
   Keep its format unchanged.
3. Run `sh scripts/public-check.sh --write-upstream-map`.
   It writes `scripts/upstream-blobs.json` from the base commit; an absent local commit gives exit code 2.
4. Run `sh scripts/public-check.sh` with the upstream commit available.
   The map must equal the deterministic generator output, including its format.
5. Run `sh tests/test_public_check.sh` and `sh tests/test_scan.sh`.
   Review each new finding; do not add a broad path exception.

## Hook

After a successful history scan, `scripts/git-hooks/pre-push` checks each pushed portable branch or portable release tag.
It passes the pushed object ID with `--ref`, so another checkout cannot hide the pushed tree's findings.
The object can be a commit or an annotated tag object.
The helper reads its tracked blobs without a checkout.
It does not execute scripts from that object.

A missing command fails closed when the index, current commit or pushed object contains it.
With the command installed, an older snapshot without `scripts/public-rules.json` is refused.
The public command exits 2 and reports that the pushed tree has no rule file.
A snapshot without `scripts/upstream-removed` also gives exit code 2; it cannot supply the required deletion policy.
The hook converts any failed public check to exit 1 and refuses the push.
Scan-only behavior applies only when the command is absent from the checkout, index, current commit and pushed tree.
A delete sends no commit and needs no public check.
Other branches keep their existing scan behavior.

Warning: Git's no-verify option skips the hook. CI must run both checks independently.

## Limits

A pattern finds word classes, not meaning.
Review documents as a stranger before each release that changes them.
No generic rule can identify every private provider choice, account name or implicit work record.

The document parser supports the repository's Markdown forms, not the complete CommonMark specification.
It skips fenced examples and does not fetch external links.
It resolves paths against tracked files, not ignored runtime files.

The default command checks working-tree content, not a different staged copy of that content.
The push hook checks committed content through `--ref`.
The scanner separately checks staged content and history.

Not verified: these checks on a Mac.
