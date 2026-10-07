#!/usr/bin/env python3
"""Offline checks for the tracked public checkout; no source values in reports."""

import hashlib
import json
import os
import re
import subprocess
import sys
import traceback
from pathlib import Path, PurePosixPath
from urllib.parse import unquote, urlsplit


class ToolError(Exception):
    pass


def git(*args, optional=False):
    result = subprocess.run(["git", *args], stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
    if result.returncode and not optional:
        raise ToolError("Git command failed")
    return result.stdout if not result.returncode else None


def blob(data):
    return hashlib.sha1(b"blob " + str(len(data)).encode() + b"\0" + data).hexdigest()


def unfence(text):
    # Keep line numbers while excluding examples from Markdown syntax checks.
    fence = None
    output = []
    for line in text.splitlines(keepends=True):
        match = re.match(r"^\s*(`{3,}|~{3,})", line)
        if match:
            mark = match[1]
            if fence is None:
                fence = mark
            elif mark[0] == fence[0] and len(mark) >= len(fence):
                fence = None
            output.append("\n")
        else:
            output.append("\n" if fence else line)
    return "".join(output)


def anchors(text):
    result = set(re.findall(r"<(?:a|h[1-6])\b[^>]*\bid=[\"\x27]([^\"\x27]+)", text, re.I))
    seen = {}
    for match in re.finditer(r"^#{1,6}\s+(.+?)\s*#*\s*$", unfence(text), re.M):
        title = re.sub(r"<[^>]+>", "", match[1]).lower()
        title = re.sub(r"[^\w\- ]", "", title).replace(" ", "-")
        n = seen.get(title, 0)
        seen[title] = n + 1
        result.add(title + (f"-{n}" if n else ""))
    return result


MAP_PATH = "scripts/upstream-blobs.json"
RULES_PATH = "scripts/public-rules.json"
REMOVED_PATH = "scripts/upstream-removed"


def removed_rules(text):
    rules = []
    for line in text.splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        if (
            line.startswith("/")
            or ".." in PurePosixPath(line).parts
            or re.search(r"[^A-Za-z0-9_./-]", line)
            or line.startswith("-")
        ):
            raise ToolError("invalid removed-path rule in scripts/upstream-removed")
        rules.append(line)
    return rules


def matches(path, rule):
    return path.startswith(rule) if rule.endswith("/") else path == rule


def require(value, kind, key):
    if not isinstance(value, kind):
        raise ToolError(f"invalid or missing key: {key}")
    if kind is str and not value.strip():
        raise ToolError(f"invalid or missing key: {key}")
    return value


def field(item, name, kind, prefix):
    require(item, dict, prefix)
    return require(item.get(name), kind, f"{prefix}.{name}")


def pattern(value, key):
    require(value, str, key)
    try:
        re.compile(value)
    except re.error:
        raise ToolError(f"invalid regex key: {key}") from None


def validate_rules(rules):
    require(rules, dict, "rules")
    words = field(rules, "words", list, "rules")
    for item in words:
        field(item, "id", str, "rules.words[]")
        pattern(field(item, "pattern", str, "rules.words[]"), "rules.words[].pattern")
    names = {item["id"] for item in words}
    if len(words) != 4 or names != {
        "private-tracker",
        "work-record",
        "development-process",
        "machine-path",
    }:
        raise ToolError("invalid key: rules.words (the four word classes are required)")
    for item in field(rules, "exceptions", list, "rules"):
        name = field(item, "rule", str, "rules.exceptions[]")
        digest = field(item, "line_blob", str, "rules.exceptions[]")
        field(item, "reason", str, "rules.exceptions[]")
        if name not in names | {"document-code-path"}:
            raise ToolError("invalid key: rules.exceptions[].rule")
        if not re.fullmatch("[0-9a-f]{40}", digest):
            raise ToolError("invalid key: rules.exceptions[].line_blob")
    for item in field(rules, "path_placeholders", list, "rules"):
        field(item, "reason", str, "rules.path_placeholders[]")
        pattern(
            field(item, "pattern", str, "rules.path_placeholders[]"),
            "rules.path_placeholders[].pattern",
        )
    helpers = field(rules, "github_scripts", dict, "rules")
    if not helpers:
        raise ToolError("invalid key: rules.github_scripts (at least one helper required)")
    for path, item in helpers.items():
        if not re.fullmatch(r"\.github/scripts/[^/]+", path):
            raise ToolError("invalid key: rules.github_scripts path")
        mode = field(item, "mode", str, "rules.github_scripts[]")
        digest = field(item, "blob", str, "rules.github_scripts[]")
        if mode not in ("100644", "100755"):
            raise ToolError("invalid key: rules.github_scripts[].mode")
        if not re.fullmatch("[0-9a-f]{40}", digest):
            raise ToolError("invalid key: rules.github_scripts[].blob")
    for path in field(rules, "workflows", list, "rules"):
        require(path, str, "rules.workflows[]")
        if not re.fullmatch(r"\.github/workflows/[^/]+\.ya?ml", path):
            raise ToolError("invalid key: rules.workflows[]")
    contracts = field(rules, "defaults", list, "rules")
    if not contracts:
        raise ToolError("invalid key: rules.defaults (contracts required)")
    for item in contracts:
        field(item, "name", str, "rules.defaults[]")
        field(item, "section", str, "rules.defaults[]")
        if "document" in item:
            pattern(item["document"], "rules.defaults[].document")
        sources = field(item, "sources", list, "rules.defaults[]")
        if not sources:
            raise ToolError("invalid key: rules.defaults[].sources")
        for source in sources:
            field(source, "path", str, "rules.defaults[].sources[]")
            pattern(
                field(source, "pattern", str, "rules.defaults[].sources[]"),
                "rules.defaults[].sources[].pattern",
            )
            if "value" in source:
                require(source["value"], str, "rules.defaults[].sources[].value")


def validate_pins(rules):
    pins = field(rules, "pins", dict, "rules")
    sources = field(pins, "sources", list, "rules.pins")
    if not sources:
        raise ToolError("invalid key: rules.pins.sources")
    names = set()
    for item in sources:
        name = field(item, "id", str, "rules.pins.sources[]")
        field(item, "path", str, "rules.pins.sources[]")
        expression = field(item, "pattern", str, "rules.pins.sources[]")
        pattern(expression, "rules.pins.sources[].pattern")
        if re.compile(expression).groups != 1 or name in names:
            raise ToolError("invalid key: rules.pins.sources[].pattern or id")
        names.add(name)
        if item.get("transform", "") not in ("", "strip-v"):
            raise ToolError("invalid key: rules.pins.sources[].transform")
    for item in field(pins, "allowed", list, "rules.pins"):
        field(item, "path", str, "rules.pins.allowed[]")
        field(item, "reason", str, "rules.pins.allowed[]")
        pattern(field(item, "pattern", str, "rules.pins.allowed[]"), "rules.pins.allowed[].pattern")
        for name in field(item, "values", list, "rules.pins.allowed[]"):
            if not isinstance(name, str) or name not in names:
                raise ToolError("invalid key: rules.pins.allowed[].values")
        if "block" in item:
            pattern(item["block"], "rules.pins.allowed[].block")
        if "line_blob" in item and not re.fullmatch(
            "[0-9a-f]{40}", field(item, "line_blob", str, "rules.pins.allowed[]")
        ):
            raise ToolError("invalid key: rules.pins.allowed[].line_blob")


def upstream_tree(commit):
    if git("cat-file", "-e", f"{commit}^{{commit}}", optional=True) is None:
        raise ToolError("upstream map generator needs the base commit locally")
    base = {}
    for record in git("ls-tree", "-r", "-z", commit).split(b"\0"):
        if record:
            meta, path = record.split(b"\t", 1)
            _mode, kind, oid = meta.decode().split()
            if kind == "blob":
                base[os.fsdecode(path)] = oid
    return base


def render_map(tag, commit, base):
    records = [
        "{",
        '  "tag": ' + json.dumps(tag) + ",",
        '  "commit": ' + json.dumps(commit) + ",",
        '  "blobs": [',
    ]
    blobs = [
        json.dumps({"path": path, "oid": base[path]}, ensure_ascii=True) for path in sorted(base)
    ]
    records.append(",\n".join("    " + item for item in blobs))
    records.extend(["  ]", "}", ""])
    return "\n".join(records).encode()


class Check:
    def __init__(self, ref=None, write_map=False):
        self.ref = ref
        self.root = Path(os.fsdecode(git("rev-parse", "--show-toplevel")).strip())
        os.chdir(self.root)
        self.entries = {}
        records = git("ls-tree", "-r", "-z", ref) if ref else git("ls-files", "--stage", "-z")
        for record in records.split(b"\0"):
            if not record:
                continue
            meta, name = record.split(b"\t", 1)
            if ref:
                mode, kind, oid = meta.decode().split()
                stage = "0"
                if kind != "blob":
                    raise ToolError("unsupported tree entry")
            else:
                mode, oid, stage = meta.decode().split()
            if stage != "0":
                raise ToolError("unmerged index")
            self.entries[os.fsdecode(name)] = (mode, oid)
        self.findings = set()
        self.cache = {}
        if self.content(RULES_PATH) is None:
            if ref:
                raise ToolError("pushed tree has no rule file: scripts/public-rules.json")
            raise ToolError("checkout has no rule file: scripts/public-rules.json")
        self.rules = self.json_input(RULES_PATH)
        validate_rules(self.rules)
        validate_pins(self.rules)
        if self.content(REMOVED_PATH) is None:
            location = "pushed tree" if ref else "checkout"
            raise ToolError(f"{location} has no removal list: {REMOVED_PATH}")
        self.removed = removed_rules(self.text(REMOVED_PATH))
        self.base = self.baseline(write_map)
        if write_map:
            return
        self.scope = set()
        for path in self.entries:
            content = self.content(path)
            if content is not None and blob(content) != self.base.get(path):
                self.scope.add(path)

    def finding(self, path, line, rule):
        self.findings.add((path, line, rule))

    def content(self, path):
        if path in self.cache:
            return self.cache[path]
        if path not in self.entries:
            return None
        if self.ref:
            data = git("cat-file", "blob", self.entries[path][1])
            self.cache[path] = data
            return data
        p = Path(path)
        # Do not follow symlinks, including a symlink in a parent directory.
        if any(parent.is_symlink() for parent in p.parents):
            self.finding(path, 1, "tree-symlink-parent")
            data = None
        elif p.is_symlink():
            data = os.fsencode(os.readlink(p))
        elif p.is_file():
            data = p.read_bytes()
        else:
            self.finding(path, 1, "tree-missing-file")
            data = None
        self.cache[path] = data
        return data

    def text(self, path):
        data = self.content(path)
        if data is None:
            raise ToolError("required tracked input is missing")
        return data.decode("utf-8", errors="replace")

    def json_input(self, path):
        try:
            return json.loads(self.text(path))
        except ValueError:
            label = "rules" if path == RULES_PATH else "upstream map"
            raise ToolError(f"invalid JSON in {label}") from None

    def baseline(self, write_map=False):
        rows = [
            line.split("\t")
            for line in self.text("scripts/upstream-base").splitlines()
            if line and not line.startswith("#")
        ]
        if any(len(row) != 3 or row[0] not in ("tag", "archive", "hit") for row in rows):
            raise ToolError("invalid upstream-base")
        tags = [row[1:] for row in rows if row[0] == "tag"]
        if len(tags) != 1:
            raise ToolError("upstream-base needs one tag")
        tag, commit = tags[0]
        if not re.fullmatch(r"[A-Za-z0-9._@+-]+", tag) or not re.fullmatch(r"[0-9a-f]{40}", commit):
            raise ToolError("invalid upstream tag or commit")
        self.upstream_tag = tag
        ref = git("rev-parse", "--verify", f"refs/upstream/tags/{tag}^{{commit}}", optional=True)
        if ref and ref.decode().strip() != commit:
            raise ToolError("upstream ref differs from upstream-base")
        if not ref and not self.ref:
            committed = git("show", "HEAD:scripts/upstream-base", optional=True)
            if committed is not None and (
                committed != self.content("scripts/upstream-base")
                or git("show", ":scripts/upstream-base") != committed
            ):
                raise ToolError("upstream-base changed without the upstream ref")
        if write_map:
            base = upstream_tree(commit)
            destination = Path(MAP_PATH)
            if destination.is_symlink() or destination.parent.is_symlink():
                raise ToolError("upstream map destination must not be a symlink")
            destination.write_bytes(render_map(tag, commit, base))
            return base
        if self.content(MAP_PATH) is None:
            raise ToolError("missing upstream map: scripts/upstream-blobs.json")
        manifest = self.json_input(MAP_PATH)
        stored_tag = field(manifest, "tag", str, "upstream map")
        stored_commit = field(manifest, "commit", str, "upstream map")
        if stored_tag != tag or stored_commit != commit:
            raise ToolError("stale upstream map: tag or commit differs from upstream-base")
        base = {}
        for item in field(manifest, "blobs", list, "upstream map"):
            path = field(item, "path", str, "upstream map.blobs[]")
            oid = field(item, "oid", str, "upstream map.blobs[]")
            if path in base:
                raise ToolError("duplicate key: upstream map.blobs[].path")
            if not re.fullmatch("[0-9a-f]{40}", oid):
                raise ToolError("invalid key: upstream map.blobs[].oid")
            base[path] = oid
        if git("cat-file", "-e", f"{commit}^{{commit}}", optional=True) is not None:
            generated = render_map(tag, commit, upstream_tree(commit))
            if generated != self.content(MAP_PATH):
                raise ToolError("stale upstream map: differs from generator output")
        return base

    def words(self):
        patterns = [(r["id"], re.compile(r["pattern"], re.I)) for r in self.rules["words"]]
        exceptions = self.rules["exceptions"]
        for path in sorted(self.scope):
            data = self.content(path)
            if b"\0" in data:
                continue
            for number, line in enumerate(data.decode("utf-8", "replace").splitlines(), 1):
                for name, pattern in patterns:
                    if pattern.search(line):
                        digest = blob((line + "\n").encode())
                        if not any(
                            e["rule"] == name and e["line_blob"] == digest for e in exceptions
                        ):
                            self.finding(path, number, name)

    def tree(self):
        for path, (mode, _oid) in self.entries.items():
            if path not in self.rules["workflows"] and any(
                matches(path, rule) for rule in self.removed
            ):
                self.finding(path, 1, "tree-removed-path")
            if (
                path == ".env"
                or path == ".local"
                or path.startswith((".local/", "data/"))
                or path == "data"
            ):
                self.finding(path, 1, "tree-private-state")
            if path.startswith(".github/"):
                expected = self.rules["github_scripts"].get(path)
                if expected:
                    if (
                        mode != expected["mode"]
                        or blob(self.content(path) or b"") != expected["blob"]
                    ):
                        self.finding(path, 1, "tree-upstream-helper")
                elif path not in self.rules["workflows"]:
                    self.finding(path, 1, "tree-github-path")
        for path in self.rules["github_scripts"]:
            if path not in self.entries:
                self.finding(path, 1, "tree-upstream-helper")
        if "LICENSE" not in self.entries or not self.content("LICENSE"):
            self.finding("LICENSE", 1, "tree-license")
        readme = self.text("README.md") if "README.md" in self.entries else ""
        if not re.search(
            r"This repository is a modified copy of \[upstream OpenViking\]"
            r"\(https://github.com/volcengine/OpenViking\)",
            readme,
        ):
            self.finding("README.md", 1, "tree-modified-notice")

    def exists(self, path):
        path = os.path.normpath(path).replace(os.sep, "/")
        return path in self.entries or any(
            p.startswith(path.rstrip("/") + "/") for p in self.entries
        )

    def link(self, source, number, target):
        target = unquote(target.strip("<>"))
        parts = urlsplit(target)
        if parts.scheme or parts.netloc:
            return
        dest = (
            os.path.normpath(os.path.join(os.path.dirname(source), parts.path))
            if parts.path
            else source
        )
        if parts.path.startswith("/"):
            dest = parts.path.lstrip("/")
        if not self.exists(dest):
            self.finding(source, number, "document-link")
        elif parts.fragment and dest.endswith(".md"):
            if parts.fragment not in anchors(self.text(dest)):
                self.finding(source, number, "document-anchor")

    def documents(self):
        for path in sorted(p for p in self.scope if p.endswith(".md")):
            text = unfence(self.text(path))
            # Reference definitions, inline links/images, and HTML links/images.
            definitions = {}
            for m in re.finditer(r"^\s{0,3}\[([^\]]+)\]:\s*(<[^>]+>|\S+)", text, re.M):
                definitions[m[1].casefold()] = m[2]
                self.link(path, text.count("\n", 0, m.start()) + 1, m[2])
            for m in re.finditer(
                r"!?\[[^\]\n]*\]\(\s*(<[^>]+>|[^\s)]+(?:\([^)]*\)[^\s)]*)*)", text
            ):
                self.link(path, text.count("\n", 0, m.start()) + 1, m[1])
            for m in re.finditer(r"!?\[([^\]\n]+)\]\[([^\]\n]*)\]", text):
                key = (m[2] or m[1]).casefold()
                if key not in definitions:
                    self.finding(path, text.count("\n", 0, m.start()) + 1, "document-reference")
            for m in re.finditer(r"\b(?:href|src)=[\"\x27]([^\"\x27]+)[\"\x27]", text):
                self.link(path, text.count("\n", 0, m.start()) + 1, m[1])
            for m in re.finditer(r"(?<!!)\[([^\]\n]+)\](?![(:\[])", text):
                key = m[1].casefold()
                if key in definitions:
                    self.link(path, text.count("\n", 0, m.start()) + 1, definitions[key])
            if path not in ("README.md", "EXPLAINER.md") and not re.fullmatch(
                r"docs/[^/]+\.md", path
            ):
                continue
            if path == "README.md":
                start = text.find("## Portable install kit and quick start")
                end = text.find("\n## ", start + 1)
                text = "\n" * text.count("\n", 0, start) + text[start : end if end >= 0 else None]
            for m in re.finditer(r"(?<!`)`([^`\n]+)`(?!`)", text):
                value = m[1]
                # A standalone path, not a command, URL, image name, or ref.
                if re.search(r"\s|://|[=|:]", value) or value.startswith(("/", "~", "$", "+refs/")):
                    continue
                if not (
                    "/" in value
                    or re.search(r"\.(?:md|sh|py|ya?ml|json|hcl|toml|conf)$", value)
                    or value.startswith(".")
                    or value in ("Dockerfile", "LICENSE")
                ):
                    continue
                if any(re.fullmatch(e["pattern"], value) for e in self.rules["path_placeholders"]):
                    continue
                value = re.sub(r":\d+$", "", value)
                matches = [p for p in self.entries if p.endswith("/" + value)]
                exists = self.exists(value) or (
                    "/" not in value and (len(matches) == 1 or "scripts/" + value in self.entries)
                )
                if not exists and not any(
                    e["rule"] == "document-code-path"
                    and e["line_blob"]
                    == blob((text.splitlines()[text.count("\n", 0, m.start())] + "\n").encode())
                    for e in self.rules["exceptions"]
                ):
                    self.finding(path, text.count("\n", 0, m.start()) + 1, "document-code-path")

    def freshness(self):
        text = self.text("EXPLAINER.md")
        # Each contract selects one table row and extracts its source value.
        for contract in self.rules["defaults"]:
            name = contract["name"]
            section = text.split(contract["section"], 1)
            if len(section) != 2:
                self.finding("EXPLAINER.md", 1, "freshness-default")
                continue
            section_start = len(text) - len(section[1])
            rows = list(
                re.finditer(r"^\| `" + re.escape(name) + r"` \| ([^|]+) \|", section[1], re.M)
            )
            if not rows:
                self.finding("EXPLAINER.md", 1, "freshness-default")
                continue
            row = rows[0]
            number = text.count("\n", 0, section_start + row.start()) + 1
            cell = row[1].strip()
            for source in contract["sources"]:
                match = re.search(source["pattern"], self.text(source["path"]), re.M)
                if not match:
                    self.finding(source["path"], 1, "freshness-source")
                    continue
                value = match[1] if match.lastindex else ""
                if "value" in source and value != source["value"]:
                    self.finding(source["path"], 1, "freshness-source")
                expected = contract.get("document")
                if expected is not None:
                    valid = re.fullmatch(expected, cell) is not None
                else:
                    valid = cell == ("`" + value + "`" if value else "Empty")
                if not valid:
                    self.finding("EXPLAINER.md", number, "freshness-default")
        scan = re.search(
            r"^GITLEAKS_IMAGE=\$\{GITLEAKS_IMAGE:-([^}]+)\}", self.text("scripts/scan.sh"), re.M
        )
        if not scan:
            raise ToolError("scanner default is not recognized")
        self.scanner_commands(scan[1])
        stages = {
            "RUST_IMAGE": "rust-toolchain",
            "NODE_IMAGE": "web-studio-builder",
            "PYTHON_IMAGE": "py-builder",
        }
        for name, stage in stages.items():
            value = re.search(r"^ARG " + name + r"=(\S+)", self.text("Dockerfile"), re.M)
            if not value:
                raise ToolError("base image default is missing")
            expected = f"| `{stage}` | `{name}` (`{value[1]}`) |"
            if not any(line.startswith(expected) for line in text.splitlines()):
                self.finding("EXPLAINER.md", 1, "freshness-image")
        # Grouped build-argument rows and defaults repeated in the bake file.
        dockerfile = self.text("Dockerfile")
        bake = self.text("docker-bake.hcl")
        for name in (
            "RUST_IMAGE",
            "NODE_IMAGE",
            "PYTHON_IMAGE",
            "RUST_DIGEST",
            "NODE_DIGEST",
            "PYTHON_DIGEST",
        ):
            source = re.search(r"^ARG " + name + r"=(\S+)", dockerfile, re.M)
            repeat = re.search(r'variable "' + name + r'" \{\s*default = "([^"]+)"', bake)
            if not source or not repeat or source[1] != repeat[1]:
                self.finding("docker-bake.hcl", 1, "freshness-source")
        grouped = {
            "`RUST_DIGEST`, `NODE_DIGEST`, `PYTHON_DIGEST`": (
                "The `ARG` lines at the top of the `Dockerfile`"
            ),
            "`npm_config_registry`, `PIP_INDEX_URL`, `UV_DEFAULT_INDEX`": "None",
        }
        for names, expected in grouped.items():
            if f"| {names} | {expected} |" not in text:
                self.finding("EXPLAINER.md", 1, "freshness-default")
        for name in ("npm_config_registry", "PIP_INDEX_URL", "UV_DEFAULT_INDEX"):
            if not re.search(r"^ARG " + name + r"$", dockerfile, re.M):
                self.finding("Dockerfile", 1, "freshness-source")
        self.steps(text)

    def steps(self, explainer):
        readme = self.text("README.md")
        section = readme.split("## Portable install kit and quick start", 1)
        if len(section) != 2:
            self.finding("README.md", 1, "freshness-steps")
            return
        quick = re.search(r"```sh\n(.*?)\n```", section[1], re.S)
        steps = re.findall(r"^### Step (\d+)\..*?\n```sh\n(.*?)\n```", explainer, re.M | re.S)
        if not quick or not steps or [int(n) for n, _ in steps] != list(range(1, len(steps) + 1)):
            self.finding("EXPLAINER.md", 1, "freshness-steps")
            return

        def normalize(command):
            command = re.split(r"\s+#", command)[0].strip()
            command = re.sub(r"^SOURCE_URL=<url of the repo>\s+", "", command)
            if command.startswith("sh scripts/fetch-upstream.sh "):
                arg = command[len("sh scripts/fetch-upstream.sh ") :]
                if arg != "\"$(awk -F '\\t' '$1 == \"tag\" { print $2 }' scripts/upstream-base)\"":
                    self.finding("EXPLAINER.md", 1, "freshness-steps")
            return command

        wanted = [
            normalize(c)
            for c in quick[1].splitlines()
            if c.strip() and not c.lstrip().startswith("#")
        ]
        actual = [normalize(c) for _, body in steps for c in body.splitlines() if c.strip()]
        extras = ["openssl rand -hex 32"]
        actual = [c for c in actual if c not in extras]
        if wanted != actual:
            self.finding("EXPLAINER.md", 1, "freshness-steps")

    def scanner_commands(self, expected):
        # Accept only this read-only sed grammar. Never execute document commands.
        grammar = r'''docker pull "\$\(sed -n 's/([^/\n]+)/([^/\n]*)/p' scripts/scan\.sh\)"'''
        for path in ("README.md", "EXPLAINER.md"):
            document = self.text(path)
            if path == "README.md":
                heading = "## Portable install kit and quick start"
            else:
                heading = "### Step 13."
            section = document.split(heading, 1)
            block = (
                re.search(r"```sh\n(.*?)\n```", section[-1], re.S) if len(section) == 2 else None
            )
            pulls = re.findall(r"^docker pull .+$", block[1], re.M) if block else []
            valid = len(pulls) == 1
            if valid:
                command = re.fullmatch(grammar, pulls[0])
                valid = command is not None
            if valid:
                # Convert the limited POSIX basic-regex form to Python syntax.
                # The anchored assignment and one capture are the supported grammar.
                search = r"^GITLEAKS_IMAGE=${GITLEAKS_IMAGE:-\(.*\)}$"
                valid = command[1] == search and command[2] == r"\1"
            if valid:
                extracted = re.findall(
                    r"^GITLEAKS_IMAGE=\$\{GITLEAKS_IMAGE:-(.*)\}$",
                    self.text("scripts/scan.sh"),
                    re.M,
                )
                valid = extracted == [expected]
            if not valid:
                self.finding(path, 1, "freshness-scanner")

    def pins(self):
        pins = self.rules["pins"]
        values = {}
        source_lines = {}
        for item in pins["sources"]:
            matches = list(re.finditer(item["pattern"], self.text(item["path"]), re.M))
            if not matches:
                self.finding(item["path"], 1, "pin-source")
            for match in matches:
                value = match[1]
                if item.get("transform") == "strip-v":
                    value = value.removeprefix("v")
                values.setdefault(item["id"], set()).add(value)
                if value.startswith("sha256:"):
                    values[item["id"]].add(value.removeprefix("sha256:"))
                line = self.text(item["path"]).count("\n", 0, match.start(1)) + 1
                source_lines.setdefault((item["path"], line), set()).add(item["id"])
        binary = re.findall(r"^GITLEAKS_VERSION=(\S+)$", self.text("scripts/scan.sh"), re.M)
        if len(binary) != 1 or set(binary) != values.get("scanner-version"):
            self.finding("scripts/scan.sh", 1, "pin-consistency")
        for path in sorted(self.scope):
            # Derived identity metadata is checked against the generator in baseline().
            if path == MAP_PATH:
                continue
            data = self.content(path)
            if b"\0" in data:
                continue
            for number, line in enumerate(data.decode("utf-8", "replace").splitlines(), 1):
                allowed = set(source_lines.get((path, number), set()))
                for entry in pins["allowed"]:
                    if entry["path"] != path or not re.fullmatch(entry["pattern"], line):
                        continue
                    if "block" in entry:
                        previous = data.decode("utf-8", "replace").splitlines()[number - 2]
                        if number < 2 or not re.fullmatch(entry["block"], previous):
                            continue
                    if "line_blob" in entry and entry["line_blob"] != blob((line + "\n").encode()):
                        continue
                    allowed.update(entry["values"])
                for name, candidates in values.items():
                    if name in allowed:
                        continue
                    for value in candidates:
                        # Do not confuse one version with a longer dependency version.
                        if re.search(r"(?<![\w.])" + re.escape(value) + r"(?![\w.])", line):
                            self.finding(path, number, "pin-copy")
                            break

    def run(self):
        self.words()
        self.pins()
        self.tree()
        self.documents()
        self.freshness()
        for path, line, rule in sorted(self.findings):
            # JSON quoting prevents a file name from injecting terminal controls.
            print(f"{json.dumps(path, ensure_ascii=True)}:{line}: {rule}")
        return int(bool(self.findings))


def main():
    ref = None
    write_map = sys.argv[1:] == ["--write-upstream-map"]
    if len(sys.argv) == 3 and sys.argv[1] == "--ref" and re.fullmatch("[0-9a-f]{40}", sys.argv[2]):
        ref = sys.argv[2]
    elif len(sys.argv) != 1 and not write_map:
        print(
            "usage: sh scripts/public-check.sh [--ref OBJECT | --write-upstream-map]",
            file=sys.stderr,
        )
        return 2
    try:
        check = Check(ref, write_map)
        return 0 if write_map else check.run()
    except ToolError as error:
        print(f"public-check: {error}", file=sys.stderr)
        return 2
    except Exception as error:
        function = traceback.extract_tb(error.__traceback__)[-1].name
        print(f"public-check: unexpected {type(error).__name__} in {function}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
