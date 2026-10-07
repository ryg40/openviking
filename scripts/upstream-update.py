#!/usr/bin/env python3
"""Read update candidates and qualify them in disposable, credential-free clones."""

import argparse
import json
import os
import re
import shutil
import signal
import subprocess
import sys
import tempfile
import time
import urllib.request
import uuid
from pathlib import Path, PurePosixPath

UPSTREAM = "https://github.com/volcengine/OpenViking.git"
RELEASES = "https://api.github.com/repos/volcengine/OpenViking/releases"
SCANNER = "https://github.com/gitleaks/gitleaks.git"
UV = "https://pypi.org/pypi/uv/json"
TAG = re.compile(r"v(\d+)\.(\d+)\.(\d+)\Z")
DIGEST = re.compile(r"sha256:[0-9a-f]{64}\Z")
KINDS = ("upstream-tag", "base-digest", "scanner", "uv")
REASON = "a required earlier step failed"


class UpdateError(Exception):
    pass


def version(tag):
    match = TAG.fullmatch(tag)
    if not match:
        raise UpdateError("expected a stable vMAJOR.MINOR.PATCH tag")
    return tuple(map(int, match.groups()))


def clean_env(home=None):
    # Do not forward keys, Git configuration, Docker auth, proxies or provider URLs.
    env = {"PATH": os.environ.get("PATH", os.defpath), "LANG": "C.UTF-8",
           "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": os.devnull,
           "GIT_TERMINAL_PROMPT": "0", "GIT_CONFIG_COUNT": "1",
           "GIT_CONFIG_KEY_0": "core.hooksPath", "GIT_CONFIG_VALUE_0": os.devnull}
    if home:
        env.update(HOME=str(home), DOCKER_CONFIG=str(home / ".docker"),
                   XDG_CACHE_HOME=str(home / ".cache"))
    else:
        env.update(HOME=os.devnull, DOCKER_CONFIG=os.devnull)
    return env


class Runner:
    """Inject this command boundary in offline tests."""

    def __init__(self, env=None, timeout=3600):
        self.env = env or clean_env()
        self.timeout = timeout

    def run(self, argv, cwd=None, env=None):
        started = time.monotonic()
        try:
            process = subprocess.Popen(argv, cwd=cwd, env={**self.env, **(env or {})},
                                       stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                       start_new_session=True)
            try:
                output, _ = process.communicate(timeout=self.timeout)
                code = process.returncode
            except subprocess.TimeoutExpired:
                os.killpg(process.pid, signal.SIGKILL)
                output, _ = process.communicate()
                code = 124
        except OSError as error:
            output, code = str(error).encode(), 127
        return code, output.decode("utf-8", errors="replace"), round(time.monotonic() - started, 3)


def checked(runner, argv, cwd=None):
    code, output, _ = runner.run(argv, cwd)
    if code:
        raise UpdateError("command failed: " + " ".join(argv[:3]) + f" (exit {code})")
    return output.strip()


def fetch_json(url):
    # No environment proxies, cookies, netrc or authorization headers.
    request = urllib.request.Request(url, headers={"User-Agent": "OpenViking-update"})
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
    with opener.open(request, timeout=60) as response:
        return json.load(response)


def pins(repo):
    dockerfile = (repo / "Dockerfile").read_text()
    args = dict(re.findall(r"^ARG (\w+)=(.+)$", dockerfile, re.M))
    tag = re.search(r"^tag\t([^\t]+)\t([0-9a-f]{40})$",
                    (repo / "scripts/upstream-base").read_text(), re.M)
    scanner = re.search(r"^GITLEAKS_IMAGE=\$\{GITLEAKS_IMAGE:-([^}]+)\}",
                        (repo / "scripts/scan.sh").read_text(), re.M)
    frontend = re.search(r"^# syntax=([^@\s]+)@(sha256:[0-9a-f]{64})$", dockerfile, re.M)
    uv = re.search(r"uv==([0-9]+\.[0-9]+\.[0-9]+)( (?:--hash=sha256:[0-9a-f]{64} ?)+)", dockerfile)
    if not all((tag, scanner, frontend, uv)):
        raise UpdateError("cannot read a pinned input from its source")
    version(tag[1])
    images = {name.lower(): {"image": args[name + "_IMAGE"], "digest": args[name + "_DIGEST"]}
              for name in ("RUST", "NODE", "PYTHON")}
    images["frontend"] = {"image": frontend[1], "digest": frontend[2]}
    if any(not DIGEST.fullmatch(pin["digest"]) for pin in images.values()):
        raise UpdateError("invalid pinned image digest")
    return {"upstream": tag[1], "commit": tag[2], "images": images,
            "scanner": scanner[1], "uv": uv[1]}


def remote_tags(runner, url):
    output = checked(runner, ["git", "ls-remote", "--tags", "--refs", url])
    return sorted({line.split("refs/tags/", 1)[1] for line in output.splitlines()
                   if "refs/tags/" in line})


def image_digest(runner, image):
    output = checked(runner, ["docker", "buildx", "imagetools", "inspect", image])
    match = re.search(r"^Digest:\s*(sha256:[0-9a-f]{64})\s*$", output, re.M)
    if not match:
        raise UpdateError("registry did not return an index digest")
    return match[1]


def detect(repo, runner, fetch=fetch_json):
    pinned = pins(repo)
    records, errors = [], []
    prereleases = []
    def add(kind, name, old, query):
        try:
            new, propose = query()
            records.append({"kind": kind, "name": name, "pinned": old,
                            "latest": new, "differs": old != new, "proposed": propose})
        except (UpdateError, OSError, ValueError) as error:
            errors.append({"kind": kind, "name": name, "error": str(error)})
    try:
        tags = remote_tags(runner, UPSTREAM)
        stable = [tag for tag in tags if TAG.fullmatch(tag)]
        prereleases = [tag for tag in tags if re.match(r"^v\d+\.\d+\.\d+[-.]?[^\d.]", tag)]
        latest = max(stable, key=version)
        add("upstream-tag", "OpenViking", pinned["upstream"],
            lambda: (latest, version(latest) > version(pinned["upstream"])))
    except (UpdateError, ValueError, OSError) as error:
        errors.append({"kind": "upstream-tag", "error": str(error)})
    for name, pin in pinned["images"].items():
        def query(pin=pin):
            value = image_digest(runner, pin["image"])
            return value, value != pin["digest"]
        add("base-digest", name, pin["digest"], query)
    def scanner_query():
        stable = [tag for tag in remote_tags(runner, SCANNER) if TAG.fullmatch(tag)]
        latest = max(stable, key=version)
        image = pinned["scanner"].split(":", 1)[0] + ":" + latest
        value = image + "@" + image_digest(runner, image)
        return value, value != pinned["scanner"]
    add("scanner", "gitleaks", pinned["scanner"], scanner_query)
    def uv_query():
        value = fetch(UV)["info"]["version"]
        return value, version("v" + value) > version("v" + pinned["uv"])
    add("uv", "uv", pinned["uv"], uv_query)
    return {"action": "detect", "inputs": records, "prereleases": prereleases,
            "errors": errors}, 2 if errors else (10 if any(r["proposed"] for r in records) else 0)


def removed_rules(repo):
    rules = []
    for line in (repo / "scripts/upstream-removed").read_text().splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        if (line.startswith("/") or ".." in PurePosixPath(line).parts
                or re.search(r"[^A-Za-z0-9_./-]", line) or line.startswith("-")):
            raise UpdateError("invalid removed-path rule")
        rules.append(line)
    return rules


def matches(path, rule):
    return path.startswith(rule) if rule.endswith("/") else path == rule


def apply_removals(runner, clone, paths, incoming, rules, workflows):
    applied, skipped = [], []
    incoming = set(incoming)
    if not isinstance(workflows, list) or not all(isinstance(p, str) for p in workflows):
        raise UpdateError("public-rules workflows must be a list of paths")
    for path in sorted(set(paths)):
        rule = next((rule for rule in rules if matches(path, rule)), None)
        if not rule:
            continue
        entry = {"path": path, "rule": rule}
        if path in workflows:
            skipped.append({**entry, "reason": "repository-owned workflow"})
        elif path not in incoming:
            skipped.append({**entry, "reason": "path is absent from the incoming upstream tree"})
        else:
            checked(runner, ["git", "rm", "-f", "--", path], clone)
            applied.append({**entry, "action": "delete"})
    return applied, skipped


def sync_paths(repo, upstream_paths):
    text = (repo / "docs/branches.md").read_text()
    heading = re.search(r"^## Sync to a new upstream release\s*$", text, re.M)
    if not heading:
        raise UpdateError("docs/branches.md: cannot find the upstream sync table heading")
    section = re.split(r"^## ", text[heading.end():], maxsplit=1, flags=re.M)[0]
    table = re.search(
        r"^[ \t]*\| Path \| Local change \| Source \|\s*\n"
        r"[ \t]*\|[ :|-]+\|[ \t]*\n((?:[ \t]*\|[^\n]+\|[ \t]*\n)+)",
        section,
        re.M,
    )
    if not table:
        raise UpdateError("docs/branches.md: cannot find the upstream sync table")
    paths = set()
    for row in table[1].splitlines():
        if not row.lstrip().startswith("| `"):
            continue
        cell = row.split("|")[1]
        values = re.findall(r"`([^`]+)`", cell)
        if "`:" in cell:
            paths.update(values[0] + item for item in values[1:])
        else:
            for value in values:
                if value.endswith("/"):
                    paths.update(p for p in upstream_paths if p.startswith(value))
                else:
                    paths.add(value)
    return paths


def safe_workdir(path, repo):
    # Check resolved ancestors too: a symlink must not bypass the checkout boundary.
    path = Path(path).absolute()
    if any(parent.is_symlink() for parent in (path, *path.parents)):
        raise UpdateError("workdir must not use a symlink")
    path = path.resolve()
    if path == repo or path in repo.parents:
        raise UpdateError("workdir must not contain the caller checkout")
    for parent in (path, *path.parents):
        bare_repo = (parent / "HEAD").is_file() and (parent / "objects").is_dir()
        if (parent / ".git").exists() or bare_repo:
            raise UpdateError("workdir must be outside every Git checkout")
    if path.exists() and not path.is_dir():
        raise UpdateError("workdir is not a directory")
    return path


class Run:
    def __init__(self, root, runner):
        self.root, self.runner = root, runner
        self.steps = []
        (root / "logs").mkdir()

    def step(self, name, argv=None, cwd=None, env=None, skip=None):
        log = self.root / "logs" / (f"{len(self.steps):02d}-" + name + ".log")
        if skip:
            code, output, seconds, status = None, skip + "\n", 0, "skipped"
        else:
            code, output, seconds = self.runner.run(argv, cwd, env)
            status = "passed" if code == 0 else "failed"
        log.write_text(output)
        self.steps.append({"name": name, "exit_code": code, "seconds": seconds,
                           "log": str(log), "status": status, **({"reason": skip} if skip else {})})
        return code, output

    def record(self, name, code, output):
        log = self.root / "logs" / (f"{len(self.steps):02d}-" + name + ".log")
        log.write_text(output)
        self.steps.append({"name": name, "exit_code": code, "seconds": 0,
                           "log": str(log), "status": "passed" if code == 0 else "failed"})


def run_root(workdir, repo):
    workdir = safe_workdir(workdir, repo)
    workdir.mkdir(parents=True, exist_ok=True)
    root = workdir / ("openviking-update-" + uuid.uuid4().hex[:12])
    root.mkdir(mode=0o700)
    for directory in ("home", "tmp", "bin"):
        (root / directory).mkdir()
    return root


def execution_env(root):
    env = clean_env(root / "home")
    env.update(TMPDIR=str(root / "tmp"), PYTHONDONTWRITEBYTECODE="1",
               GIT_AUTHOR_NAME="Update qualification", GIT_AUTHOR_EMAIL="update@example.invalid",
               GIT_COMMITTER_NAME="Update qualification",
               GIT_COMMITTER_EMAIL="update@example.invalid")
    return env


def docker_wrapper(root):
    """Name short-lived containers created by older test scripts too."""
    docker = shutil.which("docker")
    if not docker:
        raise UpdateError("docker is not installed")
    script = root / "bin/docker"
    script.write_text("#!/usr/bin/env python3\nimport os, sys, uuid\n"
                      f"docker = {docker!r}\nprefix = {root.name!r}\n"
                      "args = sys.argv[1:]\n"
                      "if args and args[0] in ('run', 'create') and '--name' not in args:\n"
                      "    args[1:1] = ['--name', prefix + '-' + uuid.uuid4().hex[:10]]\n"
                      "os.execv(docker, [docker] + args)\n")
    script.chmod(0o755)


def patch_pin(clone, kind, target, runner, fetch):
    current = pins(clone)
    dockerfile = clone / "Dockerfile"
    text = dockerfile.read_text()
    if kind == "base-digest":
        name, sep, digest = target.partition("=")
        if name not in current["images"] or not sep or not DIGEST.fullmatch(digest):
            raise UpdateError("base-digest target must be rust|node|python|frontend=sha256:HASH")
        old = current["images"][name]["digest"]
        image = current["images"][name]["image"]
        if image_digest(runner, image) != digest:
            raise UpdateError("target digest is not the current digest of the pinned image tag")
        if name == "frontend":
            text = text.replace(image + "@" + old, image + "@" + digest, 1)
        else:
            text = text.replace(
                f"ARG {name.upper()}_DIGEST={old}", f"ARG {name.upper()}_DIGEST={digest}", 1
            )
            bake = clone / "docker-bake.hcl"
            bake.write_text(bake.read_text().replace(old, digest))
        dockerfile.write_text(text)
    elif kind == "scanner":
        version(target)
        image = current["scanner"].split(":", 1)[0] + ":" + target
        new = image + "@" + image_digest(runner, image)
        script = clone / "scripts/scan.sh"
        content = script.read_text().replace(current["scanner"], new)
        content = re.sub(
            r"^GITLEAKS_VERSION=.*$", "GITLEAKS_VERSION=" + target, content, flags=re.M
        )
        script.write_text(content)
    elif kind == "uv":
        version("v" + target)
        wheels = fetch(f"https://pypi.org/pypi/uv/{target}/json")["urls"]
        hashes = sorted({wheel["digests"]["sha256"] for wheel in wheels
                         if wheel["filename"].endswith(".whl")
                         and ("manylinux" in wheel["filename"] or "musllinux" in wheel["filename"])
                         and any(arch in wheel["filename"] for arch in ("x86_64", "aarch64"))})
        if len(hashes) != 4 or any(not re.fullmatch(r"[0-9a-f]{64}", h) for h in hashes):
            raise UpdateError("uv requires four verified Linux wheel hashes")
        requirement = "uv==" + target + " " + " ".join("--hash=sha256:" + h for h in hashes)
        text, count = re.subn(r"uv==[0-9.]+(?: --hash=sha256:[0-9a-f]{64})+", requirement, text)
        if count != 1:
            raise UpdateError("expected one uv requirement")
        dockerfile.write_text(text)


def qualify(repo, args, runner_factory=Runner, fetch=fetch_json):
    result, _ = _qualify(repo, args, runner_factory, fetch)
    return result, result["exit_code"]


def _qualify(repo, args, runner_factory=Runner, fetch=fetch_json):
    if args.kind == "upstream-tag":
        version(args.to)
    elif args.kind == "scanner":
        version(args.to)
    elif args.kind == "uv":
        version("v" + args.to)
    elif not re.fullmatch(r"(rust|node|python|frontend)=sha256:[0-9a-f]{64}", args.to):
        raise UpdateError("invalid base-digest target")
    workdir = safe_workdir(args.workdir, repo)
    branch_out = None
    if args.branch_out:
        branch_out = safe_workdir(args.branch_out, repo)
        if branch_out != workdir and workdir not in branch_out.parents:
            raise UpdateError("branch-out must be inside workdir")
    root = run_root(workdir, repo)
    started = time.monotonic()
    env = execution_env(root)
    runner = runner_factory(env=env, timeout=args.step_timeout)
    run = Run(root, runner)
    clone, prefix = root / "clone", root.name
    image = prefix + ":gateway"
    scanner_image = prefix + ":scanner"
    base_image = prefix + ":base"
    branch = "sync/" + args.to if args.kind == "upstream-tag" else "topic/pin-" + args.kind
    result = {"action": "qualify", "kind": args.kind, "to": args.to, "run_id": prefix,
              "branch": branch, "run_directory": str(root), "steps": run.steps,
              "applied_rules": [], "skipped_rules": [], "conflicts": [], "bundle": None,
              "attention": args.kind == "scanner",
              "manual_steps": []}
    if args.kind == "scanner":
        result["manual_steps"].append(
            "Review the new scanner default rules against .gitleaks.toml and preserve local "
            "differences; follow docs/secret-handling.md before accepting the update."
        )
    builder_started = False
    docker_ready = False
    try:
        code, _ = run.step(
            "clone",
            ["git", "clone", "--no-local", "--no-hardlinks", "--no-checkout",
             "--branch", "local-dev", str(repo), str(clone)],
        )
        if code:
            return finish_qualify(result, run, args, clone, branch_out)
        checked(runner, ["git", "switch", "-c", branch, "origin/local-dev"], clone)
        before = checked(runner, ["git", "rev-parse", "HEAD"], clone)
        result["prerequisite_commit"] = before
        # The policy is read from this command's source, not an incoming release.
        rules = removed_rules(repo)
        if args.kind == "upstream-tag":
            code, _ = run.step("fetch", ["git", "fetch", "--no-tags", UPSTREAM,
                                        f"refs/tags/{args.to}:refs/upstream/tags/{args.to}"], clone)
            if code:
                return finish_qualify(result, run, args, clone, branch_out)
            upstream_ref = "refs/upstream/tags/" + args.to
            code, _ = run.step(
                "merge", ["git", "merge", "--no-ff", "--no-commit", upstream_ref], clone
            )
            conflicts = checked(
                runner, ["git", "diff", "--name-only", "--diff-filter=U"], clone
            ).splitlines()
            upstream_files = checked(
                runner, ["git", "ls-tree", "-r", "--name-only", upstream_ref], clone
            ).splitlines()
            # Read local ownership before the merge; incoming rules cannot remove its protection.
            policy = json.loads(checked(
                runner, ["git", "show", before + ":scripts/public-rules.json"], clone
            ))
            owned_workflows = policy["workflows"]
            paths = checked(runner, ["git", "ls-files"], clone).splitlines()
            applied, skipped = apply_removals(
                runner, clone, paths, upstream_files, rules, owned_workflows
            )
            result["applied_rules"] = applied
            result["skipped_rules"] = skipped
            deleted = {entry["path"] for entry in applied}
            conflicts = [path for path in conflicts if path not in deleted]
            result["conflicts"] = conflicts
            run.record(
                "removed-path-rules", 1 if conflicts else 0,
                json.dumps(
                    {"applied": applied, "skipped": skipped, "conflicts": conflicts}, indent=2
                ),
            )
            if conflicts or (code and not result["applied_rules"]):
                return finish_qualify(result, run, args, clone, branch_out)
            if code:
                # A failed merge command without MERGE_HEAD is not a resolved conflict.
                checked(runner, ["git", "rev-parse", "--verify", "MERGE_HEAD"], clone)
                # Git reports 1 for a merge resolved entirely by the explicit removal rules.
                run.steps[-2]["status"] = "resolved"
            local_changes = checked(
                runner,
                ["git", "diff", "--cached", "--name-only", "--diff-filter=MD", upstream_ref],
                clone,
            ).splitlines()
            known = sync_paths(repo, upstream_files)
            unexpected = [
                path for path in local_changes
                if path not in known and not any(matches(path, rule) for rule in rules)
            ]
            result["sync_table"] = {"local_changes": local_changes, "unlisted": unexpected}
            run.record(
                "sync-table", 1 if unexpected else 0, json.dumps(result["sync_table"], indent=2)
            )
            if unexpected:
                return finish_qualify(result, run, args, clone, branch_out)
            commit = checked(runner, ["git", "rev-parse", upstream_ref + "^{commit}"], clone)
            base = clone / "scripts/upstream-base"
            base.write_text(
                re.sub(r"^tag\t.*$", f"tag\t{args.to}\t{commit}", base.read_text(), flags=re.M)
            )
        else:
            patch_pin(clone, args.kind, args.to, runner, fetch)
            run.record("pin-change", 0, args.kind + " " + args.to + "\n")
        changed = checked(runner, ["git", "diff", "--name-only", before], clone).splitlines()
        docker_wrapper(root)
        docker_ready = True
        runner.env.update(PATH=str(root / "bin") + os.pathsep + env["PATH"],
                          BUILDX_BUILDER=prefix, GATEWAY_IMAGE=image, OPENVIKING_IMAGE=image,
                          TEST_NAME_PREFIX=prefix, SCAN_NAME_PREFIX=prefix + "-",
                          COMPOSE_TEST_PROJECT=prefix, COMPOSE_TEST_DIR=str(root / "compose"),
                          GITLEAKS_IMAGE=scanner_image, SCAN_ENGINE="docker")
        code, _ = run.step("builder", ["docker", "buildx", "create", "--name", prefix,
                                      "--driver", "docker-container"], clone)
        builder_started = code == 0
        scanner_pin = pins(clone)["scanner"]
        scanner_context = root / "scanner"
        scanner_context.mkdir()
        (scanner_context / "Dockerfile").write_text("FROM " + scanner_pin + "\n")
        scanner_code, _ = run.step("scanner-image", ["docker", "buildx", "build", "--load", "-t",
                                                   scanner_image, str(scanner_context)], clone,
                                  skip=None if builder_started else REASON)
        if args.kind == "upstream-tag":
            code, output = run.step("baseline", ["sh", "scripts/scan.sh", "baseline"], clone,
                                    skip=None if scanner_code == 0 else REASON)
            if code == 0:
                # scan.sh writes diagnostics on stderr; Runner combines streams.
                lines = [line for line in output.splitlines() if not line.startswith("scan:")]
                (clone / "scripts/upstream-base").write_text("\n".join(lines) + "\n")
            run.step(
                "upstream-map", ["sh", "scripts/public-check.sh", "--write-upstream-map"], clone,
                skip=None if code == 0 else REASON,
            )
        checked(runner, ["git", "add", "-A"], clone)
        run.step("tree-scan", ["sh", "scripts/scan.sh", "--level", "fail", "tree"], clone,
                 skip=None if scanner_code == 0 else REASON)
        public_code, _ = run.step(
            "public-check-early", ["sh", "scripts/public-check.sh"], clone
        )
        if public_code != 0:
            return finish_qualify(result, run, args, clone, branch_out)
        for test in ("setup_remotes", "promotion", "build_version", "scan", "public_check"):
            # This suite installs hooks in its own isolated repositories.
            # A command-level hooksPath override would prevent that test setup.
            test_env = {"GIT_CONFIG_COUNT": "0"} if test == "scan" else None
            run.step("test-" + test, ["sh", f"tests/test_{test}.sh"], clone,
                     env=test_env,
                     skip=REASON if test == "scan" and scanner_code != 0 else None)
        run.step(
            "test-upstream-update", ["python3", "-m", "unittest", "tests.test_upstream_update"],
            clone,
        )
        run.step("build-test", ["sh", "scripts/build.sh", "test"], clone,
                 skip=None if builder_started else REASON)
        gateway_code, _ = run.step("build-gateway", ["sh", "scripts/build.sh", "gateway"], clone,
                                   skip=None if builder_started else REASON)
        run.step("test-image", ["sh", "tests/test_image.sh", image], clone,
                 skip=None if gateway_code == 0 else REASON)
        run.step("test-compose", ["sh", "tests/test_compose.sh"], clone,
                 skip=None if gateway_code == 0 else REASON)
        base_pin = pins(clone)["images"]["python"]
        base_context = root / "base"
        base_context.mkdir()
        base_reference = base_pin["image"] + "@" + base_pin["digest"]
        (base_context / "Dockerfile").write_text("FROM " + base_reference + "\n")
        base_code, _ = run.step("base-image", ["docker", "buildx", "build", "--load", "-t",
                                             base_image, str(base_context)], clone,
                                skip=None if gateway_code == 0 and scanner_code == 0 else REASON)
        run.step("layer-scan", ["sh", "scripts/scan.sh", "image", image, base_image], clone,
                 skip=None if base_code == 0 else REASON)
        pi_changed = any(
            path.startswith(
                ("examples/pi-coding-agent-extension/", "examples/memory-plugin-shared/")
            )
            for path in changed
        )
        if pi_changed:
            node_code, node_output = run.step("node-version", ["node", "--version"], clone)
            node_version = re.match(r"v(\d+)\.", node_output)
            node_ok = node_code == 0 and node_version is not None and int(node_version[1]) >= 24
            if not node_ok:
                detail = "node not found" if node_code != 0 else node_output.strip()
                run.record("node-requirement", 1, "Pi tests need Node 24 or later; " + detail + "\n")
            prep, _ = run.step(
                "pi-install",
                ["npm", "ci", "--prefix", "examples/pi-coding-agent-extension", "--ignore-scripts"],
                clone, skip=None if node_ok else REASON,
            )
            synced, _ = run.step(
                "pi-sync", ["node", "examples/memory-plugin-shared/sync.mjs"],
                clone, skip=None if prep == 0 else REASON,
            )
            for name, pattern in (
                ("pi-tests", "examples/pi-coding-agent-extension/tests/*.test.mjs"),
                ("shared-tests", "examples/memory-plugin-shared/*.test.mjs"),
            ):
                files = sorted(str(p.relative_to(clone)) for p in clone.glob(pattern))
                run.step(
                    name, ["node", "--test", *files], clone, skip=None if synced == 0 else REASON
                )
        else:
            run.step("pi-tests", skip="the update changes no Pi extension or shared-library path")
        checked(runner, ["git", "add", "-A"], clone)
        run.step("final-tree-scan", ["sh", "scripts/scan.sh", "--level", "fail", "tree"], clone,
                 skip=None if scanner_code == 0 else REASON)
        run.step("public-check", ["sh", "scripts/public-check.sh"], clone)
        return finish_qualify(result, run, args, clone, branch_out)
    except (UpdateError, OSError, ValueError) as error:
        run.record("error", 2, str(error))
        return finish_qualify(result, run, args, clone, branch_out)
    finally:
        if not args.keep:
            if docker_ready:
                if builder_started:
                    cleanup_builder(run, prefix)
                cleanup_docker(run, prefix, (image, scanner_image, base_image))
            shutil.rmtree(clone, ignore_errors=True)
            if clone.exists():
                run.record("cleanup-clone", 1, "could not remove the work clone\n")
            # Keep only logs, the JSON result and an optional bundle.
            for directory in ("home", "tmp", "bin", "scanner", "base", "compose"):
                shutil.rmtree(root / directory, ignore_errors=True)
        if any(step["status"] == "failed" for step in run.steps):
            result.update(status="failed", exit_code=1)
            if result.get("bundle"):
                Path(result["bundle"]).unlink(missing_ok=True)
                result["bundle"] = None
        result["steps"] = run.steps
        result["seconds"] = round(time.monotonic() - started, 3)
        (root / "result.json").write_text(json.dumps(result, indent=2) + "\n")
        if branch_out and result.get("bundle"):
            log_target = branch_out / (result["run_id"] + "-logs")
            shutil.copytree(root / "logs", log_target, dirs_exist_ok=True)
            shutil.copy2(root / "result.json", log_target / "result.json")


def cleanup_builder(run, prefix):
    code, output = run.step("cleanup-builder", ["docker", "buildx", "rm", "--force", prefix])
    removal = run.steps[-1]
    if code == 0 or "context deadline exceeded" not in output:
        return
    # Docker can complete deletion after the client deadline. Prove absence before accepting it.
    absent = True
    for name, command in (
        ("builders", ["docker", "buildx", "ls", "--format", "{{.Name}}"]),
        ("containers", ["docker", "ps", "-a", "--format", "{{.Names}}"]),
        ("volumes", ["docker", "volume", "ls", "--format", "{{.Name}}"]),
    ):
        status, names = run.step("cleanup-builder-verify-" + name, command)
        absent = absent and status == 0 and prefix not in names
    if absent:
        removal["status"] = "resolved"
        removal["reason"] = "Docker removal timed out; subsequent listings prove object absence"


def cleanup_docker(run, prefix, images):
    # Exact names and the unique Compose label bound cleanup to this run.
    code, output = run.step(
        "cleanup-list-containers", ["docker", "ps", "-a", "--format", "{{.Names}}"]
    )
    if code == 0:
        for name in output.splitlines():
            if name.startswith(prefix + "-"):
                run.step("cleanup-container-" + name, ["docker", "rm", "-f", name])
    for kind in ("network", "volume"):
        code, output = run.step(
            "cleanup-list-" + kind,
            ["docker", kind, "ls", "--format", "{{.Name}}", "--filter",
             "label=com.docker.compose.project=" + prefix],
        )
        if code == 0:
            for name in output.splitlines():
                if name.startswith(prefix + "_"):
                    run.step("cleanup-" + kind + "-" + name, ["docker", kind, "rm", name])
    for ref in images:
        exists, _, _ = run.runner.run(["docker", "image", "inspect", ref])
        if exists == 0:
            run.step("cleanup-image-" + ref.split(":")[1], ["docker", "image", "rm", ref])


def finish_qualify(result, run, args, clone, branch_out):
    failed = any(step["status"] == "failed" for step in run.steps)
    if not failed:
        run.step(
            "commit",
            ["git", "commit", "--allow-empty", "-m", "Qualify " + args.kind + " " + args.to],
            clone,
        )
        failed = any(step["status"] == "failed" for step in run.steps)
    if not failed and branch_out:
        branch_out.mkdir(parents=True, exist_ok=True)
        bundle = branch_out / (result["run_id"] + ".bundle")
        code, _ = run.step(
            "bundle", ["git", "bundle", "create", str(bundle),
                       result["prerequisite_commit"] + ".." + result["branch"]],
            clone,
        )
        if code == 0:
            result["bundle"] = str(bundle)
            shutil.copytree(run.root / "logs", branch_out / (result["run_id"] + "-logs"))
        failed = code != 0
    result["status"] = "failed" if failed else "passed"
    result["exit_code"] = 1 if failed else 0
    return result, result["exit_code"]


def config_keys(text):
    # The upstream example is JSON with trailing commas.
    text = re.sub(r",\s*([}\]])", r"\1", text)
    obj = json.loads(text)
    keys = set()
    def walk(value, prefix=""):
        if isinstance(value, dict):
            for key, child in value.items():
                path = prefix + key
                keys.add(path)
                walk(child, path + ".")
        elif isinstance(value, list):
            for child in value:
                walk(child, prefix + "[].")
    walk(obj)
    return keys


def notes(repo, args, runner_factory=Runner, fetch=fetch_json):
    low, high = version(args.from_tag), version(args.to)
    if low >= high:
        raise UpdateError("notes needs an increasing tag range")
    root = run_root(args.workdir, repo)
    started = time.monotonic()
    runner = runner_factory(env=execution_env(root), timeout=args.step_timeout)
    run = Run(root, runner)
    clone = root / "clone"
    result = {"action": "notes", "from": args.from_tag, "to": args.to,
              "run_directory": str(root), "steps": run.steps}
    try:
        checked(runner, ["git", "init", str(clone)])
        for tag in (args.from_tag, args.to):
            code, _ = run.step("fetch-" + tag, ["git", "fetch", "--no-tags", UPSTREAM,
                                               f"refs/tags/{tag}:refs/tags/{tag}"], clone)
            if code:
                raise UpdateError("cannot fetch release range")
        changes = checked(
            runner, ["git", "diff", "--name-only", args.from_tag, args.to], clone
        ).splitlines()
        upstream_files = checked(
            runner, ["git", "ls-tree", "-r", "--name-only", args.to], clone
        ).splitlines()
        known = sync_paths(repo, upstream_files)
        important = {
            "Dockerfile", ".dockerignore", "pyproject.toml", "uv.lock", "examples/ov.conf.example"
        } | known
        relevant = [p for p in changes if p in important or p.startswith("deploy/docker/")
                    or any(matches(p, r) for r in removed_rules(repo))]
        before = config_keys(
            checked(runner, ["git", "show", args.from_tag + ":examples/ov.conf.example"], clone)
        )
        after = config_keys(
            checked(runner, ["git", "show", args.to + ":examples/ov.conf.example"], clone)
        )
        releases = []
        release_started = time.monotonic()
        for page in range(1, 101):
            rows = fetch(RELEASES + f"?per_page=100&page={page}")
            for release in rows:
                tag = release.get("tag_name", "")
                if TAG.fullmatch(tag) and low < version(tag) <= high and not release.get("draft"):
                    releases.append({
                        "tag": tag, "url": release.get("html_url"),
                        "body": release.get("body") or "",
                    })
            if len(rows) < 100:
                break
        else:
            raise UpdateError("release-note pagination exceeded 100 pages")
        if args.to not in {release["tag"] for release in releases}:
            raise UpdateError("target release notes are unavailable")
        run.record("release-notes", 0, json.dumps(releases, indent=2))
        run.steps[-1]["seconds"] = round(time.monotonic() - release_started, 3)
        breaking = any(re.search(r"(?im)^\s*#{1,6}\s+.*breaking", r["body"]) for r in releases)
        result.update(
            releases=sorted(releases, key=lambda r: version(r["tag"])),
            changed_paths=changes, relevant_paths=relevant,
            configuration_keys={"added": sorted(after - before), "removed": sorted(before - after)},
            attention=bool(relevant or breaking), breaking_section=breaking,
            status="passed", exit_code=0, seconds=round(time.monotonic() - started, 3),
        )
        return result, 0
    except (UpdateError, OSError, ValueError) as error:
        run.record("error", 2, str(error))
        result.update(status="error", exit_code=2, error=str(error),
                      seconds=round(time.monotonic() - started, 3))
        return result, 2
    finally:
        if not args.keep:
            shutil.rmtree(clone, ignore_errors=True)
            for directory in ("home", "tmp", "bin"):
                shutil.rmtree(root / directory, ignore_errors=True)
        (root / "result.json").write_text(json.dumps(result, indent=2) + "\n")


class Parser(argparse.ArgumentParser):
    def error(self, message):
        raise UpdateError(message)


def main(argv=None):
    parser = Parser(description=__doc__)
    actions = parser.add_subparsers(dest="action", required=True, parser_class=Parser)
    actions.add_parser("detect")
    qualify_parser = actions.add_parser("qualify")
    qualify_parser.add_argument("--kind", choices=KINDS, required=True)
    qualify_parser.add_argument("--to", required=True)
    qualify_parser.add_argument("--branch-out")
    notes_parser = actions.add_parser("notes")
    notes_parser.add_argument("--from", dest="from_tag", required=True)
    notes_parser.add_argument("--to", required=True)
    for sub in (qualify_parser, notes_parser):
        sub.add_argument("--workdir", required=True)
        sub.add_argument("--keep", action="store_true")
        sub.add_argument("--step-timeout", type=int, default=3600)
    try:
        args = parser.parse_args(argv)
        repo = Path(__file__).resolve().parent.parent
        if getattr(args, "step_timeout", 1) <= 0:
            raise UpdateError("step-timeout must be positive")
        started = time.monotonic()
        if args.action == "detect":
            # Docker metadata tooling can write cache files even for reads.
            with tempfile.TemporaryDirectory(prefix="openviking-update-detect-") as home:
                result, code = detect(repo, Runner(clean_env(Path(home)), 120))
        elif args.action == "qualify":
            result, code = qualify(repo, args)
        else:
            result, code = notes(repo, args)
        result["seconds"] = round(time.monotonic() - started, 3)
        # Qualification cleanup can change the result after the return tuple was built.
        code = result.get("exit_code", code)
        result["exit_code"] = code
    except (UpdateError, OSError, ValueError, KeyError) as error:
        result, code = {"status": "error", "error": str(error), "exit_code": 2}, 2
    print(json.dumps(result, indent=2))
    return code


if __name__ == "__main__":
    sys.exit(main())
