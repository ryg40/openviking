"""Offline update-command tests. Run: python3 -m unittest tests.test_upstream_update."""

import argparse
import importlib.util
import json
import os
import shutil
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location(
    "upstream_update", ROOT / "scripts/upstream-update.py"
)
update = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(update)
HASH = "sha256:" + "a" * 64


class FakeRegistry:
    def __init__(self, new_tag=False, new_digest=False):
        self.calls = []
        self.new_tag, self.new_digest = new_tag, new_digest
        self.pinned = update.pins(ROOT)

    def run(self, argv, cwd=None, env=None):
        self.calls.append(argv)
        if argv[:2] == ["git", "ls-remote"]:
            tag = (
                self.pinned["upstream"] if argv[-1] == update.UPSTREAM
                else self.pinned["scanner"].split(":", 1)[1].split("@", 1)[0]
            )
            tags = [tag]
            if argv[-1] == update.UPSTREAM:
                tags += ["v99.0.0-rc1"]
                if self.new_tag:
                    tags += ["v99.0.0"]
            return 0, "\n".join("a" * 40 + "\trefs/tags/" + t for t in tags), 0
        if argv[:4] == ["docker", "buildx", "imagetools", "inspect"]:
            image = argv[-1]
            matching = (p["digest"] for p in self.pinned["images"].values()
                        if p["image"] == image)
            digest = next(matching,
                          self.pinned["scanner"].split("@")[1])
            if self.new_digest and image == self.pinned["images"]["rust"]["image"]:
                digest = HASH
            return 0, "Digest: " + digest + "\n", 0
        raise AssertionError(argv)


def args(**kwargs):
    return argparse.Namespace(kind="upstream-tag", to="v99.1.1", workdir=kwargs.pop("workdir"),
                              branch_out=None, keep=False, step_timeout=30, **kwargs)


class Tests(unittest.TestCase):
    def test_detect_nothing_new(self):
        fake = FakeRegistry()
        result, code = update.detect(
            ROOT, fake, lambda url: {"info": {"version": fake.pinned["uv"]}}
        )
        self.assertEqual(code, 0)
        self.assertEqual(len(result["inputs"]), 7)
        self.assertEqual(result["prereleases"], ["v99.0.0-rc1"])
        self.assertFalse(any(r["proposed"] for r in result["inputs"]))

    def test_detect_new_tag(self):
        fake = FakeRegistry(new_tag=True)
        result, code = update.detect(
            ROOT, fake, lambda url: {"info": {"version": fake.pinned["uv"]}}
        )
        self.assertEqual(code, 10)
        self.assertEqual(result["inputs"][0]["latest"], "v99.0.0")

    def test_detect_new_digest(self):
        fake = FakeRegistry(new_digest=True)
        result, code = update.detect(
            ROOT, fake, lambda url: {"info": {"version": fake.pinned["uv"]}}
        )
        self.assertEqual(code, 10)
        self.assertTrue(next(r for r in result["inputs"] if r["name"] == "rust")["proposed"])

    def test_detect_registry_failure_is_not_clean(self):
        fake = FakeRegistry()
        with patch.object(fake, "run", return_value=(1, "unavailable", 0)):
            result, code = update.detect(
                ROOT, fake, lambda url: {"info": {"version": fake.pinned["uv"]}}
            )
        self.assertEqual(code, 2)
        self.assertTrue(result["errors"])

    def test_environment_drops_credentials_and_docker_overrides(self):
        with patch.dict(os.environ, {"OPENAI_API_KEY": "synthetic", "DOCKER_HOST": "synthetic",
                                     "GIT_CONFIG_COUNT": "9", "COMPOSE_TEST_DIR": "/unsafe"}):
            env = update.clean_env()
        for name in ("OPENAI_API_KEY", "DOCKER_HOST", "COMPOSE_TEST_DIR"):
            self.assertNotIn(name, env)
        self.assertEqual(env["GIT_CONFIG_COUNT"], "1")

    def test_workdir_rejects_checkout_symlink_and_ancestor(self):
        for target in (ROOT, ROOT / "data", ROOT.parent):
            with self.assertRaises(update.UpdateError):
                update.safe_workdir(target, ROOT)
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp)
            (path / "link").symlink_to(ROOT, target_is_directory=True)
            with self.assertRaises(update.UpdateError):
                update.safe_workdir(path / "link" / "new", ROOT)
            nested = path / "checkout"
            nested.mkdir()
            (nested / ".git").write_text("gitdir: elsewhere")
            with self.assertRaises(update.UpdateError):
                update.safe_workdir(nested / "work", ROOT)

    def test_removal_list_equals_upstream_deletions(self):
        runner = update.Runner()
        base = update.pins(ROOT)["commit"]
        upstream = update.checked(
            runner, ["git", "ls-tree", "-r", "--name-only", base], ROOT
        ).splitlines()
        deleted = set(update.checked(
            runner, ["git", "diff", "--name-only", "--diff-filter=D", base, "HEAD"], ROOT
        ).splitlines())
        rules = update.removed_rules(ROOT)
        owned = json.loads((ROOT / "scripts/public-rules.json").read_text())["workflows"]
        covered = {
            path for path in upstream
            if path not in owned and any(update.matches(path, rule) for rule in rules)
        }
        self.assertEqual(covered, deleted)
        self.assertTrue(update.matches(".github/workflows/new.yml", ".github/workflows/"))
        self.assertFalse(update.matches(".github/workflows-extra/new.yml", ".github/workflows/"))

    def test_timeout_has_fixed_exit_code(self):
        runner = update.Runner(timeout=0.02)
        code, _, _ = runner.run(["python3", "-c", "import time; time.sleep(5)"])
        self.assertEqual(code, 124)

    def test_sync_table_ignores_surrounding_prose(self):
        with tempfile.TemporaryDirectory() as tmp:
            repo = Path(tmp)
            (repo / "docs").mkdir()
            doc = repo / "docs/branches.md"
            doc.write_text(
                "## Sync to a new upstream release\n\nReworded introduction.\n\n"
                "| Path | Local change | Source |\n| --- | --- | --- |\n"
                "| `Dockerfile` | pins | here |\n\nDifferent closing text.\n"
                "## Another heading\n| `unrelated` | no | no |\n"
            )
            self.assertEqual(update.sync_paths(repo, []), {"Dockerfile"})
            doc.write_text("## Sync to a new upstream release\nNo table.\n")
            with self.assertRaisesRegex(update.UpdateError, "cannot find the upstream sync table"):
                update.sync_paths(repo, [])

    def test_config_keys(self):
        self.assertEqual(update.config_keys('{"server": {"port": 3,},}'), {"server", "server.port"})


class FixtureTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.repo = self.root / "source"
        self.repo.mkdir()
        self.runner = update.Runner(env={**update.clean_env(), "GIT_AUTHOR_NAME": "test",
                                        "GIT_AUTHOR_EMAIL": "test@example.invalid",
                                        "GIT_COMMITTER_NAME": "test",
                                        "GIT_COMMITTER_EMAIL": "test@example.invalid"})
        self.git("init", "-b", "local-dev")
        for path in ("Dockerfile", "docker-bake.hcl", "scripts/scan.sh", "scripts/upstream-base",
                     "scripts/upstream-removed", "docs/branches.md"):
            dest = self.repo / path
            dest.parent.mkdir(parents=True, exist_ok=True)
            dest.write_text((ROOT / path).read_text())
        (self.repo / "examples").mkdir()
        (self.repo / "examples/ov.conf.example").write_text('{"old": 1}')
        (self.repo / "README.md").write_text("original\n")
        (self.repo / "scripts/public-rules.json").write_text(json.dumps({"workflows": []}))
        for relative in ("scripts/upstream-update.py", "tests/test_upstream_update.py"):
            target = self.repo / relative
            target.parent.mkdir(exist_ok=True)
            shutil.copy2(ROOT / relative, target)
        self.git("add", ".")
        self.git("commit", "-m", "base")
        self.git("tag", "v99.1.0")
        self.git("switch", "-c", "upstream")
        (self.repo / "README.md").write_text("upstream\n")
        (self.repo / "examples/ov.conf.example").write_text('{"old": 1, "new": 2}')
        (self.repo / ".github/workflows").mkdir(parents=True)
        (self.repo / ".github/workflows/new.yml").write_text("name: new\n")
        self.git("add", ".")
        self.git("commit", "-m", "next")
        self.git("tag", "v99.1.1")
        self.git("switch", "local-dev")
        self.work = self.root / "work"

    def git(self, *argv):
        return update.checked(self.runner, ["git", *argv], self.repo)

    def state(self):
        return self.git("status", "--porcelain"), self.git("show-ref")

    def factory(self, fail_build=False, fail_public=False):
        source = self.repo
        class FakeTools(update.Runner):
            def run(inner, argv, cwd=None, env=None):
                if argv[:2] == ["git", "fetch"]:
                    argv = [str(source) if arg == update.UPSTREAM else arg for arg in argv]
                if argv[0] == "git":
                    return super(FakeTools, inner).run(argv, cwd, env)
                if argv == ["sh", "tests/test_scan.sh"]:
                    if not env or env.get("GIT_CONFIG_COUNT") != "0":
                        return 1, "hooksPath override prevents the scanner hook tests", 0
                if argv[:3] == ["sh", "scripts/scan.sh", "baseline"]:
                    return 0, (Path(cwd) / "scripts/upstream-base").read_text(), 0
                if argv == ["sh", "scripts/public-check.sh", "--write-upstream-map"]:
                    base = update.pins(Path(cwd))
                    (Path(cwd) / "scripts/upstream-blobs.json").write_text(json.dumps({
                        "tag": base["upstream"], "commit": base["commit"], "blobs": [],
                    }))
                    return 0, "fake map regenerated\n", 0
                if argv == ["sh", "scripts/public-check.sh"]:
                    if fail_public:
                        return 2, "missing public check", 0
                    base = update.pins(Path(cwd))
                    if base["upstream"] == "v99.1.1":
                        blob_map = json.loads(
                            (Path(cwd) / "scripts/upstream-blobs.json").read_text()
                        )
                        if blob_map["commit"] != base["commit"]:
                            return 2, "stale map", 0
                if argv[:3] == ["sh", "scripts/build.sh", "test"] and fail_build:
                    return 1, "synthetic build failure", 0
                if argv == ["python3", "-m", "unittest", "tests.test_upstream_update"]:
                    return 0, "fake update tests passed\n", 0
                if argv[0] in ("sh", "docker"):
                    return 0, "fake tool passed\n", 0
                raise AssertionError(argv)
        return FakeTools

    def test_merge_conflict_stops_and_preserves_caller(self):
        (self.repo / "README.md").write_text("local\n")
        self.git("add", ".")
        self.git("commit", "-m", "local")
        before = self.state()
        result, code = update.qualify(self.repo, args(workdir=str(self.work)), self.factory())
        self.assertEqual(code, 1)
        self.assertEqual(result["conflicts"], ["README.md"])
        self.assertTrue(
            any(r["path"] == ".github/workflows/new.yml" for r in result["applied_rules"])
        )
        self.assertFalse(any(s["name"] == "build-test" for s in result["steps"]))
        self.assertFalse((Path(result["run_directory"]) / "clone").exists())
        self.assertEqual(self.state(), before)

    def test_failed_build_keeps_independent_checks_and_no_bundle(self):
        before = self.state()
        options = args(workdir=str(self.work))
        options.branch_out = str(self.work / "out")
        with patch.object(update, "docker_wrapper"):
            result, code = update.qualify(self.repo, options, self.factory(fail_build=True))
        self.assertEqual(code, 1)
        build = next(step for step in result["steps"] if step["name"] == "build-test")
        self.assertEqual(build["status"], "failed")
        self.assertTrue(any(s["name"] == "build-gateway" for s in result["steps"]))
        self.assertIsNone(result["bundle"])
        self.assertEqual(self.state(), before)

    def test_success_exports_bundle_and_rule_deletion(self):
        before = self.state()
        options = args(workdir=str(self.work))
        options.branch_out = str(self.work / "out")
        with patch.object(update, "docker_wrapper"):
            result, code = update.qualify(self.repo, options, self.factory())
        self.assertEqual(code, 0)
        self.assertTrue(Path(result["bundle"]).is_file())
        self.assertEqual(self.state(), before)
        public = next(s for s in result["steps"] if s["name"] == "public-check")
        self.assertEqual(public["status"], "passed")
        names = [step["name"] for step in result["steps"]]
        self.assertLess(names.index("upstream-map"), names.index("public-check-early"))
        self.assertLess(names.index("public-check-early"), names.index("build-test"))
        self.assertIn("test-public_check", names)
        self.assertIn("test-upstream-update", names)
        self.assertTrue(result["applied_rules"])
        prerequisite = self.git("rev-parse", "local-dev")
        self.assertEqual(result["prerequisite_commit"], prerequisite)
        with Path(result["bundle"]).open("rb") as stream:
            header = stream.read(256)
        self.assertIn(("-" + prerequisite).encode(), header)
        bundle = Path(result["bundle"])
        receiver = self.root / "receiver"
        update.checked(self.runner, ["git", "clone", str(self.repo), str(receiver)])
        output = update.checked(self.runner, ["git", "bundle", "verify", str(bundle)], receiver)
        self.assertIn(prerequisite, output)
        update.checked(self.runner, ["git", "fetch", str(bundle), result["branch"]], receiver)
        count = update.checked(
            self.runner, ["git", "rev-list", "--count", prerequisite + "..FETCH_HEAD"], receiver
        )
        # The range includes the incoming upstream commit and the qualification merge.
        self.assertEqual(count, "2")
        empty = self.root / "empty"
        update.checked(self.runner, ["git", "init", str(empty)])
        status, _, _ = self.runner.run(["git", "bundle", "verify", str(bundle)], empty)
        self.assertNotEqual(status, 0)

    def test_local_workflows_survive_upstream_deletion_rules(self):
        owned = ".github/workflows/owned.yml"
        local_only = ".github/workflows/local-only.yml"
        self.git("switch", "upstream")
        (self.repo / "scripts/public-rules.json").write_text(json.dumps({"workflows": [owned]}))
        (self.repo / owned).write_text("name: owned\n")
        self.git("add", ".")
        self.git("commit", "-m", "add shared workflow path")
        self.git("tag", "v99.1.2")
        self.git("switch", "local-dev")
        (self.repo / owned).parent.mkdir(parents=True, exist_ok=True)
        (self.repo / owned).write_text("name: owned\n")
        (self.repo / local_only).write_text("name: local-only\n")
        (self.repo / "scripts/public-rules.json").write_text(json.dumps({"workflows": [owned]}))
        self.git("add", ".")
        self.git("commit", "-m", "protect local workflow")
        options = args(workdir=str(self.work))
        options.to = "v99.1.2"
        options.branch_out = str(self.work / "out")
        with patch.object(update, "docker_wrapper"):
            result, code = update.qualify(self.repo, options, self.factory())
        self.assertEqual(code, 0)
        self.assertEqual(
            {entry["path"]: entry["reason"] for entry in result["skipped_rules"]},
            {owned: "repository-owned workflow",
             local_only: "path is absent from the incoming upstream tree"},
        )
        self.assertEqual([item["path"] for item in result["applied_rules"]],
                         [".github/workflows/new.yml"])
        self.git("fetch", result["bundle"], result["branch"])
        paths = self.git("ls-tree", "-r", "--name-only", "FETCH_HEAD").splitlines()
        self.assertIn(owned, paths)
        self.assertIn(local_only, paths)
        self.assertNotIn(".github/workflows/new.yml", paths)

    def test_missing_public_check_stops_before_builds(self):
        with patch.object(update, "docker_wrapper"):
            result, code = update.qualify(
                self.repo, args(workdir=str(self.work)), self.factory(fail_public=True)
            )
        self.assertEqual(code, 1)
        public = next(s for s in result["steps"] if s["name"] == "public-check-early")
        self.assertEqual(public["exit_code"], 2)
        self.assertEqual(public["status"], "failed")
        self.assertFalse(any(s["name"] == "build-test" for s in result["steps"]))

    def test_pi_node_requirement(self):
        self.git("switch", "upstream")
        pi_path = self.repo / "examples/memory-plugin-shared/example.test.mjs"
        pi_path.parent.mkdir(parents=True)
        pi_path.write_text("// Synthetic shared-library change.\n")
        self.git("add", ".")
        self.git("commit", "-m", "change shared library")
        self.git("tag", "v99.1.2")
        self.git("switch", "local-dev")
        before = self.state()
        parent = self.factory()
        for node_code, output, accepted in (
            (127, "node unavailable\n", False),
            (0, "v22.19.0\n", False),
            (0, "v24.0.0\n", True),
            (0, "v25.0.0\n", True),
            (0, "v100.0.0\n", True),
        ):
            with self.subTest(node_code=node_code, output=output):
                calls = []
                class NodeTools(parent):
                    def run(inner, argv, cwd=None, env=None):
                        calls.append(argv)
                        if argv == ["node", "--version"]:
                            return node_code, output, 0
                        if argv[0] in ("node", "npm"):
                            return 0, "fake Pi tool passed\n", 0
                        return super(NodeTools, inner).run(argv, cwd, env)
                options = args(workdir=str(self.work))
                options.to = "v99.1.2"
                options.branch_out = str(self.work / "out")
                with patch.object(update, "docker_wrapper"):
                    result, code = update.qualify(self.repo, options, NodeTools)
                self.assertEqual(code, 0 if accepted else 1)
                steps = {step["name"]: step for step in result["steps"]}
                self.assertEqual(steps["node-version"]["exit_code"], node_code)
                if accepted:
                    self.assertNotIn("node-requirement", steps)
                    self.assertTrue(Path(result["bundle"]).is_file())
                else:
                    requirement = steps["node-requirement"]
                    self.assertEqual(requirement["exit_code"], 1)
                    self.assertEqual(requirement["status"], "failed")
                    detail = "node not found" if node_code else output.strip()
                    self.assertEqual(Path(requirement["log"]).read_text(),
                                     "Pi tests need Node 24 or later; " + detail + "\n")
                    self.assertIsNone(result["bundle"])
                    self.assertFalse(any(argv[0] == "npm" or argv[:2] == ["node", "--test"]
                                         or argv == ["node", "examples/memory-plugin-shared/sync.mjs"]
                                         for argv in calls))
                for name in ("pi-install", "pi-sync", "pi-tests", "shared-tests"):
                    self.assertEqual(steps[name]["status"], "passed" if accepted else "skipped")
                self.assertFalse((Path(result["run_directory"]) / "clone").exists())
                self.assertEqual(self.state(), before)

    def test_scanner_result_requires_manual_rule_review(self):
        options = args(workdir=str(self.work))
        options.kind, options.to = "scanner", "v99.0.0"
        with patch.object(update, "patch_pin"), patch.object(update, "docker_wrapper"):
            result, code = update.qualify(self.repo, options, self.factory())
        self.assertEqual(code, 0)
        self.assertTrue(result["attention"])
        self.assertIn(".gitleaks.toml", result["manual_steps"][0])
        self.assertIn("docs/secret-handling.md", result["manual_steps"][0])

    def test_notes_attention_and_caller_unchanged(self):
        before = self.state()
        options = argparse.Namespace(from_tag="v99.1.0", to="v99.1.1", workdir=str(self.work),
                                     keep=False, step_timeout=30)
        releases = [{"tag_name": "v99.1.1", "html_url": "https://example.invalid/release",
                     "body": "## Breaking changes\nChanged configuration."}]
        result, code = update.notes(self.repo, options, self.factory(), lambda url: releases)
        self.assertEqual(code, 0)
        self.assertTrue(result["attention"])
        self.assertEqual(result["configuration_keys"]["added"], ["new"])
        self.assertIn("README.md", result["relevant_paths"])
        self.assertEqual(self.state(), before)

    def test_modify_delete_conflict_is_resolved_only_by_rule(self):
        self.git("switch", "upstream")
        (self.repo / ".github/workflows/new.yml").write_text("name: changed\n")
        self.git("add", ".")
        self.git("commit", "-m", "workflow update")
        self.git("tag", "v99.1.2")
        self.git("switch", "local-dev")
        self.git("merge", "--ff-only", "v99.1.1")
        self.git("rm", ".github/workflows/new.yml")
        self.git("commit", "-m", "remove workflow")
        options = args(workdir=str(self.work))
        options.to = "v99.1.2"
        with patch.object(update, "docker_wrapper"):
            result, code = update.qualify(self.repo, options, self.factory())
        self.assertEqual(code, 0)
        merge = next(s for s in result["steps"] if s["name"] == "merge")
        self.assertEqual(merge["exit_code"], 1)
        self.assertEqual(merge["status"], "resolved")
        self.assertEqual(result["conflicts"], [])

    def test_pin_changes_read_canonical_sources(self):
        registry = FakeRegistry(new_digest=True)
        update.patch_pin(self.repo, "base-digest", "rust=" + HASH, registry, None)
        self.assertEqual(update.pins(self.repo)["images"]["rust"]["digest"], HASH)
        self.assertIn(HASH, (self.repo / "docker-bake.hcl").read_text())
        platforms = (
            ("manylinux", "x86_64"), ("manylinux", "aarch64"),
            ("musllinux", "x86_64"), ("musllinux", "aarch64"),
        )
        wheels = [
            {"filename": f"uv-99.2.3-py3-none-{lib}_{arch}.whl",
             "digests": {"sha256": str(i) * 64}}
            for i, (lib, arch) in enumerate(platforms, 1)
        ]
        update.patch_pin(self.repo, "uv", "99.2.3", registry, lambda url: {"urls": wheels})
        self.assertEqual(update.pins(self.repo)["uv"], "99.2.3")
        update.patch_pin(self.repo, "scanner", "v99.0.0", registry, None)
        self.assertIn(":v99.0.0@", update.pins(self.repo)["scanner"])

    def test_missing_workflow_does_not_hide_other_conflicts(self):
        (self.repo / "README.md").write_text("local\n")
        self.git("add", ".")
        self.git("commit", "-m", "conflicting change")
        result, _ = update.qualify(self.repo, args(workdir=str(self.work)), self.factory())
        self.assertEqual(result["conflicts"], ["README.md"])
        self.assertEqual(result["applied_rules"][0]["rule"], ".github/workflows/")

    def test_cleanup_failure_fails_result_and_removes_bundle(self):
        parent = self.factory()
        class FailingCleanup(parent):
            def run(inner, argv, cwd=None, env=None):
                if argv[:3] == ["docker", "buildx", "rm"]:
                    return 1, "synthetic cleanup failure", 0
                return super(FailingCleanup, inner).run(argv, cwd, env)
        options = args(workdir=str(self.work))
        options.branch_out = str(self.work / "out")
        with patch.object(update, "docker_wrapper"):
            result, code = update.qualify(self.repo, options, FailingCleanup)
        self.assertEqual(code, 1)
        self.assertEqual(result["status"], "failed")
        self.assertIsNone(result["bundle"])
        self.assertEqual(list((self.work / "out").glob("*.bundle")), [])

    def test_builder_deadline_requires_proven_absence(self):
        parent = self.factory()
        for remains in (False, True):
            class Deadline(parent):
                def run(inner, argv, cwd=None, env=None):
                    if argv[:3] == ["docker", "buildx", "rm"]:
                        return 1, "context deadline exceeded", 0
                    if argv[:3] == ["docker", "volume", "ls"]:
                        output = "buildx_buildkit_deadline_state" if remains else ""
                        return 0, output, 0
                    return super(Deadline, inner).run(argv, cwd, env)
            root = self.root / ("remaining" if remains else "absent")
            root.mkdir()
            run = update.Run(root, Deadline())
            update.cleanup_builder(run, "deadline")
            self.assertEqual(run.steps[0]["status"], "failed" if remains else "resolved")
            self.assertEqual(len(run.steps), 4)

    def test_branch_out_must_be_inside_workdir(self):
        options = args(workdir=str(self.work))
        options.branch_out = str(self.root / "outside")
        with self.assertRaises(update.UpdateError):
            update.qualify(self.repo, options)


if __name__ == "__main__":
    unittest.main()
