#!/usr/bin/env python3

"""Plan, verify, and publish a tested main-branch Omabox release."""

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import stat
import subprocess
import sys
import tempfile
from urllib.parse import quote, urlencode


SHA_PATTERN = re.compile(r"[0-9a-f]{40}\Z")
VERSION_PATTERN = re.compile(r"(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\Z")
REPO_PATTERN = re.compile(r"[A-Za-z0-9][A-Za-z0-9-]*/[A-Za-z0-9_.-]+\Z")
REQUIRED_JOBS = {"Native build and unit tests", "Guest service tests"}
AUTOMATION_MARKER = "Automation: Omabox release workflow (schema 1)"
MAX_ASSET_BYTES = 2_147_483_648
MAX_METADATA_BYTES = 1_048_576


class ReleaseError(Exception):
    pass


class APIError(ReleaseError):
    def __init__(self, message, status=None):
        super().__init__(message)
        self.status = status


def require(condition, message):
    if not condition:
        raise ReleaseError(message)


def valid_sha(value):
    require(isinstance(value, str) and SHA_PATTERN.fullmatch(value), "Expected a full lowercase 40-character commit SHA.")
    return value


def positive_integer(value, label):
    require(not isinstance(value, bool) and isinstance(value, (int, str)), f"Invalid {label}.")
    require(re.fullmatch(r"[1-9][0-9]{0,19}", str(value)), f"Invalid {label}.")
    return int(value)


def version_tuple(value):
    require(isinstance(value, str) and len(value) <= 64, "Invalid release version.")
    match = VERSION_PATTERN.fullmatch(value)
    require(match is not None, "Expected a MAJOR.MINOR.PATCH release version without leading zeroes.")
    return tuple(map(int, match.groups()))


def unique_object(pairs):
    result = {}
    for key, value in pairs:
        require(key not in result, f"Duplicate JSON field: {key}")
        result[key] = value
    return result


def parse_json(data):
    try:
        return json.loads(data, object_pairs_hook=unique_object)
    except (UnicodeError, json.JSONDecodeError) as error:
        raise ReleaseError("Invalid JSON document.") from error


def regular_file(path):
    try:
        info = path.lstat()
    except OSError as error:
        raise ReleaseError(f"Cannot read required file: {path.name}") from error
    require(stat.S_ISREG(info.st_mode), f"Expected a regular file without a symlink: {path.name}")
    return info


def read_small_file(path, limit=MAX_METADATA_BYTES):
    info = regular_file(path)
    require(info.st_size <= limit, f"Metadata is too large: {path.name}")
    descriptor = os.open(path, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0))
    with os.fdopen(descriptor, "rb") as stream:
        require(stat.S_ISREG(os.fstat(stream.fileno()).st_mode), f"Not a regular file: {path.name}")
        result = stream.read(limit + 1)
    require(len(result) <= limit, f"Metadata is too large: {path.name}")
    return result


def file_integrity(path):
    regular_file(path)
    descriptor = os.open(path, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0))
    digest = hashlib.sha256()
    with os.fdopen(descriptor, "rb") as stream:
        before = os.fstat(stream.fileno())
        require(stat.S_ISREG(before.st_mode), f"Not a regular file: {path.name}")
        require(0 < before.st_size < MAX_ASSET_BYTES, f"Asset must be nonempty and smaller than 2 GiB: {path.name}")
        for chunk in iter(lambda: stream.read(8 * 1024 * 1024), b""):
            digest.update(chunk)
        after = os.fstat(stream.fileno())
    require((before.st_size, before.st_mtime_ns, before.st_ino) ==
            (after.st_size, after.st_mtime_ns, after.st_ino), f"Asset changed during verification: {path.name}")
    return {"size": after.st_size, "sha256": digest.hexdigest()}


class GitHub:
    def __init__(self, repository, environment=None):
        require(isinstance(repository, str) and REPO_PATTERN.fullmatch(repository), "Set GH_REPO to owner/repository.")
        require(repository.split("/")[1] not in (".", ".."), "Invalid repository name.")
        self.repository = repository
        self.environment = dict(os.environ if environment is None else environment)
        self.environment.update(GH_HOST="github.com", GH_PROMPT_DISABLED="1")

    def api(self, endpoint, method="GET", payload=None, upload=None):
        upload_prefix = f"https://uploads.github.com/repos/{self.repository}/releases/"
        require(endpoint.startswith(f"repos/{self.repository}/") or
                (upload is not None and endpoint.startswith(upload_prefix)), "Unexpected GitHub API destination.")
        require(payload is None or upload is None, "Cannot combine JSON and file uploads.")
        command = ["gh", "api", "--hostname", "github.com", "--method", method,
                   "--include", "-H", "Accept: application/vnd.github+json",
                   "-H", "X-GitHub-Api-Version: 2022-11-28", endpoint]
        data = None
        if payload is not None:
            command.extend(["--input", "-"])
            data = json.dumps(payload).encode()
        if upload is not None:
            command.extend(["-H", "Content-Type: application/octet-stream", "--input", str(upload)])
        result = subprocess.run(command, input=data, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                env=self.environment, timeout=1800 if upload is not None else 120, check=False)
        output = result.stdout.replace(b"\r\n", b"\n")
        header, separator, body = output.partition(b"\n\n")
        status_match = re.match(rb"HTTP/\S+ ([0-9]{3})\b", header)
        status = int(status_match[1]) if status_match else None
        if result.returncode or status is None or not 200 <= status < 300:
            if status is None:
                error_status = re.search(rb"\(HTTP ([0-9]{3})\)", result.stderr)
                status = int(error_status[1]) if error_status else None
            raise APIError(f"GitHub {method} request failed" + (f" (HTTP {status})." if status else "."), status)
        require(separator, "GitHub returned an invalid HTTP response.")
        return parse_json(body) if body.strip() else None

    def optional(self, endpoint):
        try:
            return self.api(endpoint)
        except APIError as error:
            if error.status == 404:
                return None
            raise

    def pages(self, endpoint, key=None):
        values = []
        separator = "&" if "?" in endpoint else "?"
        for page in range(1, 1001):
            response = self.api(f"{endpoint}{separator}per_page=100&page={page}")
            batch = response.get(key) if key and isinstance(response, dict) else response
            require(isinstance(batch, list), "GitHub pagination returned an invalid list.")
            require(all(isinstance(item, dict) for item in batch), "GitHub pagination returned invalid entries.")
            values.extend(batch)
            if len(batch) < 100:
                return values
        raise ReleaseError("GitHub pagination exceeded its safety limit.")

    def upload(self, release_id, path):
        identifier = positive_integer(release_id, "release ID")
        endpoint = (f"https://uploads.github.com/repos/{self.repository}/releases/{identifier}/assets?"
                    + urlencode({"name": path.name}))
        return self.api(endpoint, "POST", upload=path)


def same_repository(value, repository):
    return isinstance(value, dict) and isinstance(value.get("full_name"), str) and value["full_name"].lower() == repository.lower()


def main_commit(github):
    reference = github.api(f"repos/{github.repository}/git/ref/heads/main")
    require(isinstance(reference, dict) and reference.get("ref") == "refs/heads/main", "Invalid main branch reference.")
    target = reference.get("object", {})
    require(target.get("type") == "commit", "Main must point to a commit.")
    return valid_sha(target.get("sha"))


def trusted_run_metadata(run, repository, commit):
    require(isinstance(run, dict), "Invalid CI run.")
    require(same_repository(run.get("repository"), repository) and
            same_repository(run.get("head_repository"), repository), "CI must originate in this repository.")
    require(run.get("head_branch") == "main" and run.get("event") == "push", "CI must be a push on main.")
    require(run.get("status") == "completed" and run.get("conclusion") == "success", "CI must have completed successfully.")
    require(valid_sha(run.get("head_sha")) == commit, "CI does not match the candidate commit.")


def verify_ci(github, run_id, commit):
    identifier = positive_integer(run_id, "CI run ID")
    workflow = github.api(f"repos/{github.repository}/actions/workflows/ci.yml")
    require(isinstance(workflow, dict) and workflow.get("path") == ".github/workflows/ci.yml", "CI workflow path does not match ci.yml.")
    workflow_id = positive_integer(workflow.get("id"), "CI workflow ID")
    run = github.api(f"repos/{github.repository}/actions/runs/{identifier}")
    trusted_run_metadata(run, github.repository, commit)
    require(run.get("id") == identifier and run.get("workflow_id") == workflow_id, "CI run does not belong to ci.yml.")
    jobs = github.pages(f"repos/{github.repository}/actions/runs/{identifier}/jobs?filter=latest", "jobs")
    for name in REQUIRED_JOBS:
        matches = [job for job in jobs if job.get("name") == name]
        require(len(matches) == 1, f"CI must contain exactly one required job: {name}")
        job = matches[0]
        require(job.get("status") == "completed" and job.get("conclusion") == "success", f"Required CI job did not pass: {name}")
        require(job.get("run_id", identifier) == identifier and job.get("head_sha", commit) == commit,
                f"Required CI job belongs to another run or commit: {name}")
    return identifier


def find_successful_ci(github, commit):
    query = urlencode({"event": "push", "status": "success", "branch": "main", "head_sha": commit})
    runs = github.pages(f"repos/{github.repository}/actions/workflows/ci.yml/runs?{query}", "workflow_runs")
    for run in sorted(runs, key=lambda item: positive_integer(item.get("id"), "CI run ID"), reverse=True):
        try:
            trusted_run_metadata(run, github.repository, commit)
            return verify_ci(github, run["id"], commit)
        except APIError:
            raise
        except ReleaseError:
            continue
    raise ReleaseError("No trusted successful push CI run with both required jobs exists for this main commit.")


def stable_releases(releases):
    return [release for release in releases if release.get("draft") is False
            and release.get("prerelease") is False and release.get("published_at")]


def next_version(releases):
    versions = []
    for release in stable_releases(releases):
        tag = release.get("tag_name")
        if isinstance(tag, str) and tag.startswith("v"):
            try:
                versions.append(version_tuple(tag[1:]))
            except ReleaseError:
                continue
    if not versions:
        return "0.1.0"
    major, minor, patch = max(versions)
    return f"{major}.{minor}.{patch + 1}"


def tag_commit(github, tag, optional=False):
    require(isinstance(tag, str) and tag and len(tag) <= 256, "Invalid Git tag.")
    reference = github.optional(f"repos/{github.repository}/git/ref/tags/{quote(tag, safe='')}")
    if reference is None:
        require(optional, f"Published release tag is missing: {tag}")
        return None
    require(isinstance(reference, dict) and reference.get("ref") == f"refs/tags/{tag}", "GitHub returned another tag reference.")
    target = reference.get("object", {})
    visited = set()
    for _ in range(16):
        sha = valid_sha(target.get("sha"))
        if target.get("type") == "commit":
            return sha
        require(target.get("type") == "tag" and sha not in visited, "Tag does not resolve to a commit.")
        visited.add(sha)
        annotation = github.api(f"repos/{github.repository}/git/tags/{sha}")
        require(isinstance(annotation, dict), "Invalid annotated tag.")
        target = annotation.get("object", {})
    raise ReleaseError("Annotated tag chain exceeds the safety limit.")


def published_for_commit(github, releases, commit):
    for release in stable_releases(releases):
        if tag_commit(github, release.get("tag_name")) == commit:
            return release
    return None


def owned_draft_commit(release):
    require(isinstance(release, dict) and release.get("draft") is True
            and not release.get("published_at") and release.get("prerelease") is False,
            "Refusing to modify a published release or a prerelease.")
    require(release.get("author", {}).get("login") == "github-actions[bot]", "Draft was not created by the release automation bot.")
    body = release.get("body")
    require(isinstance(body, str), "Draft has no source ownership marker.")
    automation_markers = [line for line in body.splitlines() if line.startswith("Automation:")]
    require(automation_markers == [AUTOMATION_MARKER], "Draft has no trusted automation ownership marker.")
    markers = [line for line in body.splitlines() if line.startswith("Source commit:")]
    require(len(markers) == 1 and markers[0].startswith("Source commit: "), "Draft is not owned by one source commit.")
    commit = valid_sha(markers[0][len("Source commit: "):])
    require(release.get("target_commitish") == commit, "Draft source marker does not match its target commit.")
    positive_integer(release.get("id"), "release ID")
    return commit


def ensure_owned_draft(release, tag, commit):
    source = owned_draft_commit(release)
    require(release.get("tag_name") == tag and source == commit, "Draft release does not target this version and commit.")
    return release


def release_collision(releases, tag, commit):
    matches = [release for release in releases if release.get("tag_name") == tag]
    require(len(matches) <= 1, "Multiple releases use the planned tag.")
    return ensure_owned_draft(matches[0], tag, commit) if matches else None


def available_version(releases, commit):
    major, minor, patch = version_tuple(next_version(releases))
    for _ in range(1000):
        version = f"{major}.{minor}.{patch}"
        matches = [release for release in releases if release.get("tag_name") == "v" + version]
        require(len(matches) <= 1, "Multiple releases use the planned tag.")
        if not matches or owned_draft_commit(matches[0]) == commit:
            return version
        patch += 1
    raise ReleaseError("Too many versions are reserved by unfinished release drafts.")


def make_plan(github, event_name, event, environment=None):
    environment = os.environ if environment is None else environment
    require(isinstance(event, dict) and same_repository(event.get("repository"), github.repository), "Event must belong to GH_REPO.")
    identifier = None
    if event_name == "workflow_run":
        run = event.get("workflow_run", {})
        commit = valid_sha(run.get("head_sha"))
        trusted_run_metadata(run, github.repository, commit)
        require(event.get("action") == "completed", "Expected a completed workflow_run event.")
        identifier = positive_integer(run.get("id"), "CI run ID")
    elif event_name == "workflow_dispatch":
        require(event.get("ref") in ("main", "refs/heads/main"), "Manual releases must run on main.")
        require(environment.get("GITHUB_REF", "refs/heads/main") == "refs/heads/main", "Manual workflow ref must be main.")
        inputs = event.get("inputs") or {}
        require(isinstance(inputs, dict), "Invalid manual workflow inputs.")
        requested = inputs.get("commit")
        commit = valid_sha(requested) if requested else None
    else:
        raise ReleaseError("Only workflow_run and workflow_dispatch events may plan releases.")
    head = main_commit(github)
    commit = commit or head
    plan = {"schemaVersion": 1, "repository": github.repository, "should_release": False,
            "reason": "", "commit": commit, "ci_run_id": identifier, "version": "", "tag": ""}
    if commit != head:
        return {**plan, "reason": "Candidate is no longer the current main commit."}
    identifier = verify_ci(github, identifier, commit) if identifier else find_successful_ci(github, commit)
    plan["ci_run_id"] = identifier
    releases = github.pages(f"repos/{github.repository}/releases")
    existing = published_for_commit(github, releases, commit)
    if existing:
        return {**plan, "reason": "This source commit already has a published stable release.", "tag": existing["tag_name"]}
    version = available_version(releases, commit)
    tag = f"v{version}"
    release_collision(releases, tag, commit)
    existing_target = tag_commit(github, tag, optional=True)
    require(existing_target in (None, commit), "Planned tag already points to another commit.")
    return {**plan, "should_release": True, "reason": "Current main passed both required CI jobs.", "version": version, "tag": tag}


def write_plan(plan, path, github_output=None):
    path.write_text(json.dumps(plan, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    if github_output:
        with open(github_output, "a", encoding="utf-8") as stream:
            for key in ("should_release", "tag", "version", "commit", "ci_run_id"):
                value = plan.get(key)
                text = str(value).lower() if isinstance(value, bool) else "" if value is None else str(value)
                require("\n" not in text and "\r" not in text, "Unsafe workflow output.")
                stream.write(f"{key}={text}\n")


def verify_artifacts(directory, version, build, commit, ci_run, team, add_provenance=False):
    version_tuple(version)
    build = str(positive_integer(build, "build number"))
    commit = valid_sha(commit)
    ci_run = positive_integer(ci_run, "CI run ID")
    require(isinstance(team, str) and re.fullmatch(r"[A-Z0-9]{10}", team), "Invalid signing team ID.")
    directory = Path(directory)
    require(directory.is_dir() and not directory.is_symlink(), "Release directory must be a directory without a symlink.")
    files = list(directory.iterdir())
    for path in files:
        regular_file(path)
    filename = f"Omabox-{version}-arm64.dmg"
    require([path.name for path in files if path.suffix.lower() == ".dmg"] == [filename], "Expected exactly the versioned arm64 DMG.")
    manifest_path = directory / "release-manifest.json"
    manifest = parse_json(read_small_file(manifest_path))
    require(isinstance(manifest, dict), "Invalid release manifest.")
    expected = {"schemaVersion": 1, "version": version, "buildNumber": build, "teamID": team,
                "architecture": "arm64", "minimumSystemVersion": "26.0", "file": filename, "verified": True}
    for key, value in expected.items():
        require(type(manifest.get(key)) is type(value) and manifest[key] == value, f"Release manifest mismatch: {key}")
    image = file_integrity(directory / filename)
    require(type(manifest.get("byteCount")) is int and manifest["byteCount"] == image["size"], "DMG byte count does not match its manifest.")
    require(manifest.get("sha256") == image["sha256"], "DMG SHA-256 does not match its manifest.")
    checksum = f"{image['sha256']}  {filename}\n".encode()
    require(read_small_file(directory / "SHA256SUMS", 1024) == checksum, "SHA256SUMS must contain exactly the verified DMG checksum.")
    provenance = {"sourceCommit": commit, "ciRunID": ci_run}
    for key, value in provenance.items():
        if key in manifest:
            require(type(manifest[key]) is type(value) and manifest[key] == value, f"Release provenance mismatch: {key}")
        else:
            require(add_provenance, f"Release manifest lacks provenance: {key}")
    if add_provenance and any(key not in manifest for key in provenance):
        manifest.update(provenance)
        descriptor, temporary = tempfile.mkstemp(prefix=".release-manifest-", dir=directory)
        try:
            with os.fdopen(descriptor, "w", encoding="utf-8") as stream:
                stream.write(json.dumps(manifest, indent=2, sort_keys=True) + "\n")
                stream.flush()
                os.fsync(stream.fileno())
            os.replace(temporary, manifest_path)
        finally:
            if os.path.exists(temporary):
                os.unlink(temporary)
    return {filename: image, "SHA256SUMS": file_integrity(directory / "SHA256SUMS"),
            "release-manifest.json": file_integrity(manifest_path)}


def asset_matches(asset, name, integrity):
    return (isinstance(asset, dict) and asset.get("name") == name and asset.get("state") == "uploaded"
            and type(asset.get("size")) is int and asset["size"] == integrity["size"]
            and asset.get("digest") == f"sha256:{integrity['sha256']}")


def remote_assets(github, release_id):
    return github.pages(f"repos/{github.repository}/releases/{release_id}/assets")


def verify_remote_assets(github, release_id, artifacts):
    assets = remote_assets(github, release_id)
    require(len(assets) == len(artifacts) and {asset.get("name") for asset in assets} == set(artifacts),
            "Remote release must contain exactly the three verified assets.")
    for asset in assets:
        name = asset["name"]
        require(asset_matches(asset, name, artifacts[name]), f"Remote asset size or SHA-256 does not match: {name}")


def current_draft(github, release_id, tag, commit):
    release = github.api(f"repos/{github.repository}/releases/{release_id}")
    require(release.get("id") == release_id, "GitHub returned another release.")
    return ensure_owned_draft(release, tag, commit)


def validate_plan(plan, repository):
    require(isinstance(plan, dict) and type(plan.get("schemaVersion")) is int and plan["schemaVersion"] == 1, "Invalid release plan schema.")
    require(plan.get("repository") == repository, "Release plan belongs to another repository.")
    require(plan.get("should_release") is True, "Release plan does not authorize a release.")
    valid_sha(plan.get("commit"))
    version_tuple(plan.get("version"))
    require(plan.get("tag") == "v" + plan["version"], "Release plan tag and version do not match.")
    positive_integer(plan.get("ci_run_id"), "CI run ID")


def publication_gate(github, plan):
    if main_commit(github) != plan["commit"]:
        return "Candidate is no longer the current main commit."
    verify_ci(github, plan["ci_run_id"], plan["commit"])
    releases = github.pages(f"repos/{github.repository}/releases")
    if published_for_commit(github, releases, plan["commit"]):
        return "This source commit already has a published stable release."
    require(available_version(releases, plan["commit"]) == plan["version"], "Available release version changed after planning; rebuild with a new plan.")
    release_collision(releases, plan["tag"], plan["commit"])
    return None


def publish(github, directory, plan, build, team):
    validate_plan(plan, github.repository)
    directory = Path(directory)
    commit, tag = plan["commit"], plan["tag"]
    artifacts = verify_artifacts(directory, plan["version"], build, commit, plan["ci_run_id"], team)
    reason = publication_gate(github, plan)
    if reason:
        return {"published": False, "reason": reason}
    target = tag_commit(github, tag, optional=True)
    require(target in (None, commit), "Release tag already points to another commit.")
    releases = github.pages(f"repos/{github.repository}/releases")
    draft = release_collision(releases, tag, commit)
    if draft is None:
        body = (f"Omabox {tag} for Apple silicon. Requires macOS 26 or later.\n\n"
                f"{AUTOMATION_MARKER}\n"
                f"Source commit: {commit}\n"
                f"CI run: https://github.com/{github.repository}/actions/runs/{plan['ci_run_id']}\n\n"
                "Download the DMG, open it, and drag Omabox to Applications. "
                "SHA256SUMS and release-manifest.json describe the verified download.\n")
        draft = github.api(f"repos/{github.repository}/releases", "POST", payload={
            "tag_name": tag, "target_commitish": commit, "name": f"Omabox {tag}", "body": body,
            "draft": True, "prerelease": False, "make_latest": "false"})
        ensure_owned_draft(draft, tag, commit)
    release_id = positive_integer(draft["id"], "release ID")
    assets = remote_assets(github, release_id)
    names = [asset.get("name") for asset in assets]
    require(len(set(names)) == len(names) and set(names) <= set(artifacts), "Owned draft contains unexpected or duplicate assets; manual review is required.")
    by_name = {asset["name"]: asset for asset in assets}
    for name, integrity in artifacts.items():
        current_draft(github, release_id, tag, commit)
        require(file_integrity(directory / name) == integrity, f"Local asset changed before upload: {name}")
        existing = by_name.get(name)
        if existing and asset_matches(existing, name, integrity):
            continue
        if existing:
            asset_id = positive_integer(existing.get("id"), "asset ID")
            github.api(f"repos/{github.repository}/releases/assets/{asset_id}", "DELETE")
        current_draft(github, release_id, tag, commit)
        uploaded = github.upload(release_id, directory / name)
        require(asset_matches(uploaded, name, integrity), f"Uploaded asset size or SHA-256 does not match: {name}")
    verify_remote_assets(github, release_id, artifacts)
    reason = publication_gate(github, plan)
    if reason:
        return {"published": False, "reason": reason, "draft_id": release_id}
    current_draft(github, release_id, tag, commit)
    target = tag_commit(github, tag, optional=True)
    require(target in (None, commit), "Release tag changed to another commit.")
    if target is None:
        github.api(f"repos/{github.repository}/git/refs", "POST", payload={"ref": f"refs/tags/{tag}", "sha": commit})
    require(tag_commit(github, tag) == commit, "Release tag does not resolve to the tested commit.")
    if main_commit(github) != commit:
        return {"published": False, "reason": "Main moved before publication.", "draft_id": release_id}
    current_draft(github, release_id, tag, commit)
    released = github.api(f"repos/{github.repository}/releases/{release_id}", "PATCH", payload={
        "draft": False, "prerelease": False, "make_latest": "true", "target_commitish": commit})
    require(isinstance(released, dict) and released.get("draft") is False and released.get("prerelease") is False
            and released.get("tag_name") == tag and released.get("published_at"), "GitHub did not confirm stable publication.")
    require(tag_commit(github, tag) == commit, "Published tag does not match the tested commit.")
    verify_remote_assets(github, release_id, artifacts)
    return {"published": True, "tag": tag, "commit": commit, "url": released.get("html_url")}


def main(arguments=None):
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    planning = commands.add_parser("plan")
    planning.add_argument("--event", required=True, type=Path)
    planning.add_argument("--output", required=True, type=Path)
    verification = commands.add_parser("verify")
    verification.add_argument("--directory", required=True, type=Path)
    verification.add_argument("--version", required=True)
    verification.add_argument("--build", required=True)
    verification.add_argument("--commit", required=True)
    verification.add_argument("--ci-run", required=True)
    verification.add_argument("--team", required=True)
    publishing = commands.add_parser("publish")
    publishing.add_argument("--directory", required=True, type=Path)
    publishing.add_argument("--plan", required=True, type=Path)
    publishing.add_argument("--build", required=True)
    publishing.add_argument("--team", required=True)
    args = parser.parse_args(arguments)
    try:
        if args.command == "verify":
            result = verify_artifacts(args.directory, args.version, args.build, args.commit, args.ci_run, args.team, add_provenance=True)
        else:
            require(os.environ.get("GH_TOKEN"), "Set GH_TOKEN for GitHub API access.")
            github = GitHub(os.environ.get("GH_REPO"))
            if args.command == "plan":
                result = make_plan(github, os.environ.get("GITHUB_EVENT_NAME"), parse_json(read_small_file(args.event)))
                write_plan(result, args.output, os.environ.get("GITHUB_OUTPUT"))
            else:
                result = publish(github, args.directory, parse_json(read_small_file(args.plan)), args.build, args.team)
        print(json.dumps(result, indent=2, sort_keys=True))
        return 0
    except (ReleaseError, OSError, subprocess.SubprocessError) as error:
        print(f"release-automation: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
