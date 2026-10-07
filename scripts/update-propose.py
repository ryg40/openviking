#!/usr/bin/env python3
"""Publish one qualified development update from the workflow's environment inputs."""

import base64
import hashlib
import json
import os
import re
import subprocess
import sys
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path


class Stop(Exception):
    """A fixed, credential-free refusal reason that can be retained as evidence."""


def require(value, reason):
    if not value:
        raise Stop(reason)


def candidate(record):
    kind, name, latest = record["kind"], record["name"], record["latest"]
    if kind == "upstream-tag":
        require(re.fullmatch(r"v[0-9]+\.[0-9]+\.[0-9]+", latest), "invalid upstream tag")
        target, branch = latest, "sync/" + latest
    elif kind == "base-digest":
        require(
            name in ("rust", "node", "python", "frontend")
            and re.fullmatch(r"sha256:[0-9a-f]{64}", latest),
            "invalid digest candidate",
        )
        target, branch = name + "=" + latest, "topic/pin-base-digest"
    elif kind == "scanner":
        match = re.fullmatch(r"[^@\s]+:(v[0-9]+\.[0-9]+\.[0-9]+)@sha256:[0-9a-f]{64}", latest)
        require(match, "invalid scanner candidate")
        target, branch = match[1], "topic/pin-scanner"
    else:
        require(
            kind == "uv" and re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", latest),
            "invalid uv candidate",
        )
        target, branch = latest, "topic/pin-uv"
    identity = json.dumps([kind, name, latest], separators=(",", ":"))
    return {
        "kind": kind,
        "to": target,
        "branch": branch,
        "from": record["pinned"],
        "title": "Update " + kind + " " + target,
        "marker": "<!-- openviking-update:"
        + hashlib.sha256(identity.encode()).hexdigest()
        + " -->",
    }


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        raise Stop("API redirect refused")


def payload(item, qualification, notes):
    attention = bool(
        qualification.get("attention")
        or qualification.get("manual_steps")
        or notes.get("attention")
    )
    summary = {
        "kind": item["kind"],
        "to": item["to"],
        "branch": item["branch"],
        "attention": attention,
        "manual_steps": qualification.get("manual_steps", []),
        "conflicts": qualification.get("conflicts", []),
        "steps": qualification.get("steps", []),
        "notes_steps": notes.get("steps", []),
    }
    body = item["marker"] + "\n\n"
    body += "Qualification records and logs are in the update-evidence job artifact.\n\n"
    body += "```json\n" + json.dumps(summary, indent=2) + "\n```\n"
    if notes:
        brief = {
            key: value
            for key, value in notes.items()
            if key not in ("releases", "steps", "run_directory")
        }
        body += "\n## Upstream changes\n\n```json\n" + json.dumps(brief, indent=2) + "\n```\n"
        for release in notes.get("releases", []):
            body += "\n## " + release["tag"] + "\n\n" + release.get("body", "") + "\n"
    return {"title": ("[attention] " if attention else "") + item["title"], "body": body}


class Dispatcher:
    """Inject process and repository API boundaries for offline tests."""

    def __init__(self, environ=None, process=None, api=None):
        self.environ = os.environ if environ is None else environ
        self.process = subprocess.run if process is None else process
        self.api = api

    def server(self):
        url = self.environ["UPDATE_SERVER"].rstrip("/")
        parsed = urllib.parse.urlsplit(url)
        require(
            parsed.scheme == "https"
            and parsed.hostname
            and not parsed.username
            and not parsed.password
            and not parsed.query
            and not parsed.fragment,
            "invalid server context",
        )
        repo = self.environ["UPDATE_REPOSITORY"]
        require(
            re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", repo),
            "invalid repository context",
        )
        return url, repo

    def token(self):
        token = self.environ.get("UPDATE_TOKEN", "")
        require(token and "\n" not in token and "\r" not in token, "update token is unavailable")
        return token

    def request(self, method, path, body=None):
        if self.api is not None:
            return self.api(method, path, body)
        url, repo = self.server()
        token = self.token()
        data = None if body is None else json.dumps(body).encode()
        req = urllib.request.Request(
            url + "/api/v1/repos/" + repo + path,
            data=data,
            method=method,
            headers={"Authorization": "token " + token, "Content-Type": "application/json"},
        )
        opener = urllib.request.build_opener(urllib.request.ProxyHandler({}), NoRedirect())
        try:
            with opener.open(req, timeout=60) as response:
                return json.load(response)
        except urllib.error.HTTPError as error:
            if method == "GET" and error.code == 404 and path.startswith("/branches/"):
                return None
            raise Stop("API request failed with HTTP " + str(error.code)) from None
        except (OSError, ValueError):
            raise Stop("API request failed") from None

    def open_rows(self, endpoint):
        for page in range(1, 1001):
            rows = self.request("GET", endpoint + "?state=open&limit=50&page=" + str(page))
            require(isinstance(rows, list), "invalid API list")
            yield from rows
            if len(rows) < 50:
                return
        raise Stop("API pagination limit reached")

    def existing(self, item):
        for endpoint in ("/pulls", "/issues"):
            for row in self.open_rows(endpoint):
                title = row.get("title", "").removeprefix("[attention] ")
                if (
                    title == item["title"]
                    or item["marker"] in (row.get("body") or "")
                    or (
                        endpoint == "/pulls"
                        and (row.get("head") or {}).get("ref") == item["branch"]
                    )
                ):
                    return True
        return False

    def occupied(self, item):
        path = "/branches/" + urllib.parse.quote(item["branch"], safe="")
        return self.request("GET", path) is not None

    def invoke(self, argv, output, credentials=False):
        env = {
            "PATH": self.environ.get("PATH", os.defpath),
            "LANG": "C.UTF-8",
            "GIT_CONFIG_NOSYSTEM": "1",
            "GIT_CONFIG_GLOBAL": os.devnull,
            "GIT_TERMINAL_PROMPT": "0",
        }
        if credentials:
            url, _ = self.server()
            auth = base64.b64encode(("x-access-token:" + self.token()).encode()).decode()
            config = [
                ("core.hooksPath", os.devnull),
                ("push.followTags", "false"),
                ("credential.helper", ""),
                ("http.followRedirects", "false"),
                ("http." + url + "/.extraHeader", "Authorization: Basic " + auth),
            ]
        else:
            config = [("core.hooksPath", os.devnull)]
        env["GIT_CONFIG_COUNT"] = str(len(config))
        for index, (key, value) in enumerate(config):
            env["GIT_CONFIG_KEY_" + str(index)] = key
            env["GIT_CONFIG_VALUE_" + str(index)] = value
        result = self.process(argv, env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        # A server can echo credentials. Retain only the authenticated exit code.
        if credentials:
            output.write_text("authenticated Git command exit " + str(result.returncode) + "\n")
        else:
            output.write_bytes(result.stdout)
            output.with_suffix(".stderr.log").write_bytes(result.stderr)
        return result.returncode

    def publish(self, item, qualification, notes, ready, work):
        # Repeat lookups after qualification and before each publication boundary.
        if self.existing(item):
            return "existing"
        body = payload(item, qualification, notes)
        if not ready:
            if self.existing(item):
                return "existing"
            self.request("POST", "/issues", body)
            return "issue"
        require(
            qualification.get("branch") == item["branch"], "bundle branch does not match candidate"
        )
        bundle = Path(qualification["bundle"])
        require(
            bundle.is_file()
            and not bundle.is_symlink()
            and work.resolve() in bundle.resolve().parents,
            "bundle is outside update work directory",
        )
        prerequisite = qualification.get("prerequisite_commit", "")
        require(re.fullmatch(r"[0-9a-f]{40}", prerequisite), "invalid bundle prerequisite")
        if self.occupied(item):
            return "occupied"
        commands = [
            ["git", "cat-file", "-e", prerequisite + "^{commit}"],
            ["git", "bundle", "verify", str(bundle)],
            [
                "git",
                "fetch",
                "--no-tags",
                str(bundle),
                item["branch"] + ":refs/heads/" + item["branch"],
            ],
        ]
        for index, command in enumerate(commands):
            require(
                self.invoke(command, work / ("bundle-" + str(index) + ".log")) == 0,
                "bundle import failed",
            )
        if self.existing(item):
            return "existing"
        url, repo = self.server()
        # One explicit candidate refspec; no force, tag following or release branch.
        require(
            self.invoke(
                [
                    "git",
                    "push",
                    url + "/" + repo + ".git",
                    "refs/heads/" + item["branch"] + ":refs/heads/" + item["branch"],
                ],
                work / "push.log",
                credentials=True,
            )
            == 0,
            "candidate push failed",
        )
        if self.existing(item):
            return "existing"
        self.request("POST", "/pulls", {**body, "head": item["branch"], "base": "local-dev"})
        return "pull_request"

    def dispatch(self, work, outcome):
        detection = json.loads((work / "detect.json").read_text())
        require(
            detection.get("exit_code") == 10 and not detection.get("errors"),
            "detection is not a complete proposal result",
        )
        for record in detection["inputs"]:
            if not record.get("proposed"):
                continue
            item = candidate(record)
            if self.existing(item) or self.occupied(item):
                continue
            outcome["selected"] = item
            head_log = work / "source-head.log"
            require(
                self.invoke(["git", "rev-parse", "HEAD"], head_log) == 0,
                "source commit is unavailable",
            )
            local_log = work / "source-local-dev.log"
            if (
                self.invoke(["git", "rev-parse", "--verify", "refs/heads/local-dev"], local_log)
                != 0
            ):
                require(
                    self.invoke(["git", "branch", "local-dev", "HEAD"], local_log) == 0,
                    "cannot prepare source branch",
                )
                require(
                    self.invoke(["git", "rev-parse", "refs/heads/local-dev"], local_log) == 0,
                    "source branch is unavailable",
                )
            require(
                head_log.read_text() == local_log.read_text(),
                "source branch does not match event checkout",
            )
            code = self.invoke(
                [
                    "python3",
                    "scripts/upstream-update.py",
                    "qualify",
                    "--kind",
                    item["kind"],
                    "--to",
                    item["to"],
                    "--workdir",
                    str(work),
                    "--branch-out",
                    str(work / "bundles"),
                ],
                work / "qualify.json",
            )
            qualification = json.loads((work / "qualify.json").read_text())
            ready = (
                code == 0
                and qualification.get("status") == "passed"
                and bool(qualification.get("bundle"))
            )
            notes = {}
            if ready and item["kind"] == "upstream-tag":
                notes_code = self.invoke(
                    [
                        "python3",
                        "scripts/upstream-update.py",
                        "notes",
                        "--from",
                        item["from"],
                        "--to",
                        item["to"],
                        "--workdir",
                        str(work),
                    ],
                    work / "notes.json",
                )
                notes = json.loads((work / "notes.json").read_text())
                ready = notes_code == 0 and notes.get("status") == "passed"
            outcome["status"] = self.publish(item, qualification, notes, ready, work)
            return 0 if ready else 1
        outcome["status"] = "no_unhandled_candidate"
        return 0

    def main(self):
        outcome = {"status": "error", "selected": None}
        work = None
        try:
            work = Path(self.environ["UPDATE_WORK"])
            code = self.dispatch(work, outcome)
        except Stop as error:
            outcome["error"] = str(error)
            code = 1
        except Exception as error:
            # Other exception text can contain credentials, response bodies or private URLs.
            outcome["error"] = type(error).__name__
            code = 1
        try:
            require(work is not None, "update work directory is unavailable")
            (work / "dispatch.json").write_text(json.dumps(outcome, indent=2) + "\n")
        except Exception as error:
            print("Cannot write dispatch evidence: " + type(error).__name__, file=sys.stderr)
            return 1
        return code


if __name__ == "__main__":
    raise SystemExit(Dispatcher().main())
