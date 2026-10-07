#!/bin/sh
# Read the workflow YAML subset and check commands without executing jobs.
# Python uses only its standard library. No runner, build or network is needed.
set -eu
repo=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd -P)
exec python3 - "$repo" <<'PY'
import copy
import glob
import json
import re
import shlex
import subprocess
import sys
from pathlib import Path

root = Path(sys.argv[1])
paths = (".gitea/workflows/checks.yml", ".github/workflows/checks.yml", ".gitea/workflows/upstream-update.yml")
tracked = {p for p in subprocess.check_output(
    ["git", "-C", str(root), "ls-files", "-z"]).decode().split("\0") if p}


class Invalid(ValueError):
    pass


def require(value, reason):
    if not value:
        raise Invalid(reason)


def scalar(text):
    if text.startswith("'"):
        require(re.fullmatch(r"'(?:[^']|'')*'", text), "invalid single-quoted scalar")
        return text[1:-1].replace("''", "'")
    if text.startswith('"'):
        try:
            value = json.loads(text)
        except ValueError:
            raise Invalid("invalid double-quoted scalar") from None
        require(isinstance(value, str), "double-quoted scalar must be text")
        return value
    # Only the plain scalar forms used by these files belong to the subset.
    require(re.fullmatch(r"[A-Za-z0-9_/][A-Za-z0-9_./@:-]*", text) and not text.endswith(":"),
            "unsupported scalar form")
    if text in ("true", "false"):
        return text == "true"
    if re.fullmatch(r"[0-9]+", text):
        return int(text)
    require(text not in ("null", "Null", "NULL", "yes", "no", "~"), "ambiguous plain scalar")
    return text


def parse(text):
    """Strict indentation-based YAML subset; refuse every unsupported form."""
    lines = text.splitlines()
    rows = []
    i = 0
    while i < len(lines):
        line = lines[i]
        require("\t" not in line and not re.search(r"[\x00-\x08\x0b-\x1f]", line), "control character")
        if not line.strip() or line.lstrip().startswith("#"):
            i += 1
            continue
        indent = len(line) - len(line.lstrip(" "))
        require(indent % 2 == 0, "indentation must use two spaces")
        body = line[indent:]
        # Comments after a scalar are allowed only on pinned action lines.
        if body.startswith("uses: "):
            body = re.sub(r" # v[0-9.]+$", "", body)
        block = None
        if body.endswith(": |"):
            require(body == "run: |", "only run mapping values support literal blocks")
            body = body[:-1].rstrip()
            start = i + 1
            i += 1
            content = []
            while i < len(lines):
                item = lines[i]
                if item.strip() and len(item) - len(item.lstrip(" ")) <= indent:
                    break
                require(not item.strip() or item.startswith(" " * (indent + 2)), "bad literal block indent")
                require("\t" not in item, "tab in literal block")
                content.append(item[indent + 2:] if item.strip() else "")
                i += 1
            require(i > start and any(content), "empty literal block")
            block = "\n".join(content) + "\n"
        else:
            i += 1
        rows.append((indent, body, block))

    def entry(body, block):
        match = re.fullmatch(r"([A-Za-z][A-Za-z0-9_-]*):(?: (.*))?", body)
        require(match, "mapping key or separator outside subset")
        value = block if block is not None else (scalar(match[2]) if match[2] else None)
        return match[1], value

    def collection(index, indent):
        require(index < len(rows) and rows[index][0] == indent, "bad child indentation")
        sequence = rows[index][1].startswith("- ")
        result = [] if sequence else {}
        while index < len(rows) and rows[index][0] == indent:
            _, body, block = rows[index]
            require(body.startswith("- ") == sequence, "mixed mapping and sequence")
            index += 1
            if sequence:
                item = body[2:]
                if re.match(r"[A-Za-z][A-Za-z0-9_-]*:", item):
                    key, value = entry(item, block)
                    require(value is not None, "sequence mapping needs an initial scalar")
                    value = {key: value}
                    if index < len(rows) and rows[index][0] > indent:
                        tail, index = collection(index, indent + 2)
                        require(isinstance(tail, dict) and not value.keys() & tail.keys(), "invalid sequence mapping")
                        value.update(tail)
                else:
                    require(block is None, "literal sequence scalar outside subset")
                    value = scalar(item)
                    require(index == len(rows) or rows[index][0] <= indent, "scalar has children")
                result.append(value)
            else:
                key, value = entry(body, block)
                require(key not in result, "duplicate mapping key")
                if index < len(rows) and rows[index][0] > indent:
                    require(value is None, "scalar has children")
                    value, index = collection(index, indent + 2)
                result[key] = value
        return result, index

    require(rows and rows[0][0] == 0, "missing root mapping")
    result, index = collection(0, 0)
    require(index == len(rows) and isinstance(result, dict), "unconsumed or invalid root")
    return result


DEVELOPMENT_BUILD = "${{ gitea.event_name == 'pull_request' || (gitea.event_name == 'push' && (gitea.ref == 'refs/heads/local-dev' || startsWith(gitea.ref, 'refs/heads/sync/'))) }}"


def development_build_result(expression, event, ref):
    """Evaluate only the event/ref condition subset, never runner expressions."""
    require(expression.startswith("${{ ") and expression.endswith(" }}"), "invalid condition wrapper")
    text = expression[4:-3]
    token_pattern = re.compile(r"\s*(\|\||&&|==|[(),]|'[^']*'|gitea\.(?:event_name|ref)|startsWith)")
    tokens = []
    position = 0
    while position < len(text):
        match = token_pattern.match(text, position)
        require(match, "condition syntax outside subset")
        tokens.append(match[1])
        position = match.end()
    index = 0
    context = {"gitea.event_name": event, "gitea.ref": ref}

    def take():
        nonlocal index
        require(index < len(tokens), "incomplete condition")
        value = tokens[index]
        index += 1
        return value

    def operand():
        token = take()
        if token == "(":
            value = disjunction()
            require(take() == ")", "unclosed condition group")
            return value
        if token == "startsWith":
            require(take() == "(", "missing function arguments")
            value = operand()
            require(take() == ",", "missing function separator")
            prefix = operand()
            require(take() == ")" and isinstance(value, str) and isinstance(prefix, str), "invalid prefix arguments")
            return value.startswith(prefix)
        if token in context:
            return context[token]
        require(token.startswith("'"), "unexpected condition operand")
        return token[1:-1]

    def comparison():
        nonlocal index
        value = operand()
        if index < len(tokens) and tokens[index] == "==":
            index += 1
            other = operand()
            require(isinstance(value, str) and isinstance(other, str), "equality needs string operands")
            value = value == other
        require(isinstance(value, bool), "logical condition needs a boolean")
        return value

    def conjunction():
        nonlocal index
        value = comparison()
        while index < len(tokens) and tokens[index] == "&&":
            index += 1
            other = comparison()
            value = value and other
        return value

    def disjunction():
        nonlocal index
        value = conjunction()
        while index < len(tokens) and tokens[index] == "||":
            index += 1
            other = conjunction()
            value = value or other
        return value

    result = disjunction()
    require(index == len(tokens), "unconsumed condition syntax")
    return result


SCANNER_PULL = 'docker pull "$(sed -n \'s/^GITLEAKS_IMAGE=${GITLEAKS_IMAGE:-\\(.*\\)}$/\\1/p\' scripts/scan.sh)"'
UPSTREAM_FETCH = 'sh scripts/fetch-upstream.sh "$(awk -F \'\\t\' \'$1 == "tag" { print $2 }\' scripts/upstream-base)"'
BASE_LOOKUP = 'base=$(awk -F= \'/^ARG PYTHON_IMAGE=/ { image=$2 } /^ARG PYTHON_DIGEST=/ { digest=$2 } END { print image "@" digest }\' Dockerfile)'
SHELL_TESTS = ["test_setup_remotes.sh", "test_promotion.sh", "test_build_version.sh", "test_public_check.sh", "test_workflows.sh"]
FIXED_LINES = {
    'set -eu',
    'test "$(git rev-parse --is-shallow-repository)" = false',
    'image="openviking-ci:${CI_RUN}-${CI_ATTEMPT}"',
    'trap \'docker image rm "$image" >/dev/null 2>&1 || true\' EXIT',
    'test "$(node -p \'Number(process.versions.node.split(".")[0]) >= 24\')" = true',
    BASE_LOOKUP,
}


def path_exists(path):
    if "*" in path:
        require(any(p in tracked for p in glob.glob(path, root_dir=root)), "run path glob has no tracked file")
    else:
        require(path in tracked or any(p.startswith(path.rstrip("/") + "/") for p in tracked), "run path is not tracked")
        require((root / path).exists(), "run path is absent")


def commands(script):
    require(isinstance(script, str) and script.endswith("\n"), "run must be a literal block")
    require(subprocess.run(["sh", "-n"], input=script, text=True, capture_output=True).returncode == 0,
            "invalid POSIX shell syntax")
    for line in script.splitlines():
        require(line and line == line.strip(), "unsupported blank or indented shell line")
        if line == SCANNER_PULL:
            path_exists("scripts/scan.sh")
            continue
        if line == UPSTREAM_FETCH:
            path_exists("scripts/fetch-upstream.sh")
            path_exists("scripts/upstream-base")
            continue
        if line in FIXED_LINES:
            if line == BASE_LOOKUP:
                path_exists("Dockerfile")
            continue
        # Nothing else may contain shell substitutions, redirection, control
        # operators or assignments. Explicit forms keep shell parsing bounded.
        simple = re.sub(r'^(?:SCAN_REF="\$CI_REF" (?:SCAN_EXCLUDE_UPSTREAM=0 )?|GATEWAY_IMAGE="\$image" |TEST_NAME_PREFIX="openviking-ci-image-\$\{CI_RUN\}-\$\{CI_ATTEMPT\}" |OPENVIKING_IMAGE="\$image" COMPOSE_TEST_PROJECT="openviking-ci-\$\{CI_RUN\}-\$\{CI_ATTEMPT\}" )', '', line)
        require(not re.search(r"[;|&<>`\n]|\$\(", simple), "unsupported shell form")
        tokens = shlex.split(simple)
        if tokens[:1] == ["sh"]:
            require(len(tokens) >= 2, "shell needs a tracked script")
            path_exists(tokens[1])
            allowed = {
                "scripts/setup-remotes.sh": [()],
                "scripts/public-check.sh": [()],
                "scripts/scan.sh": [("tree",), ("history",), ("--level", "fail", "tree"),
                                    ("--level", "fail", "history", "HEAD"),
                                    ("--level", "fail", "image", "$image", "$base")],
                "scripts/build.sh": [("test",), ("gateway",)],
                "tests/test_image.sh": [("$image",)],
                "tests/test_compose.sh": [()],
                "tests/test_scan.sh": [()],
                **{"tests/" + p: [()] for p in SHELL_TESTS},
            }
            require(tuple(tokens[2:]) in allowed.get(tokens[1], []), "script or arguments outside contract")
        elif tokens[:3] == ["python3", "-m", "unittest"]:
            require(len(tokens) == 4 and tokens[3] in
                    ("tests.test_upstream_update", "tests.test_update_propose"), "unapproved Python test")
            path_exists(tokens[3].replace(".", "/") + ".py")
        elif tokens[:1] == ["node"]:
            if len(tokens) == 2:
                require(tokens[1] == "examples/memory-plugin-shared/sync.mjs", "unapproved Node script")
                path_exists(tokens[1])
            else:
                require(len(tokens) == 3 and tokens[1] == "--test" and tokens[2] in
                        ("examples/pi-coding-agent-extension/tests/*.test.mjs", "examples/memory-plugin-shared/*.test.mjs"),
                        "unapproved Node test")
                path_exists(tokens[2])
        else:
            require(tokens == ["npm", "ci", "--prefix", "examples/pi-coding-agent-extension", "--ignore-scripts"],
                    "command outside contract")
            path_exists("examples/pi-coding-agent-extension/package-lock.json")


def validate(path, workflow):
    if path == paths[2]:
        return validate_update(workflow)
    public = path.startswith(".github/")
    require(set(workflow) == {"name", "on", "permissions", "defaults", "env", "jobs"}, "workflow keys outside contract")
    require(workflow["permissions"] == {"contents": "read"}, "permissions must be contents: read only")
    require(workflow["defaults"] == {"run": {"shell": "sh"}}, "default shell must be sh")
    context = "github" if public else "gitea"
    require(workflow["env"] == {
        "CI_REF": "${{ " + context + ".ref }}", "SCAN_NAME_PREFIX": "openviking-ci-",
        "CI_RUN": "${{ " + context + ".run_id }}", "CI_ATTEMPT": "${{ " + context + ".run_attempt }}",
        "SOURCE_URL": "${{ " + context + ".server_url }}/${{ " + context + ".repository }}",
    }, "environment must use safe runner context")
    expected_events = {"push": {"branches": ["portable"], "tags": ["portable-v*"]},
                       "pull_request": None, "workflow_dispatch": None} if public else {
        event: {"branches": ["local-dev", "topic/**", "sync/**"]} for event in ("push", "pull_request")}
    require(workflow["on"] == expected_events, "unexpected workflow triggers")
    require(set(workflow["jobs"]) == {"fast", "build"}, "expected fast and build jobs")
    for name, job in workflow["jobs"].items():
        keys = {"runs-on", "timeout-minutes", "steps"}
        if name == "build":
            keys.add("needs")
            require(job.get("needs") == "fast", "build must need fast")
            keys.add("if")
            if public:
                require(job.get("if") == "${{ github.event_name == 'workflow_dispatch' }}", "public build must be manual only")
            else:
                require(job.get("if") == DEVELOPMENT_BUILD, "development build must filter by event and ref")
        require(set(job) == keys, "job keys outside contract")
        require(job["runs-on"] == ("ubuntu-latest" if public else "kit-amd64"), "unexpected runner label")
        require(job["timeout-minutes"] == (15 if name == "fast" else 60), "unexpected timeout")
        require(isinstance(job["steps"], list) and job["steps"], "steps must be a sequence")
        checkout = 0
        node_setup = 0
        runs = []
        for number, step in enumerate(job["steps"]):
            require(isinstance(step, dict) and isinstance(step.get("name"), str), "step needs a name")
            if "uses" in step:
                require(set(step) == {"name", "uses", "with"}, "action step keys outside contract")
                match = re.fullmatch(r"(?:https://github\.com/)?actions/(checkout|setup-node)@[0-9a-f]{40}", step["uses"])
                require(match, "action needs a full commit hash")
                require(step["uses"].startswith("actions/") == public, "action source must match its server contract")
                if match[1] == "checkout":
                    require(number == 0, "checkout must be the initial step")
                    inputs = {"fetch-depth": 0, "persist-credentials": False}
                    if not public:
                        inputs.update({"github-server-url": "${{ gitea.server_url }}",
                                       "repository": "${{ gitea.repository }}", "ref": "${{ gitea.sha }}"})
                    require(step["with"] == inputs, "checkout must retain full history without credentials")
                    checkout += 1
                else:
                    require(name == "build" and number == len(job["steps"]) - 2 and
                            step["with"] == {"node-version": "24"}, "Node setup must precede the extension test runtime")
                    node_setup += 1
            else:
                require(set(step) == {"name", "run"}, "run step keys outside contract")
                commands(step["run"])
                runs.extend(step["run"].splitlines())
        require(checkout == 1, "job must have exactly one checkout")
        require(node_setup == (1 if name == "build" else 0), "Node setup belongs to build only")
        if name == "fast":
            scans = ['SCAN_REF="$CI_REF" sh scripts/scan.sh --level fail tree',
                     'SCAN_REF="$CI_REF" SCAN_EXCLUDE_UPSTREAM=0 sh scripts/scan.sh --level fail history HEAD'] if public else [
                'SCAN_REF="$CI_REF" sh scripts/scan.sh tree', 'SCAN_REF="$CI_REF" sh scripts/scan.sh history']
            update_tests = [] if public else ["python3 -m unittest tests.test_upstream_update",
                                              "python3 -m unittest tests.test_update_propose"]
            require(runs == ['test "$(git rev-parse --is-shallow-repository)" = false', SCANNER_PULL,
                             *scans, "sh scripts/public-check.sh", *["sh tests/" + p for p in SHELL_TESTS], *update_tests],
                    "fast commands or their order changed")
        else:
            expected = [] if public else ["sh scripts/setup-remotes.sh", UPSTREAM_FETCH]
            expected += [SCANNER_PULL, "sh tests/test_scan.sh", 'set -eu',
                         'image="openviking-ci:${CI_RUN}-${CI_ATTEMPT}"',
                         'trap \'docker image rm "$image" >/dev/null 2>&1 || true\' EXIT',
                         "sh scripts/build.sh test", 'GATEWAY_IMAGE="$image" sh scripts/build.sh gateway',
                         'TEST_NAME_PREFIX="openviking-ci-image-${CI_RUN}-${CI_ATTEMPT}" sh tests/test_image.sh "$image"',
                         'OPENVIKING_IMAGE="$image" COMPOSE_TEST_PROJECT="openviking-ci-${CI_RUN}-${CI_ATTEMPT}" sh tests/test_compose.sh',
                         BASE_LOOKUP, 'sh scripts/scan.sh --level fail image "$image" "$base"',
                         'set -eu', 'test "$(node -p \'Number(process.versions.node.split(".")[0]) >= 24\')" = true',
                         'npm ci --prefix examples/pi-coding-agent-extension --ignore-scripts',
                         'node examples/memory-plugin-shared/sync.mjs',
                         'node --test examples/pi-coding-agent-extension/tests/*.test.mjs',
                         'node --test examples/memory-plugin-shared/*.test.mjs']
            require(runs == expected, "build commands or their order changed")

    # Pins belong to their existing source files, never the workflow text.
    scan = (root / "scripts/scan.sh").read_text()
    scanner = re.search(r"^GITLEAKS_IMAGE=\$\{GITLEAKS_IMAGE:-([^}]+)\}$", scan, re.M)[1]
    base = (root / "scripts/upstream-base").read_text()
    upstream = next(line.split("\t")[1] for line in base.splitlines() if line.startswith("tag\t"))
    serialized = json.dumps(workflow)
    require(scanner not in serialized and upstream not in serialized and "sha256:" not in serialized,
            "workflow copies a source pin")
    require(not re.search(r"secrets\.|(?:git|docker) (?:push|tag)|scripts/promote\.sh|--push|--mirror|--follow-tags|arm64", serialized),
            "workflow has credentials or release mutation")


UPDATE_DETECT = '''set -eu
mkdir -p "$UPDATE_WORK"
code=0
python3 scripts/upstream-update.py detect > "$UPDATE_WORK/detect.json" || code=$?
case "$code" in
  0) echo 'proposed=false' >> "$GITHUB_OUTPUT" ;;
  10) echo 'proposed=true' >> "$GITHUB_OUTPUT" ;;
  *) exit "$code" ;;
esac
'''
UPDATE_PROPOSE = "python3 scripts/update-propose.py\n"


def update_command(script):
    require(script == UPDATE_PROPOSE, "update proposal must call only the tracked dispatcher")
    path_exists("scripts/update-propose.py")
    require(subprocess.run(["sh", "-n"], input=script, text=True, capture_output=True).returncode == 0,
            "invalid update shell syntax")


def validate_update(workflow):
    require(set(workflow) == {"name", "on", "permissions", "defaults", "concurrency", "env", "jobs"}, "update workflow keys changed")
    require(workflow["on"] == {"schedule": [{"cron": "17 3 * * *"}], "workflow_dispatch": None}, "updates need daily and manual triggers only")
    require(workflow["permissions"] == {"contents": "read"}, "detect has read permission only")
    require(workflow["defaults"] == {"run": {"shell": "sh"}}, "update shell must be sh")
    require(workflow["concurrency"] == {"group": "openviking-development-update", "cancel-in-progress": False},
            "update runs must serialize without cancellation")
    require(workflow["env"] == {
        "UPDATE_WORK": "${{ runner.temp }}/openviking-update-${{ gitea.run_id }}-${{ gitea.run_attempt }}",
        "UPDATE_SERVER": "${{ gitea.server_url }}", "UPDATE_REPOSITORY": "${{ gitea.repository }}"}, "update context is not neutral")
    require(set(workflow["jobs"]) == {"detect", "qualify"}, "update jobs changed")
    pins = {"checkout": "34e114876b0b11c390a56381ad16ebd13914f8d5",
            "setup-node": "49933ea5288caeca8642d1e84afbd3f7d6820020",
            "upload-artifact": "c6a366c94c3e0affe28c06c8df20a878f24da3cf",
            "download-artifact": "9bc31d5ccc31df68ecc42ccf4149144866c47d8a"}
    checkout = {"fetch-depth": 0, "persist-credentials": False,
                "github-server-url": "${{ gitea.server_url }}", "repository": "${{ gitea.repository }}", "ref": "${{ gitea.sha }}"}
    for name, job in workflow["jobs"].items():
        keys = {"if", "runs-on", "timeout-minutes", "steps"} | ({"outputs"} if name == "detect" else {"needs", "permissions"})
        require(set(job) == keys, "update job keys changed")
        require(job["runs-on"] == "kit-amd64" and job["timeout-minutes"] == (15 if name == "detect" else 90), "update runner or timeout changed")
        if name == "detect":
            require(job["if"] == "${{ gitea.ref == 'refs/heads/local-dev' }}" and
                    job["outputs"] == {"proposed": "${{ steps.detect.outputs.proposed }}"}, "detection ref or outputs changed")
            actions = [(0, "checkout", checkout), (2, "upload-artifact", {
                "name": "update-detection", "path": "${{ env.UPDATE_WORK }}/detect.json",
                "if-no-files-found": "error", "retention-days": 7})]
            require(len(job["steps"]) == 3, "detection steps changed")
            step = job["steps"][1]
            require(set(step) == {"name", "id", "run"} and step["id"] == "detect" and
                    step["run"] == UPDATE_DETECT, "detection command or exit handling changed")
            path_exists("scripts/upstream-update.py")
            require(subprocess.run(["sh", "-n"], input=step["run"], text=True, capture_output=True).returncode == 0, "invalid detect shell")
        else:
            require(job["if"] == "${{ needs.detect.outputs.proposed == 'true' && gitea.ref == 'refs/heads/local-dev' }}" and
                    job["needs"] == "detect", "qualification gate changed")
            require(job["permissions"] == {"contents": "write", "pull-requests": "write", "issues": "write"}, "qualification permissions widened")
            actions = [(0, "checkout", checkout), (1, "download-artifact", {"name": "update-detection", "path": "${{ env.UPDATE_WORK }}"}),
                       (2, "setup-node", {"node-version": "24"}), (4, "upload-artifact", {
                           "name": "update-evidence", "path": "${{ env.UPDATE_WORK }}", "if-no-files-found": "error", "retention-days": 7})]
            require(len(job["steps"]) == 5, "qualification steps changed")
            step = job["steps"][3]
            require(set(step) == {"name", "env", "run"} and
                    step["env"] == {"UPDATE_TOKEN": "${{ secrets.UPDATE_TOKEN || secrets.GITEA_TOKEN }}"}, "publication token contract changed")
            update_command(step["run"])
        for number, action, inputs in actions:
            step = job["steps"][number]
            require(set(step) == {"name", "uses", "with"} | ({"if"} if action == "upload-artifact" else set()), "update action keys changed")
            require(step["uses"] == "https://github.com/actions/" + action + "@" + pins[action] and step["with"] == inputs,
                    "update action, pin or inputs changed")
            if action == "upload-artifact":
                require(step["if"] == "${{ always() }}", "failure evidence must always upload")
    require("scripts/promote.sh" not in json.dumps(workflow), "update workflow must not promote")


count = 0
failures = []


def check(name, callback, bad=False):
    global count
    count += 1
    try:
        callback()
        passed = not bad
    except (Invalid, KeyError, TypeError, ValueError):
        passed = bad
    print(("ok - " if passed else "FAIL - ") + name)
    if not passed:
        failures.append(name)


workflows = {}
for path in paths:
    text = (root / path).read_text()
    workflow = parse(text)
    workflows[path] = workflow
    check(path + " YAML subset and safety contracts", lambda p=path, w=workflow: validate(p, w))
    uses = re.findall(r"^\s*uses: (.+)$", text, re.M)
    require(uses and all(re.fullmatch(r"(?:https://github\.com/)?actions/(checkout|setup-node|upload-artifact|download-artifact)@[0-9a-f]{40} # v[0-9.]+", item) for item in uses),
            "action pin needs a version comment")

public_path = paths[1]
public = workflows[public_path]


def changed(callback, path=public_path):
    value = copy.deepcopy(workflows[path])
    callback(value)
    validate(path, value)


development_path = paths[0]
development_condition = workflows[development_path]["jobs"]["build"]["if"]
for name, event, ref, expected in [
    ("local-dev push builds", "push", "refs/heads/local-dev", True),
    ("sync push builds", "push", "refs/heads/sync/release", True),
    ("nested sync push builds", "push", "refs/heads/sync/releases/next", True),
    ("topic push skips build", "push", "refs/heads/topic/change", False),
    ("nested topic push skips build", "push", "refs/heads/topic/changes/next", False),
    ("topic pull request builds", "pull_request", "refs/heads/topic/change", True),
    ("sync pull request builds", "pull_request", "refs/heads/sync/release", True),
    ("local-dev pull request builds", "pull_request", "refs/heads/local-dev", True),
    ("preview pull ref builds", "pull_request", "refs/pull/1/merge", True),
    ("sync-like branch skips build", "push", "refs/heads/sync-other", False),
    ("sync tag skips build", "push", "refs/tags/sync/release", False),
    ("non-push sync event skips build", "workflow_dispatch", "refs/heads/sync/release", False),
]:
    check("development build: " + name, lambda e=event, r=ref, wanted=expected: require(
        development_build_result(development_condition, e, r) is wanted, "wrong build decision"))
for name, callback in [
    ("unfiltered development build", lambda w: w["jobs"]["build"].pop("if")),
    ("topic push build enabled", lambda w: w["jobs"]["build"].update({"if": DEVELOPMENT_BUILD.replace(
        "refs/heads/sync/", "refs/heads/topic/")})),
    ("local-dev builds removed", lambda w: w["jobs"]["build"].update({"if": DEVELOPMENT_BUILD.replace(
        "refs/heads/local-dev", "refs/heads/topic/change")})),
    ("pull-request builds removed", lambda w: w["jobs"]["build"].update({"if": "${{ gitea.event_name == 'push' }}"})),
    ("sync builds removed", lambda w: w["jobs"]["build"].update({"if": "${{ gitea.ref == 'refs/heads/local-dev' }}"})),
    ("development path filter", lambda w: w["on"]["push"].update(paths=["Dockerfile"])),
]:
    check("control: " + name, lambda c=callback: changed(c, development_path), bad=True)


controls = [
    ("uses without hash", lambda w: w["jobs"]["fast"]["steps"][0].update(uses="actions/checkout@v4")),
    ("absent run file", lambda w: w["jobs"]["fast"]["steps"][1].update(run="sh tests/missing.sh\n")),
    ("copied scanner pin", lambda w: w["jobs"]["fast"]["steps"][2].update(run="docker pull " + re.search(
        r"^GITLEAKS_IMAGE=\$\{GITLEAKS_IMAGE:-([^}]+)\}$", (root / "scripts/scan.sh").read_text(), re.M)[1] + "\n")),
    ("absent permissions", lambda w: w.pop("permissions")),
    ("write permissions", lambda w: w.update(permissions={"contents": "write"})),
    ("wider permissions", lambda w: w["permissions"].update(packages="write")),
    ("push job", lambda w: w["jobs"]["fast"]["steps"][1].update(run="git push origin HEAD\n")),
    ("tag job", lambda w: w["jobs"]["fast"]["steps"][1].update(run="git tag portable-v1.0.0\n")),
    ("image push", lambda w: w["jobs"]["build"]["steps"][2].update(run="docker push example.invalid/image\n")),
    ("shallow checkout", lambda w: w["jobs"]["fast"]["steps"][0]["with"].update({"fetch-depth": 1})),
    ("persistent checkout credentials", lambda w: w["jobs"]["fast"]["steps"][0]["with"].update({"persist-credentials": True})),
    ("automatic public build", lambda w: w["jobs"]["build"].pop("if")),
    ("secret environment", lambda w: w["env"].update(KEY="${{ secrets.KEY }}")),
    ("copied digest in environment", lambda w: w["env"].update(DIGEST="sha256:" + "a" * 64)),
    ("leaked scanner ref into tests", lambda w: w["env"].update(SCAN_REF="${{ github.ref }}")),
    ("Node setup after tests", lambda w: w["jobs"]["build"]["steps"].append(w["jobs"]["build"]["steps"].pop(-2))),
    ("missing runtime test", lambda w: w["jobs"]["build"]["steps"][3].update(run="sh scripts/build.sh test\n")),
    ("unapproved action", lambda w: w["jobs"]["fast"]["steps"][0].update(uses="other/action@" + "a" * 40)),
    ("nonexistent shell command", lambda w: w["jobs"]["fast"]["steps"][1].update(run="missing-command\n")),
    ("embedded shell mutation", lambda w: w["jobs"]["fast"]["steps"][1].update(run="sh tests/test_promotion.sh; git push origin HEAD\n")),
    ("invalid shell syntax", lambda w: w["jobs"]["fast"]["steps"][1].update(run="sh 'tests/test_promotion.sh\n")),
    ("public fail level removed", lambda w: w["jobs"]["fast"]["steps"][3].update(run="sh scripts/scan.sh tree\nsh scripts/scan.sh history\n")),
    ("upstream exclusion enabled", lambda w: w["jobs"]["fast"]["steps"][3].update(run="sh scripts/scan.sh --level fail tree\nSCAN_EXCLUDE_UPSTREAM=1 sh scripts/scan.sh --level fail history HEAD\n")),
    ("wrong public trigger", lambda w: w["on"]["push"].update(branches=["local-dev"])),
    ("checkout without full hash", lambda w: w["jobs"]["fast"]["steps"][0].update(uses="actions/checkout@" + "a" * 39)),
    ("automatic tag following", lambda w: w["jobs"]["fast"]["steps"][1].update(run="git push --follow-tags\n")),
    ("manual release mutation", lambda w: w["jobs"]["build"]["steps"][2].update(run="sh scripts/promote.sh --version 1.0.0\n")),
    ("arm build", lambda w: w["jobs"]["build"]["steps"][2].update(run="RELEASE_PLATFORMS=linux/arm64 sh scripts/build.sh release\n")),
]
for name, callback in controls:
    check("control: " + name, lambda c=callback: changed(c), bad=True)
for name, expression in [
    ("condition with unknown function", "${{ unknown(gitea.ref) }}"),
    ("condition with missing parenthesis", DEVELOPMENT_BUILD.replace("))) }}", ")) }}")),
    ("condition with extra operand", DEVELOPMENT_BUILD.replace(" }}", " 'extra' }}")),
]:
    check("control: " + name, lambda e=expression: development_build_result(e, "push", "refs/heads/local-dev"), bad=True)
for name, text in [
    ("duplicate YAML key", "name: a\nname: b\n"),
    ("odd YAML indent", "jobs:\n   fast: a\n"),
    ("YAML anchor", "name: &value a\n"),
    ("YAML alias", "name: *value\n"),
    ("flow mapping", "permissions: {contents: read}\n"),
    ("folded scalar", "run: >\n  echo a\n"),
    ("multiple YAML documents", "name: a\n---\nname: b\n"),
    ("unbalanced quote", "name: 'a\n"),
    ("plain reserved indicator", "name: :\n"),
    ("implicit sequence indicator", "name: -\n"),
    ("trailing plain colon", "name: a:\n"),
    ("sequence literal outside subset", "steps:\n  - run: |\n    echo a\n"),
    ("scalar with child", "name: a\n  child: b\n"),
]:
    check("control: " + name, lambda t=text: parse(t), bad=True)
update_path = paths[2]
update_script = workflows[update_path]["jobs"]["qualify"]["steps"][3]["run"]
for name, callback in [
    ("update action without hash", lambda w: w["jobs"]["detect"]["steps"][0].update(uses="https://github.com/actions/checkout@v4")),
    ("update permissions widened", lambda w: w["jobs"]["qualify"]["permissions"].update(packages="write")),
    ("update provider secret", lambda w: w["jobs"]["qualify"]["steps"][3]["env"].update(PROVIDER_KEY="${{ secrets.PROVIDER_KEY }}")),
    ("update force push", lambda w: w["jobs"]["qualify"]["steps"][3].update(run=update_script + 'git push --force\n')),
    ("update portable push", lambda w: w["jobs"]["qualify"]["steps"][3].update(run=update_script + 'git push origin HEAD:refs/heads/portable\n')),
    ("update local-dev push", lambda w: w["jobs"]["qualify"]["steps"][3].update(run=update_script + 'git push origin HEAD:refs/heads/local-dev\n')),
    ("update absent script", lambda w: w["jobs"]["qualify"]["steps"][3].update(run=update_script.replace('scripts/update-propose.py', 'scripts/missing.py'))),
    ("update dispatcher arguments", lambda w: w["jobs"]["qualify"]["steps"][3].update(run=update_script.rstrip() + ' --force\n')),
    ("update checkout stores token", lambda w: w["jobs"]["qualify"]["steps"][0]["with"].update({"persist-credentials": True})),
    ("update no serialization", lambda w: w.pop("concurrency")),
    ("update cancels cleanup", lambda w: w["concurrency"].update({"cancel-in-progress": True})),
    ("update artifact not always", lambda w: w["jobs"]["qualify"]["steps"][-1].pop("if")),
    ("update wrong source branch", lambda w: w["jobs"]["detect"].update({"if": "${{ gitea.ref == 'refs/heads/portable' }}"})),
    ("public upstream test added", lambda w: w["jobs"]["fast"]["steps"][-1].update(
        run=w["jobs"]["fast"]["steps"][-1]["run"] + "python3 -m unittest tests.test_upstream_update\n")),
]:
    path = public_path if name.startswith("public ") else update_path
    check("control: " + name, lambda c=callback, p=path: changed(c, p), bad=True)

rules = json.loads((root / "scripts/public-rules.json").read_text())
check("public workflow allow list is exact", lambda: require(rules["workflows"] == [public_path], "wrong workflow allow list"))
check("promotion scanner prefix is neutral", lambda: require(
    re.search(r"^SCAN_NAME_PREFIX=\$\{SCAN_NAME_PREFIX:-([^}]+)\}$", (root / "scripts/promote.sh").read_text(), re.M)[1]
    == "openviking-promote-", "unexpected promotion scanner default"))
print(str(count) + " workflow controls; " + str(len(failures)) + " failures")
sys.exit(bool(failures))
PY
