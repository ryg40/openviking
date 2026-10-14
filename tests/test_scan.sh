#!/bin/sh
# Offline test for scripts/scan.sh, scripts/git-hooks and scripts/install-hooks.sh.
# All repositories are temporary. The scanner image must be present
# (docker pull, see docs/secret-handling.md); no network is used.
#
# Usage: sh tests/test_scan.sh
#
# The synthetic token and the host values are built at run time from parts,
# so no tracked file contains them.

set -eu

repo_root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)

work=$(mktemp -d "${TMPDIR:-/tmp}/test-scan.XXXXXX")
work=$(CDPATH='' cd -- "$work" && pwd -P)
trap 'rm -rf "$work"' EXIT
# In sh, an INT or TERM handler does not end the script; exit runs the EXIT trap.
trap 'exit 130' INT TERM

# Name the helper containers like the other test containers of this repository.
SCAN_NAME_PREFIX=${SCAN_NAME_PREFIX:-openviking-test-scan-}
export SCAN_NAME_PREFIX
# Isolate Git from the global and system configuration (and its hooks).
: >"$work/gitconfig"
GIT_CONFIG_GLOBAL=$work/gitconfig GIT_CONFIG_NOSYSTEM=1
GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@example.invalid
GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@example.invalid
export GIT_CONFIG_GLOBAL GIT_CONFIG_NOSYSTEM GIT_AUTHOR_NAME GIT_AUTHOR_EMAIL \
    GIT_COMMITTER_NAME GIT_COMMITTER_EMAIL
unset SCAN_REF GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE 2>/dev/null || true

failures=0
pass() { echo "ok   - $1"; }
fail() { echo "FAIL - $1"; failures=$((failures + 1)); }
# expect_status <name> <status> <command...>: output goes to $work/out.
expect_status() {
    name=$1; want=$2; shift 2
    got=0; "$@" >"$work/out" 2>&1 || got=$?
    if [ "$got" -eq "$want" ]; then pass "$name"; else fail "$name (exit $got, expected $want)"; sed 's/^/     /' "$work/out"; fi
}
expect_out() {
    name=$1; text=$2
    if grep -qF -- "$text" "$work/out"; then pass "$name"; else fail "$name (no '$text')"; sed 's/^/     /' "$work/out"; fi
}
expect_no_out() {
    name=$1; text=$2
    if grep -qF -- "$text" "$work/out"; then fail "$name"; else pass "$name"; fi
}

# Synthetic values, built from parts.
token=$(printf '%s%s%s%s' ghp _ Zx9QwEr7TyUi3OpA s5DfGh1JkLz2XcVbNm4Q)
host_ip=$(printf '%s.%s.%s' 192 168 7.42)
host_path=$(printf '/var/lib/%s' example-state)
host_name=$(printf '%s-%s' example home)
allow=$(printf 'gitleaks:%s' allow)
ip10=$(printf '%s.%s' 10 20.30.40)

# A copy of the scan, so that the untracked .local/host-values.deny of this
# checkout does not change the results. The tests write the local deny list
# of the copy ($local_deny) when they need one.
tool=$work/tool
mkdir -p "$tool/scripts"
cp "$repo_root/.gitleaks.toml" "$tool/"
cp "$repo_root/scripts/scan.sh" "$repo_root/scripts/host-values.deny" "$repo_root/scripts/host-values.regex" \
    "$tool/scripts/"
scan=$tool/scripts/scan.sh
# The upstream base of the copy: a commit that no test repository has, and no
# hit line. The section "upstream content" writes its own.
{ grep '^#' "$repo_root/scripts/upstream-base"; printf 'tag\tv0.0.0\t%040d\n' 0; } >"$tool/scripts/upstream-base"
local_deny=$tool/.local/host-values.deny
# write_local_deny <pattern>...: the local deny list of the copy.
write_local_deny() {
    mkdir -p "$tool/.local"
    { printf '# local deny list of the test\n'; printf '%s\n' "$@"; } >"$local_deny"
}
write_local_deny "$host_path" "$host_name"

g() { git -c init.defaultBranch=main "$@"; }
new_repo() {
    rm -rf "$1"; mkdir -p "$1"
    g -C "$1" init -q
    printf 'hello\n' >"$1/README"
    g -C "$1" add README
    g -C "$1" commit -q -m init
}
in_repo() { dir=$1; shift; (cd "$dir" && "$@"); }

echo "# negative control"
expect_status "selftest mode finds the synthetic token and a host value" 0 sh "$scan" selftest
mkdir "$work/nc"
printf 'api = "%s"\n' "$token" >"$work/nc/token.txt"
new_repo "$work/nc-repo"
cp "$work/nc/token.txt" "$work/nc-repo/token.txt"
g -C "$work/nc-repo" add token.txt
expect_status "a synthetic token in a temporary file gives a finding" 1 in_repo "$work/nc-repo" sh "$scan" tree
expect_out "the finding names the file, the line and the rule" "token.txt:1  rule github-pat"
expect_no_out "the output does not contain the token" "$token"

echo "# fixture allowlist (Bearer)"
# The exact dummy value of the Pi extension fixture is accepted; a Bearer
# token of real shape in the same command is not.
bearer=$(printf '%s%s%s' Qm7vT2xK9pLw 4RzN8cYd1HsB 6fJeU3gA0oVi)
new_repo "$work/bearer"
printf "command: \"curl -H 'Authorization: Bearer %s' https://example.invalid\",\n" bearer-value >"$work/bearer/fixture.mjs"
g -C "$work/bearer" add fixture.mjs
expect_status "Bearer fixture value bearer-value: accepted" 0 in_repo "$work/bearer" sh "$scan" tree
printf "command: \"curl -H 'Authorization: Bearer %s' https://example.invalid\",\n" "$bearer" >"$work/bearer/fixture.mjs"
g -C "$work/bearer" add fixture.mjs
expect_status "Bearer token of real shape: finding" 1 in_repo "$work/bearer" sh "$scan" tree
expect_out "the Bearer finding names the rule" "fixture.mjs:1  rule curl-auth-header"
expect_no_out "the output does not contain the Bearer token" "$bearer"

echo "# authentication placeholder allowlist"
new_repo "$work/root-placeholder"
root_placeholder=$(printf '%s%s' your-secret-root-key -here)
root_value=$(printf '%s%s%s' Qm7vT2xK9pLw 4RzN8cYd1HsB 6fJeU3gA0oVi)
printf 'curl -H "X-API-Key: %s" https://example.invalid\n' "$root_placeholder" >"$work/root-placeholder/auth.md"
g -C "$work/root-placeholder" add auth.md
expect_status "exact authentication placeholder: accepted" 0 in_repo "$work/root-placeholder" sh "$scan" tree
printf 'curl -H "X-API-Key: %s" https://example.invalid\n' "$root_value" >"$work/root-placeholder/auth.md"
g -C "$work/root-placeholder" add auth.md
expect_status "changed authentication value: finding" 1 in_repo "$work/root-placeholder" sh "$scan" tree
expect_out "changed authentication value names the rule" "auth.md:1  rule curl-auth-header"
expect_no_out "changed authentication value stays redacted" "$root_value"
for root_value in "prefix-$root_placeholder" "$root_placeholder-suffix"; do
    printf 'curl -H "X-API-Key: %s" https://example.invalid\n' "$root_value" >"$work/root-placeholder/auth.md"
    g -C "$work/root-placeholder" add auth.md
    expect_status "authentication placeholder with extra text: finding" 1 in_repo "$work/root-placeholder" sh "$scan" tree
done

echo "# tree mode"
new_repo "$work/clean"
expect_status "clean tree: exit 0" 0 in_repo "$work/clean" sh "$scan" tree
expect_out "clean tree: summary line" "scan: 0 secret finding(s), 0 host-value finding(s)"

new_repo "$work/wt"
printf 'x = "%s"\n' "$token" >"$work/wt/README"
expect_status "unstaged change of a tracked file: finding" 1 in_repo "$work/wt" sh "$scan" tree
printf 'x = "%s"\n' "$token" >"$work/wt/untracked.txt"
g -C "$work/wt" checkout -q README
expect_status "untracked file: not scanned" 0 in_repo "$work/wt" sh "$scan" tree
g -C "$work/wt" add untracked.txt
expect_status "staged new file: finding" 1 in_repo "$work/wt" sh "$scan" tree
expect_status "staged mode: finding" 1 in_repo "$work/wt" sh "$scan" staged
expect_out "staged mode names the file" "untracked.txt:1"

echo "# host values"
new_repo "$work/host"
mkdir -p "$work/host/config"
printf 'api_base: http://%s:8080\n' "$host_ip" >"$work/host/config/a.yaml"
printf 'state: %s/x\n' "$host_path" >"$work/host/config/b.yaml"
g -C "$work/host" add config
expect_status "host value, --level warn: exit 0" 0 in_repo "$work/host" sh "$scan" --level warn tree
expect_out "host value, warn: printed" "warn  host value  config/a.yaml:1  rule host-value-private-192"
expect_out "host value, warn: local pattern printed" "config/b.yaml:1  rule host-value-local-1"
expect_status "host value, --level fail: exit 1" 1 in_repo "$work/host" sh "$scan" --level fail tree
expect_out "host value, fail: printed" "FAIL  host value  config/a.yaml:1"
expect_status "host value, default level on branch main is warn" 0 in_repo "$work/host" sh "$scan" tree
g -C "$work/host" checkout -q -b portable
expect_status "host value, default level on branch portable is fail" 1 in_repo "$work/host" sh "$scan" tree
g -C "$work/host" commit -q -m host
g -C "$work/host" checkout -q -b other
g -C "$work/host" tag portable-v1
expect_status "host value, default level with a tag portable-v* at HEAD is fail" 1 in_repo "$work/host" sh "$scan" tree
expect_status "host value, SCAN_REF=refs/heads/x sets warn" 0 in_repo "$work/host" env SCAN_REF=refs/heads/x sh "$scan" tree

echo "# deny list files"
new_repo "$work/deny"
mkdir -p "$work/deny/scripts" "$work/deny/other"
# A deny list with the patterns of the local list and an address.
{ cat "$repo_root/scripts/host-values.deny"; printf '%s\n' "$host_path" "$host_name" "$host_ip"; } \
    >"$work/deny/scripts/host-values.deny"
g -C "$work/deny" add scripts
expect_status "the tracked deny list itself is not reported" 0 in_repo "$work/deny" sh "$scan" --level fail tree
cp "$work/deny/scripts/host-values.deny" "$work/deny/other/host-values.deny"
cp "$work/deny/scripts/host-values.deny" "$work/deny/scripts/host-values.deny.bak"
g -C "$work/deny" add other scripts
expect_status "a copy of the deny list at another path is reported" 1 in_repo "$work/deny" sh "$scan" --level fail tree
expect_out "copy in other/ is reported" "other/host-values.deny:"
expect_out "copy with another name is reported" "scripts/host-values.deny.bak:"
g -C "$work/deny" rm -q --cached other/host-values.deny scripts/host-values.deny.bak
printf 'key = "%s"\n' "$token" >>"$work/deny/scripts/host-values.deny"
g -C "$work/deny" add scripts/host-values.deny
expect_status "a secret in the deny list is reported" 1 in_repo "$work/deny" sh "$scan" --level fail tree
expect_out "secret in the deny list: rule" "scripts/host-values.deny:"
g -C "$work/deny" rm -q --cached scripts/host-values.deny

echo "# local deny list"
new_repo "$work/local"
mkdir -p "$work/local/.local"
cp "$local_deny" "$work/local/.local/host-values.deny"
printf 'name: %s\n' "$host_name" >"$work/local/.local/notes.txt"
printf 'host: %s\n' "$host_name" >"$work/local/a.txt"
g -C "$work/local" add a.txt
expect_status "a pattern of the local deny list gives a finding" 1 in_repo "$work/local" sh "$scan" --level fail tree
expect_out "local pattern: rule" "FAIL  host value  a.txt:1  rule host-value-local-2"
expect_no_out "the untracked local deny list is not reported" ".local/host-values.deny"
expect_no_out "an untracked file in .local/ is not scanned" ".local/notes.txt"
expect_status "local pattern, staged: finding" 1 in_repo "$work/local" sh "$scan" --level fail staged
expect_out "local pattern, staged: rule" "a.txt:1  rule host-value-local-2"
g -C "$work/local" rm -q --cached a.txt
expect_status "the local deny list in a local-dev style checkout: clean" 0 in_repo "$work/local" sh "$scan" --level fail tree
g -C "$work/local" add -f .local/host-values.deny
expect_status "a tracked local deny list: policy finding" 1 in_repo "$work/local" sh "$scan" --level fail tree
expect_out "tracked local deny list: policy rule" "FAIL  policy  .local/host-values.deny  rule policy-local-file"
expect_no_out "tracked local deny list: no host-value finding in it" "host value  .local/host-values.deny"
expect_status "a tracked local deny list, staged: policy finding" 1 in_repo "$work/local" sh "$scan" staged
expect_out "tracked local deny list, staged: policy rule" "FAIL  policy  .local/host-values.deny  rule policy-local-file"
g -C "$work/local" rm -q --cached .local/host-values.deny
mv "$local_deny" "$work/local-deny.saved"
printf 'host: %s\n' "$host_name" >"$work/local/a.txt"
printf 'api_base: http://%s:8080\n' "$ip10" >"$work/local/b.txt"
g -C "$work/local" add a.txt b.txt
expect_status "no local deny list: the scan runs" 1 in_repo "$work/local" sh "$scan" --level fail tree
expect_no_out "no local deny list: no local rule" "host-value-local-"
expect_out "no local deny list: the regex list works alone" "b.txt:1  rule host-value-private-10"
expect_status "no local deny list: selftest" 0 sh "$scan" selftest
# A tracked deny list with no pattern and a regex list with no rule: no rule at all.
cp "$tool/scripts/host-values.regex" "$work/regex.saved"
grep '^#' "$work/regex.saved" >"$tool/scripts/host-values.regex"
expect_status "no host-value rule at all: usage error" 2 sh "$scan" selftest
expect_out "no host-value rule: message" "no host-value rule in"
write_local_deny "$host_name"
expect_status "only a local pattern and no regex rule: selftest" 0 sh "$scan" selftest
cp "$work/regex.saved" "$tool/scripts/host-values.regex"
mv "$work/local-deny.saved" "$local_deny"
printf 'bad"pattern\n' >>"$local_deny"
expect_status "a quote in the local deny list: usage error" 2 sh "$scan" selftest
expect_out "a quote in the local deny list: message" ".local/host-values.deny: a pattern contains a quote"
write_local_deny "$host_path" "$host_name"

echo "# history mode"
new_repo "$work/hist"
printf 'x = "%s"\n' "$token" >"$work/hist/old.txt"
g -C "$work/hist" add old.txt
g -C "$work/hist" commit -q -m "add token"
old_commit=$(g -C "$work/hist" rev-parse --short=12 HEAD)
g -C "$work/hist" rm -q old.txt
g -C "$work/hist" commit -q -m "remove token"
expect_status "history: tree is clean now" 0 in_repo "$work/hist" sh "$scan" tree
expect_status "history: token in an old commit gives a finding" 1 in_repo "$work/hist" sh "$scan" history
expect_out "history: the finding names the commit" "old.txt:1  rule github-pat  commit $old_commit"
expect_no_out "history: the output does not contain the token" "$token"
expect_status "history: a range without the commit is clean" 0 in_repo "$work/hist" sh "$scan" history HEAD~1..HEAD
expect_status "all: finds the old commit" 1 in_repo "$work/hist" sh "$scan" all

echo "# files that Git treats as binary"
# git diff and git log -p print "Binary files differ" for a file with a NUL
# byte; staged and history must still read its content.
new_repo "$work/bin"
printf 'x = "%s"\n\000\n' "$token" >"$work/bin/nul.dat"
printf '\211PNG\r\n\032\n\000\000\000\015IHDR\n' >"$work/bin/logo.png"
printf 'x = "%s"\n' "$token" >>"$work/bin/logo.png"
g -C "$work/bin" add nul.dat logo.png
expect_status "binary: Git sees the two files as binary" 0 \
    test "$(g -C "$work/bin" diff --cached --numstat | grep -c '^-	-	')" -eq 2
expect_status "binary, staged: finding" 1 in_repo "$work/bin" sh "$scan" staged
expect_out "binary, staged: the file with a NUL byte" "nul.dat:1  rule github-pat"
expect_out "binary, staged: the file with a PNG header" "logo.png:4  rule github-pat"
expect_no_out "binary, staged: the output does not contain the token" "$token"
g -C "$work/bin" commit -q -m "add binary files"
bin_commit=$(g -C "$work/bin" rev-parse --short=12 HEAD)
g -C "$work/bin" rm -q nul.dat logo.png
g -C "$work/bin" commit -q -m "remove binary files"
expect_status "binary, history after deletion: finding" 1 in_repo "$work/bin" sh "$scan" history
expect_out "binary, history: the file with a NUL byte" "nul.dat:1  rule github-pat  commit $bin_commit"
expect_out "binary, history: the file with a PNG header" "logo.png:4  rule github-pat  commit $bin_commit"
expect_no_out "binary, history: the output does not contain the token" "$token"

echo "# content does not switch the scan off"
new_repo "$work/allow"
printf 'x = "%s" # %s\napi_base: http://%s:8080 # %s\n' "$token" "$allow" "$host_ip" "$allow" >"$work/allow/a.txt"
g -C "$work/allow" add a.txt
expect_status "gitleaks:allow, tree: finding" 1 in_repo "$work/allow" sh "$scan" --level fail tree
expect_out "gitleaks:allow does not hide a secret" "a.txt:1  rule github-pat"
expect_out "gitleaks:allow does not hide a host value" "a.txt:2  rule host-value-private-192"
expect_status "gitleaks:allow, staged: finding" 1 in_repo "$work/allow" sh "$scan" staged
expect_out "gitleaks:allow, staged: the secret" "a.txt:1  rule github-pat"
g -C "$work/allow" commit -q -m allow
allow_commit=$(g -C "$work/allow" rev-parse HEAD)
# A tracked .gitleaksignore with the fingerprint of the finding.
printf '%s:a.txt:github-pat:1\n' "$allow_commit" >"$work/allow/.gitleaksignore"
mkdir -p "$work/allow/sub"
printf '{}\n' >"$work/allow/sub/.gitleaksbaseline"
g -C "$work/allow" add .gitleaksignore sub
g -C "$work/allow" commit -q -m ignore
expect_status ".gitleaksignore, history: finding" 1 in_repo "$work/allow" sh "$scan" history
expect_out ".gitleaksignore, history: the secret is still found" "a.txt:1  rule github-pat  commit $(printf '%.12s' "$allow_commit")"
expect_out ".gitleaksignore, history: policy finding" "FAIL  policy  .gitleaksignore  rule policy-ignore-file"
expect_out ".gitleaksbaseline, history: policy finding" "sub/.gitleaksbaseline  rule policy-ignore-file"
expect_status ".gitleaksignore, tree: finding" 1 in_repo "$work/allow" sh "$scan" tree
expect_out ".gitleaksignore, tree: policy finding" "FAIL  policy  .gitleaksignore  rule policy-ignore-file"
expect_out ".gitleaksbaseline, tree: policy finding" "FAIL  policy  sub/.gitleaksbaseline  rule policy-ignore-file"
new_repo "$work/ign"
printf 'x = "%s"\n' "$token" >"$work/ign/a.txt"
printf 'a.txt:github-pat:1\n' >"$work/ign/.gitleaksignore"
mkdir -p "$work/ign/sub"
printf '{}\n' >"$work/ign/sub/.gitleaksbaseline"
g -C "$work/ign" add a.txt sub
expect_status "untracked .gitleaksignore, staged .gitleaksbaseline, staged: finding" 1 in_repo "$work/ign" sh "$scan" staged
expect_out "untracked .gitleaksignore does not hide a staged secret" "a.txt:1  rule github-pat"
expect_out ".gitleaksbaseline, staged: policy finding" "FAIL  policy  sub/.gitleaksbaseline  rule policy-ignore-file"
g -C "$work/ign" add .gitleaksignore
expect_status "staged .gitleaksignore, staged: finding" 1 in_repo "$work/ign" sh "$scan" staged
expect_out ".gitleaksignore, staged: policy finding" "FAIL  policy  .gitleaksignore  rule policy-ignore-file"
g -C "$work/ign" commit -q -m baseline
expect_status ".gitleaksbaseline in a commit, all: finding" 1 in_repo "$work/ign" sh "$scan" all
expect_out ".gitleaksbaseline, all: policy finding with the commit" "sub/.gitleaksbaseline  rule policy-ignore-file (gitleaks ignore or baseline file)  commit"

echo "# archives, dumps, bundles, messages, names, symlinks"
new_repo "$work/arc"
mkdir -p "$work/arc-src"
printf 'x = "%s"\n' "$token" >"$work/arc-src/t.txt"
gzip -c "$work/arc-src/t.txt" >"$work/arc/t.txt.gz"
(cd "$work/arc-src" && python3 -m zipfile -c "$work/arc/t.zip" t.txt && tar -cf "$work/arc/t.tar" t.txt)
# Content only: a gzip file with another name, a Git bundle, a pg_dump text dump.
cp "$work/arc/t.txt.gz" "$work/arc/data.bin"
g -C "$work/arc" bundle create -q "$work/arc/repo.txt" HEAD 2>/dev/null
printf -- '--\n-- %s database dump\n--\n' PostgreSQL >"$work/arc/notes.txt"
ln -s "$token" "$work/arc/link"
printf 'ok\n' >"$work/arc/$token.txt"
g -C "$work/arc" add .
expect_status "archives and more, tree: finding" 1 in_repo "$work/arc" sh "$scan" tree
for f in t.txt.gz t.zip t.tar data.bin repo.txt notes.txt; do
    expect_out "tree: policy finding for $f" "FAIL  policy  $f  rule policy-archive"
done
expect_out "tree: token inside the gzip file" "t.txt.gz:1  rule github-pat"
expect_out "tree: token inside the zip file" "t.zip!t.txt:1  rule github-pat"
expect_out "tree: token inside the tar file" "t.tar!t.txt:1  rule github-pat"
expect_out "tree: symlink target text" "FAIL  secret  link:1  rule github-pat"
expect_out "tree: file name" "FAIL  secret  (file names):"
expect_no_out "tree: the output does not contain the token" "$token"
expect_status "archives and more, staged: finding" 1 in_repo "$work/arc" sh "$scan" staged
expect_out "staged: policy finding for a zip file" "FAIL  policy  t.zip  rule policy-archive"
expect_out "staged: policy finding for a bundle by content" "FAIL  policy  repo.txt  rule policy-archive"
expect_out "staged: file name" "FAIL  secret  (file names):"
g -C "$work/arc" commit -q -m archives
arc_commit=$(g -C "$work/arc" rev-parse --short=12 HEAD)
expect_status "archives and more, history: finding" 1 in_repo "$work/arc" sh "$scan" history
expect_out "history: policy finding for a tar file" "FAIL  policy  t.tar  rule policy-archive (archive, database dump or Git bundle)  commit $arc_commit"
expect_out "history: policy finding for a dump by content" "FAIL  policy  notes.txt  rule policy-archive"
expect_out "history: file name" "FAIL  secret  (file names):"
expect_out "history: symlink target text" "FAIL  secret  link:1  rule github-pat  commit $arc_commit"
new_repo "$work/msg"
printf 'x\n' >"$work/msg/x.txt"
g -C "$work/msg" add x.txt
g -C "$work/msg" commit -q -m "add x" -m "key $token" -m "host $host_ip"
msg_commit=$(g -C "$work/msg" rev-parse --short=12 HEAD)
expect_status "commit message: tree is clean" 0 in_repo "$work/msg" sh "$scan" tree
expect_status "commit message, history: finding" 1 in_repo "$work/msg" sh "$scan" history
expect_out "history: token in the commit message" "FAIL  secret  (commit message):3  rule github-pat  commit $msg_commit"
expect_out "history: host value in the commit message" "(commit message):5  rule host-value-private-192"
expect_no_out "history: the output does not contain the token" "$token"
expect_status "commit message, all: finding" 1 in_repo "$work/msg" sh "$scan" all
expect_out "all: token in the commit message" "(commit message):3  rule github-pat  commit $msg_commit"

echo "# the true|false|null allowlist is anchored"
new_repo "$work/anchor"
printf 'password = "%s%s"\ntoken = "%s%s%s"\n' false Passw0rdX9kQ ghp_ falseZx9QwEr7TyUi3O pAs5DfGh1JkLz2XcV >"$work/anchor/a.txt"
g -C "$work/anchor" add a.txt
expect_status "a secret that contains false: finding" 1 in_repo "$work/anchor" sh "$scan" tree
expect_out "password with false: finding" "a.txt:1  rule generic-api-key"
expect_out "token with false: finding" "a.txt:2  rule github-pat"

echo "# a path with a blank, a comma and a colon"
odd="$work/odd dir,x:y"
new_repo "$odd/repo"
printf 'x = "%s"\n' "$token" >"$odd/repo/leak.txt"
g -C "$odd/repo" add leak.txt
expect_status "odd path, staged: finding" 1 in_repo "$odd/repo" sh "$scan" staged
expect_out "odd path, staged: the file" "leak.txt:1  rule github-pat"
g -C "$odd/repo" commit -q -m leak
expect_status "odd path, history: finding" 1 in_repo "$odd/repo" sh "$scan" history
expect_out "odd path, history: the file" "leak.txt:1  rule github-pat"
g -C "$odd/repo" worktree add -q "$odd/wt" -b wt 2>/dev/null
expect_status "odd path, history in a worktree: finding" 1 in_repo "$odd/wt" sh "$scan" history
expect_status "odd path, TMPDIR with a blank: tree finding" 1 in_repo "$odd/repo" env TMPDIR="$odd" sh "$scan" tree

echo "# private address ranges"
new_repo "$work/ranges"
{
    printf 'a = http://%s:80/\n' "$ip10"
    printf 'b = %s.%s\n' 172 20.1.2
    printf 'c = %s.%s\n' 192 168.1.2
    printf 'd = %s.%s\n' 100 100.1.2
    printf 'e = [%s::1]\n' fd12:3456
    printf 'f = host=%s.%s\n' 10 1.2.3
} >"$work/ranges/hosts.txt"
v=$(printf '%s.%s' 10 2.3.4)
{
    printf 'pkg==%s\npkg>=%s\nimage: repo:%s\nv%s\n%s.dev0\npkg-%s.tar\n' "$v" "$v" "$v" "$v" "$v" "$v"
    printf '%s.0.0.1 %s.0.2.1 %s.51.100.1 %s.0.113.1 %s:db8::1\n' 127 192 198 203 2001
    printf '%s.%s %s.%s %s.%s %s.%s\n' 172 15.1.1 172 32.1.1 100 63.1.1 100 128.1.1
} >"$work/ranges/clean.txt"
g -C "$work/ranges" add .
expect_status "private ranges, --level fail: finding" 1 in_repo "$work/ranges" sh "$scan" --level fail tree
expect_out "10/8" "hosts.txt:1  rule host-value-private-10"
expect_out "172.16/12" "hosts.txt:2  rule host-value-private-172"
expect_out "192.168/16" "hosts.txt:3  rule host-value-private-192"
expect_out "100.64/10" "hosts.txt:4  rule host-value-shared-100"
expect_out "IPv6 unique local" "hosts.txt:5  rule host-value-private-ula"
expect_out "10/8 after =" "hosts.txt:6  rule host-value-private-10"
expect_no_out "no finding for a version pin, loopback, documentation and public addresses" "clean.txt"

echo "# upstream content"
# A repository with two upstream commits (the first adds a token, the second
# removes it), the upstream tag refs/upstream/tags/v1.0.0, and one local commit
# that adds the scan with its own scripts/upstream-base.
up=$work/up
new_repo "$up"
mkdir -p "$up/docs" "$up/tests"
printf 'server: http://%s:8080/\n' "$ip10" >"$up/docs/up.md"
printf 'name: %s\n' "$host_name" >"$up/tests/home.md"
printf 'x = "%s"\n' "$token" >"$up/old-token.txt"
gzip -c "$up/README" >"$up/docs/demo.gz"
g -C "$up" add .
g -C "$up" commit -q -m "upstream 1"
up_first=$(g -C "$up" rev-parse HEAD)
g -C "$up" rm -q old-token.txt
g -C "$up" commit -q -m "upstream 2"
up_commit=$(g -C "$up" rev-parse HEAD)
g -C "$up" update-ref refs/upstream/tags/v1.0.0 "$up_commit"
mkdir -p "$up/scripts/git-hooks"
cp "$repo_root/.gitleaks.toml" "$up/"
cp "$repo_root/scripts/scan.sh" "$repo_root/scripts/host-values.deny" "$repo_root/scripts/host-values.regex" \
    "$repo_root/scripts/install-hooks.sh" "$up/scripts/"
cp "$repo_root/scripts/git-hooks/"* "$up/scripts/git-hooks/"
{
    grep '^#' "$repo_root/scripts/upstream-base"
    printf 'tag\tv1.0.0\t%s\n' "$up_commit"
    printf 'archive\t%s\tdocs/demo.gz\n' "$(g -C "$up" rev-parse HEAD:docs/demo.gz)"
} >"$up/scripts/upstream-base"
g -C "$up" add .gitleaks.toml scripts
g -C "$up" commit -q -m "local: add the scan"
mkdir -p "$up/.local"
cp "$local_deny" "$up/.local/host-values.deny"
printf '.local/\n' >>"$up/.git/info/exclude"
us=$up/scripts/scan.sh

expect_status "upstream: a home pattern in an upstream file fails" 1 in_repo "$up" sh "$us" --level fail tree
expect_out "upstream: the home pattern is reported" "FAIL  host value  tests/home.md:1  rule host-value-local-2"
expect_no_out "upstream: the private address of the upstream file is accepted" "docs/up.md"
expect_no_out "upstream: the archive of the exact entry is accepted" "docs/demo.gz"
expect_out "upstream: the accepted findings are counted" "2 finding(s) in upstream content accepted (v1.0.0, base commit)"
mv "$up/.local/host-values.deny" "$work/up-deny.saved"
expect_status "upstream: without the local deny list the upstream files pass at level fail" 0 \
    in_repo "$up" sh "$us" --level fail tree
printf 'server: http://%s:8080/\n' "$ip10" >"$up/local.md"
g -C "$up" add local.md
expect_status "upstream: the same address in a local file fails" 1 in_repo "$up" sh "$us" --level fail tree
expect_out "upstream: the local file is reported" "FAIL  host value  local.md:1  rule host-value-private-10"
expect_no_out "upstream: the upstream file is not reported" "docs/up.md"
expect_status "upstream: the local file, staged: finding" 1 in_repo "$up" sh "$us" --level fail staged
expect_out "upstream: staged names the local file" "local.md:1  rule host-value-private-10"
g -C "$up" rm -q --cached local.md
rm "$up/local.md"
printf 'more\n' >>"$up/docs/up.md"
expect_status "upstream: a changed upstream file is local content" 1 in_repo "$up" sh "$us" --level fail tree
expect_out "upstream: the changed file is reported" "docs/up.md:1  rule host-value-private-10"
g -C "$up" checkout -q -- docs/up.md
cp "$up/docs/demo.gz" "$up/docs/copy.gz"
g -C "$up" add docs/copy.gz
expect_status "upstream: a copy of the archive at another path fails" 1 in_repo "$up" sh "$us" --level fail tree
expect_out "upstream: the copy is a policy finding" "FAIL  policy  docs/copy.gz  rule policy-archive"
g -C "$up" rm -q --cached docs/copy.gz
rm "$up/docs/copy.gz"
printf 'other\n' | gzip -c >"$up/docs/demo.gz"
expect_status "upstream: a changed archive fails" 1 in_repo "$up" sh "$us" --level fail tree
expect_out "upstream: the changed archive is a policy finding" "FAIL  policy  docs/demo.gz  rule policy-archive"
g -C "$up" checkout -q -- docs/demo.gz
expect_status "upstream: history without a range skips the upstream commits" 0 in_repo "$up" sh "$us" history
expect_out "upstream: history counts the local commit only" "1 commit(s)"
expect_status "upstream: history HEAD finds the token of the upstream commit" 1 in_repo "$up" sh "$us" history HEAD
expect_out "upstream: the upstream token is reported" "old-token.txt:1  rule github-pat  commit $(printf '%.12s' "$up_first")"
g -C "$up" update-ref refs/upstream/tags/v1.0.0 "$up_first"
expect_status "upstream: a tag ref with another commit is an error" 2 in_repo "$up" sh "$us" tree
expect_out "upstream: the error names the ref" "refs/upstream/tags/v1.0.0 is $up_first"
g -C "$up" update-ref refs/upstream/tags/v1.0.0 "$up_commit"
# Remove the upstream files, then restore them: staged and history compare the
# blobs of the index and of the commit with the base commit.
g -C "$up" rm -q docs/up.md docs/demo.gz
g -C "$up" commit -q -m "local: remove"
g -C "$up" checkout -q "$up_commit" -- docs/up.md docs/demo.gz
expect_status "upstream: restored upstream files, staged: accepted" 0 in_repo "$up" sh "$us" --level fail staged
expect_out "upstream: staged counts the accepted findings" "2 finding(s) in upstream content accepted"
g -C "$up" commit -q -m "local: restore"
expect_status "upstream: restored upstream files, history: accepted" 0 in_repo "$up" sh "$us" --level fail history
expect_out "upstream: history counts the accepted findings" "2 finding(s) in upstream content accepted"
mv "$work/up-deny.saved" "$up/.local/host-values.deny"
in_repo "$up" sh "$us" baseline >"$work/baseline" 2>"$work/out" || fail "upstream: baseline (exit $?)"
expect_out "upstream: baseline counts its hit lines" "1 hit line(s) for v1.0.0"
cp "$work/baseline" "$work/out"
expect_out "upstream: the baseline has the upstream address" "	docs/up.md"
expect_out "upstream: the baseline keeps the archive entry" "archive	"
expect_no_out "upstream: the baseline has no local rule hit" "tests/home.md"
expect_no_out "upstream: the baseline has no home value" "$host_name"
expect_no_out "upstream: the baseline has no address" "$ip10"

# A repository without the base commit (like a shallow clone): the hit lines apply.
fresh=$work/fresh
new_repo "$fresh"
mkdir -p "$fresh/docs" "$fresh/tests" "$fresh/scripts"
for f in docs/up.md docs/demo.gz tests/home.md .gitleaks.toml scripts/scan.sh scripts/host-values.deny \
    scripts/host-values.regex; do
    cp "$up/$f" "$fresh/$f"
done
cp "$work/baseline" "$fresh/scripts/upstream-base"
g -C "$fresh" add .
g -C "$fresh" commit -q -m "copy"
fs=$fresh/scripts/scan.sh
expect_status "baseline: the upstream address passes without the base commit" 0 in_repo "$fresh" sh "$fs" --level fail tree
expect_out "baseline: the hit lines are used" "finding(s) in upstream content accepted (v1.0.0, baseline of scripts/upstream-base)"
printf 'server: http://%s:9090/\n' "$ip10" >"$fresh/docs/up.md"
expect_status "baseline: a changed line fails" 1 in_repo "$fresh" sh "$fs" --level fail tree
expect_out "baseline: the changed line is reported" "docs/up.md:1  rule host-value-private-10"
g -C "$fresh" checkout -q -- docs/up.md
printf 'server: http://%s:8080/\n' "$ip10" >"$fresh/local.md"
g -C "$fresh" add local.md
expect_status "baseline: the same line in a local file fails" 1 in_repo "$fresh" sh "$fs" --level fail tree
expect_out "baseline: the local file is reported" "local.md:1  rule host-value-private-10"
g -C "$fresh" rm -q --cached local.md
mkdir -p "$fresh/.local"
cp "$local_deny" "$fresh/.local/host-values.deny"
printf '.local/\n' >>"$fresh/.git/info/exclude"
expect_status "baseline: a home pattern in an upstream file fails" 1 in_repo "$fresh" sh "$fs" --level fail tree
expect_out "baseline: the home pattern is reported" "tests/home.md:1  rule host-value-local-2"

echo "# scripts/upstream-base without the upstream ref"
# An uncommitted tag line that names a local commit must not turn local
# content into upstream content when refs/upstream/tags/<tag> is absent.
ub=$work/ub
new_repo "$ub"
mkdir -p "$ub/scripts"
cp "$repo_root/.gitleaks.toml" "$ub/"
cp "$repo_root/scripts/scan.sh" "$repo_root/scripts/host-values.deny" "$repo_root/scripts/host-values.regex" \
    "$tool/scripts/upstream-base" "$ub/scripts/"
printf 'server: http://%s:8080/\n' "$ip10" >"$ub/leak.txt"
g -C "$ub" add .
g -C "$ub" commit -q -m "local: the scan and a host value"
ub_commit=$(g -C "$ub" rev-parse HEAD)
ubs=$ub/scripts/scan.sh
expect_status "upstream-base: the committed file without the ref: the host value fails" 1 \
    in_repo "$ub" sh "$ubs" --level fail tree
{ grep -v '^tag	' "$tool/scripts/upstream-base"; printf 'tag\tv0.0.1\t%s\n' "$ub_commit"; } \
    >"$ub/scripts/upstream-base"
expect_status "upstream-base: an edited tag line without the ref: tree stops" 2 \
    in_repo "$ub" sh "$ubs" --level fail tree
expect_out "upstream-base: the message names the way to get the ref" "get the ref with: sh scripts/fetch-upstream.sh v0.0.1"
expect_status "upstream-base: an edited tag line without the ref: history stops" 2 in_repo "$ub" sh "$ubs" history
expect_out "upstream-base: history names the file" "scripts/upstream-base differs from HEAD"
g -C "$ub" add scripts/upstream-base
expect_status "upstream-base: a staged tag line without the ref: tree stops" 2 in_repo "$ub" sh "$ubs" --level fail tree
g -C "$ub" update-ref refs/upstream/tags/v0.0.1 "$ub_commit"
expect_status "upstream-base: the edited tag line with the ref: accepted as before" 0 \
    in_repo "$ub" sh "$ubs" --level fail tree
expect_out "upstream-base: with the ref the base commit is used" "1 finding(s) in upstream content accepted (v0.0.1, base commit)"
expect_status "upstream-base: the edited tag line with the ref: baseline runs" 0 in_repo "$ub" sh "$ubs" baseline
expect_out "upstream-base: baseline writes the hit line" "	leak.txt"
# A repository without HEAD has no committed version to compare with.
empty=$work/empty
rm -rf "$empty"; mkdir -p "$empty/scripts"
g -C "$empty" init -q
cp "$ub/.gitleaks.toml" "$empty/"
cp "$ub/scripts/"* "$empty/scripts/"
g -C "$empty" add .
expect_status "upstream-base: a repository without HEAD: tree runs" 0 in_repo "$empty" sh "$empty/scripts/scan.sh" --level fail tree
expect_status "upstream-base: a repository without HEAD: staged runs" 0 in_repo "$empty" sh "$empty/scripts/scan.sh" --level fail staged

# pre-push: the upstream commits are not scanned, except for a portable ref.
g init -q --bare "$work/up-remote.git"
g -C "$up" remote add origin "$work/up-remote.git"
in_repo "$up" sh scripts/install-hooks.sh >/dev/null
# First, while the remote is empty: a portable ref skips the commits that the
# remote has, and after the next push the remote has main.
expect_status "upstream pre-push: a new portable branch is scanned in all of its history" 1 \
    g -C "$up" push -q origin main:portable
expect_out "upstream pre-push: the upstream token refuses the portable push" "old-token.txt:1  rule github-pat"
expect_status "upstream pre-push: a new branch with an upstream token in its history is accepted" 0 \
    g -C "$up" push -q origin main

echo "# hooks in a temporary clone"
g init -q --bare "$work/remote.git"
g clone -q "$work/remote.git" "$work/clone" 2>/dev/null
c=$work/clone
mkdir -p "$c/scripts/git-hooks"
cp "$repo_root/.gitleaks.toml" "$c/"
cp "$repo_root/scripts/scan.sh" "$repo_root/scripts/host-values.deny" "$repo_root/scripts/host-values.regex" \
    "$tool/scripts/upstream-base" "$repo_root/scripts/install-hooks.sh" "$c/scripts/"
cp "$repo_root/scripts/git-hooks/"* "$c/scripts/git-hooks/"
g -C "$c" add .
g -C "$c" commit -q -m "add scan"
# The untracked local deny list of the clone (.gitignore of the clone is empty).
mkdir -p "$c/.local"
cp "$local_deny" "$c/.local/host-values.deny"
printf '.local/\n' >>"$c/.git/info/exclude"
expect_status "install-hooks.sh --check before install: exit 1" 1 in_repo "$c" sh scripts/install-hooks.sh --check
expect_status "install-hooks.sh installs" 0 in_repo "$c" sh scripts/install-hooks.sh
expect_status "install-hooks.sh --check after install: exit 0" 0 in_repo "$c" sh scripts/install-hooks.sh --check
g -C "$c" push -q origin main >/dev/null 2>&1
before=$(g -C "$c" rev-parse HEAD)
printf 'x = "%s"\n' "$token" >"$c/leak.txt"
g -C "$c" add leak.txt
expect_status "pre-commit: a commit with a token is refused" 1 g -C "$c" commit -q -m leak
expect_out "pre-commit: message" "pre-commit: commit refused"
expect_status "pre-commit: HEAD is unchanged" 0 test "$(g -C "$c" rev-parse HEAD)" = "$before"
g -C "$c" commit -q --no-verify -m "leak without hook"
expect_status "pre-push: a push with a token is refused" 1 g -C "$c" push -q origin main
expect_out "pre-push: message" "pre-push: push refused"
expect_status "pre-push: the remote branch is unchanged" 0 test "$(g -C "$work/remote.git" rev-parse main)" = "$before"

# Continue on a branch without the leak commit.
g -C "$c" checkout -q -b clean "$before"
printf 'api_base: http://%s\n' "$host_ip" >"$c/host.yaml"
g -C "$c" add host.yaml
expect_status "pre-commit: a host value on another branch is a warning" 0 g -C "$c" commit -q -m host
# First portable: a portable ref skips the commits that the remote has on main.
expect_status "pre-push: a host value to branch portable is refused" 1 g -C "$c" push -q origin clean:portable
expect_status "pre-push: a host value to branch main is a warning" 0 g -C "$c" push -q origin clean:main
printf 'name: %s\n' "$host_name" >"$c/name.txt"
g -C "$c" add name.txt
expect_status "pre-commit: a local pattern on another branch is a warning" 0 g -C "$c" commit -q -m name
expect_out "pre-commit: the local rule is printed" "warn  host value  name.txt:1  rule host-value-local-2"
expect_status "pre-push: a local pattern to branch portable is refused" 1 g -C "$c" push -q origin clean:portable
expect_out "pre-push: the local rule refuses the push" "FAIL  host value  name.txt:1  rule host-value-local-2"
g -C "$c" tag portable-v1
expect_status "pre-push: a host value to a tag portable-v* is refused" 1 g -C "$c" push -q origin portable-v1
# shellcheck disable=SC2016 # the inner sh expands $1
expect_status "pre-push: a new branch with a new clean commit is accepted" 0 sh -c '
    cd "$1" && git checkout -q -b feature && printf "ok\n" >ok.txt && git add ok.txt &&
    git commit -q -m ok && git push -q origin feature' sh "$c"

echo "# pre-push guard: a remote other than origin and upstream"
# The remote shared takes only refs/heads/portable and refs/tags/portable-v*.
# local-dev: the branch clean and one new commit with a host value.
g init -q --bare "$work/shared.git"
g -C "$c" remote add shared "$work/shared.git"
g -C "$c" checkout -q -b local-dev clean
printf 'api_base: http://%s\n' "$host_ip" >"$c/host2.yaml"
g -C "$c" add host2.yaml
g -C "$c" commit -q --no-verify -m "host value"
g -C "$c" checkout -q feature
# portable: a synthetic orphan commit with one clean file.
blob=$(printf 'portable\n' | g -C "$c" hash-object -w --stdin)
ptree=$(printf '100644 blob %s\tREADME\n' "$blob" | g -C "$c" mktree)
pcommit=$(g -C "$c" commit-tree -m portable "$ptree")
g -C "$c" update-ref refs/heads/portable "$pcommit"
g -C "$c" tag portable-v0.0.1 "$pcommit"
expect_status "guard: a push of local-dev to shared is refused" 1 g -C "$c" push -q shared local-dev
expect_out "guard: the message names the ref and the remote" "pre-push: refused: push of refs/heads/local-dev to 'shared'"
expect_out "guard: the message names the reason" "pre-push: push refused; local-dev, topic/*, sync/* and upstream tags hold host values"
expect_no_out "guard: the refusal comes before any scan" "pre-push: scan"
expect_status "guard: shared has no local-dev" 1 g -C "$work/shared.git" rev-parse -q --verify refs/heads/local-dev
expect_status "guard: local-dev to portable of shared goes to the scan and is refused" 1 g -C "$c" push -q shared local-dev:portable
expect_out "guard: the scan refuses local-dev as portable" "pre-push: scan refs/heads/local-dev -> refs/heads/portable"
expect_status "guard: a push of portable to shared runs the scan and passes" 0 g -C "$c" push -q shared portable
expect_out "guard: the scan runs for portable" "pre-push: scan refs/heads/portable -> refs/heads/portable"
expect_status "guard: shared has portable" 0 test "$(g -C "$work/shared.git" rev-parse portable)" = "$pcommit"
expect_status "guard: a push of the tag portable-v0.0.1 to shared runs the scan and passes" 0 g -C "$c" push -q shared portable-v0.0.1
expect_out "guard: the scan runs for the tag" "pre-push: scan refs/tags/portable-v0.0.1 -> refs/tags/portable-v0.0.1"
g -C "$c" tag v9.9.9 "$pcommit"
expect_status "guard: another tag to shared is refused" 1 g -C "$c" push -q shared v9.9.9
expect_out "guard: the message names the tag" "pre-push: refused: push of refs/tags/v9.9.9 to 'shared'"
expect_status "guard: portable with local-dev in one push is refused" 1 g -C "$c" push -q shared portable local-dev
g -C "$work/shared.git" branch other portable
expect_status "guard: a delete of another branch on shared is refused" 1 g -C "$c" push -q shared --delete other
expect_out "guard: the message names the delete" "pre-push: refused: delete of refs/heads/other to 'shared'"
expect_status "guard: shared still has the branch" 0 g -C "$work/shared.git" rev-parse -q --verify refs/heads/other
expect_status "guard: a push of local-dev to origin keeps the scan" 0 g -C "$c" push -q origin local-dev
expect_out "guard: origin: the scan runs" "pre-push: scan refs/heads/local-dev -> refs/heads/local-dev"
expect_out "guard: origin: a host value is a warning" "warn  host value"
expect_no_out "guard: origin: no guard message" "pre-push: refused"
expect_status "guard: a URL in place of a remote name is refused for local-dev" 1 g -C "$c" push -q "$work/shared.git" local-dev
expect_out "guard: the message names the URL" "pre-push: refused: push of refs/heads/local-dev to '$work/shared.git'"
g -C "$c" tag portable-v0.0.2 "$pcommit"
expect_status "guard: a URL in place of a remote name accepts a tag portable-v*" 0 g -C "$c" push -q "$work/shared.git" portable-v0.0.2
expect_out "guard: URL: the scan runs for the tag" "pre-push: scan refs/tags/portable-v0.0.2 -> refs/tags/portable-v0.0.2"
# The hook prints a URL without its credential (no network: the hook is run directly).
sec=$(printf '%s%s' SECRET PW7)
# shellcheck disable=SC2016 # the inner sh expands $1 and $2
expect_status "guard: a URL with a credential is refused" 1 in_repo "$c" sh -c '
    printf "refs/heads/local-dev %s refs/heads/local-dev %040d\n" "$1" 0 |
        sh scripts/git-hooks/pre-push "$2" "$2"' sh "$pcommit" "https://bot:$sec@git.example.invalid/o/r.git"
expect_out "guard: the URL is printed without the credential" "to 'https://git.example.invalid/o/r.git'"
expect_no_out "guard: the credential is not printed" "$sec"

g -C "$c" worktree add -q "$work/clone-wt" -b wtbranch 2>/dev/null
printf 'x = "%s"\n' "$token" >"$work/clone-wt/leak.txt"
g -C "$work/clone-wt" add leak.txt
expect_status "pre-commit in a worktree: a commit with a token is refused" 1 g -C "$work/clone-wt" commit -q -m leak
g -C "$work/clone-wt" commit -q --no-verify -m leak
expect_status "pre-push in a worktree: a push with a token is refused" 1 g -C "$work/clone-wt" push -q origin wtbranch

echo "# pre-push: a portable ref scans the commits that the remote does not have"
# Snapshot 1 of a portable chain has a host value that the upstream base does
# not accept, and the remote pub has it. Snapshot 2 is clean, with a new tag.
s1_blob=$(printf 'api_base: http://%s\n' "$host_ip" | g -C "$c" hash-object -w --stdin)
s1_tree=$(printf '100644 blob %s\tnet.md\n' "$s1_blob" | g -C "$c" mktree)
s1=$(g -C "$c" commit-tree -m "snapshot 1" "$s1_tree")
s2_blob=$(printf 'api_base: http://example.invalid\n' | g -C "$c" hash-object -w --stdin)
s2_tree=$(printf '100644 blob %s\tnet.md\n' "$s2_blob" | g -C "$c" mktree)
s2=$(g -C "$c" commit-tree -p "$s1" -m "snapshot 2" "$s2_tree")
g -C "$c" tag -a -m "snapshot 2" portable-v0.2.0 "$s2"
s2_tag=$(g -C "$c" rev-parse portable-v0.2.0)
g init -q --bare "$work/pub.git"
g -C "$c" remote add pub "$work/pub.git"
g -C "$c" push -q --no-verify pub "$s1:refs/heads/portable"
g -C "$c" fetch -q pub
expect_status "portable range: the new tag alone to the remote name is accepted" 0 \
    g -C "$c" push -q --dry-run pub portable-v0.2.0
expect_out "portable range: the remote-tracking ref leaves one commit" "scan: history $s2_tag --not --remotes=pub: 1 commit(s)"
expect_status "portable range: the branch and the new tag to the URL are accepted" 0 \
    g -C "$c" push -q --dry-run "$work/pub.git" "$s2:refs/heads/portable" portable-v0.2.0
expect_out "portable range: the branch scans one commit" "scan: history $s1..$s2: 1 commit(s)"
expect_out "portable range: the remote branch of the push leaves one commit for the tag" \
    "scan: history $s2_tag --not $s1: 1 commit(s)"
g init -q --bare "$work/pub-empty.git"
expect_status "portable range: the same push to an empty remote is refused" 1 \
    g -C "$c" push -q --dry-run "$work/pub-empty.git" "$s2:refs/heads/portable" portable-v0.2.0
expect_out "portable range: the empty remote gets the whole chain" "scan: history $s2_tag: 2 commit(s)"
expect_out "portable range: the finding is in snapshot 1" "FAIL  host value  net.md:1  rule host-value-private-192"
expect_out "portable range: the finding names snapshot 1" "commit $(printf '%.12s' "$s1")"
# A URL is not a remote name: the tag alone gets the whole chain, and the
# printed range holds no part of the URL (no network: the hook is run directly).
# shellcheck disable=SC2016 # the inner sh expands $1 and $2
expect_status "portable range: the new tag alone to a URL is refused" 1 in_repo "$c" sh -c '
    printf "refs/tags/portable-v0.2.0 %s refs/tags/portable-v0.2.0 %040d\n" "$1" 0 |
        sh scripts/git-hooks/pre-push "$2" "$2"' sh "$s2_tag" "https://bot:$sec@git.example.invalid/o/r.git"
expect_out "portable range: URL: the whole chain" "scan: history $s2_tag: 2 commit(s)"
expect_no_out "portable range: URL: the credential is not printed" "$sec"

echo "# hooks fail closed, pre-merge-commit, a branch without the scan"
g -C "$c" checkout -q -f clean
rm "$c/scripts/scan.sh"
printf 'ok\n' >"$c/f1.txt"
g -C "$c" add f1.txt
expect_status "pre-commit: scan.sh gone from the working tree, in the index: refused" 1 g -C "$c" commit -q -m f1
expect_out "pre-commit: fail closed message" "scripts/scan.sh is not in the working tree, but it is in the index or in HEAD"
g -C "$c" rm -q --cached scripts/scan.sh
expect_status "pre-commit: the commit that deletes scan.sh: refused" 1 g -C "$c" commit -q -m "remove scan"
expect_status "pre-push: scan.sh gone from the working tree: refused" 1 g -C "$c" push -q origin clean:main
g -C "$c" restore --staged scripts/scan.sh
g -C "$c" checkout -q -- scripts/scan.sh
rm -r "$c/scripts/git-hooks"
expect_status "dispatcher: hooks gone from the working tree: refused" 1 g -C "$c" commit -q -m f1
expect_out "dispatcher: fail closed message" "is not in the working tree, but"
g -C "$c" checkout -q -- scripts/git-hooks
expect_status "pre-commit: the restored hooks accept a clean commit" 0 g -C "$c" commit -q -m f1
# git commit -a and git commit <path> use a temporary index (GIT_INDEX_FILE).
printf 'x = "%s"\n' "$token" >"$c/f1.txt"
expect_status "pre-commit: git commit -a with a token is refused" 1 g -C "$c" commit -q -a -m leak
expect_status "pre-commit: git commit <path> with a token is refused" 1 g -C "$c" commit -q -m leak f1.txt
g -C "$c" checkout -q -- f1.txt
# pre-merge-commit: a merge without a conflict brings a token.
g -C "$c" checkout -q -b leaky
printf 'x = "%s"\n' "$token" >"$c/merge-leak.txt"
g -C "$c" add merge-leak.txt
g -C "$c" commit -q --no-verify -m "leak for merge"
g -C "$c" checkout -q clean
before=$(g -C "$c" rev-parse HEAD)
expect_status "pre-merge-commit: a merge with a token is refused" 1 g -C "$c" merge -q --no-ff -m merge leaky
expect_out "pre-merge-commit: message" "pre-merge-commit: commit refused"
g -C "$c" merge --abort 2>/dev/null || true
expect_status "pre-merge-commit: HEAD is unchanged" 0 test "$(g -C "$c" rev-parse HEAD)" = "$before"
g -C "$c" checkout -q -b clean-side
printf 'ok\n' >"$c/side.txt"
g -C "$c" add side.txt
g -C "$c" commit -q -m side
g -C "$c" checkout -q clean
expect_status "pre-merge-commit: a clean merge is accepted" 0 g -C "$c" merge -q --no-ff -m merge clean-side
# A branch that never had the scan.
g -C "$c" checkout -q --orphan plain
g -C "$c" rm -rq --cached .
rm -rf "$c/scripts" "$c/.gitleaks.toml"
printf 'plain\n' >"$c/plain.txt"
g -C "$c" add plain.txt
expect_status "a branch without the scan: commit accepted" 0 g -C "$c" commit -q -m plain
expect_out "a branch without the scan: the reason is printed" "pre-commit: this branch has no scripts/git-hooks/pre-commit and no scripts/scan.sh; no scan"
g -C "$c" checkout -q -f clean

expect_status "install-hooks.sh --uninstall" 0 in_repo "$c" sh scripts/install-hooks.sh --uninstall
expect_status "core.hooksPath is removed" 1 g -C "$c" config --get core.hooksPath
expect_status "the dispatcher copies are removed" 1 test -e "$(g -C "$c" rev-parse --git-common-dir)/scan-hooks"

echo
if [ "$failures" -eq 0 ]; then
    echo "all tests passed"
else
    echo "$failures test(s) failed"
    exit 1
fi
