#!/bin/sh
# Run the promotion block of docs/branches.md in a synthetic repository.
# Checks: one parentless commit on the first promotion, the tree of local-dev,
# the message "Promote local-dev <rev>", the generic identity in the author and
# committer lines, no host value in the commit, a later promotion with one
# parent, a file that local-dev deleted, and update-ref with a stale old value.
#
# Usage: sh tests/test_promotion.sh
#
# The test builds a new repository in a temporary directory and runs the block
# only there. It never runs a Git command that writes in this checkout, and it
# refuses to run the block in this repository or in a worktree of it.
# In sh, an INT or TERM handler does not end the script; exit runs the EXIT trap.
set -eu

repo=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd -P)
doc=$repo/docs/branches.md
[ -f "$doc" ] || { echo "FAIL $doc not found"; exit 1; }

# Read-only facts of this checkout, taken before the environment is isolated:
# the common Git directory (to refuse it later) and the e-mail domain of the
# user (it must not reach the commit).
repo_common=$(git -C "$repo" rev-parse --git-common-dir 2>/dev/null || true)
case $repo_common in
    '') ;;
    /*) ;;
    *) repo_common=$repo/$repo_common ;;
esac
[ -z "$repo_common" ] || repo_common=$(CDPATH='' cd -- "$repo_common" && pwd -P)
user_domain=$(git -C "$repo" config user.email 2>/dev/null | sed -n 's/.*@//p' || true)

tmp=$(mktemp -d /tmp/openviking-promotion-test.XXXXXX)
tmp=$(CDPATH='' cd -- "$tmp" && pwd -P)
trap 'rm -rf "$tmp"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
failed=0

# The block between the promotion markers, without the marker and fence lines
# and without the list indent.
block=$(sed -n '/<!-- promotion:begin/,/<!-- promotion:end/p' "$doc" |
    sed -e '/<!--/d' -e '/```/d' -e 's/^   //')
[ -n "$block" ] || { echo "FAIL no promotion block in docs/branches.md"; exit 1; }

# No global or system configuration and no hooks of the caller. GIT_CONFIG_GLOBAL
# needs Git 2.32; HOME gives the same isolation with an older Git.
# The caller identity is a private one: the block must replace it.
private_name='Private developer'
private_email=dev@private-host.invalid
HOME=$tmp GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
GIT_AUTHOR_NAME=$private_name GIT_AUTHOR_EMAIL=$private_email
GIT_COMMITTER_NAME=$private_name GIT_COMMITTER_EMAIL=$private_email
export HOME GIT_CONFIG_GLOBAL GIT_CONFIG_NOSYSTEM GIT_AUTHOR_NAME GIT_AUTHOR_EMAIL GIT_COMMITTER_NAME GIT_COMMITTER_EMAIL
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES

generic='OpenViking portable <portable@example.invalid>'

check() {
    name=$1
    shift
    if "$@"; then
        printf 'ok   %s\n' "$name"
    else
        printf 'FAIL %s\n' "$name"
        failed=1
    fi
}

eq() {
    [ "$1" = "$2" ] || { printf '  %s != %s\n' "$1" "$2"; return 1; }
}

# The block runs only in the synthetic repository: the working directory must
# be under the temporary directory, and its Git directory must not be the one
# of this checkout or of a worktree of it.
safe_dir() {
    here=$(pwd -P)
    case $here in
        "$tmp"/*) ;;
        *) printf '  working directory %s is not under %s\n' "$here" "$tmp"; return 1 ;;
    esac
    common=$(git rev-parse --git-common-dir)
    case $common in /*) ;; *) common=$here/$common ;; esac
    common=$(CDPATH='' cd -- "$common" && pwd -P)
    case $common in
        "$tmp"/*) ;;
        *) printf '  Git directory %s is not under %s\n' "$common" "$tmp"; return 1 ;;
    esac
    if [ -n "$repo_common" ] && [ "$common" = "$repo_common" ]; then
        printf '  Git directory %s belongs to this checkout\n' "$common"
        return 1
    fi
}

promote() {
    (cd "$tmp/r" && safe_dir && sh -eu -c "$block") >"$tmp/out" 2>&1 || { cat "$tmp/out"; return 1; }
}

unrelated() {
    ! git merge-base portable local-dev >/dev/null
}

same_tree() {
    eq "$(git rev-parse 'portable^{tree}')" "$(git rev-parse 'local-dev^{tree}')"
}

absent() {
    ! git cat-file -e "portable:$1" 2>/dev/null
}

# The commit object must not name the caller identity, the e-mail domain of
# this checkout's user, or a pattern of the untracked host deny list.
no_host_value() {
    git cat-file commit portable >"$tmp/commit"
    set -- "$private_email" "$private_name"
    [ -z "$user_domain" ] || set -- "$@" "$user_domain"
    if [ -f "$repo/.local/host-values.deny" ]; then
        while IFS= read -r pattern || [ -n "$pattern" ]; do
            case $pattern in '' | '#'*) continue ;; esac
            set -- "$@" "$pattern"
        done <"$repo/.local/host-values.deny"
    fi
    for pattern in "$@"; do
        if grep -Fqi -e "$pattern" "$tmp/commit"; then
            echo "  the commit contains a host value"
            return 1
        fi
    done
}

# git init -b needs Git 2.28; symbolic-ref works with each version.
git init -q "$tmp/r"
cd "$tmp/r"
git symbolic-ref HEAD refs/heads/local-dev
printf 'a\n' >a.txt
printf 'b\n' >b.txt
mkdir d && printf 'c\n' >d/c.txt
git add -A && git commit -q -m "first"
git commit -q --allow-empty -m "second, with history that portable must not get"

refuses_checkout() {
    ! (cd "$repo" && safe_dir) >/dev/null
}
check "the block refuses to run in this checkout" refuses_checkout
check "first promotion runs" promote
check "portable has one commit" eq "$(git rev-list --count portable)" 1
check "the commit has no parent" eq "$(git rev-list --parents -n 1 portable)" "$(git rev-parse portable)"
check "portable has the tree of local-dev" same_tree
check "message names the local-dev revision" eq "$(git log -1 --format=%s portable)" "Promote local-dev $(git rev-parse local-dev)"
check "author is the generic identity" eq "$(git log -1 --format='%an <%ae>' portable)" "$generic"
check "committer is the generic identity" eq "$(git log -1 --format='%cn <%ce>' portable)" "$generic"
check "the commit has no host value" no_host_value
check "no shared history" unrelated
check "HEAD stays on local-dev" eq "$(git symbolic-ref --short HEAD)" local-dev
check "working tree stays clean" eq "$(git status --porcelain)" ""
first=$(git rev-parse portable)

# local-dev changes a file, deletes a file and a directory, adds a file.
printf 'a2\n' >a.txt
git rm -q b.txt d/c.txt
printf 'e\n' >e.txt
git add -A && git commit -q -m "change, delete, add"
check "later promotion runs" promote
check "portable has two commits" eq "$(git rev-list --count portable)" 2
check "the only parent is the previous portable commit" \
    eq "$(git rev-list --parents -n 1 portable)" "$(git rev-parse portable) $first"
check "portable has the tree of local-dev" same_tree
check "a file that local-dev deleted is gone" absent b.txt
check "a directory that local-dev deleted is gone" absent d
check "a changed file is in portable" eq "$(git show portable:a.txt)" a2
check "an added file is in portable" eq "$(git show portable:e.txt)" e
check "message names the new local-dev revision" eq "$(git log -1 --format=%s portable)" "Promote local-dev $(git rev-parse local-dev)"
check "author and committer stay generic" eq "$(git log -1 --format='%an <%ae>|%cn <%ce>' portable)" "$generic|$generic"
check "the commit has no host value" no_host_value
check "no shared history" unrelated

# update-ref moves portable only from the expected old value.
stale=$(git rev-parse portable)
moved=$(git commit-tree -m other 'local-dev^{tree}')
git update-ref refs/heads/portable "$moved" "$stale"
refuses() {
    ! git update-ref refs/heads/portable "$1" "$2" 2>/dev/null
}
check "update-ref refuses a stale old value" refuses "$stale" "$first"
check "portable stays at the moved commit" eq "$(git rev-parse portable)" "$moved"

# Negative control: without its identity lines the block keeps the private
# identity, and the host value check finds it.
bare_block=$(printf '%s\n' "$block" | sed -e '/^GIT_/d' -e '/^export GIT_/d')
git init -q "$tmp/r2"
cd "$tmp/r2"
git symbolic-ref HEAD refs/heads/local-dev
printf 'a\n' >a.txt
git add -A && git commit -q -m "first"
(safe_dir && sh -eu -c "$bare_block") >"$tmp/out" 2>&1
check "control: without the identity lines the author is private" \
    eq "$(git log -1 --format='%an <%ae>' portable)" "$private_name <$private_email>"
finds_host_value() {
    ! no_host_value >/dev/null
}
check "control: the host value check finds the private identity" finds_host_value

# Command controls use small check stubs. The real scanner and public checker
# have their own suites; stubs make failure order and exact ranges observable.
if ! python3 - "$repo" "$tmp" <<'PYTEST'
import os
import shutil
import subprocess
import sys
from pathlib import Path

source, work = map(Path, sys.argv[1:])
block = (source / "docs/branches.md").read_text().split("<!-- promotion:begin", 1)[1]
block = block.split("<!-- promotion:end", 1)[0].split("```sh\n", 1)[1].split("```", 1)[0]
block = "\n".join(line.removeprefix("   ") for line in block.splitlines())
env = dict(os.environ, GIT_AUTHOR_DATE="2000-01-01T00:00:00 +0000",
           GIT_COMMITTER_DATE="2000-01-01T00:00:00 +0000")
# Keep the test out of caller-specific Git configuration and environment.
for key in list(env):
    if key.startswith("GIT_CONFIG_") and key not in ("GIT_CONFIG_GLOBAL", "GIT_CONFIG_NOSYSTEM"):
        del env[key]
count = 0
failures = []


def run(path, args, extra=None):
    path = path.resolve()
    assert path.is_relative_to(work) and str(path).startswith("/tmp/")
    return subprocess.run(args, cwd=path, env=dict(env, **(extra or {})),
                          capture_output=True, text=True)


def git(path, *args):
    result = run(path, ["git", *args])
    if result.returncode:
        raise RuntimeError("fixture Git command failed: " + " ".join(args))
    return result.stdout.strip()


def object_inventory(path):
    # Object IDs ignore allocation changes; storage names still detect new copies or packs.
    objects = tuple(sorted(git(path, "cat-file", "--batch-all-objects",
                               "--batch-check=%(objectname)").splitlines()))
    directory = Path(git(path, "rev-parse", "--git-path", "objects"))
    if not directory.is_absolute():
        directory = path / directory
    loose = tuple(oid for oid in objects if (directory / oid[:2] / oid[2:]).is_file())
    packs = tuple(sorted(pack.name for pack in directory.glob("pack/*.pack")))
    return objects, loose, packs


def check(name, condition):
    global count
    count += 1
    print(("ok   " if condition else "FAIL ") + name)
    if not condition:
        failures.append(name)


def state(path):
    return (git(path, "for-each-ref"), git(path, "status", "--porcelain"),
            git(path, "config", "--local", "--list"))


def fixture(name, private=True):
    path = work / name
    path.mkdir()
    git(path, "init", "-q")
    git(path, "symbolic-ref", "HEAD", "refs/heads/local-dev")
    (path / "scripts").mkdir()
    shutil.copy2(source / "scripts/promote.sh", path / "scripts/promote.sh")
    (path / ".gitignore").write_text(".local/\n")
    (path / "scripts/public-rules.json").write_text("{}\n")
    (path / "scripts/scan.sh").write_text("""#!/bin/sh
printf 'scan %s|%s|%s|exclude=%s\\n' "$1 ${2:-} ${3:-}" "${4:-}" "${SCAN_REF:-}" "${SCAN_EXCLUDE_UPSTREAM:-}" >>"$TEST_LOG"
[ "${SCAN_FAIL:-}" != "${3:-$1}" ] || exit "${CHECK_EXIT:-1}"
if [ "${SCAN_RACE:-0}" = 1 ] && [ "${3:-}" = history ]; then
    git update-ref refs/heads/portable local-dev
fi
exit 0
""")
    (path / "scripts/public-check.sh").write_text("""#!/bin/sh
printf 'public %s\\n' "$*" >>"$TEST_LOG"
[ "${PUBLIC_FAIL:-0}" = 0 ] || exit "${CHECK_EXIT:-1}"
if [ "${1:-}" = --ref ]; then
    git cat-file -e "$2^{commit}:scripts/public-rules.json" 2>/dev/null || exit 2
fi
exit 0
""")
    (path / "a.txt").write_text("a\n")
    (path / "gone.txt").write_text("gone\n")
    git(path, "add", "-A")
    git(path, "commit", "-qm", "first")
    git(path, "commit", "-q", "--allow-empty", "-m", "private history")
    if private:
        (path / ".local").mkdir()
        (path / ".local/host-values.deny").write_text("fixture-private-value\n")
    return path


def promote(path, *args, extra=None):
    common = Path(git(path, "rev-parse", "--git-common-dir"))
    if not common.is_absolute():
        common = path / common
    assert common.resolve().is_relative_to(work)
    log = work / (path.name + ".checks")
    log.write_text("")
    result = run(path, ["sh", "scripts/promote.sh", *args], dict(TEST_LOG=str(log), **(extra or {})))
    return result, log.read_text().splitlines()


def refuses(name, path, args=(), extra=None, code=1, reason=None):
    before = state(path)
    result, calls = promote(path, *args, extra=extra)
    check(name, result.returncode == code and state(path) == before and
          (reason is None or reason in result.stderr))
    return result, calls


def remote(path, name="shared"):
    bare = work / (path.name + "-" + name + ".git")
    bare.mkdir()
    git(bare, "init", "--bare", "-q")
    git(bare, "symbolic-ref", "HEAD", "refs/heads/portable")
    git(path, "remote", "add", name, str(bare))
    return bare


inventory_path = fixture("inventory")
inventory_before = object_inventory(inventory_path)
inventory_state = state(inventory_path)
sample = work / "unreferenced.txt"
sample.write_text("unreferenced inventory control\n")
blob = git(inventory_path, "hash-object", "-w", str(sample))
inventory_after = object_inventory(inventory_path)
check("inventory detects a new unreferenced loose object",
      inventory_after != inventory_before and blob in inventory_after[0] and
      blob not in inventory_before[0] and state(inventory_path) == inventory_state)
git(inventory_path, "repack", "-a")
packed_inventory = object_inventory(inventory_path)
check("inventory detects a new pack of existing objects",
      packed_inventory != inventory_after and packed_inventory[0] == inventory_after[0] and
      packed_inventory[2] != inventory_after[2] and state(inventory_path) == inventory_state)

path = fixture("command")
before = state(path)
objects = object_inventory(path)
result, calls = promote(path)
check("command dry run writes no objects, refs, index, tree or config",
      result.returncode == 0 and state(path) == before and object_inventory(path) == objects)
check("dry run runs tree then public check", calls == ["scan --level fail tree|||exclude=", "public "])
check("local-dev history requires deny list by default", "host deny required: 1" in result.stdout)
check("first dry run reports a new tree", "trees differ: yes" in result.stdout)
# Fixed dates make the block and command produce byte-identical commits.
git(path, "update-ref", "-d", "refs/heads/portable")
result = run(path, ["sh", "-eu", "-c", block])
assert result.returncode == 0
expected = git(path, "rev-parse", "portable")
git(path, "update-ref", "-d", "refs/heads/portable")
result, calls = promote(path, "--version", "0.1.9")
check("first command commit equals document block byte-for-byte",
      result.returncode == 0 and git(path, "rev-parse", "portable") == expected)
first = git(path, "rev-parse", "portable")
check("first history scan uses only new root", calls[-1] == "scan --level fail history|" + first + "|refs/heads/portable|exclude=0")
check("source public check uses exact local-dev commit", calls[2] == "public --ref " + git(path, "rev-parse", "local-dev"))
check("tag is annotated and generic", git(path, "cat-file", "-t", "portable-v0.1.9") == "tag" and
      git(path, "for-each-ref", "--format=%(taggername) %(taggeremail)", "refs/tags/portable-v0.1.9") ==
      "OpenViking portable <portable@example.invalid>")
check("command overrides identity without changing caller environment", env["GIT_AUTHOR_NAME"] == "Private developer" and
      env["GIT_AUTHOR_EMAIL"] == "dev@private-host.invalid")
check("command prints generic author, committer and tagger", all(x in result.stdout for x in
      ["author: OpenViking portable <portable@example.invalid>", "committer: OpenViking portable <portable@example.invalid>",
       "tagger: OpenViking portable <portable@example.invalid>"]))
check("no private identity in release object", "Private developer" not in git(path, "cat-file", "commit", first) and
      "private-host.invalid" not in git(path, "cat-file", "tag", "portable-v0.1.9"))
(path / "a.txt").write_text("changed\n")
git(path, "rm", "-q", "gone.txt")
git(path, "add", "a.txt")
git(path, "commit", "-qm", "change and delete")
run(path, ["sh", "-eu", "-c", block])
expected = git(path, "rev-parse", "portable")
git(path, "update-ref", "refs/heads/portable", first)
result, calls = promote(path, "--version", "0.1.10")
second = git(path, "rev-parse", "portable")
check("numeric 0.1.10 exceeds 0.1.9 and chain equals document block", result.returncode == 0 and second == expected)
check("chain has exactly one old portable parent", git(path, "rev-list", "--parents", "-n", "1", second) == second + " " + first)
check("chain history scan uses exact new range", calls[-1] == "scan --level fail history|" + first + ".." + second + "|refs/heads/portable|exclude=0")
check("command retains source tree and deletions", git(path, "rev-parse", "portable^{tree}") == git(path, "rev-parse", "local-dev^{tree}") and
      run(path, ["git", "cat-file", "-e", "portable:gone.txt"]).returncode != 0)
check("command has no private shared history", run(path, ["git", "merge-base", "portable", "local-dev"]).returncode == 1)
objects = object_inventory(path)
result, calls = refuses("unchanged tree refuses a new version", path, ("--version", "0.2.0"), reason="nothing to promote")
check("nothing to promote writes no object", object_inventory(path) == objects and not calls)
result, calls = promote(path)
check("dry run reports identical trees", result.returncode == 0 and "trees differ: no" in result.stdout)
# Make the next source differ so each version and scan refusal tests its own rule.
(path / "next.txt").write_text("next source\n")
git(path, "add", "next.txt")
git(path, "commit", "-qm", "next source")
result, calls = promote(path)
check("dry run reports changed source trees", result.returncode == 0 and "trees differ: yes" in result.stdout)
refuses("existing release tag", path, ("--version", "0.1.10"))
refuses("lower release version", path, ("--version", "0.1.8"))
refuses("lower minor despite greater patch", path, ("--version", "0.0.99"))
refuses("invalid version", path, ("--version", "1.2"), code=2)
refuses("leading-zero version", path, ("--version", "01.2.3"), code=2)
refuses("push without release", path, ("--push", "shared"), code=2)
refuses("root without version", path, ("--root",), code=2)
refuses("tag without push", path, ("--tag", "portable-v0.1.10"), code=2)
refuses("unknown option", path, ("--bad",), code=2)
refuses("dry-run needs push", path, ("--dry-run",), code=2)
refuses("development mode needs push", path, ("--development-remote",), code=2)
refuses("push dry-run refuses version creation", path,
        ("--version", "1.0.0", "--push", "shared", "--dry-run"), code=2, reason="existing tag")
refuses("duplicate version option", path, ("--version", "1.0.0", "--version", "1.0.1"), code=2)
refuses("mutually exclusive tag and version", path, ("--tag", "portable-v0.1.10", "--version", "1.0.0", "--push", "shared"), code=2)
(path / "untracked.txt").write_text("dirty\n")
refuses("untracked dirty file", path)
(path / "untracked.txt").unlink()
(path / "a.txt").write_text("dirty\n")
refuses("unstaged dirty file", path)
git(path, "add", "a.txt")
refuses("staged dirty file", path)
git(path, "restore", "--source=HEAD", "--staged", "--worktree", "a.txt")
git(path, "switch", "-q", "portable")
refuses("checkout of portable", path)
git(path, "switch", "-q", "local-dev")
other = work / "checked-portable"
git(path, "worktree", "add", "-q", str(other), "portable")
refuses("portable checked out in linked worktree", path)
git(path, "worktree", "remove", str(other))
git(path, "symbolic-ref", "refs/heads/portable", "refs/heads/local-dev")
refuses("symbolic portable ref", path)
git(path, "symbolic-ref", "--delete", "refs/heads/portable")
git(path, "update-ref", "refs/heads/portable", second)
(path / ".local/host-values.deny").unlink()
refuses("missing default host deny", path)
(path / ".local/host-values.deny").touch()
refuses("empty default host deny", path)
(path / ".local/host-values.deny").write_text(" # comment\n \n")
refuses("comment-only default host deny", path)
(path / ".local/host-values.deny").unlink()
(path / ".local/host-values.deny").symlink_to("../a.txt")
refuses("symlink host deny", path)
(path / ".local/host-values.deny").unlink()
(path / ".local/host-values.deny").write_text("fixture-private-value\n")
shallow = work / "shallow"
assert run(work, ["git", "clone", "-q", "--depth=1", "file://" + str(path), str(shallow)]).returncode == 0
refuses("shallow repository", shallow)
# A release clone has only portable-derived history and no source object.
clone = work / "release-clone"
assert run(work, ["git", "clone", "-q", "--single-branch", "--branch", "portable", "--no-local", str(path), str(clone)]).returncode == 0
git(clone, "switch", "-q", "--detach")
result, calls = promote(clone)
check("portable-only clone does not require host deny", result.returncode == 0 and "host deny required: 0" in result.stdout)
refuses("explicit host requirement in release clone", clone, ("--host-deny-required",))
refuses("new release needs local-dev", clone, ("--version", "1.0.0"))
git(path, "switch", "-q", "--detach")
git(path, "branch", "-D", "local-dev")
(path / ".local/host-values.deny").unlink()
refuses("retained source object still requires host deny", path)
git(path, "branch", "local-dev", "HEAD")
git(path, "switch", "-q", "local-dev")
(path / ".local/host-values.deny").write_text("fixture-private-value\n")
tracking = fixture("tracking-default", private=False)
git(tracking, "switch", "-q", "-c", "topic/test")
git(tracking, "update-ref", "refs/remotes/development/local-dev", git(tracking, "rev-parse", "local-dev"))
git(tracking, "branch", "-D", "local-dev")
refuses("remote-tracking local-dev requires host deny", tracking)
for mode in ("tree", "history"):
    result, calls = refuses("failed " + mode + " scan changes no refs", path, ("--version", "0.2.0"), extra={"SCAN_FAIL": mode})
    check("scan failure stops at " + mode, len(calls) == (1 if mode == "tree" else 4))
result, calls = refuses("public finding changes no refs", path, ("--version", "0.2.0"), extra={"PUBLIC_FAIL": "1"})
check("public failure prevents creation and history scan", len(calls) == 2)
refuses("check tool errors use exit 2", path, ("--version", "0.2.0"), extra={"SCAN_FAIL": "tree", "CHECK_EXIT": "2"}, code=2)
git(path, "tag", "portable-vmalformed")
refuses("malformed existing release version", path, ("--version", "0.2.0"))
git(path, "tag", "-d", "portable-vmalformed")
git(path, "tag", "portable-v1.0.0")
refuses("lower major despite greater minor and patch", path, ("--version", "0.9.999"))
git(path, "tag", "-d", "portable-v1.0.0")
git(path, "tag", "portable-v999999999999999999999999999999.0.0")
refuses("decimal comparison has no integer overflow", path, ("--version", "2.0.0"))
git(path, "tag", "-d", "portable-v999999999999999999999999999999.0.0")

bare = remote(path)
refuses("upstream remote", path, ("--tag", "portable-v0.1.10", "--push", "upstream"))
refuses("absent remote", path, ("--tag", "portable-v0.1.10", "--push", "absent"))
git(path, "config", "remote.shared.pushurl", "DISABLED")
refuses("DISABLED push URL", path, ("--tag", "portable-v0.1.10", "--push", "shared"))
git(path, "config", "--unset", "remote.shared.pushurl")
for url in ("https://user:synthetic-password@example.invalid/repo", "https://user:raw/slash@example.invalid/repo", "git@example.invalid:repo", "https://example.invalid/repo?access=synthetic-password", "ext::helper"):
    git(path, "remote", "set-url", "shared", url)
    result, calls = refuses("unsafe URL is refused without disclosure", path, ("--tag", "portable-v0.1.10", "--push", "shared"))
    check("unsafe URL stays out of output", url not in result.stdout + result.stderr and "synthetic-password" not in result.stdout + result.stderr and not calls)
git(path, "remote", "set-url", "shared", str(bare))
git(path, "config", "url.https://user:synthetic-password@example.invalid/.insteadOf", str(bare))
result, calls = refuses("URL rewrite with credentials", path, ("--tag", "portable-v0.1.10", "--push", "shared"))
check("rewritten credential stays out of output", "synthetic-password" not in result.stdout + result.stderr)
git(path, "config", "--remove-section", "url.https://user:synthetic-password@example.invalid/")
git(path, "remote", "set-url", "shared", "https://user:synthetic-password@example.invalid/repo")
git(path, "config", "url." + str(bare) + ".insteadOf", "https://user:synthetic-password@example.invalid/repo")
result, calls = refuses("raw credential URL stays refused after safe rewrite", path, ("--tag", "portable-v0.1.10", "--push", "shared"))
check("raw configured credential stays out of output", "synthetic-password" not in result.stdout + result.stderr)
git(path, "config", "--remove-section", "url." + str(bare))
git(path, "remote", "set-url", "shared", str(bare))
git(path, "config", "remote.shared.pushurl", str(work / "elsewhere.git"))
refuses("different fetch and push URLs", path, ("--tag", "portable-v0.1.10", "--push", "shared"))
git(path, "config", "--unset", "remote.shared.pushurl")
git(path, "config", "--add", "remote.shared.url", str(bare))
refuses("multiple remote URLs", path, ("--tag", "portable-v0.1.10", "--push", "shared"))
git(path, "config", "--unset-all", "remote.shared.url")
git(path, "config", "remote.shared.url", str(bare))
git(path, "config", "remote.shared.mirror", "true")
refuses("mirror configuration", path, ("--tag", "portable-v0.1.10", "--push", "shared"))
git(path, "config", "--unset", "remote.shared.mirror")
refuses("missing existing tag", path, ("--tag", "portable-v0.9.9", "--push", "shared"))
git(path, "tag", "portable-v0.2.0", second)
refuses("lightweight existing tag", path, ("--tag", "portable-v0.2.0", "--push", "shared"))
git(path, "tag", "-d", "portable-v0.2.0")
refuses("existing tag is not current portable tip", path, ("--tag", "portable-v0.1.9", "--push", "shared"))
# Force a different HEAD checkout to prove the source-object check is independent.
no_rules = fixture("source-check")
git(no_rules, "switch", "-q", "-c", "topic/check")
git(no_rules, "rm", "-q", "scripts/public-rules.json")
git(no_rules, "commit", "-qm", "remove rules")
git(no_rules, "branch", "-f", "local-dev", "HEAD")
git(no_rules, "switch", "-q", "--detach", "HEAD~1")
refuses("source tree check fails despite clean checkout", no_rules, ("--version", "1.0.0"), code=2)
# Existing old tag without rules must fail before any push dry run.
old_tree = git(path, "rev-parse", "portable^{tree}")
index = work / "old.index"
result = run(path, ["git", "read-tree", old_tree], {"GIT_INDEX_FILE": str(index)})
assert result.returncode == 0
run(path, ["git", "update-index", "--force-remove", "scripts/public-rules.json"], {"GIT_INDEX_FILE": str(index)})
tree = run(path, ["git", "write-tree"], {"GIT_INDEX_FILE": str(index)}).stdout.strip()
old_commit = git(path, "commit-tree", tree, "-m", "old release")
git(path, "update-ref", "refs/heads/portable", old_commit)
git(path, "tag", "-a", "portable-v0.0.1", "-m", "old release", old_commit)
result, calls = refuses("old release without public rules", path, ("--tag", "portable-v0.0.1", "--push", "shared"), reason="create a new checked release")
check("old release sends no remote ref", git(bare, "for-each-ref") == "")
git(path, "update-ref", "refs/heads/portable", second)
git(path, "tag", "-d", "portable-v0.0.1")
# Explicit pushes must ignore both configured wildcard refspecs and followTags.
git(path, "config", "remote.shared.push", "refs/heads/*:refs/heads/*")
git(path, "config", "push.followTags", "true")
git(path, "tag", "-a", "unrelated-tag", "-m", "extra", second)
remote_before = git(bare, "for-each-ref")
remote_objects = object_inventory(bare)
local_before = state(path)
objects = object_inventory(path)
planned, planned_calls = promote(path, "--tag", "portable-v0.1.10", "--push", "shared", "--dry-run")
check("push dry-run leaves remote and local refs unchanged", planned.returncode == 0 and
      git(bare, "for-each-ref") == remote_before and state(path) == local_before and
      object_inventory(path) == objects and object_inventory(bare) == remote_objects)
check("push dry-run runs all release checks", len(planned_calls) == 4 and planned_calls[-1] ==
      "scan --level fail history|" + second + "|refs/heads/portable|exclude=0")
check("push dry-run stops after the printed plan and dry-run result",
      planned.stdout.endswith("promote: push dry run passed\n") and "git ls-remote" not in planned.stdout)
result, calls = promote(path, "--tag", "portable-v0.1.10", "--push", "shared")
check("existing tag push succeeds with local bare remote", result.returncode == 0)
check("approved dry-run output equals real push plan byte-for-byte",
      result.stdout.split("promote: git ls-remote", 1)[0] == planned.stdout and calls == planned_calls)
check("only explicit portable and one release tag reach target", git(bare, "for-each-ref", "--format=%(refname)").splitlines() ==
      ["refs/heads/portable", "refs/tags/portable-v0.1.10"])
check("plan has remote, URL, old, new and exact refs", all(x in result.stdout for x in
      ["remote: shared", "URL: " + str(bare), "old remote portable: absent", "new portable: " + second,
       "ref: " + second + ":refs/heads/portable", "ref: " + git(path, "rev-parse", "portable-v0.1.10") + ":refs/tags/portable-v0.1.10",
       "promote: push dry run passed", "promote: git ls-remote shared"]))
check("existing release scans committed object and full portable history", calls[2].startswith("public --ref ") and
      calls[3] == "scan --level fail history|" + second + "|refs/heads/portable|exclude=0")
foreign_bare = remote(path, "helper")
git(foreign_bare, "fetch", "-q", "--no-tags", str(bare), "refs/heads/portable:refs/heads/extra")
result, calls = promote(path, "--tag", "portable-v0.1.10", "--push", "helper")
check("foreign helper branch is reported with nonzero exit", result.returncode == 1 and "refs/heads/extra" in result.stdout and "foreign refs: 1" in result.stdout)
check("foreign helper branch remains; no ref is deleted", git(foreign_bare, "rev-parse", "refs/heads/extra") == second)
helper_before = git(foreign_bare, "for-each-ref")
result, calls = promote(path, "--tag", "portable-v0.1.10", "--push", "helper", "--development-remote")
check("explicit development mode accepts and counts foreign refs", result.returncode == 0 and
      "other refs: 1" in result.stdout and "refs/heads/extra" not in result.stdout and
      git(foreign_bare, "for-each-ref") == helper_before)
# A remote named origin stays strict unless the explicit option is present.
development_bare = remote(path, "origin")
git(development_bare, "fetch", "-q", "--no-tags", str(path), "refs/heads/local-dev:refs/heads/local-dev")
private_commit = git(development_bare, "rev-parse", "local-dev")
git(development_bare, "update-ref", "refs/heads/topic/sample", private_commit)
git(development_bare, "update-ref", "refs/tags/private-tag", private_commit)
git(development_bare, "update-ref", "refs/pull/1/head", private_commit)
git(development_bare, "symbolic-ref", "HEAD", "refs/heads/local-dev")
result, calls = promote(path, "--tag", "portable-v0.1.10", "--push", "origin")
check("origin name does not imply development mode", result.returncode == 1 and
      "foreign refs: 3" in result.stdout and "refs/heads/local-dev" in result.stdout)
strict_calls = calls
development_before = git(development_bare, "for-each-ref")
planned, planned_calls = promote(path, "--tag", "portable-v0.1.10", "--push", "origin", "--development-remote", "--dry-run")
result, calls = promote(path, "--tag", "portable-v0.1.10", "--push", "origin", "--development-remote")
check("development mode hides other refs and development HEAD", result.returncode == 0 and
      "other refs: 3" in result.stdout and "server pull refs: 1" in result.stdout and
      all(name not in result.stdout for name in ("refs/heads/local-dev", "refs/heads/topic/sample", "private-tag", "refs/pull/", private_commit)))
check("development mode preserves every unrelated ref", git(development_bare, "for-each-ref") == development_before)
check("development option changes no pre-push checks", calls == planned_calls == strict_calls and
      calls[2].startswith("public --ref "))
check("development plan includes audit mode and matches execution", planned.returncode == 0 and
      "audit mode: development" in planned.stdout and
      result.stdout.split("promote: git ls-remote", 1)[0] == planned.stdout)
refuses("development mode cannot bypass upstream refusal", path,
        ("--tag", "portable-v0.1.10", "--push", "upstream", "--development-remote"))
refuses("development mode cannot bypass public check", path,
        ("--tag", "portable-v0.1.10", "--push", "origin", "--development-remote"), extra={"PUBLIC_FAIL": "1"})
refuses("development mode cannot bypass history check", path,
        ("--tag", "portable-v0.1.10", "--push", "origin", "--development-remote"), extra={"SCAN_FAIL": "history"})
git(bare, "update-ref", "refs/pull/1/head", second)
git(bare, "symbolic-ref", "HEAD", "refs/heads/absent")
result, calls = promote(path, "--tag", "portable-v0.1.10", "--push", "shared")
check("unborn remote HEAD does not count as a foreign ref", result.returncode == 0)
git(bare, "symbolic-ref", "HEAD", "refs/heads/portable")
result, calls = promote(path, "--tag", "portable-v0.1.10", "--push", "shared")
check("server pull refs are count-only and not a failure", result.returncode == 0 and "server pull refs: 1" in result.stdout and "refs/pull/" not in result.stdout)
refuses("root refuses target with portable chain", path, ("--version", "0.2.0", "--root", "--push", "shared"))
only_tag = remote(path, "tag-only")
git(only_tag, "fetch", "-q", "--no-tags", str(bare), "refs/tags/portable-v0.1.10:refs/tags/portable-v0.1.10")
refuses("root refuses target with only release tag", path, ("--version", "0.2.0", "--root", "--push", "tag-only"))
refuses("development mode cannot bypass root rules", path,
        ("--version", "0.2.0", "--root", "--push", "shared", "--development-remote"))
same_root = fixture("same-tree-root")
result, calls = promote(same_root, "--version", "1.0.0")
(same_root / "a.txt").write_text("second snapshot\n")
git(same_root, "add", "a.txt")
git(same_root, "commit", "-qm", "second snapshot")
result, calls = promote(same_root, "--version", "1.0.1")
old_root = git(same_root, "rev-parse", "portable")
result, calls = promote(same_root, "--version", "1.0.2", "--root")
new_root = git(same_root, "rev-parse", "portable")
check("root permits unchanged tree for a new parentless snapshot", result.returncode == 0 and new_root != old_root and
      git(same_root, "rev-parse", old_root + "^{tree}") == git(same_root, "rev-parse", new_root + "^{tree}") and
      git(same_root, "rev-list", "--parents", "-n", "1", new_root) == new_root and
      git(same_root, "cat-file", "-t", "portable-v1.0.2") == "tag")
root_path = fixture("root")
root_bare = remote(root_path)
result, calls = promote(root_path, "--version", "1.0.0", "--root", "--push", "shared")
new = git(root_path, "rev-parse", "portable")
check("explicit root can publish to empty target", result.returncode == 0 and git(root_path, "rev-list", "--parents", "-n", "1", new) == new)
check("root scanner checks only the new commit", calls[-1] == "scan --level fail history|" + new + "|refs/heads/portable|exclude=0")
result, calls = promote(path, "--version", "0.2.0", "--root")
new = git(path, "rev-parse", "portable")
check("explicit root replaces local chain without parent", result.returncode == 0 and git(path, "rev-list", "--parents", "-n", "1", new) == new)
refuses("later push of root cannot replace target chain", path, ("--tag", "portable-v0.2.0", "--push", "shared"), reason="root tag cannot replace")
check("refused root leaves remote portable intact", git(bare, "rev-parse", "portable") == second)
transaction = fixture("transaction")
result, calls = promote(transaction, "--version", "1.0.0", extra={"SCAN_RACE": "1"})
check("concurrent portable update prevents partial local release transaction", result.returncode == 1 and
      git(transaction, "rev-parse", "portable") == git(transaction, "rev-parse", "local-dev") and
      run(transaction, ["git", "show-ref", "--verify", "refs/tags/portable-v1.0.0"]).returncode != 0)
# An unpublished root must also refuse a target with only another release tag.
refuses("later root push refuses an existing release-tag chain", path, ("--tag", "portable-v0.2.0", "--push", "tag-only"), reason="root tag cannot replace")
refuses("push dry-run preserves existing root safety boundary", path,
        ("--tag", "portable-v0.2.0", "--push", "tag-only", "--dry-run"), reason="root tag cannot replace")
result, calls = promote(root_path, "--tag", "portable-v1.0.0", "--push", "shared")
check("existing published root can be pushed again", result.returncode == 0)
# Capture each push invocation through a real synthetic pre-push hook.
hook_path = fixture("push-hook")
hook_bare = remote(hook_path)
hooks = hook_path / ".git/hooks/pre-push"
hooks.write_text("#!/bin/sh\ncat >>\"$TEST_PUSH_LOG\"\n")
hooks.chmod(0o755)
push_log = work / "push-input"
result, calls = promote(hook_path, "--version", "1.0.0", "--push", "shared", extra={"TEST_PUSH_LOG": str(push_log)})
lines = push_log.read_text().splitlines()
check("new version push invokes hook on dry run then actual push", result.returncode == 0 and len(lines) == 4 and lines[:2] == lines[2:])
check("hook receives exactly two allowed explicit refs per push", {line.split()[2] for line in lines} == {"refs/heads/portable", "refs/tags/portable-v1.0.0"})
plan_hook = fixture("plan-hook")
plan_bare = remote(plan_hook)
result, calls = promote(plan_hook, "--version", "1.0.0")
plan_hook_file = plan_hook / ".git/hooks/pre-push"
plan_hook_file.write_text("#!/bin/sh\ncat >>\"$TEST_PUSH_LOG\"\n")
plan_hook_file.chmod(0o755)
plan_log = work / "plan-input"
result, calls = promote(plan_hook, "--tag", "portable-v1.0.0", "--push", "shared", "--dry-run",
                        extra={"TEST_PUSH_LOG": str(plan_log)})
check("push dry-run invokes only one hook pass and writes no remote refs", result.returncode == 0 and
      len(plan_log.read_text().splitlines()) == 2 and git(plan_bare, "for-each-ref") == "")
refuses("push dry-run still refuses public finding", plan_hook,
        ("--tag", "portable-v1.0.0", "--push", "shared", "--dry-run"), extra={"PUBLIC_FAIL": "1"})
refuses("push dry-run still refuses failed history scan", plan_hook,
        ("--tag", "portable-v1.0.0", "--push", "shared", "--dry-run"), extra={"SCAN_FAIL": "history"})
check("both push passes pin the checked object IDs", {line.split()[1] for line in lines} ==
      {git(hook_path, "rev-parse", "portable"), git(hook_path, "rev-parse", "portable-v1.0.0")})
race = fixture("push-race")
race_bare = remote(race)
hooks = race / ".git/hooks/pre-push"
hooks.write_text("#!/bin/sh\ncat >/dev/null\ngit update-ref refs/heads/portable local-dev\n")
hooks.chmod(0o755)
result, calls = promote(race, "--version", "1.0.0", "--push", "shared")
check("concurrent ref movement cannot substitute private push objects", result.returncode == 0 and
      git(race_bare, "rev-parse", "portable") == git(race, "rev-parse", "portable-v1.0.0^{commit}") and
      git(race_bare, "rev-parse", "portable") != git(race, "rev-parse", "local-dev"))
# A server rejection must not expose raw network output.
reject = fixture("reject")
reject_bare = remote(reject)
server_hook = reject_bare / "hooks/pre-receive"
server_hook.write_text("#!/bin/sh\necho synthetic-credential >&2\nexit 1\n")
server_hook.chmod(0o755)
result, calls = promote(reject, "--version", "1.0.0", "--push", "shared")
check("failed actual push retains local release but hides server output", result.returncode == 1 and "synthetic-credential" not in result.stdout + result.stderr and
      git(reject, "rev-parse", "portable-v1.0.0^{commit}") == git(reject, "rev-parse", "portable") and git(reject_bare, "for-each-ref") == "")
# Use the real public check and pre-push hook on an orphan fixture. Only the
# scanner stays stubbed; no scanner image or live remote is needed here.
real = fixture("real-public")
paths = subprocess.check_output(["git", "-C", str(source), "ls-files", "-z"]).split(b"\0")
for raw in paths:
    if not raw:
        continue
    name = os.fsdecode(raw)
    if name == "scripts/scan.sh":
        continue
    src, dest = source / name, real / name
    dest.parent.mkdir(parents=True, exist_ok=True)
    if src.is_symlink():
        dest.symlink_to(os.readlink(src))
    elif src.is_file():
        shutil.copy2(src, dest)
# Retain the scanner's source contracts for the public checker, but exit
# through the stub before its engine selection can start a container.
scanner = (real / "scripts/scan.sh").read_text()
contracts = (source / "scripts/scan.sh").read_text()
(real / "scripts/scan.sh").write_text(contracts.replace("set -eu\n", "set -eu\n" + scanner, 1))
git(real, "add", "-A")
git(real, "commit", "-qm", "public fixture")
real_bare = remote(real)
shutil.copy2(source / "scripts/git-hooks/pre-push", real / ".git/hooks/pre-push")
(real / ".git/hooks/pre-push").chmod(0o755)
result, calls = promote(real, "--version", "1.0.0")
check("real public checker creates the local release before approval", result.returncode == 0)
real_before = git(real_bare, "for-each-ref")
real_objects = object_inventory(real_bare)
planned, planned_calls = promote(real, "--tag", "portable-v1.0.0", "--push", "shared", "--dry-run")
check("real checker and hook run push plan without remote changes", planned.returncode == 0 and
      git(real_bare, "for-each-ref") == real_before and object_inventory(real_bare) == real_objects)
result, calls = promote(real, "--tag", "portable-v1.0.0", "--push", "shared")
check("real checker and hook produce the same approved push plan", result.returncode == 0 and
      result.stdout.split("promote: git ls-remote", 1)[0] == planned.stdout)
if result.returncode:
    print(result.stdout + result.stderr)
check("real public checker and hook accept new orphan commit and annotated tag",
      result.returncode == 0 and git(real_bare, "rev-parse", "portable") == git(real, "rev-parse", "portable"))
check("real hook never sends private development branch",
      git(real_bare, "for-each-ref", "--format=%(refname)").splitlines() ==
      ["refs/heads/portable", "refs/tags/portable-v1.0.0"])
print(str(count) + " command checks; " + str(len(failures)) + " failures")
sys.exit(bool(failures))
PYTEST
then
    failed=1
fi

if [ "$failed" = 0 ]; then
    echo "all promotion checks passed"
else
    echo "promotion checks failed"
    exit 1
fi
