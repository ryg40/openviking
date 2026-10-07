#!/bin/sh
# Offline test for scripts/setup-remotes.sh and scripts/fetch-upstream.sh.
# A local bare repository stands in for upstream through UPSTREAM_URL, and
# another one for the shared Git server through SHARED_URL.
#
# Usage: tests/test_setup_remotes.sh
#   TEST_NETWORK=1  also fetch one tag from github.com (optional)

set -eu

repo_root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
setup=$repo_root/scripts/setup-remotes.sh
fetch=$repo_root/scripts/fetch-upstream.sh
base_tag=$(awk -F '\t' '$1 == "tag" { print $2; exit }' "$repo_root/scripts/upstream-base")
base_commit=$(awk -F '\t' '$1 == "tag" { print $3; exit }' "$repo_root/scripts/upstream-base")

work=$(mktemp -d "${TMPDIR:-/tmp}/test-setup-remotes.XXXXXX")
trap 'rm -rf "$work"' EXIT
# In sh, an INT or TERM handler does not end the script; exit runs the EXIT trap.
trap 'exit 130' INT TERM

# Keep the global and system Git config of the host out of the test.
GIT_CONFIG_GLOBAL=$work/gitconfig
GIT_CONFIG_NOSYSTEM=1
export GIT_CONFIG_GLOBAL GIT_CONFIG_NOSYSTEM
unset SHARED_URL SHARED_REMOTE 2>/dev/null || true

failures=0
nl='
'
pass() { echo "ok   - $1"; }
fail() { echo "FAIL - $1"; failures=$((failures + 1)); }
expect_ok() {
    name=$1; shift
    if "$@" >"$work/out" 2>&1; then pass "$name"; else fail "$name"; cat "$work/out"; fi
}
not() { ! "$@"; }
# in_dir <dir> <command>...: run a command in another directory.
in_dir() { (cd "$1" && shift && "$@"); }
# has_ref [<git dir>] <ref>
has_ref() {
    if [ $# -eq 2 ]; then git -C "$1" rev-parse --verify --quiet "$2" >/dev/null
    else git rev-parse --verify --quiet "$1" >/dev/null; fi
}
expect() {
    name=$1; shift
    if "$@"; then pass "$name"; else fail "$name"; fi
}
expect_status() {
    name=$1; want=$2; shift 2
    got=0; "$@" >"$work/out" 2>&1 || got=$?
    if [ "$got" -eq "$want" ]; then pass "$name"; else fail "$name (exit $got, expected $want)"; cat "$work/out"; fi
}
expect_fail() {
    name=$1; shift
    if "$@" >"$work/out" 2>&1; then fail "$name"; cat "$work/out"; else pass "$name"; fi
}

git_quiet() { git -c init.defaultBranch=main -c user.name=test -c user.email=test@example.invalid "$@" >/dev/null 2>&1; }

# Fake upstream: three releases on one line of history (an annotated tag,
# a lightweight tag, a CLI tag) and a non-release tag. Then a bare copy.
git_quiet init "$work/upstream-src"
for v in 1.0.0 1.1.0 1.2.0; do
    echo "$v" >"$work/upstream-src/version.txt"
    git_quiet -C "$work/upstream-src" add version.txt
    git_quiet -C "$work/upstream-src" commit -m "release $v"
done
git_quiet -C "$work/upstream-src" tag -a v1.0.0 -m v1.0.0 HEAD~2
git_quiet -C "$work/upstream-src" tag v1.1.0 HEAD~1
git_quiet -C "$work/upstream-src" tag cli@1.2.0 HEAD
git_quiet -C "$work/upstream-src" tag nightly HEAD
git_quiet clone --bare "$work/upstream-src" "$work/upstream.git"
# file:// makes Git use the normal transport, so --depth works as with a server.
UPSTREAM_URL=file://$work/upstream.git
export UPSTREAM_URL

# Fake clone of this repo: one local tag, an "origin" with credentials in its
# URL, and the old upstream configuration (main branch refspec, no tagOpt).
git_quiet init "$work/clone"
git_quiet -C "$work/clone" commit --allow-empty -m init
git_quiet -C "$work/clone" tag pre-split-test
git -C "$work/clone" remote add origin https://user:s3cret@example.invalid/openviking.git
git -C "$work/clone" remote add upstream "$UPSTREAM_URL"
git -C "$work/clone" remote set-url --push upstream DISABLED
git -C "$work/clone" config remote.upstream.fetch '+refs/heads/main:refs/remotes/upstream/main'
git_quiet -C "$work/clone" update-ref refs/remotes/upstream/main HEAD
cd "$work/clone"

# Existing remote: converted in place, old refs kept.
expect_fail "--check fails with the old configuration" sh "$setup" --check
expect_ok "setup converts the old configuration" sh "$setup"
expect "prints the old and new fetch refspec" grep -qF "changed remote.upstream.fetch: '+refs/heads/main:refs/remotes/upstream/main' -> '+refs/upstream-none/*:refs/upstream/none/*'" "$work/out"
expect "prints the new tagOpt" grep -qF "changed remote.upstream.tagOpt: '' -> '--no-tags'" "$work/out"
expect "does not print the unchanged push URL" not grep -q 'changed remote.upstream.pushurl' "$work/out"
expect "refs/remotes/upstream/main is kept" has_ref refs/remotes/upstream/main
expect "local tag is kept" [ "$(git tag -l)" = pre-split-test ]
expect "origin URL printed without credentials" not grep -q s3cret "$work/out"
expect "origin URL printed" grep -qF "origin: https://example.invalid/openviking.git (not changed)" "$work/out"

# New clone: remote absent.
git_quiet init "$work/new"
expect_ok "setup in a new clone" in_dir "$work/new" sh "$setup"
expect "new clone: url" [ "$(git -C "$work/new" config remote.upstream.url)" = "$UPSTREAM_URL" ]
expect "new clone: pushurl" [ "$(git -C "$work/new" config remote.upstream.pushurl)" = DISABLED ]
expect "new clone: tagOpt" [ "$(git -C "$work/new" config remote.upstream.tagOpt)" = --no-tags ]
expect "new clone: fetch" [ "$(git -C "$work/new" config --get-all remote.upstream.fetch)" = '+refs/upstream-none/*:refs/upstream/none/*' ]
expect "warns if origin is absent" grep -q "warning: remote 'origin' is absent" "$work/out"

# Idempotent.
git config --get-regexp '^remote\.' >"$work/config1"
cp .git/config "$work/file1"
expect_ok "second run" sh "$setup"
expect "second run prints no change" grep -qx "upstream: no change" "$work/out"
git config --get-regexp '^remote\.' >"$work/config2"
expect "second run gives the same configuration" cmp -s "$work/config1" "$work/config2"
expect "second run leaves the config file as it is" cmp -s "$work/file1" .git/config
expect_ok "--check passes after setup" sh "$setup" --check
expect "--check changes nothing" cmp -s "$work/file1" .git/config
expect "origin is not changed" [ "$(git config remote.origin.url)" = https://user:s3cret@example.invalid/openviking.git ]
expect_fail "git push upstream fails" git push upstream HEAD:refs/heads/test
expect "push did not reach the fake upstream" not has_ref "$work/upstream.git" refs/heads/test

# Drift: --check exits 1, setup repairs.
git remote set-url --push upstream "$UPSTREAM_URL"
expect_status "--check exits 1 after a changed push URL" 1 sh "$setup" --check
expect_ok "setup repairs the push URL" sh "$setup"
expect_status "--check exits 0 after repair" 0 sh "$setup" --check

git config remote.upstream.fetch '+refs/heads/*:refs/remotes/upstream/*'
expect_status "--check exits 1 after a changed refspec" 1 sh "$setup" --check
expect_ok "setup repairs the refspec" sh "$setup"

git config --add remote.upstream.fetch '+refs/heads/*:refs/remotes/upstream/*'
expect_status "--check exits 1 with an extra refspec" 1 sh "$setup" --check
expect_ok "setup removes the extra refspec" sh "$setup"

git config --unset remote.upstream.tagOpt
expect_status "--check exits 1 after a removed tagOpt" 1 sh "$setup" --check
expect_ok "setup repairs tagOpt" sh "$setup"
expect_status "--check exits 0 after all repairs" 0 sh "$setup" --check
expect_status "--check refuses an unknown argument" 2 sh "$setup" --fix

# A plain fetch transfers nothing.
expect_ok "plain git fetch upstream" git fetch upstream
expect "plain fetch creates no refs" [ -z "$(git for-each-ref refs/upstream)" ]
expect "plain fetch creates no tags" [ "$(git tag -l)" = pre-split-test ]
if dry=$(git fetch upstream --dry-run 2>&1); then pass "git fetch --dry-run exits 0"; else fail "git fetch --dry-run exits 0"; fi
expect "git fetch --dry-run prints nothing" [ -z "$dry" ]

# Credentials in URLs.
secret_url=https://bot:TOPSECRET@mirror.example.invalid/ov.git
UPSTREAM_URL=$secret_url sh "$setup" --check >"$work/out" 2>&1 || true
expect "--check prints the expected URL without credentials" not grep -q TOPSECRET "$work/out"
UPSTREAM_URL=$secret_url sh "$setup" >"$work/out" 2>&1 || true
expect "setup prints UPSTREAM_URL without credentials" not grep -q TOPSECRET "$work/out"
expect "setup prints the mirror URL" grep -qF 'upstream: https://mirror.example.invalid/ov.git' "$work/out"
sh "$setup" >"$work/out" 2>&1 || true
expect "setup prints the old URL without credentials" not grep -q TOPSECRET "$work/out"
expect "setup prints the old URL" grep -qF "'https://mirror.example.invalid/ov.git' ->" "$work/out"
expect_ok "setup restores the test URL" sh "$setup" --check

# Credential forms in the origin URL and in UPSTREAM_URL. Each case:
# <URL> <expected printed URL>. No part of the secret (USR7, PW1 to PW4,
# TOK9, PASS5) may be printed. A raw '/' in a password cannot be parsed,
# so that URL is hidden. An scp-style URL has no secret and stays as it is.
git_quiet init "$work/cred"
git -C "$work/cred" remote add origin https://example.invalid/placeholder.git
in_dir "$work/cred" sh "$setup" >/dev/null 2>&1
while read -r cred_url cred_shown; do
    git -C "$work/cred" remote set-url origin "$cred_url" </dev/null
    in_dir "$work/cred" sh "$setup" --check </dev/null >"$work/out" 2>&1 || true
    expect "origin $cred_url: printed as $cred_shown" grep -qxF "origin: $cred_shown (not changed)" "$work/out"
    expect "origin $cred_url: no part of the secret printed" not grep -qE 'USR7|PW[1-4]|TOK9|PASS5' "$work/out"
    (cd "$work/cred" && UPSTREAM_URL=$cred_url sh "$setup" --check) </dev/null >"$work/out" 2>&1 || true
    expect "UPSTREAM_URL $cred_url: printed as $cred_shown" grep -qF "expected '$cred_shown'" "$work/out"
    expect "UPSTREAM_URL $cred_url: no part of the secret printed" not grep -qE 'USR7|PW[1-4]|TOK9|PASS5' "$work/out"
done <<'CASES'
https://USR7:PW1@PW2@host.invalid/x.git https://host.invalid/x.git
https://USR7:PW3/PW4@host.invalid/x.git <url hidden>
https://TOK9@host.invalid/x.git https://host.invalid/x.git
ssh://git:PASS5@host.invalid/x.git ssh://host.invalid/x.git
https://host.invalid/x.git https://host.invalid/x.git
git@host.invalid:x.git git@host.invalid:x.git
CASES

# The remote shared: a separate clone, so that the upstream cases stay apart.
git_quiet init "$work/sh"
git_quiet -C "$work/sh" commit --allow-empty -m init
git_quiet -C "$work/sh" branch local-dev
git_quiet -C "$work/sh" branch portable
git_quiet -C "$work/sh" tag portable-v0.0.1
git_quiet -C "$work/sh" tag v9.9.9
git_quiet init --bare "$work/shared.git"
shared_url=file://$work/shared.git
in_dir "$work/sh" sh "$setup" >/dev/null 2>&1
expect_ok "shared: --check without the remote passes" in_dir "$work/sh" sh "$setup" --check
expect "shared: --check says that the remote is absent" grep -qF "shared: remote 'shared' is absent" "$work/out"
expect_ok "shared: setup without SHARED_URL passes" in_dir "$work/sh" sh "$setup"
expect "shared: setup without SHARED_URL creates no remote" [ -z "$(git -C "$work/sh" config --get-regexp '^remote\.shared\.' || true)" ]
expect_status "shared: --check with SHARED_URL and no remote exits 1" 1 in_dir "$work/sh" env SHARED_URL="$shared_url" sh "$setup" --check
expect_ok "shared: setup with SHARED_URL" in_dir "$work/sh" env SHARED_URL="$shared_url" sh "$setup"
expect "shared: prints the new push refspecs" grep -qF "changed remote.shared.push: '' -> 'refs/heads/portable:refs/heads/portable refs/tags/portable-v*:refs/tags/portable-v*'" "$work/out"
expect "shared: url" [ "$(git -C "$work/sh" config --get-all remote.shared.url)" = "$shared_url" ]
expect "shared: pushurl equals url" [ "$(git -C "$work/sh" config --get-all remote.shared.pushurl)" = "$shared_url" ]
expect "shared: fetch portable only" [ "$(git -C "$work/sh" config --get-all remote.shared.fetch)" = '+refs/heads/portable:refs/remotes/shared/portable' ]
expect "shared: tagOpt" [ "$(git -C "$work/sh" config --get-all remote.shared.tagOpt)" = --no-tags ]
expect "shared: push refspecs" [ "$(git -C "$work/sh" config --get-all remote.shared.push)" = "refs/heads/portable:refs/heads/portable${nl}refs/tags/portable-v*:refs/tags/portable-v*" ]
expect "shared: upstream is not changed" [ "$(git -C "$work/sh" config remote.upstream.pushurl)" = DISABLED ]
cp "$work/sh/.git/config" "$work/shfile1"
expect_ok "shared: second run" in_dir "$work/sh" env SHARED_URL="$shared_url" sh "$setup"
expect "shared: second run prints no change" grep -qx "shared: no change" "$work/out"
expect "shared: second run leaves the config file as it is" cmp -s "$work/shfile1" "$work/sh/.git/config"
expect_ok "shared: --check passes after setup" in_dir "$work/sh" sh "$setup" --check
expect_ok "shared: --check with SHARED_URL passes after setup" in_dir "$work/sh" env SHARED_URL="$shared_url" sh "$setup" --check
expect "shared: --check changes nothing" cmp -s "$work/shfile1" "$work/sh/.git/config"

# A plain push sends only portable and portable-v*; a plain fetch reads portable only.
expect_ok "shared: plain git push shared" git -C "$work/sh" push shared
expect "shared: the server has portable" has_ref "$work/shared.git" refs/heads/portable
expect "shared: the server has portable-v0.0.1" has_ref "$work/shared.git" refs/tags/portable-v0.0.1
expect "shared: the server has no local-dev" not has_ref "$work/shared.git" refs/heads/local-dev
expect "shared: the server has no other tag" not has_ref "$work/shared.git" refs/tags/v9.9.9
git_quiet -C "$work/shared.git" branch other portable
expect_ok "shared: plain git fetch shared" git -C "$work/sh" fetch shared
expect "shared: fetch gives refs/remotes/shared/portable" has_ref "$work/sh" refs/remotes/shared/portable
expect "shared: fetch gives no other remote-tracking ref" [ "$(git -C "$work/sh" for-each-ref --format='%(refname)' refs/remotes/shared)" = refs/remotes/shared/portable ]

# Drift: --check exits 1 with a message, setup repairs.
git -C "$work/sh" config --add remote.shared.fetch '+refs/heads/*:refs/remotes/shared/*'
expect_status "shared: --check exits 1 with a wildcard refspec" 1 in_dir "$work/sh" sh "$setup" --check
expect "shared: the message names the key" grep -qF "check: remote.shared.fetch is" "$work/out"
expect_ok "shared: setup repairs the refspec" in_dir "$work/sh" env SHARED_URL="$shared_url" sh "$setup"
git -C "$work/sh" config --unset-all remote.shared.push
expect_status "shared: --check exits 1 without push refspecs" 1 in_dir "$work/sh" sh "$setup" --check
expect_ok "shared: setup repairs the push refspecs" in_dir "$work/sh" env SHARED_URL="$shared_url" sh "$setup"
git -C "$work/sh" config remote.shared.pushurl "$UPSTREAM_URL"
expect_status "shared: --check exits 1 with another push URL" 1 in_dir "$work/sh" sh "$setup" --check
expect_ok "shared: setup repairs the push URL" in_dir "$work/sh" env SHARED_URL="$shared_url" sh "$setup"
git -C "$work/sh" config --unset remote.shared.tagOpt
expect_status "shared: --check exits 1 without tagOpt" 1 in_dir "$work/sh" sh "$setup" --check
expect_ok "shared: setup repairs tagOpt" in_dir "$work/sh" env SHARED_URL="$shared_url" sh "$setup"
expect_status "shared: --check with another SHARED_URL exits 1" 1 in_dir "$work/sh" env SHARED_URL=file:///other.git sh "$setup" --check
expect_ok "shared: --check exits 0 after all repairs" in_dir "$work/sh" sh "$setup" --check

# Credentials in SHARED_URL are not printed.
secret_shared=https://bot:SHAREDSECRET@git.example.invalid/o/ov.git
expect_status "shared: --check with a credential URL exits 1" 1 in_dir "$work/sh" env SHARED_URL="$secret_shared" sh "$setup" --check
expect "shared: --check prints no credential" not grep -q SHAREDSECRET "$work/out"
expect "shared: --check prints the URL without credentials" grep -qF "expected 'https://git.example.invalid/o/ov.git'" "$work/out"
expect_ok "shared: setup with a credential URL" in_dir "$work/sh" env SHARED_URL="$secret_shared" sh "$setup"
expect "shared: setup prints no credential" not grep -q SHAREDSECRET "$work/out"
expect "shared: setup prints the URL without credentials" grep -qF "shared: https://git.example.invalid/o/ov.git (" "$work/out"
expect_ok "shared: --check with a credential URL in the config" in_dir "$work/sh" sh "$setup" --check
expect "shared: --check prints no credential from the config" not grep -q SHAREDSECRET "$work/out"
expect_ok "shared: setup restores the test URL" in_dir "$work/sh" env SHARED_URL="$shared_url" sh "$setup"
expect "shared: the old URL is printed without credentials" not grep -q SHAREDSECRET "$work/out"

# SHARED_REMOTE: another name; the names of the other remotes and of the branch are refused.
expect_ok "SHARED_REMOTE=gh: setup" in_dir "$work/sh" env SHARED_REMOTE=gh SHARED_URL="$shared_url" sh "$setup"
expect "SHARED_REMOTE=gh: fetch refspec names the remote" [ "$(git -C "$work/sh" config --get-all remote.gh.fetch)" = '+refs/heads/portable:refs/remotes/gh/portable' ]
expect_ok "SHARED_REMOTE=gh: --check" in_dir "$work/sh" env SHARED_REMOTE=gh sh "$setup" --check
for bad in portable origin upstream -x 'a b' 'a/b'; do
    expect_status "SHARED_REMOTE '$bad' is refused" 2 in_dir "$work/sh" env SHARED_REMOTE="$bad" SHARED_URL="$shared_url" sh "$setup"
done
expect "no remote portable" [ -z "$(git -C "$work/sh" config --get-regexp '^remote\.portable\.' || true)" ]

# Tag names.
for bad in '' main v1 'v1.2.3;x' -v1.2.3 'v1.2.3 x' 'v1 .2.3' v1..2 v1.2.3.. 1.2.3 'cli@1.2' 'cli@1.2.3-x' \
    'v1.2.3:refs/heads/x' 'v1.2.3*' nightly "v1.2.3${nl}x" 'v1.2.3	' \
    v1.2.3.a..b v1.2.3-rc.; do
    label=$(printf '%s' "$bad" | tr '\n\t' '??')
    expect_status "fetch-upstream refuses '$label'" 2 sh "$fetch" "$bad"
done
# The refusal message prints the name as given, also with a backslash.
expect_status "fetch-upstream refuses a name with a backslash" 2 sh "$fetch" 'v1.2.3-\a'
expect "refusal prints the name with the backslash" grep -qF "error: 'v1.2.3-\\a' is not" "$work/out"
expect_status "fetch-upstream refuses no argument" 2 sh "$fetch"
expect_status "fetch-upstream refuses two arguments" 2 sh "$fetch" v1.0.0 v1.1.0
expect_status "fetch-upstream refuses --shallow alone" 2 sh "$fetch" --shallow

# The fetch needs a correct setup.
git config --unset remote.upstream.tagOpt
expect_status "fetch-upstream stops if --check fails" 1 sh "$fetch" v1.0.0
expect "no ref after a stopped fetch" [ -z "$(git for-each-ref refs/upstream)" ]
sh "$setup" >/dev/null 2>&1

# Default fetch: full history, tag outside refs/tags/, repo not shallow.
# v1.2.0 does not exist upstream (only cli@1.2.0), so this must fail.
expect_fail "fetch of a missing tag fails" sh "$fetch" v1.2.0
if commit=$(sh "$fetch" cli@1.2.0 2>"$work/err"); then pass "fetch-upstream cli@1.2.0"; else fail "fetch-upstream cli@1.2.0"; cat "$work/err"; fi
expect "prints the commit ID" [ "$commit" = "$(git -C "$work/upstream.git" rev-parse 'cli@1.2.0^{commit}')" ]
expect "ref refs/upstream/tags/cli@1.2.0" [ "$(git rev-parse 'refs/upstream/tags/cli@1.2.0^{commit}')" = "$commit" ]
if commit=$(sh "$fetch" v1.0.0 2>"$work/err"); then pass "fetch-upstream v1.0.0 (annotated)"; else fail "fetch-upstream v1.0.0 (annotated)"; cat "$work/err"; fi
expect "annotated tag: prints the commit ID" [ "$commit" = "$(git -C "$work/upstream.git" rev-parse 'v1.0.0^{commit}')" ]
expect "repo is not shallow after a default fetch" [ "$(git rev-parse --is-shallow-repository)" = false ]
expect "no .git/shallow file" [ ! -e .git/shallow ]
expect "full history: v1.0.0 is an ancestor of cli@1.2.0" git merge-base --is-ancestor refs/upstream/tags/v1.0.0 refs/upstream/tags/cli@1.2.0
expect "full history: all upstream commits are present" [ "$(git rev-list --count refs/upstream/tags/cli@1.2.0)" -eq 3 ]
expect "git tag -l shows no upstream tag" [ "$(git tag -l)" = pre-split-test ]
expect "no promisor setting after a default fetch" [ -z "$(git config --get remote.upstream.promisor || true)" ]
expect_ok "--check passes after fetch" sh "$setup" --check

# --shallow: refused in a repo with commits, allowed in an empty repo.
expect_status "--shallow refused in a repo with commits" 2 sh "$fetch" --shallow v1.1.0
expect "refusal explains the reason" grep -q -- '--shallow refused' "$work/out"
expect "repo is still not shallow" [ "$(git rev-parse --is-shallow-repository)" = false ]
expect "no ref after the refusal" not has_ref refs/upstream/tags/v1.1.0
if commit=$(cd "$work/new" && sh "$fetch" --shallow v1.1.0 2>"$work/err"); then pass "--shallow in an empty repo"; else fail "--shallow in an empty repo"; cat "$work/err"; fi
expect "--shallow prints the commit ID" [ "$commit" = "$(git -C "$work/upstream.git" rev-parse 'v1.1.0^{commit}')" ]
expect "empty repo is shallow after --shallow" [ "$(git -C "$work/new" rev-parse --is-shallow-repository)" = true ]
expect "shallow repo has one commit" [ "$(git -C "$work/new" rev-list --count refs/upstream/tags/v1.1.0)" -eq 1 ]
expect_ok "--shallow allowed in a shallow repo" in_dir "$work/new" sh "$fetch" --shallow cli@1.2.0
expect "shallow repo: no tag in refs/tags" [ -z "$(git -C "$work/new" tag -l)" ]

# Optional: one tag from GitHub, shallow, in an empty repo.
if [ "${TEST_NETWORK:-0}" = 1 ]; then
    git_quiet init "$work/net"
    if commit=$(cd "$work/net" && unset UPSTREAM_URL && sh "$setup" >/dev/null 2>&1 && sh "$fetch" --shallow "$base_tag" 2>"$work/err"); then
        pass "network: fetch $base_tag from github.com"
    else
        fail "network: fetch $base_tag from github.com"; cat "$work/err"
    fi
    expect "network: $base_tag commit" [ "$commit" = "$base_commit" ]
else
    echo "skip - network test (set TEST_NETWORK=1)"
fi

if [ "$failures" -eq 0 ]; then echo "all tests passed"; else echo "$failures test(s) failed"; exit 1; fi
