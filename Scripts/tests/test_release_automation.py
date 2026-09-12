import copy
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch
from urllib.parse import parse_qs, unquote, urlsplit


SCRIPT = Path(__file__).resolve().parents[1] / "release_automation.py"
SPEC = importlib.util.spec_from_file_location("release_automation", SCRIPT)
automation = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(automation)
COMMIT = "a" * 40
OTHER_COMMIT = "b" * 40
TEAM = "6Q29HJZ4AG"
REPOSITORY = "owner/Omabox"


def successful_run(identifier=23, commit=COMMIT):
    return {"id": identifier, "workflow_id": 12, "head_sha": commit,
            "head_branch": "main", "event": "push", "status": "completed", "conclusion": "success",
            "repository": {"full_name": REPOSITORY}, "head_repository": {"full_name": REPOSITORY}}


def release(identifier=1, tag="v0.1.0", commit=COMMIT, draft=False, prerelease=False):
    return {"id": identifier, "tag_name": tag, "target_commitish": commit, "draft": draft,
            "prerelease": prerelease, "published_at": None if draft else "2026-09-11T00:00:00Z",
            "body": f"{automation.AUTOMATION_MARKER}\nSource commit: {commit}\n",
            "author": {"login": "github-actions[bot]"},
            "html_url": f"https://github.com/{REPOSITORY}/releases/tag/{tag}"}


class FakeGitHub(automation.GitHub):
    def __init__(self):
        super().__init__(REPOSITORY, {})
        self.head = COMMIT
        self.runs = {23: successful_run()}
        self.jobs = {23: [{"id": index, "name": name, "status": "completed", "conclusion": "success",
                          "run_id": 23, "head_sha": COMMIT}
                         for index, name in enumerate(sorted(automation.REQUIRED_JOBS), start=1)]}
        self.releases = []
        self.assets = {}
        self.tags = {}
        self.annotations = {}
        self.requests = []
        self.hook = None
        self.fail_upload = None
        self.bad_digest = None
        self.next_asset_id = 100

    @property
    def mutations(self):
        return [item for item in self.requests if item[0] != "GET"]

    def add_release(self, value):
        self.releases.append(value)
        self.assets[value["id"]] = []
        if not value["draft"]:
            self.tags[value["tag_name"]] = {"type": "commit", "sha": value["target_commitish"]}

    def api(self, endpoint, method="GET", payload=None, upload=None):
        self.requests.append((method, endpoint, payload, upload))
        if self.hook:
            self.hook(self, endpoint, method, payload)
        parsed = urlsplit(endpoint)
        path = parsed.path.lstrip("/")
        prefix = f"repos/{REPOSITORY}/"
        if not path.startswith(prefix):
            raise AssertionError(f"Unexpected fake API destination: {endpoint}")
        route = path[len(prefix):]
        query = parse_qs(parsed.query)

        def page(items):
            start = (int(query.get("page", ["1"])[0]) - 1) * 100
            return copy.deepcopy(items[start:start + 100])

        def missing():
            raise automation.APIError("Not found", 404)

        if route == "git/ref/heads/main" and method == "GET":
            return {"ref": "refs/heads/main", "object": {"type": "commit", "sha": self.head}}
        if route == "actions/workflows/ci.yml":
            return {"id": 12, "path": ".github/workflows/ci.yml"}
        if route == "actions/workflows/ci.yml/runs":
            return {"workflow_runs": page(list(self.runs.values()))}
        if route.startswith("actions/runs/"):
            pieces = route.split("/")
            identifier = int(pieces[2])
            if len(pieces) == 4 and pieces[3] == "jobs":
                return {"jobs": page(self.jobs.get(identifier, []))}
            return copy.deepcopy(self.runs[identifier]) if identifier in self.runs else missing()
        if route.startswith("git/ref/tags/"):
            tag = unquote(route[len("git/ref/tags/"):])
            return {"ref": f"refs/tags/{tag}", "object": copy.deepcopy(self.tags[tag])} if tag in self.tags else missing()
        if route.startswith("git/tags/"):
            sha = route[len("git/tags/"):]
            return {"object": copy.deepcopy(self.annotations[sha])} if sha in self.annotations else missing()
        if route == "git/refs" and method == "POST":
            tag = payload["ref"][len("refs/tags/"):]
            if tag in self.tags:
                raise automation.APIError("Already exists", 422)
            self.tags[tag] = {"type": "commit", "sha": payload["sha"]}
            return {"ref": payload["ref"], "object": copy.deepcopy(self.tags[tag])}
        if route == "releases":
            if method == "GET":
                return page(self.releases)
            if method == "POST":
                value = {**copy.deepcopy(payload), "id": max([item["id"] for item in self.releases], default=0) + 1,
                         "published_at": None, "author": {"login": "github-actions[bot]"},
                         "html_url": "https://github.com/owner/Omabox/releases/tag/" + payload["tag_name"]}
                self.add_release(value)
                return copy.deepcopy(value)
        if route.startswith("releases/assets/") and method == "DELETE":
            identifier = int(route.split("/")[-1])
            for assets in self.assets.values():
                for asset in assets:
                    if asset["id"] == identifier:
                        assets.remove(asset)
                        return None
            return missing()
        if route.startswith("releases/"):
            pieces = route.split("/")
            identifier = int(pieces[1])
            if len(pieces) == 3 and pieces[2] == "assets":
                if method == "GET":
                    return page(self.assets[identifier])
                if method == "POST":
                    name = query["name"][0]
                    if self.fail_upload == name:
                        raise automation.APIError("Upload interrupted", 502)
                    data = Path(upload).read_bytes()
                    digest = "0" * 64 if self.bad_digest == name else hashlib.sha256(data).hexdigest()
                    value = {"id": self.next_asset_id, "name": name, "size": len(data),
                             "digest": f"sha256:{digest}", "state": "uploaded"}
                    self.next_asset_id += 1
                    self.assets[identifier].append(value)
                    return copy.deepcopy(value)
            for item in self.releases:
                if item["id"] == identifier:
                    if method == "PATCH":
                        item.update(copy.deepcopy(payload))
                        if payload.get("draft") is False:
                            item["published_at"] = "2026-09-11T00:00:00Z"
                    return copy.deepcopy(item)
            return missing()
        raise AssertionError(f"Unhandled fake API request: {method} {endpoint}")


class PlanningTests(unittest.TestCase):
    def setUp(self):
        self.github = FakeGitHub()
        self.event = {"action": "completed", "repository": {"full_name": REPOSITORY},
                      "workflow_run": successful_run()}

    def plan(self):
        return automation.make_plan(self.github, "workflow_run", self.event, {})

    def test_successful_main_gets_initial_version_and_no_mutations(self):
        plan = self.plan()
        self.assertTrue(plan["should_release"])
        self.assertEqual((plan["tag"], plan["version"], plan["commit"], plan["ci_run_id"]), ("v0.1.0", "0.1.0", COMMIT, 23))
        self.assertFalse(self.github.mutations)

    def test_stale_main_skips_before_expensive_ci_or_release_queries(self):
        self.github.head = OTHER_COMMIT
        plan = self.plan()
        self.assertFalse(plan["should_release"])
        self.assertIn("current main", plan["reason"])
        self.assertEqual(len(self.github.requests), 1)

    def test_rejects_fork_pr_wrong_branch_and_unsuccessful_events(self):
        variants = [{"head_repository": {"full_name": "fork/Omabox"}}, {"event": "pull_request"},
                    {"head_branch": "feature"}, {"conclusion": "failure"}, {"status": "in_progress"}]
        for values in variants:
            with self.subTest(values=values):
                event = copy.deepcopy(self.event)
                event["workflow_run"].update(values)
                with self.assertRaises(automation.ReleaseError):
                    automation.make_plan(self.github, "workflow_run", event, {})
        self.assertFalse(self.github.requests)

    def test_requires_full_sha_and_matching_event_repository(self):
        for commit in ("a" * 7, "A" * 40, "main", COMMIT + "\n"):
            with self.subTest(commit=commit):
                self.event["workflow_run"]["head_sha"] = commit
                with self.assertRaises(automation.ReleaseError):
                    self.plan()
        self.event["workflow_run"]["head_sha"] = COMMIT
        self.event["repository"]["full_name"] = "other/repository"
        with self.assertRaises(automation.ReleaseError):
            self.plan()

    def test_live_ci_is_verified_instead_of_trusting_event_success(self):
        self.github.runs[23]["conclusion"] = "failure"
        with self.assertRaisesRegex(automation.ReleaseError, "successfully"):
            self.plan()

    def test_other_workflow_cannot_impersonate_ci(self):
        self.github.runs[23]["workflow_id"] = 90
        with self.assertRaisesRegex(automation.ReleaseError, "ci.yml"):
            self.plan()

    def test_each_required_job_must_be_present_successful_and_unique(self):
        original = copy.deepcopy(self.github.jobs[23])
        cases = [[], original[:1], original + [original[0]],
                 [{**original[0], "conclusion": "skipped"}, original[1]],
                 [{**original[0], "head_sha": OTHER_COMMIT}, original[1]]]
        for jobs in cases:
            with self.subTest(jobs=jobs):
                self.github.jobs[23] = jobs
                with self.assertRaises(automation.ReleaseError):
                    self.plan()

    def test_manual_dispatch_uses_trusted_push_ci_for_current_main(self):
        event = {"repository": {"full_name": REPOSITORY}, "ref": "refs/heads/main", "inputs": {"commit": COMMIT}}
        plan = automation.make_plan(self.github, "workflow_dispatch", event, {"GITHUB_REF": "refs/heads/main"})
        self.assertTrue(plan["should_release"])
        self.assertEqual(plan["ci_run_id"], 23)

    def test_manual_dispatch_defaults_to_main_and_rejects_nonmain_ref(self):
        event = {"repository": {"full_name": REPOSITORY}, "ref": "main"}
        self.assertEqual(automation.make_plan(self.github, "workflow_dispatch", event, {})["commit"], COMMIT)
        for ref in ("refs/tags/v0.1.0", "feature", None):
            with self.subTest(ref=ref):
                event["ref"] = ref
                with self.assertRaises(automation.ReleaseError):
                    automation.make_plan(self.github, "workflow_dispatch", event, {})

    def test_manual_stale_requested_commit_skips(self):
        event = {"repository": {"full_name": REPOSITORY}, "ref": "main", "inputs": {"commit": OTHER_COMMIT}}
        self.assertFalse(automation.make_plan(self.github, "workflow_dispatch", event, {})["should_release"])

    def test_manual_successful_run_without_required_jobs_is_not_releasable(self):
        self.github.jobs[23] = []
        event = {"repository": {"full_name": REPOSITORY}, "ref": "main"}
        with self.assertRaisesRegex(automation.ReleaseError, "No trusted successful"):
            automation.make_plan(self.github, "workflow_dispatch", event, {})

    def test_next_version_uses_numeric_max_ignoring_drafts_prereleases_and_nonsemver(self):
        versions = [release(tag="v1.9.19"), release(tag="v1.10.0"), release(tag="v1.2.30"),
                    release(tag="v9.0.0", draft=True), release(tag="v8.0.0", prerelease=True),
                    release(tag="v01.2.3"), release(tag="nightly")]
        self.assertEqual(automation.next_version(versions), "1.10.1")
        self.assertEqual(automation.next_version([release(tag="v1.0.0", draft=True)]), "0.1.0")

    def test_completed_source_is_idempotent_even_when_tag_is_annotated(self):
        self.github.add_release(release())
        annotation_sha = "c" * 40
        self.github.tags["v0.1.0"] = {"type": "tag", "sha": annotation_sha}
        self.github.annotations[annotation_sha] = {"type": "commit", "sha": COMMIT}
        plan = self.plan()
        self.assertFalse(plan["should_release"])
        self.assertIn("already", plan["reason"])
        self.assertFalse(self.github.mutations)

    def test_body_source_marker_cannot_fake_published_source(self):
        value = release(commit=OTHER_COMMIT)
        value["body"] = f"Source commit: {COMMIT}"
        self.github.add_release(value)
        self.assertEqual(self.plan()["tag"], "v0.1.1")

    def test_annotated_tag_cycle_is_rejected(self):
        sha = "c" * 40
        self.github.tags["v0.1.0"] = {"type": "tag", "sha": sha}
        self.github.annotations[sha] = {"type": "tag", "sha": sha}
        with self.assertRaisesRegex(automation.ReleaseError, "resolve to a commit"):
            automation.tag_commit(self.github, "v0.1.0")

    def test_release_pagination_reaches_older_published_source(self):
        for index in range(100):
            self.github.add_release(release(identifier=index + 1, tag=f"draft-{index}", draft=True))
        self.github.add_release(release(identifier=101))
        self.assertFalse(self.plan()["should_release"])
        self.assertTrue(any("releases?per_page=100&page=2" in request[1] for request in self.github.requests))

    def test_foreign_draft_and_other_commit_tag_are_rejected_before_build(self):
        foreign = release(draft=True, commit=OTHER_COMMIT)
        foreign["author"]["login"] = "human"
        self.github.add_release(foreign)
        with self.assertRaises(automation.ReleaseError):
            self.plan()
        self.github.releases.clear()
        self.github.tags["v0.1.0"] = {"type": "commit", "sha": OTHER_COMMIT}
        with self.assertRaisesRegex(automation.ReleaseError, "another commit"):
            self.plan()

    def test_owned_draft_can_be_resumed_without_changing_version(self):
        self.github.add_release(release(draft=True))
        self.assertEqual(self.plan()["tag"], "v0.1.0")

    def test_abandoned_bot_draft_reserves_version_without_mutations(self):
        self.github.add_release(release(draft=True, commit=OTHER_COMMIT))
        self.assertEqual(self.plan()["tag"], "v0.1.1")
        self.assertFalse(self.github.mutations)

    def test_automation_marker_and_bot_author_are_both_required_for_reservations(self):
        for changes in ({"body": f"Source commit: {OTHER_COMMIT}"},
                        {"author": {"login": "human"}}, {"target_commitish": "main"}):
            with self.subTest(changes=changes):
                self.github = FakeGitHub()
                self.github.add_release({**release(draft=True, commit=OTHER_COMMIT), **changes})
                with self.assertRaises(automation.ReleaseError):
                    self.plan()
                self.assertFalse(self.github.mutations)

    def test_writes_scalar_github_outputs(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            plan = self.plan()
            automation.write_plan(plan, root / "plan.json", root / "output")
            self.assertEqual(json.loads((root / "plan.json").read_text()), plan)
            self.assertEqual((root / "output").read_text(),
                             f"should_release=true\ntag=v0.1.0\nversion=0.1.0\ncommit={COMMIT}\nci_run_id=23\n")


class ArtifactFixture:
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.directory = Path(temporary.name)
        self.filename = "Omabox-0.1.0-arm64.dmg"
        content = b"Test notarized-image fixture"
        (self.directory / self.filename).write_bytes(content)
        digest = hashlib.sha256(content).hexdigest()
        self.manifest = {"schemaVersion": 1, "verified": True, "version": "0.1.0", "buildNumber": "11",
                         "teamID": TEAM, "architecture": "arm64", "minimumSystemVersion": "26.0",
                         "file": self.filename, "byteCount": len(content), "sha256": digest,
                         "appNotarizationID": "fixture-app", "dmgNotarizationID": "fixture-dmg"}
        self.write_manifest()
        (self.directory / "SHA256SUMS").write_text(f"{digest}  {self.filename}\n")

    def write_manifest(self):
        (self.directory / "release-manifest.json").write_text(json.dumps(self.manifest))

    def verify(self, add=True):
        return automation.verify_artifacts(self.directory, "0.1.0", "11", COMMIT, 23, TEAM, add_provenance=add)


class ArtifactTests(ArtifactFixture, unittest.TestCase):
    def test_verification_adds_provenance_and_is_idempotent(self):
        artifacts = self.verify()
        self.assertEqual(set(artifacts), {self.filename, "SHA256SUMS", "release-manifest.json"})
        self.manifest = json.loads((self.directory / "release-manifest.json").read_text())
        self.assertEqual((self.manifest["sourceCommit"], self.manifest["ciRunID"]), (COMMIT, 23))
        original = (self.directory / "release-manifest.json").read_bytes()
        self.verify()
        self.assertEqual((self.directory / "release-manifest.json").read_bytes(), original)

    def test_publication_requires_existing_provenance(self):
        with self.assertRaisesRegex(automation.ReleaseError, "lacks provenance"):
            self.verify(add=False)

    def test_wrong_manifest_platform_signature_version_or_build_is_rejected(self):
        cases = {"schemaVersion": True, "verified": 1, "version": "0.1.1", "buildNumber": "12",
                 "teamID": "AAAAAAAAAA", "architecture": "x86_64", "minimumSystemVersion": "25.0",
                 "file": "../other.dmg", "byteCount": True, "sha256": "0" * 64}
        original = copy.deepcopy(self.manifest)
        for key, value in cases.items():
            with self.subTest(key=key):
                self.manifest = {**original, key: value}
                self.write_manifest()
                with self.assertRaises(automation.ReleaseError):
                    self.verify()

    def test_tampered_dmg_is_rejected(self):
        (self.directory / self.filename).write_bytes(b"altered download")
        with self.assertRaises(automation.ReleaseError):
            self.verify()

    def test_checksum_must_be_exact_and_cannot_reference_other_files(self):
        original = (self.directory / "SHA256SUMS").read_bytes()
        for value in (original + original, original.replace(b"  ", b" *"), original.rstrip(b"\n"), b"0  ../secret\n"):
            with self.subTest(value=value):
                (self.directory / "SHA256SUMS").write_bytes(value)
                with self.assertRaisesRegex(automation.ReleaseError, "SHA256SUMS"):
                    self.verify()

    def test_extra_dmg_is_rejected(self):
        (self.directory / "unexpected.DMG").write_bytes(b"other")
        with self.assertRaisesRegex(automation.ReleaseError, "exactly"):
            self.verify()

    def test_symlinked_asset_is_rejected(self):
        image = self.directory / self.filename
        real = self.directory / "real-image"
        image.rename(real)
        image.symlink_to(real)
        with self.assertRaisesRegex(automation.ReleaseError, "symlink"):
            self.verify()

    def test_symlinked_metadata_and_directories_are_rejected(self):
        manifest = self.directory / "release-manifest.json"
        manifest.rename(self.directory / "real-manifest")
        manifest.symlink_to(self.directory / "real-manifest")
        with self.assertRaisesRegex(automation.ReleaseError, "symlink"):
            self.verify()
        manifest.unlink()
        self.write_manifest()
        (self.directory / "subdirectory").mkdir()
        with self.assertRaisesRegex(automation.ReleaseError, "regular file"):
            self.verify()

    def test_asset_size_limit_is_strictly_below_two_gib(self):
        image = self.directory / self.filename
        with patch.object(automation, "MAX_ASSET_BYTES", image.stat().st_size):
            with self.assertRaisesRegex(automation.ReleaseError, "smaller than 2 GiB"):
                self.verify()

    def test_conflicting_provenance_cannot_be_rewritten(self):
        for provenance in ({"sourceCommit": OTHER_COMMIT}, {"ciRunID": 24}, {"ciRunID": "23"}):
            with self.subTest(provenance=provenance):
                self.write_manifest()
                value = {**self.manifest, **provenance}
                (self.directory / "release-manifest.json").write_text(json.dumps(value))
                with self.assertRaisesRegex(automation.ReleaseError, "provenance mismatch"):
                    self.verify()

    def test_duplicate_json_manifest_fields_are_rejected(self):
        value = json.dumps(self.manifest)
        (self.directory / "release-manifest.json").write_text(value[:-1] + ', "verified": true}')
        with self.assertRaisesRegex(automation.ReleaseError, "Duplicate JSON"):
            self.verify()


class PublicationTests(ArtifactFixture, unittest.TestCase):
    def setUp(self):
        super().setUp()
        self.github = FakeGitHub()
        self.plan = {"schemaVersion": 1, "repository": REPOSITORY, "should_release": True,
                     "tag": "v0.1.0", "version": "0.1.0", "commit": COMMIT, "ci_run_id": 23}
        self.verify()

    def publish(self):
        return automation.publish(self.github, self.directory, self.plan, "11", TEAM)

    def test_publishes_draft_only_after_three_remote_digests_and_tested_tag(self):
        self.assertTrue(self.publish()["published"])
        self.assertEqual(self.github.tags["v0.1.0"], {"type": "commit", "sha": COMMIT})
        self.assertEqual(len(self.github.assets[1]), 3)
        changes = self.github.mutations
        self.assertEqual(changes[0][2]["draft"], True)
        self.assertEqual(changes[-1][0], "PATCH")
        self.assertEqual(changes[-1][2]["make_latest"], "true")
        self.assertEqual(sum(request[3] is not None for request in changes), 3)
        self.assertEqual(self.github.releases[0]["draft"], False)

    def test_completed_published_release_is_never_modified_on_rerun(self):
        self.publish()
        count = len(self.github.mutations)
        result = self.publish()
        self.assertFalse(result["published"])
        self.assertIn("already", result["reason"])
        self.assertEqual(len(self.github.mutations), count)

    def test_stale_head_or_failed_ci_causes_no_remote_mutations(self):
        self.github.head = OTHER_COMMIT
        self.assertFalse(self.publish()["published"])
        self.assertFalse(self.github.mutations)
        self.github.head = COMMIT
        self.github.jobs[23][0]["conclusion"] = "failure"
        with self.assertRaises(automation.ReleaseError):
            self.publish()
        self.assertFalse(self.github.mutations)

    def test_new_stable_version_requires_new_build(self):
        self.github.add_release(release(commit=OTHER_COMMIT))
        with self.assertRaisesRegex(automation.ReleaseError, "version changed"):
            self.publish()
        self.assertFalse(self.github.mutations)

    def test_interrupted_upload_leaves_draft_and_rerun_retains_matching_assets(self):
        self.github.fail_upload = "SHA256SUMS"
        with self.assertRaises(automation.APIError):
            self.publish()
        self.assertTrue(self.github.releases[0]["draft"])
        self.assertEqual(len(self.github.assets[1]), 1)
        self.assertFalse(self.github.tags)
        first_asset = copy.deepcopy(self.github.assets[1][0])
        self.github.fail_upload = None
        self.assertTrue(self.publish()["published"])
        self.assertEqual(self.github.assets[1][0], first_asset)
        self.assertFalse(any(request[0] == "DELETE" for request in self.github.requests))

    def test_corrupt_owned_draft_asset_can_be_replaced_without_touching_published_assets(self):
        self.github.add_release(release(draft=True))
        self.github.assets[1] = [{"id": 80, "name": self.filename, "size": 3, "state": "starter", "digest": None}]
        self.assertTrue(self.publish()["published"])
        self.assertEqual([request[1] for request in self.github.requests if request[0] == "DELETE"],
                         [f"repos/{REPOSITORY}/releases/assets/80"])

    def test_foreign_marker_or_published_prerelease_never_has_assets_overwritten(self):
        cases = [release(draft=True, commit=OTHER_COMMIT), release(draft=True), release(prerelease=True)]
        cases[0]["author"]["login"] = "human"
        cases[1]["body"] = "A manually prepared draft without ownership."
        for value in cases:
            with self.subTest(release=value):
                self.github = FakeGitHub()
                self.github.add_release(value)
                with self.assertRaises(automation.ReleaseError):
                    self.publish()
                self.assertFalse(self.github.mutations)

    def test_duplicate_source_marker_and_unexpected_draft_assets_fail_closed(self):
        value = release(draft=True)
        value["body"] += f"Source commit: {OTHER_COMMIT}\n"
        self.github.add_release(value)
        with self.assertRaisesRegex(automation.ReleaseError, "not owned"):
            self.publish()
        value["body"] = f"{automation.AUTOMATION_MARKER}\nSource commit: {COMMIT}\n"
        self.github.assets[1] = [{"id": 80, "name": "unrelated.zip"}]
        with self.assertRaisesRegex(automation.ReleaseError, "unexpected"):
            self.publish()
        self.assertFalse(self.github.mutations)

    def test_wrong_remote_digest_stops_before_tag_or_publication(self):
        self.github.bad_digest = self.filename
        with self.assertRaisesRegex(automation.ReleaseError, "Uploaded asset"):
            self.publish()
        self.assertTrue(self.github.releases[0]["draft"])
        self.assertFalse(self.github.tags)
        self.assertFalse(any(request[0] == "PATCH" for request in self.github.requests))

    def test_main_advancing_during_upload_keeps_release_in_draft(self):
        def advance(github, endpoint, method, payload):
            if method == "POST" and endpoint.startswith("https://uploads.github.com/") and "release-manifest.json" in endpoint:
                github.head = OTHER_COMMIT
        self.github.hook = advance
        result = self.publish()
        self.assertFalse(result["published"])
        self.assertTrue(self.github.releases[0]["draft"])
        self.assertFalse(self.github.tags)

    def test_next_main_skips_abandoned_draft_and_publishes_without_deleting_anything(self):
        def advance(github, endpoint, method, payload):
            if method == "POST" and endpoint.startswith("https://uploads.github.com/") and "release-manifest.json" in endpoint:
                github.head = OTHER_COMMIT
        self.github.hook = advance
        self.assertFalse(self.publish()["published"])
        old_draft = copy.deepcopy(self.github.releases[0])
        old_assets = copy.deepcopy(self.github.assets[1])
        self.github.hook = None
        self.github.runs[24] = successful_run(24, OTHER_COMMIT)
        self.github.jobs[24] = [{**job, "run_id": 24, "head_sha": OTHER_COMMIT} for job in self.github.jobs[23]]
        event = {"action": "completed", "repository": {"full_name": REPOSITORY},
                 "workflow_run": successful_run(24, OTHER_COMMIT)}
        plan = automation.make_plan(self.github, "workflow_run", event, {})
        self.assertEqual(plan["tag"], "v0.1.1")
        new_name = "Omabox-0.1.1-arm64.dmg"
        (self.directory / self.filename).rename(self.directory / new_name)
        manifest = {**self.manifest, "version": "0.1.1", "buildNumber": "12", "file": new_name}
        (self.directory / "release-manifest.json").write_text(json.dumps(manifest))
        (self.directory / "SHA256SUMS").write_text(f"{manifest['sha256']}  {new_name}\n")
        automation.verify_artifacts(self.directory, "0.1.1", "12", OTHER_COMMIT, 24, TEAM, add_provenance=True)
        result = automation.publish(self.github, self.directory, plan, "12", TEAM)
        self.assertTrue(result["published"])
        self.assertEqual(self.github.releases[0], old_draft)
        self.assertEqual(self.github.assets[1], old_assets)
        self.assertEqual(self.github.tags["v0.1.1"]["sha"], OTHER_COMMIT)
        self.assertFalse(any(request[0] == "DELETE" for request in self.github.requests))

    def test_main_advancing_after_tag_creation_keeps_tag_and_reserves_old_draft(self):
        def advance(github, endpoint, method, payload):
            if method == "GET" and endpoint.endswith("git/ref/heads/main") and "v0.1.0" in github.tags:
                github.head = OTHER_COMMIT
        self.github.hook = advance
        result = self.publish()
        self.assertFalse(result["published"])
        self.assertEqual(self.github.tags["v0.1.0"]["sha"], COMMIT)
        self.assertTrue(self.github.releases[0]["draft"])
        self.assertEqual(automation.available_version(self.github.releases, OTHER_COMMIT), "0.1.1")
        self.assertFalse(any(request[0] in ("DELETE", "PATCH") for request in self.github.requests))

    def test_release_published_externally_during_upload_is_not_modified_again(self):
        def external_publication(github, endpoint, method, payload):
            if method == "GET" and endpoint == f"repos/{REPOSITORY}/releases/1" and len(github.assets.get(1, [])) == 1:
                github.releases[0]["draft"] = False
                github.releases[0]["published_at"] = "2026-09-11T00:00:00Z"
        self.github.hook = external_publication
        with self.assertRaisesRegex(automation.ReleaseError, "published release"):
            self.publish()
        self.assertEqual(sum(request[3] is not None for request in self.github.mutations), 1)
        self.assertFalse(any(request[0] in ("PATCH", "DELETE") for request in self.github.requests))

    def test_tag_collision_does_not_create_draft(self):
        self.github.tags["v0.1.0"] = {"type": "commit", "sha": OTHER_COMMIT}
        with self.assertRaisesRegex(automation.ReleaseError, "another commit"):
            self.publish()
        self.assertFalse(self.github.mutations)


class GitHubBoundaryTests(unittest.TestCase):
    def test_json_mutations_use_structured_stdin_without_shell_interpolation(self):
        client = automation.GitHub(REPOSITORY, {"GH_TOKEN": "test-token", "GH_HOST": "untrusted.example"})
        response = subprocess.CompletedProcess([], 0, b'HTTP/2.0 201 Created\r\ncontent-type: application/json\r\n\r\n{"id":1}\n', b"")
        payload = {"body": "Literal $(command) `text`\nSecond line", "draft": True}
        with patch.object(automation.subprocess, "run", return_value=response) as run:
            self.assertEqual(client.api(f"repos/{REPOSITORY}/releases", "POST", payload), {"id": 1})
        command = run.call_args.args[0]
        self.assertIsInstance(command, list)
        self.assertNotIn("test-token", command)
        self.assertEqual(json.loads(run.call_args.kwargs["input"]), payload)
        self.assertEqual(run.call_args.kwargs["env"]["GH_HOST"], "github.com")
        self.assertFalse(run.call_args.kwargs.get("shell", False))

    def test_optional_handles_only_404_and_does_not_mask_other_api_failures(self):
        client = automation.GitHub(REPOSITORY, {})
        for status in (404, 403, 500):
            result = subprocess.CompletedProcess([], 1, f"HTTP/2.0 {status} Failed\n\n{{}}".encode(), b"")
            with self.subTest(status=status), patch.object(automation.subprocess, "run", return_value=result):
                if status == 404:
                    self.assertIsNone(client.optional(f"repos/{REPOSITORY}/git/ref/tags/v0.1.0"))
                else:
                    with self.assertRaises(automation.APIError):
                        client.optional(f"repos/{REPOSITORY}/git/ref/tags/v0.1.0")

    def test_untrusted_destination_is_rejected_without_a_subprocess(self):
        client = automation.GitHub(REPOSITORY, {})
        with patch.object(automation.subprocess, "run") as run:
            with self.assertRaises(automation.ReleaseError):
                client.api("https://untrusted.example/collect")
            run.assert_not_called()


if __name__ == "__main__":
    unittest.main()
