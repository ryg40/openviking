#!/bin/sh
# Offline controls in an isolated temporary checkout; no service or network.
set -eu
repo_root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
work=$(mktemp -d "${TMPDIR:-/tmp}/public-check-test.XXXXXX")
trap 'rm -rf "$work"' EXIT
trap 'exit 130' INT TERM
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE 2>/dev/null || true
python3 - "$repo_root" "$work" <<'PY'
import hashlib
import importlib.util
import json
import os
import re
import shutil
import subprocess
import sys
from pathlib import Path

source, root = map(Path, sys.argv[1:])


def git(*args):
    return subprocess.check_output(["git", "-C", str(root), *args], stderr=subprocess.DEVNULL)


subprocess.run(["git", "init", "-q", str(root)], check=True)
paths = subprocess.check_output(["git", "-C", str(source), "ls-files", "-z"]).split(b"\0")
for raw in paths:
    if not raw:
        continue
    path = os.fsdecode(raw)
    src, dest = source / path, root / path
    dest.parent.mkdir(parents=True, exist_ok=True)
    if src.is_symlink():
        dest.symlink_to(os.readlink(src))
    elif src.is_file():
        shutil.copy2(src, dest)
git("add", "-A")
git("-c", "user.name=test", "-c", "user.email=test@example.invalid", "commit", "-qm", "fixture")
os.chdir(root)
failures = []
count = 0


def check(name, want, rule=None, args=(), message=None):
    global count
    count += 1
    result = subprocess.run(
        ["sh", "scripts/public-check.sh", *args], capture_output=True, text=True
    )
    if (
        "hidden-source-value" in result.stdout + result.stderr
        or result.returncode != want
        or any(
            item not in result.stdout
            for item in ((rule,) if isinstance(rule, str) else rule or ())
        )
        or (message and message not in result.stderr)
    ):
        failures.append(name)
        print("FAIL - " + name + " (exit " + str(result.returncode) + ")")
        print(result.stdout + result.stderr)
    else:
        print("ok - " + name)
    return result


def mutate(name, path, change, rule, want=1, message=None):
    p = root / path
    before = p.read_bytes() if p.exists() else None
    p.parent.mkdir(parents=True, exist_ok=True)
    p.write_text(change(before.decode() if before is not None else ""))
    git("add", "-f", path)
    result = check(name, want, rule, message=message)
    if before is None:
        p.unlink()
        git("rm", "-q", "--cached", path)
    else:
        p.write_bytes(before)
        git("add", path)
    return result


def control(name, condition):
    global count
    count += 1
    print(("ok - " if condition else "FAIL - ") + name)
    if not condition:
        failures.append(name)


def snapshot(ref, writes=(), remove=()):
    index = root / "snapshot.index"
    env = dict(os.environ, GIT_INDEX_FILE=str(index))
    subprocess.run(["git", "read-tree", ref], env=env, check=True)
    for path, data in writes:
        oid = subprocess.check_output(["git", "hash-object", "-w", "--stdin"], input=data)
        subprocess.run(
            ["git", "update-index", "--add", "--cacheinfo", "100644", oid.decode().strip(), path],
            env=env,
            check=True,
        )
    for path in remove:
        subprocess.run(["git", "update-index", "--force-remove", path], env=env, check=True)
    tree = subprocess.check_output(["git", "write-tree"], env=env).decode().strip()
    return git(
        "-c", "user.name=test", "-c", "user.email=test@example.invalid",
        "commit-tree", tree, "-m", "snapshot fixture",
    ).decode().strip()


check("clean orphan tree without upstream objects", 0)
check("usage error", 2, args=("--bad",))
check(
    "generator without upstream objects",
    2,
    args=("--write-upstream-map",),
    message="upstream map generator needs the base commit locally",
)
for name, line in [
    ("private-tracker", "issue " + "987654"),
    ("work-record", "20" + "24-01-02 verified deployment"),
    ("development-process", "the " + "owner approved this"),
    ("machine-path", "/ho" + "me/private-user/project"),
]:
    result = None
    mutate(name, "sample.txt", lambda old, line=line: line + "\n", name)
mutate(
    "date and version alone are not work records",
    "sample.txt",
    lambda _: "20" + "24-01-02\npkg==10.2.3.4\n",
    None,
    0,
)
mutate("relative link", "sample.md", lambda _: "[x](absent.md)\n", "document-link")
mutate(
    "reference link", "sample.md", lambda _: "[x][target]\n[target]: absent.md\n", "document-link"
)
mutate("undefined reference", "sample.md", lambda _: "[x][missing]\n", "document-reference")
mutate("HTML link", "sample.md", lambda _: '<a href="absent.md">x</a>\n', "document-link")
mutate("fragment", "sample.md", lambda _: "[x](README.md#no-such-heading)\n", "document-anchor")
mutate("code path", "docs/sample.md", lambda _: "`scripts/absent.sh`\n", "document-code-path")
mutate(
    "external link and fenced sample",
    "sample.md",
    lambda _: "[x](https://example.invalid/missing)\n```md\n[x](absent.md)\n```\n",
    None,
    0,
)
for path in (".env", ".local/sample.txt", "data/sample.txt"):
    mutate("private state " + path, path, lambda _: "sample\n", "tree-private-state")
mutate(
    "workflow allow list and removal rule both report",
    ".github/workflows/sample.yml",
    lambda _: "name: sample\n",
    ("tree-github-path", "tree-removed-path"),
)
mutate(
    "template forbidden by both tree rules",
    ".github/ISSUE_TEMPLATE/sample.md",
    lambda _: "sample\n",
    ("tree-github-path", "tree-removed-path"),
)
mutate(
    "listed directory includes nested paths",
    ".github/ISSUE_TEMPLATE/nested/sample.md",
    lambda _: "sample\n",
    ("tree-github-path", "tree-removed-path"),
)
mutate("exact removed path", "docker-compose.yml", lambda _: "sample\n", "tree-removed-path")
mutate(
    "exact GitHub removal reports both rules",
    ".github/PULL_REQUEST_TEMPLATE.md",
    lambda _: "sample\n",
    ("tree-github-path", "tree-removed-path"),
)
mutate(
    "exact path does not match a suffix", "docker-compose.yml.bak", lambda _: "sample\n", None, 0
)
result = mutate(
    "directory sibling still fails GitHub policy",
    ".github/ISSUE_TEMPLATE-extra/sample.md",
    lambda _: "sample\n",
    "tree-github-path",
)
control("directory sibling does not match removal rule", "tree-removed-path" not in result.stdout)

# Both readers consume the same fixture for every supported and rejected line form.
readers = []
for name, filename in (
    ("public_check", "public_check.py"), ("upstream_update", "upstream-update.py")
):
    spec = importlib.util.spec_from_file_location(name, root / "scripts" / filename)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    readers.append(module)
public, update = readers
removed_path = root / "scripts/upstream-removed"
saved_removed = removed_path.read_bytes()
valid = (
    "\n  # comment\r\n\t\n  dir/ \r\n exact.txt\t\n._A-z09/file-name.txt\n"
    "./literal\ndir//\ndir/..name\ndir/-name\n"
)
expected = ["dir/", "exact.txt", "._A-z09/file-name.txt", "./literal", "dir//",
            "dir/..name", "dir/-name"]
removed_path.write_text(valid)
control(
    "removal readers agree on whitespace comments blank lines and allowed characters",
    public.removed_rules(valid) == update.removed_rules(root) == expected,
)
invalid_lines = [
    ("absolute path", "/absolute"),
    ("parent path", "../file"),
    ("nested parent part", "dir/../file"),
    ("parent part at end", "dir/.."),
    ("option prefix", "-file"),
    ("glob", "dir/*"),
    ("inline comment", "file # comment"),
    ("space inside path", "dir/file name"),
    ("backslash", "dir\\file"),
    ("non-ASCII character", "file-" + chr(233)),
    ("control character", "file" + chr(0)),
]
for name, line in invalid_lines:
    text = "# comment\n\n " + line + " \n"
    removed_path.write_text(text)
    rejected = []
    for reader, argument, error in (
        (public.removed_rules, text, public.ToolError),
        (update.removed_rules, root, update.UpdateError),
    ):
        try:
            reader(argument)
        except error:
            rejected.append(True)
        else:
            rejected.append(False)
    control("removal readers both reject " + name, rejected == [True, True])
    check(
        "invalid removal line: " + name, 2,
        message="invalid removed-path rule in scripts/upstream-removed",
    )
for path, rule, wanted in (
    (".github/workflows/new.yml", ".github/workflows/", True),
    (".github/workflows-extra/new.yml", ".github/workflows/", False),
    ("dir/nested/file", "dir/", True),
    ("dir", "dir/", False),
    ("exact.txt", "exact.txt", True),
    ("exact.txt.bak", "exact.txt", False),
    ("exact.txt/file", "exact.txt", False),
    ("dir/..name", "dir/..name", True),
    ("dir/-name", "dir/-name", True),
    ("./literal", "./literal", True),
    ("literal", "./literal", False),
    ("dir//file", "dir//", True),
    ("dir/file", "dir//", False),
):
    control(
        "removal matchers agree: " + path + " against " + rule,
        public.matches(path, rule) == update.matches(path, rule) == wanted,
    )
removed_path.write_bytes(saved_removed)
removed_path.unlink()
check("missing checkout removal list fails closed", 2, message="checkout has no removal list")
check("generator requires removal list", 2, args=("--write-upstream-map",),
      message="checkout has no removal list")
removed_path.write_bytes(saved_removed)

rules_path = root / "scripts/public-rules.json"
saved_rules = rules_path.read_bytes()
rules = json.loads(saved_rules)
owned = ".github/workflows/owned.yml"
rules["workflows"].append(owned)
rules_path.write_text(json.dumps(rules, indent=2) + "\n")
mutate("owned workflow overrides directory removal", owned, lambda _: "name: owned\n", None, 0)
removed_path.write_bytes(saved_removed + (owned + "\n").encode())
mutate("owned workflow overrides exact removal", owned, lambda _: "name: owned\n", None, 0)
mutate(
    "workflow exception is exact",
    ".github/workflows/owned-other.yml",
    lambda _: "name: other\n",
    ("tree-github-path", "tree-removed-path"),
)
rules_path.write_bytes(saved_rules)
removed_path.write_bytes(saved_removed)
check("clean tree after removal controls", 0)
mutate(
    "empty helper map",
    "scripts/public-rules.json",
    lambda old: json.dumps(dict(json.loads(old), github_scripts={}), indent=2) + "\n",
    None,
    2,
    message="invalid key: rules.github_scripts (at least one helper required)",
)
helpers = json.loads(saved_rules)["github_scripts"]
for size in range(1, len(helpers)):
    rules = json.loads(saved_rules)
    rules["github_scripts"] = dict(list(helpers.items())[:size])
    try:
        public.validate_rules(rules)
    except public.ToolError:
        accepted = False
    else:
        accepted = True
    control("valid helper map size " + str(size), accepted)

sample_helper = ".github/scripts/sample-helper.sh"
sample_data = "#!/bin/sh\nexit 0\n"
mutate("helper outside map", sample_helper, lambda _: sample_data, "tree-github-path")
rules = json.loads(saved_rules)
data = sample_data.encode()
rules["github_scripts"][sample_helper] = {
    "mode": "100644",
    "blob": hashlib.sha1(b"blob " + str(len(data)).encode() + b"\0" + data).hexdigest(),
}
for field, value, message in (
    ("mode", "100600", "invalid key: rules.github_scripts[].mode"),
    ("blob", "not-a-blob", "invalid key: rules.github_scripts[].blob"),
):
    invalid = json.loads(json.dumps(rules))
    invalid["github_scripts"][sample_helper][field] = value
    mutate(
        "expanded helper map rejects invalid " + field,
        "scripts/public-rules.json",
        lambda _, invalid=invalid: json.dumps(invalid, indent=2) + "\n",
        None,
        2,
        message=message,
    )
invalid = json.loads(json.dumps(rules))
invalid["github_scripts"]["scripts/sample-helper.sh"] = invalid["github_scripts"].pop(sample_helper)
mutate(
    "expanded helper map rejects invalid path",
    "scripts/public-rules.json",
    lambda _: json.dumps(invalid, indent=2) + "\n",
    None,
    2,
    message="invalid key: rules.github_scripts path",
)
rules_path.write_text(json.dumps(rules, indent=2) + "\n")
mutate("expanded helper map with tracked helper", sample_helper, lambda _: sample_data, None, 0)
rules_path.write_bytes(saved_rules)
helper = ".github/scripts/check-marketplace-archive.mjs"
git("rm", "-q", "--cached", helper)
check("mapped helper absent from tree", 1, "tree-upstream-helper")
git("add", helper)
mutate("changed helper", helper, lambda old: old + "\n// changed\n", "tree-upstream-helper")
helper = ".github/scripts/check-plugin-version-bumps.sh"
git("update-index", "--chmod=-x", helper)
check("helper mode", 1, "tree-upstream-helper")
git("update-index", "--chmod=+x", helper)
mutate("license", "LICENSE", lambda _: "", "tree-license")
mutate(
    "modified-copy notice",
    "README.md",
    lambda old: old.replace("This repository is a modified copy", "This repository is a copy"),
    "tree-modified-notice",
)
mutate(
    "scanner source changed",
    "scripts/scan.sh",
    lambda old: re.sub(r"^(GITLEAKS_IMAGE=.+)$", r"\1 # changed", old, flags=re.M),
    "pin-source",
)
mutate(
    "base image source changed",
    "Dockerfile",
    lambda old: re.sub(r"^ARG NODE_IMAGE=.+$", "ARG NODE_IMAGE=node:999-test", old, flags=re.M),
    "freshness-image",
)
mutate(
    "environment default changed",
    ".env.example",
    lambda old: old.replace("OPENVIKING_PORT=1933", "OPENVIKING_PORT=1934"),
    "freshness-default",
)
mutate(
    "Compose default changed",
    "compose.yaml",
    lambda old: old.replace("OPENVIKING_PORT:-1933", "OPENVIKING_PORT:-1934"),
    "freshness-default",
)
mutate(
    "bake default changed",
    "docker-bake.hcl",
    lambda old: old.replace('default = "openviking:local"', 'default = "openviking:changed"'),
    "freshness-default",
)
mutate(
    "script default changed",
    "scripts/scan.sh",
    lambda old: old.replace("SCAN_ENGINE:-auto", "SCAN_ENGINE:-binary"),
    "freshness-default",
)
mutate(
    "document default changed",
    "EXPLAINER.md",
    lambda old: old.replace("| `SCAN_ENGINE` | `auto` |", "| `SCAN_ENGINE` | `binary` |"),
    "freshness-default",
)
mutate(
    "step command changed",
    "EXPLAINER.md",
    lambda old: old.replace("\nsh scripts/build.sh gateway\n", "\nsh scripts/build.sh smoke\n"),
    "freshness-steps",
)
mutate(
    "quick start changed",
    "README.md",
    lambda old: old.replace("docker compose ps ", "docker compose top "),
    "freshness-steps",
)
mutate(
    "quick start scanner pull missing",
    "README.md",
    lambda old: "\n".join(line for line in old.split("\n") if not line.startswith("docker pull ")),
    "freshness-steps",
)
mutate(
    "quick start scanner pull changed",
    "README.md",
    lambda old: old.replace("sed -n", "sed -e"),
    "freshness-scanner",
)
# Pin controls take current values from sources, never duplicate them in this test.
tag_line = next(
    line
    for line in Path("scripts/upstream-base").read_text().splitlines()
    if line.startswith("tag\t")
)
pin_tag, pin_commit = tag_line.split("\t")[1:]
docker_source = Path("Dockerfile").read_text()
scan_source = Path("scripts/scan.sh").read_text()
pin_digest = re.search(r"^ARG RUST_DIGEST=(.+)$", docker_source, re.M)[1]
pin_scanner = re.search(r"^GITLEAKS_IMAGE=\$\{GITLEAKS_IMAGE:-([^}]+)\}", scan_source, re.M)[1]
pin_uv = re.search(r"uv==([0-9.]+)", docker_source)[1]
for label, value in [
    ("tag", pin_tag),
    ("version", pin_tag.removeprefix("v")),
    ("commit", pin_commit),
    ("digest", pin_digest),
    ("bare digest", pin_digest.removeprefix("sha256:")),
    ("scanner", pin_scanner),
    ("uv", pin_uv),
]:
    mutate("copied pin " + label, "docs/sample.md", lambda _, value=value: value + "\n", "pin-copy")
pin_scanner_version = pin_scanner.split(":", 1)[1].split("@", 1)[0]
result = mutate(
    "test fixture equal to current scanner version",
    "tests/test_upstream_update.py",
    lambda old: old + '\nSCANNER_FIXTURE = "' + pin_scanner_version + '"\n',
    "pin-copy",
)
control(
    "scanner fixture finding names the test file",
    any(line.startswith('"tests/test_upstream_update.py":') and line.endswith("pin-copy")
        for line in result.stdout.splitlines()),
)
mutate(
    "synthetic scanner test fixture",
    "tests/test_upstream_update.py",
    lambda old: old + '\nSCANNER_FIXTURE = "v99.0.0"\n',
    None,
    0,
)
mutate(
    "binary scanner version mismatch",
    "scripts/scan.sh",
    lambda old: re.sub(r"^GITLEAKS_VERSION=.+$", "GITLEAKS_VERSION=v999.0.0", old, flags=re.M),
    "pin-consistency",
)
mutate(
    "unrelated dependency version", "docs/sample.md", lambda _: "dependency==987.654.321\n", None, 0
)
example = next(
    line
    for line in Path("EXPLAINER.md").read_text().splitlines()
    if line.startswith("| Image version |")
)
mutate("allowed format example", "EXPLAINER.md", lambda old: old, None, 0)
mutate(
    "changed allowed example",
    "EXPLAINER.md",
    lambda old: old.replace(example, example + " " + pin_tag + " changed"),
    "pin-copy",
)
mutate(
    "stage cell cannot accept a digest",
    "EXPLAINER.md",
    lambda old: old.replace("| `rust-toolchain` |", "| `rust-toolchain` | " + pin_digest),
    "pin-copy",
)
mutate(
    "literal fetch tag refused",
    "README.md",
    lambda old: re.sub(
        r"^sh scripts/fetch-upstream.sh .+$",
        "sh scripts/fetch-upstream.sh " + pin_tag,
        old,
        flags=re.M,
    ),
    "freshness-steps",
)
mutate(
    "EXPLAINER sed mismatch",
    "EXPLAINER.md",
    lambda old: old.replace("sed -n", "sed -e"),
    "freshness-scanner",
)
scanner_digest = pin_scanner.split("@", 1)[1]
mutate(
    "source scanner digest update needs no document edit",
    "scripts/scan.sh",
    lambda old: old.replace(scanner_digest, "sha256:" + "a" * 64),
    None,
    0,
)
# A copied image pin in an unrelated bake block cannot use the required-copy exception.
mutate(
    "wrong bake block",
    "docker-bake.hcl",
    lambda old: old + '\nvariable "EXTRA" {\n  default = "' + pin_digest + '"\n}\n',
    "pin-copy",
)
# An exact upstream blob is accepted. Any changed byte puts the file in scope.
rules_path = root / "scripts/public-rules.json"
saved_rules = rules_path.read_bytes()
rules = json.loads(saved_rules)
map_path = root / "scripts/upstream-blobs.json"
saved_map = map_path.read_bytes()
manifest = json.loads(saved_map)
data = ("issue " + "987654\n").encode()
sample_blob = hashlib.sha1(b"blob " + str(len(data)).encode() + b"\0" + data).hexdigest()
manifest["blobs"].append({"path": "upstream.txt", "oid": sample_blob})
map_path.write_text(json.dumps(manifest, indent=2) + "\n")
mutate("unchanged upstream blob", "upstream.txt", lambda _: data.decode(), None, 0)
mutate("changed upstream blob", "upstream.txt", lambda _: data.decode() + "\n", "private-tracker")
# Exact upstream exceptions remain line-specific after a local change.
upstream_exception = next(
    item["line_blob"] for item in rules["exceptions"]
    if item["rule"] == "private-tracker"
    and item["reason"] == "Exact upstream session implementation reference; not a private tracker reference."
)
upstream_line = next(
    line for line in Path("openviking/session/session.py").read_text().splitlines(keepends=True)
    if hashlib.sha1(b"blob " + str(len(line.encode())).encode() + b"\0" + line.encode()).hexdigest()
    == upstream_exception
)
mutate("exact upstream reference exception", "sample.txt", lambda _: upstream_line, None, 0)
mutate(
    "changed upstream reference exception fails",
    "sample.txt",
    lambda _: upstream_line.rstrip("\n") + " changed\n",
    "private-tracker",
)
# Exact content exception accepts one line, not the next line or the whole file.
rules["exceptions"].append(
    {"rule": "private-tracker", "line_blob": sample_blob, "reason": "Synthetic test line."}
)
rules_path.write_text(json.dumps(rules, indent=2) + "\n")
mutate("content exception", "sample.txt", lambda _: data.decode(), None, 0)
mutate(
    "exception does not accept another line",
    "sample.txt",
    lambda _: data.decode() + "issue " + "987655\n",
    "private-tracker",
)
rules_path.write_bytes(saved_rules)
map_path.write_bytes(saved_map)
git("add", "scripts/public-rules.json")
# The hook checks the pushed commit, not the checkout. Stub only the scanner.
scan = root / "scripts/scan.sh"
saved_scan = scan.read_bytes()
scan.write_text('#!/bin/sh\nprintf "scan-called\\n" >&2\n')
git("add", "scripts/scan.sh")
git(
    "-c",
    "user.name=test",
    "-c",
    "user.email=test@example.invalid",
    "commit",
    "-qm",
    "scanner fixture",
)
sha = git("rev-parse", "HEAD").decode().strip()
# Use a command stub to test routing independently of the freshness source.
command = root / "scripts/public-check.sh"
saved_command = command.read_bytes()
command.write_text('#!/bin/sh\nprintf "public-called %s %s\\n" "$1" "$2" >&2\nexit 1\n')
zero = "0" * 40
for ref, want in [
    ("refs/heads/portable", 1),
    ("refs/tags/portable-v0.0.0", 1),
    ("refs/heads/topic/sample", 0),
]:
    result = subprocess.run(
        ["sh", "scripts/git-hooks/pre-push", "origin", "unused"],
        input=f"HEAD {sha} {ref} {zero}\n",
        capture_output=True,
        text=True,
    )
    count += 1
    good = result.returncode == want
    if want:
        good = (
            good
            and f"public-called --ref {sha}" in result.stderr
            and result.stderr.index("scan-called") < result.stderr.index("public-called")
        )
    else:
        good = good and "public-called" not in result.stderr
    print(("ok - " if good else "FAIL - ") + "hook routing " + ref)
    if not good:
        failures.append("hook routing")
command.unlink()
result = subprocess.run(
    ["sh", "scripts/git-hooks/pre-push", "origin", "unused"],
    input=f"HEAD {sha} refs/heads/portable {zero}\n",
    capture_output=True,
    text=True,
)
count += 1
if result.returncode == 0:
    failures.append("missing command")
command.write_bytes(saved_command)
scan.write_bytes(saved_scan)
git("add", "scripts/scan.sh")
git(
    "-c",
    "user.name=test",
    "-c",
    "user.email=test@example.invalid",
    "commit",
    "-qm",
    "restore scanner",
)
sha = git("rev-parse", "HEAD").decode().strip()
mutate("working tree finding", "sample.txt", lambda _: "issue " + "987654\n", "private-tracker")
(root / "sample.txt").write_text("issue " + "987654\n")
git("add", "sample.txt")
check("ref reads committed tree rather than checkout", 0, args=("--ref", sha))
(root / "sample.txt").unlink()
git("rm", "-q", "--cached", "sample.txt")
# Snapshot policy must come from that object, never from the caller's checkout.
removed_sha = snapshot(sha, (("docker-compose.yml", b"sample\n"),))
check("ref finds an exact removed path absent from checkout", 1, "tree-removed-path",
      args=("--ref", removed_sha))
path = "sample-removed.txt"
removed_sha = snapshot(sha, (
    (path, b"sample\n"),
    ("scripts/upstream-removed", saved_removed + (path + "\n").encode()),
))
check("ref reads its own removal list", 1, "tree-removed-path", args=("--ref", removed_sha))
removed_path.write_bytes(saved_removed + b"README.md\n")
check("ref ignores checkout removal-list edits", 0, args=("--ref", sha))
removed_path.write_bytes(saved_removed)
owned_rules = json.loads(saved_rules)
owned_rules["workflows"].append(owned)
owned_sha = snapshot(sha, (
    (owned, b"name: owned\n"),
    ("scripts/public-rules.json", (json.dumps(owned_rules, indent=2) + "\n").encode()),
))
check("ref uses its own workflow exception", 0, args=("--ref", owned_sha))
forbidden_sha = snapshot(sha, ((owned, b"name: owned\n"),))
rules_path.write_text(json.dumps(owned_rules, indent=2) + "\n")
check(
    "checkout workflow exception cannot hide ref findings", 1,
    ("tree-removed-path", "tree-github-path"), args=("--ref", forbidden_sha),
)
rules_path.write_bytes(saved_rules)
invalid_sha = snapshot(sha, (("scripts/upstream-removed", b"../invalid\n"),))
check("invalid ref removal list fails closed", 2, args=("--ref", invalid_sha),
      message="invalid removed-path rule in scripts/upstream-removed")
missing_sha = snapshot(sha, remove=("scripts/upstream-removed",))
check("missing ref removal list fails closed", 2, args=("--ref", missing_sha),
      message="pushed tree has no removal list: scripts/upstream-removed")
check("clean ref after removal controls", 0, args=("--ref", sha))
# Real annotated tag object, including the hook's object argument.
git(
    "-c",
    "user.name=test",
    "-c",
    "user.email=test@example.invalid",
    "tag",
    "-a",
    "portable-v0.0.1",
    "-m",
    "release",
    sha,
)
tag_oid = git("rev-parse", "portable-v0.0.1").decode().strip()
assert tag_oid != sha
check("annotated tag object", 0, args=("--ref", tag_oid))
scan.write_text("#!/bin/sh\nexit 0\n")
result = subprocess.run(
    ["sh", "scripts/git-hooks/pre-push", "origin", "unused"],
    input=f"HEAD {missing_sha} refs/heads/portable {zero}\n",
    capture_output=True,
    text=True,
)
control(
    "hook refuses a pushed tree without the removal list",
    result.returncode == 1 and "pushed tree has no removal list" in result.stderr,
)
result = subprocess.run(
    ["sh", "scripts/git-hooks/pre-push", "origin", "unused"],
    input=f"HEAD {tag_oid} refs/tags/portable-v0.0.1 {zero}\n",
    capture_output=True,
    text=True,
)
count += 1
if result.returncode != 0 or "public check" not in result.stderr:
    failures.append("annotated tag hook")
# An older snapshot has no rule file; the current command must refuse it.
old_index = root / "old.index"
old_env = dict(os.environ, GIT_INDEX_FILE=str(old_index))
subprocess.run(["git", "read-tree", sha], env=old_env, check=True)
subprocess.run(
    ["git", "update-index", "--force-remove", "scripts/public-rules.json"], env=old_env, check=True
)
old_tree = subprocess.check_output(["git", "write-tree"], env=old_env).decode().strip()
old_sha = (
    git(
        "-c",
        "user.name=test",
        "-c",
        "user.email=test@example.invalid",
        "commit-tree",
        old_tree,
        "-m",
        "old snapshot",
    )
    .decode()
    .strip()
)
check(
    "old snapshot missing rules",
    2,
    args=("--ref", old_sha),
    message="pushed tree has no rule file: scripts/public-rules.json",
)
result = subprocess.run(
    ["sh", "scripts/git-hooks/pre-push", "origin", "unused"],
    input=f"HEAD {old_sha} refs/heads/portable {zero}\n",
    capture_output=True,
    text=True,
)
count += 1
if result.returncode != 1 or "pushed tree has no rule file" not in result.stderr:
    failures.append("old snapshot hook refusal")
scan.write_bytes(saved_scan)
# Validate generation and the fetched-ref guard without a network fetch.
base_path = root / "scripts/upstream-base"
old_base = base_path.read_bytes()
tag = manifest["tag"]
base_path.write_text("tag\t" + tag + "\t" + sha + "\n")
git("update-ref", "refs/upstream/tags/" + tag, sha)
check(
    "stale map message", 2, message="stale upstream map: tag or commit differs from upstream-base"
)
check("generate upstream map", 0, args=("--write-upstream-map",))
generated = map_path.read_bytes()
check("repeat generator", 0, args=("--write-upstream-map",))
assert generated == map_path.read_bytes()
check("fetched upstream tree agrees with generated map", 0)
map_path.write_bytes(generated + b"\n")
check("map format mismatch", 2, message="stale upstream map: differs from generator output")
map_path.write_bytes(saved_map)
base_path.write_bytes(old_base)
check("wrong upstream ref fails closed", 2)
git("update-ref", "-d", "refs/upstream/tags/" + tag)


def invalid_exception(old):
    rules = json.loads(old)
    rules["exceptions"][0]["reason"] = ""
    return json.dumps(rules, indent=2) + "\n"


mutate(
    "invalid exception message",
    "scripts/public-rules.json",
    invalid_exception,
    None,
    2,
    message="invalid or missing key: rules.exceptions[].reason",
)
mutate(
    "missing rule key message",
    "scripts/public-rules.json",
    lambda old: old.replace('"defaults":', '"unused":'),
    None,
    2,
    message="invalid or missing key: rules.defaults",
)
mutate(
    "unexpected error names class and function",
    "scripts/public_check.py",
    lambda old: old.replace(
        "def validate_rules(rules):",
        'def validate_rules(rules):\n    raise KeyError("hidden-source-value")',
    ),
    None,
    2,
    message="unexpected KeyError in validate_rules",
)
print(str(count) + " controls; " + str(len(failures)) + " failures")
sys.exit(bool(failures))
PY
