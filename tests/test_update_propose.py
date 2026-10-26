"""Offline dispatcher tests. Run: python3 -m unittest tests.test_update_propose -v."""

import base64
import contextlib
import importlib.util
import io
import json
import os
import subprocess
import tempfile
import unittest
import urllib.error
from pathlib import Path
from unittest.mock import Mock, patch

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("update_propose", ROOT / "scripts/update-propose.py")
propose = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(propose)
TOKEN = "synthetic-token"
SERVER = "https://git.example.invalid"
SECRET_MESSAGE = "response " + TOKEN + " https://user:password@git.example.invalid/private"


def record(kind="upstream-tag", name="OpenViking", latest="v99.2.3", pinned="v99.2.2"):
    return {"kind": kind, "name": name, "latest": latest, "pinned": pinned, "proposed": True}


class Fixture:
    """Replace every process and API call while keeping dispatcher orchestration real."""

    def __init__(self, work, rows=None):
        self.work = work
        self.item = propose.candidate(record())
        self.bundle = work / "candidate.bundle"
        self.bundle.write_text("synthetic bundle")
        self.qualification = {
            "status": "passed",
            "branch": self.item["branch"],
            "bundle": str(self.bundle),
            "prerequisite_commit": "a" * 40,
            "attention": False,
            "manual_steps": [],
            "conflicts": [],
            "steps": [{"name": "merge", "exit_code": 0, "status": "passed"}],
        }
        self.notes = {
            "status": "passed",
            "attention": False,
            "breaking_section": False,
            "releases": [{"tag": "v99.2.3", "body": "Release body"}],
        }
        self.qualify_code = self.notes_code = 0
        self.process_calls = []
        self.api_calls = []
        self.open_rows = {"/pulls": [], "/issues": []}
        self.branches = set()
        self.codes = {}
        self.local_exists = False
        self.local_commit = "a" * 40
        self.remote_commit = "a" * 40
        self.qualified_commit = "b" * 40
        self.merge_commit = "c" * 40
        self.integration_push_code = 0
        self.move_after_push = False
        self.environment = {
            "UPDATE_WORK": str(work),
            "UPDATE_SERVER": SERVER,
            "UPDATE_REPOSITORY": "owner/repo",
            "UPDATE_TOKEN": TOKEN,
            "PROVIDER_KEY": "synthetic-provider",
            "GIT_CONFIG_COUNT": "99",
            "HTTP_PROXY": "https://proxy.example.invalid",
        }
        self.dispatcher = propose.Dispatcher(self.environment, self.process, self.api)
        inputs = rows if rows is not None else [record(), record("uv", "uv", "99.2.3", "99.2.2")]
        (work / "detect.json").write_text(
            json.dumps({"exit_code": 10, "errors": [], "inputs": inputs})
        )

    def process(self, argv, **kwargs):
        self.process_calls.append((argv, kwargs["env"]))
        stdout, stderr, code = b"", b"", 0
        if argv[:2] == ["git", "rev-parse"]:
            code = 1 if "--verify" in argv and not self.local_exists else 0
            commit = "a" * 40 if argv[-1] == "HEAD" else self.local_commit
            if argv[-1] == "refs/heads/" + self.item["branch"]:
                commit = self.qualified_commit
                code = 0
            stdout = (commit + "\n").encode()
        elif argv[:2] == ["git", "branch"]:
            self.local_exists = True
        elif argv[:3] == ["python3", "scripts/upstream-update.py", "qualify"]:
            stdout, code = json.dumps(self.qualification).encode(), self.qualify_code
        elif argv[:3] == ["python3", "scripts/upstream-update.py", "notes"]:
            stdout, code = json.dumps(self.notes).encode(), self.notes_code
        elif argv[:2] == ["git", "commit-tree"]:
            stdout = (self.merge_commit + "\n").encode()
        elif argv[:2] == ["git", "push"]:
            stdout = stderr = SECRET_MESSAGE.encode()
            if argv[-1].endswith(":refs/heads/local-dev"):
                code = self.integration_push_code
                if code == 0:
                    self.remote_commit = "d" * 40 if self.move_after_push else self.merge_commit
        elif argv[:2] not in (
            ["git", "cat-file"], ["git", "bundle"], ["git", "fetch"], ["git", "merge-base"]
        ):
            raise AssertionError(argv)
        code = self.codes.get(tuple(argv[:2]), code)
        return subprocess.CompletedProcess(argv, code, stdout, stderr)

    def api(self, method, path, body=None):
        self.api_calls.append((method, path, body))
        if method == "POST":
            return {}
        if path == "/branches/local-dev":
            return {"commit": {"id": self.remote_commit}}
        if path.startswith("/branches/"):
            return {} if path.split("/branches/", 1)[1] in self.branches else None
        endpoint = path.split("?", 1)[0]
        return self.open_rows[endpoint]

    def outcome(self):
        return json.loads((self.work / "dispatch.json").read_text())

    def commands(self, prefix):
        return [argv for argv, _ in self.process_calls if argv[: len(prefix)] == prefix]

    def posts(self):
        return [(path, body) for method, path, body in self.api_calls if method == "POST"]


class CandidateTests(unittest.TestCase):
    def test_candidate_mapping_and_stable_marker(self):
        for kind, name, latest, target, branch in [
            ("upstream-tag", "OpenViking", "v99.2.3", "v99.2.3", "sync/v99.2.3"),
            (
                "base-digest",
                "python",
                "sha256:" + "a" * 64,
                "python=sha256:" + "a" * 64,
                "topic/pin-base-digest",
            ),
            (
                "scanner",
                "gitleaks",
                "example/scanner:v99.2.3@sha256:" + "b" * 64,
                "v99.2.3",
                "topic/pin-scanner",
            ),
            ("uv", "uv", "99.2.3", "99.2.3", "topic/pin-uv"),
        ]:
            with self.subTest(kind=kind):
                source = record(kind, name, latest)
                item = propose.candidate(source)
                self.assertEqual((item["to"], item["branch"]), (target, branch))
                self.assertRegex(item["marker"], r"^<!-- openviking-update:[0-9a-f]{64} -->$")
                self.assertEqual(item["marker"], propose.candidate(source)["marker"])
                self.assertNotEqual(
                    item["marker"],
                    propose.candidate(
                        {**source, "name": "rust" if kind == "base-digest" else name + "other"}
                    )["marker"],
                )

    def test_refuses_unsafe_targets(self):
        for target in ("--force", "portable", "local-dev", "v99.2.3;git push", "../other"):
            with self.subTest(target=target), self.assertRaises(propose.Stop):
                propose.candidate(record(latest=target))
        for source in [
            record("base-digest", "other", "sha256:" + "a" * 64),
            record("base-digest", "python", "sha256:wrong"),
            record("scanner", "gitleaks", "example/scanner:latest@sha256:" + "a" * 64),
            record("uv", "uv", "99.2.3-rc1"),
            record("unknown", "uv", "99.2.3"),
        ]:
            with self.subTest(source=source), self.assertRaises(propose.Stop):
                propose.candidate(source)


class DispatcherTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.work = Path(temporary.name)
        self.fixture = Fixture(self.work)

    def assert_error(self, expected):
        self.assertEqual(self.fixture.dispatcher.main(), 1)
        self.assertEqual(self.fixture.outcome()["error"], expected)
        evidence = (self.work / "dispatch.json").read_text()
        for secret in (TOKEN, "password", SECRET_MESSAGE):
            self.assertNotIn(secret, evidence)
        self.assertFalse(self.fixture.posts())

    def test_single_candidate_explicit_refspec_notes_and_evidence(self):
        fixture = self.fixture
        self.assertEqual(fixture.dispatcher.main(), 0)
        self.assertEqual(fixture.outcome()["status"], "pull_request")
        self.assertEqual(fixture.outcome()["selected"], fixture.item)
        qualifications = fixture.commands(["python3", "scripts/upstream-update.py", "qualify"])
        self.assertEqual(len(qualifications), 1)
        self.assertEqual(qualifications[0][3:7], ["--kind", "upstream-tag", "--to", "v99.2.3"])
        self.assertEqual(qualifications[0][-2:], ["--branch-out", str(self.work / "bundles")])
        self.assertEqual(
            len(fixture.commands(["python3", "scripts/upstream-update.py", "notes"])), 1
        )
        self.assertEqual(
            fixture.commands(["git", "branch"]), [["git", "branch", "local-dev", "HEAD"]]
        )
        self.assertEqual(
            fixture.commands(["git", "cat-file"]),
            [["git", "cat-file", "-e", "a" * 40 + "^{commit}"]],
        )
        self.assertEqual(
            fixture.commands(["git", "bundle"]), [["git", "bundle", "verify", str(fixture.bundle)]]
        )
        self.assertEqual(
            fixture.commands(["git", "fetch"]),
            [
                [
                    "git",
                    "fetch",
                    "--no-tags",
                    str(fixture.bundle),
                    "sync/v99.2.3:refs/heads/sync/v99.2.3",
                ]
            ],
        )
        self.assertEqual(
            fixture.commands(["git", "push"]),
            [
                [
                    "git",
                    "push",
                    SERVER + "/owner/repo.git",
                    "refs/heads/sync/v99.2.3:refs/heads/sync/v99.2.3",
                ]
            ],
        )
        path, body = fixture.posts()[0]
        self.assertEqual(path, "/pulls")
        self.assertEqual((body["head"], body["base"]), ("sync/v99.2.3", "local-dev"))
        self.assertIn("Release body", body["body"])
        self.assertIn("update-evidence", body["body"])

    def test_automatic_upstream_merge_pins_tree_parents_and_push(self):
        fixture = self.fixture
        fixture.environment["UPDATE_AUTO_MERGE"] = "true"
        self.assertEqual(fixture.dispatcher.main(), 0)
        self.assertEqual(fixture.outcome()["status"], "merged")
        self.assertEqual(fixture.commands(["git", "commit-tree"]), [[
            "git", "commit-tree", "b" * 40 + "^{tree}", "-p", "a" * 40, "-p", "b" * 40,
            "-m", "Merge upstream v99.2.3 into local-dev",
        ]])
        self.assertEqual(fixture.commands(["git", "merge-base"]), [[
            "git", "merge-base", "--is-ancestor", "a" * 40, "b" * 40,
        ]])
        self.assertEqual(fixture.commands(["git", "push"]), [[
            "git", "push", SERVER + "/owner/repo.git", "c" * 40 + ":refs/heads/local-dev",
        ]])
        self.assertFalse(fixture.posts())
        self.assertEqual(fixture.remote_commit, "c" * 40)
        argv, env = next(call for call in fixture.process_calls if call[0][:2] == ["git", "push"])
        self.assertNotIn(TOKEN, " ".join(argv))
        self.assertEqual(env["GIT_COMMITTER_EMAIL"], "update@example.invalid")
        self.assertEqual((self.work / "merge-push.log").read_text(), "authenticated Git command exit 0\n")

    def test_automatic_merge_keeps_attention_and_pin_candidates_as_proposals(self):
        for qualification, notes in [
            ({"attention": True}, {}),
            ({"attention": None}, {}),
            ({"steps": []}, {}),
            ({"manual_steps": None}, {}),
            ({"manual_steps": ["review"]}, {}),
            ({"conflicts": ["Dockerfile"]}, {}),
            ({"steps": [{"status": "failed", "exit_code": 1}]}, {}),
            ({}, {"attention": True}),
            ({}, {"attention": None}),
            ({}, {"breaking_section": True}),
            ({}, {"breaking_section": None}),
        ]:
            with self.subTest(qualification=qualification, notes=notes):
                fixture = Fixture(self.work)
                fixture.environment["UPDATE_AUTO_MERGE"] = "true"
                fixture.qualification.update(qualification)
                fixture.notes.update(notes)
                self.assertEqual(fixture.dispatcher.main(), 0)
                self.assertEqual(fixture.outcome()["status"], "pull_request")
                self.assertFalse(fixture.commands(["git", "commit-tree"]))
        fixture = Fixture(self.work, rows=[record("uv", "uv", "99.2.3", "99.2.2")])
        fixture.environment["UPDATE_AUTO_MERGE"] = "true"
        fixture.qualification["branch"] = "topic/pin-uv"
        self.assertEqual(fixture.dispatcher.main(), 0)
        self.assertEqual(fixture.outcome()["status"], "pull_request")
        self.assertFalse(fixture.commands(["git", "commit-tree"]))

    def test_automatic_merge_refuses_stale_or_unrelated_sources(self):
        self.fixture.environment["UPDATE_AUTO_MERGE"] = "true"
        self.fixture.remote_commit = "d" * 40
        self.assert_error("development branch changed; qualify again")
        self.assertFalse(self.fixture.commands(["git", "commit-tree"]))
        self.assertFalse(self.fixture.commands(["git", "push"]))
        self.fixture.remote_commit = "a" * 40
        self.fixture.qualification["prerequisite_commit"] = "e" * 40
        self.assert_error("qualification source does not match checkout")
        self.assertFalse(self.fixture.commands(["git", "push"]))
        self.fixture.qualification["prerequisite_commit"] = "a" * 40
        self.fixture.codes[("git", "merge-base")] = 1
        self.assert_error("qualified commit does not contain source")
        self.assertFalse(self.fixture.commands(["git", "push"]))

    def test_automatic_merge_push_failure_and_uncertain_response_never_retry(self):
        self.fixture.environment["UPDATE_AUTO_MERGE"] = "true"
        self.fixture.integration_push_code = 1
        self.assert_error("integration push failed; inspect remote before retry")
        self.assertEqual(len(self.fixture.commands(["git", "push"])), 1)
        self.assertNotIn(TOKEN, (self.work / "merge-push.log").read_text())
        fixture = Fixture(self.work)
        fixture.environment["UPDATE_AUTO_MERGE"] = "true"
        fixture.move_after_push = True
        self.assertEqual(fixture.dispatcher.main(), 1)
        self.assertEqual(fixture.outcome()["error"], "integration result is uncertain; inspect remote")
        self.assertEqual(len(fixture.commands(["git", "push"])), 1)
        self.assertFalse(fixture.posts())

    def test_invalid_automatic_merge_setting_refuses_publication(self):
        self.fixture.environment["UPDATE_AUTO_MERGE"] = "yes"
        self.assert_error("invalid automatic merge setting")
        self.assertFalse(self.fixture.commands(["git", "push"]))

    def test_failed_qualification_never_automatically_merges(self):
        self.fixture.environment["UPDATE_AUTO_MERGE"] = "true"
        self.fixture.qualify_code = 1
        self.fixture.qualification["status"] = "failed"
        self.assertEqual(self.fixture.dispatcher.main(), 1)
        self.assertEqual(self.fixture.outcome()["status"], "issue")
        self.assertFalse(self.fixture.commands(["git", "push"]))
        self.assertFalse(self.fixture.commands(["git", "commit-tree"]))

    def test_failure_issue_never_pushes(self):
        self.fixture.qualify_code = 1
        self.fixture.qualification.update(
            status="failed", conflicts=["Dockerfile"], steps=[{"name": "merge", "exit_code": 1}]
        )
        self.assertEqual(self.fixture.dispatcher.main(), 1)
        self.assertEqual(self.fixture.outcome()["status"], "issue")
        self.assertFalse(self.fixture.commands(["git", "push"]))
        self.assertFalse(self.fixture.commands(["python3", "scripts/upstream-update.py", "notes"]))
        path, body = self.fixture.posts()[0]
        self.assertEqual(path, "/issues")
        self.assertIn("Dockerfile", body["body"])
        self.assertIn('"exit_code": 1', body["body"])

    def test_notes_failure_never_creates_pull_request(self):
        self.fixture.notes_code = 2
        self.fixture.notes.update(status="error", steps=[{"name": "release", "exit_code": 2}])
        self.assertEqual(self.fixture.dispatcher.main(), 1)
        self.assertEqual(self.fixture.posts()[0][0], "/issues")
        self.assertIn('"exit_code": 2', self.fixture.posts()[0][1]["body"])
        self.assertFalse(self.fixture.commands(["git", "push"]))

    def test_attention_flags_and_manual_steps(self):
        for qualification, notes in [
            ({"manual_steps": ["review scanner rules"]}, {}),
            ({"attention": True}, {}),
            ({}, {"attention": True}),
        ]:
            with self.subTest(qualification=qualification, notes=notes):
                fixture = Fixture(self.work)
                fixture.qualification.update(qualification)
                fixture.notes.update(notes)
                self.assertEqual(fixture.dispatcher.main(), 0)
                self.assertTrue(fixture.posts()[0][1]["title"].startswith("[attention] "))

    def test_existing_proposal_skips_all_qualification(self):
        self.fixture.open_rows["/issues"] = [
            {"title": self.fixture.item["title"]},
            {"title": propose.candidate(record("uv", "uv", "99.2.3", "99.2.2"))["title"]},
        ]
        self.assertEqual(self.fixture.dispatcher.main(), 0)
        self.assertEqual(self.fixture.outcome()["status"], "no_unhandled_candidate")
        self.assertFalse(self.fixture.process_calls)
        self.assertFalse(self.fixture.posts())

    def test_skips_existing_branch_and_selects_next_candidate(self):
        self.fixture.branches.add("sync%2Fv99.2.3")
        self.fixture.qualification["branch"] = "topic/pin-uv"
        self.assertEqual(self.fixture.dispatcher.main(), 0)
        self.assertEqual(self.fixture.outcome()["selected"]["kind"], "uv")
        self.assertFalse(self.fixture.commands(["python3", "scripts/upstream-update.py", "notes"]))
        self.assertEqual(self.fixture.posts()[0][1]["head"], "topic/pin-uv")

    def test_unproposed_inputs_are_skipped(self):
        fixture = Fixture(self.work, rows=[{**record(), "proposed": False}])
        self.assertEqual(fixture.dispatcher.main(), 0)
        self.assertFalse(fixture.api_calls)
        self.assertFalse(fixture.process_calls)

    def test_duplicate_matches_branch_title_and_marker(self):
        for endpoint, row in [
            ("/pulls", {"head": {"ref": self.fixture.item["branch"]}}),
            ("/issues", {"title": "[attention] " + self.fixture.item["title"]}),
            ("/issues", {"body": self.fixture.item["marker"]}),
        ]:
            with self.subTest(endpoint=endpoint, row=row):
                fixture = Fixture(self.work)
                fixture.open_rows[endpoint] = [row]
                self.assertTrue(fixture.dispatcher.existing(fixture.item))

    def test_duplicate_lookup_reads_later_pages(self):
        pages = []

        def api(method, path, body):
            pages.append(path)
            return [{}] * 50 if path.endswith("page=1") else [{"title": "last"}]

        dispatcher = propose.Dispatcher(api=api)
        self.assertEqual(len(list(dispatcher.open_rows("/issues"))), 51)
        self.assertEqual(len(pages), 2)

    def test_duplicate_checks_at_publication_boundaries(self):
        for stage in (0, 1, 2):
            with self.subTest(stage=stage):
                fixture = Fixture(self.work)
                lookups = 0

                def api(method, path, body, fixture=fixture, stage=stage):
                    nonlocal lookups
                    if path.startswith("/pulls?"):
                        lookups += 1
                        if lookups == stage + 1:
                            return [{"body": fixture.item["marker"]}]
                    return fixture.api(method, path, body)

                fixture.dispatcher.api = api
                status = fixture.dispatcher.publish(
                    fixture.item, fixture.qualification, fixture.notes, True, self.work
                )
                self.assertEqual(status, "existing")
                self.assertFalse(fixture.posts())
                self.assertEqual(bool(fixture.commands(["git", "push"])), stage == 2)

    def test_occupied_branch_prevents_import_and_publication(self):
        self.fixture.branches.add("sync%2Fv99.2.3")
        status = self.fixture.dispatcher.publish(
            self.fixture.item, self.fixture.qualification, {}, True, self.work
        )
        self.assertEqual(status, "occupied")
        self.assertFalse(self.fixture.process_calls)
        self.assertFalse(self.fixture.posts())

    def test_children_drop_credentials_and_ambient_configuration(self):
        self.assertEqual(self.fixture.dispatcher.main(), 0)
        for argv, env in self.fixture.process_calls:
            with self.subTest(argv=argv):
                for name in ("UPDATE_TOKEN", "PROVIDER_KEY", "HTTP_PROXY"):
                    self.assertNotIn(name, env)
                self.assertEqual(env["GIT_CONFIG_GLOBAL"], os.devnull)
                self.assertEqual(env["GIT_CONFIG_NOSYSTEM"], "1")
                config = {
                    env["GIT_CONFIG_KEY_" + str(index)]: env["GIT_CONFIG_VALUE_" + str(index)]
                    for index in range(int(env["GIT_CONFIG_COUNT"]))
                }
                self.assertEqual(config["core.hooksPath"], os.devnull)
                if argv[:2] != ["git", "push"]:
                    self.assertEqual(env["GIT_CONFIG_COUNT"], "1")
                    self.assertNotIn("Authorization", json.dumps(env))

    def test_authenticated_output_exit_code_only(self):
        self.assertEqual(self.fixture.dispatcher.main(), 0)
        self.assertEqual((self.work / "push.log").read_text(), "authenticated Git command exit 0\n")
        self.assertFalse((self.work / "push.stderr.log").exists())
        argv, env = next(
            call for call in self.fixture.process_calls if call[0][:2] == ["git", "push"]
        )
        self.assertNotIn(TOKEN, " ".join(argv))
        config = {
            env["GIT_CONFIG_KEY_" + str(index)]: env["GIT_CONFIG_VALUE_" + str(index)]
            for index in range(int(env["GIT_CONFIG_COUNT"]))
        }
        self.assertEqual(config["push.followTags"], "false")
        self.assertEqual(config["http.followRedirects"], "false")
        self.assertEqual(config["credential.helper"], "")
        auth = base64.b64encode(("x-access-token:" + TOKEN).encode()).decode()
        self.assertEqual(config["http." + SERVER + "/.extraHeader"], "Authorization: Basic " + auth)

    def test_missing_token_retains_fixed_reason(self):
        self.fixture.dispatcher.api = None
        del self.fixture.environment["UPDATE_TOKEN"]
        self.assert_error("update token is unavailable")

    def test_invalid_server_retains_no_user_information(self):
        self.fixture.dispatcher.api = None
        self.fixture.environment["UPDATE_SERVER"] = "https://user:password@git.example.invalid"
        self.assert_error("invalid server context")

    def test_invalid_bundle_path_retains_fixed_reason(self):
        self.fixture.qualification["bundle"] = str(self.work.parent / "absent.bundle")
        self.assert_error("bundle is outside update work directory")
        self.assertFalse(self.fixture.commands(["git", "push"]))

    def test_symlink_bundle_is_refused(self):
        link = self.work / "link.bundle"
        link.symlink_to(self.fixture.bundle)
        self.fixture.qualification["bundle"] = str(link)
        self.assert_error("bundle is outside update work directory")

    def test_bundle_verify_failure_retains_fixed_reason(self):
        self.fixture.codes[("git", "bundle")] = 1
        self.assert_error("bundle import failed")
        self.assertFalse(self.fixture.commands(["git", "fetch"]))
        self.assertFalse(self.fixture.commands(["git", "push"]))

    def test_invalid_bundle_branch_and_prerequisite(self):
        for key, value, reason in [
            ("branch", "portable", "bundle branch does not match candidate"),
            ("prerequisite_commit", "wrong", "invalid bundle prerequisite"),
        ]:
            with self.subTest(key=key):
                self.fixture.qualification[key] = value
                self.assert_error(reason)
                self.fixture.qualification[key] = (
                    self.fixture.item["branch"] if key == "branch" else "a" * 40
                )

    def test_source_mismatch_retains_fixed_reason(self):
        self.fixture.local_exists = True
        self.fixture.local_commit = "b" * 40
        self.assert_error("source branch does not match event checkout")
        self.assertFalse(
            self.fixture.commands(["python3", "scripts/upstream-update.py", "qualify"])
        )

    def test_push_failure_retains_exit_code_only(self):
        self.fixture.codes[("git", "push")] = 1
        self.assert_error("candidate push failed")
        self.assertEqual((self.work / "push.log").read_text(), "authenticated Git command exit 1\n")
        self.assertFalse((self.work / "push.stderr.log").exists())

    def test_other_exception_retains_only_class(self):
        for error in (
            OSError(SECRET_MESSAGE),
            ValueError(SECRET_MESSAGE),
            KeyError(SECRET_MESSAGE),
        ):
            with self.subTest(error=type(error).__name__):

                def process(argv, error=error, **kwargs):
                    raise error

                self.fixture.dispatcher.process = process
                self.assert_error(type(error).__name__)

    def test_invalid_json_retains_only_class(self):
        (self.work / "detect.json").write_text(SECRET_MESSAGE)
        self.assert_error("JSONDecodeError")

    def test_incomplete_detection_retains_fixed_reason(self):
        (self.work / "detect.json").write_text(
            json.dumps({"exit_code": 2, "errors": [SECRET_MESSAGE]})
        )
        self.assert_error("detection is not a complete proposal result")

    def test_failure_issue_api_error_retains_reason(self):
        self.fixture.qualify_code = 1

        def api(method, path, body):
            if method == "POST":
                raise propose.Stop("API request failed with HTTP 403")
            return self.fixture.api(method, path, body)

        self.fixture.dispatcher.api = api
        self.assert_error("API request failed with HTTP 403")
        self.assertFalse(self.fixture.commands(["git", "push"]))

    def test_unwritable_evidence_fails_without_exception_text(self):
        fixture = Fixture(self.work, rows=[])
        (self.work / "dispatch.json").mkdir()
        stderr = io.StringIO()
        with contextlib.redirect_stderr(stderr):
            self.assertEqual(fixture.dispatcher.main(), 1)
        self.assertEqual(stderr.getvalue(), "Cannot write dispatch evidence: IsADirectoryError\n")


class IntegrationTests(unittest.TestCase):
    """Real Git proves merge ancestry and the non-forced concurrent-push boundary."""

    def test_merge_tree_and_concurrent_base_update(self):
        for race in (False, True):
            with self.subTest(race=race), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                repo, remote, work = root / "repo", root / "remote.git", root / "evidence"
                repo.mkdir()
                work.mkdir()
                env = {
                    "PATH": os.environ.get("PATH", os.defpath),
                    "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": os.devnull,
                    "GIT_AUTHOR_NAME": "test", "GIT_AUTHOR_EMAIL": "test@example.invalid",
                    "GIT_COMMITTER_NAME": "test", "GIT_COMMITTER_EMAIL": "test@example.invalid",
                    "GIT_CONFIG_COUNT": "1", "GIT_CONFIG_KEY_0": "core.hooksPath",
                    "GIT_CONFIG_VALUE_0": os.devnull,
                }

                def git(*args, cwd=repo):
                    return subprocess.run(
                        ["git", *args], cwd=cwd, env=env, check=True,
                        stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                    ).stdout.decode().strip()

                git("init", "-b", "local-dev")
                (repo / "value.txt").write_text("base\n")
                git("add", ".")
                git("commit", "-m", "base")
                base = git("rev-parse", "HEAD")
                git("clone", "--bare", str(repo), str(remote))
                git("switch", "-c", "sync/v99.2.3")
                (repo / "value.txt").write_text("qualified\n")
                git("commit", "-am", "qualified")
                tip = git("rev-parse", "HEAD")
                rival = git("commit-tree", base + "^{tree}", "-p", base, "-m", "concurrent")
                fixture = Fixture(work)
                fixture.qualification["prerequisite_commit"] = base
                (work / "source-head.log").write_text(base + "\n")
                pushes = []

                def process(argv, **kwargs):
                    if argv[:2] == ["git", "push"]:
                        pushes.append(argv)
                        if race:
                            git("fetch", "--no-tags", str(repo), rival, cwd=remote)
                            git("update-ref", "refs/heads/local-dev", rival, base, cwd=remote)
                        argv = [*argv[:2], str(remote), *argv[3:]]
                    return subprocess.run(argv, cwd=repo, **kwargs)

                def api(method, path, body):
                    self.assertEqual((method, path), ("GET", "/branches/local-dev"))
                    return {"commit": {"id": git("rev-parse", "refs/heads/local-dev", cwd=remote)}}

                dispatcher = propose.Dispatcher(fixture.environment, process, api)
                if race:
                    with self.assertRaisesRegex(propose.Stop, "integration push failed"):
                        dispatcher.merge_upstream(fixture.item, fixture.qualification, work)
                    self.assertEqual(git("rev-parse", "local-dev", cwd=remote), rival)
                else:
                    self.assertEqual(
                        dispatcher.merge_upstream(fixture.item, fixture.qualification, work), "merged"
                    )
                    merged = git("rev-parse", "local-dev", cwd=remote)
                    self.assertEqual(git("show", "-s", "--format=%P", merged, cwd=remote), base + " " + tip)
                    self.assertEqual(git("rev-parse", merged + "^{tree}", cwd=remote), git("rev-parse", tip + "^{tree}"))
                    self.assertEqual(git("show", "local-dev:value.txt", cwd=remote), "qualified")
                self.assertEqual(len(pushes), 1)
                self.assertNotIn("--force", pushes[0])
                self.assertEqual(git("rev-parse", "local-dev"), base)
                self.assertFalse(git("tag", "--list"))


class ApiTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.work = Path(self.temporary.name)
        self.fixture = Fixture(self.work)
        self.fixture.dispatcher.api = None

    def test_api_rejection_drops_body_token_and_url(self):
        error = urllib.error.HTTPError(
            "https://user:password@git.example.invalid",
            403,
            SECRET_MESSAGE,
            {},
            io.BytesIO(SECRET_MESSAGE.encode()),
        )
        opener = Mock()
        opener.open.side_effect = error
        with patch.object(propose.urllib.request, "build_opener", return_value=opener):
            self.assertEqual(self.fixture.dispatcher.main(), 1)
        evidence = self.fixture.outcome()
        self.assertEqual(evidence["error"], "API request failed with HTTP 403")
        for secret in (TOKEN, "password", SECRET_MESSAGE):
            self.assertNotIn(secret, json.dumps(evidence))

    def test_branch_404_only_means_unoccupied(self):
        opener = Mock()
        opener.open.side_effect = urllib.error.HTTPError(SERVER, 404, SECRET_MESSAGE, {}, None)
        with patch.object(propose.urllib.request, "build_opener", return_value=opener):
            self.assertIsNone(self.fixture.dispatcher.request("GET", "/branches/sync%2Fv99.2.3"))
            for method, path in (("GET", "/issues"), ("POST", "/branches/other")):
                with self.subTest(method=method), self.assertRaisesRegex(propose.Stop, "HTTP 404"):
                    self.fixture.dispatcher.request(method, path)

    def test_network_error_and_invalid_response_have_fixed_reason(self):
        for error in (OSError(SECRET_MESSAGE), ValueError(SECRET_MESSAGE)):
            with self.subTest(error=type(error).__name__):
                opener = Mock()
                opener.open.side_effect = error
                with patch.object(propose.urllib.request, "build_opener", return_value=opener):
                    self.assertEqual(self.fixture.dispatcher.main(), 1)
                self.assertEqual(self.fixture.outcome()["error"], "API request failed")

    def test_api_disables_proxy_and_redirects(self):
        response = io.BytesIO(b"[]")
        opener = Mock()
        opener.open.return_value = response
        with patch.object(propose.urllib.request, "build_opener", return_value=opener) as build:
            self.assertEqual(self.fixture.dispatcher.request("GET", "/issues"), [])
        handlers = build.call_args.args
        self.assertEqual(handlers[0].proxies, {})
        self.assertIsInstance(handlers[1], propose.NoRedirect)
        with self.assertRaisesRegex(propose.Stop, "API redirect refused"):
            handlers[1].redirect_request(None, None, 302, SECRET_MESSAGE, {}, SERVER)
        req = opener.open.call_args.args[0]
        self.assertEqual(req.get_header("Authorization"), "token " + TOKEN)
        self.assertNotIn(TOKEN, req.full_url)

    def test_invalid_repository_or_token_is_refused(self):
        for key, value, reason in [
            ("UPDATE_REPOSITORY", "owner/repo/extra", "invalid repository context"),
            ("UPDATE_TOKEN", "line\nbreak", "update token is unavailable"),
        ]:
            with self.subTest(key=key):
                original = self.fixture.environment[key]
                self.fixture.environment[key] = value
                with patch.object(
                    propose.urllib.request, "build_opener", side_effect=AssertionError
                ):
                    with self.assertRaisesRegex(propose.Stop, reason):
                        self.fixture.dispatcher.request("GET", "/issues")
                self.fixture.environment[key] = original


if __name__ == "__main__":
    unittest.main()
