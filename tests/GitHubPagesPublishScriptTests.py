#!/usr/bin/env python3

from __future__ import annotations

import os
import signal
import shutil
import subprocess
import tempfile
import time
import unittest
from pathlib import Path


PROJECT_ROOT = Path(__file__).resolve().parents[1]
PUBLISH_SCRIPT = PROJECT_ROOT / "scripts" / "publish_github_pages.sh"


class GitHubPagesPublishScriptTests(unittest.TestCase):
    def run_command(
        self,
        arguments: tuple[str, ...],
        *,
        cwd: Path,
        env: dict[str, str] | None = None,
        check: bool = True,
    ) -> subprocess.CompletedProcess[str]:
        command_env = os.environ.copy()
        if env:
            command_env.update(env)
        return subprocess.run(
            arguments,
            cwd=cwd,
            env=command_env,
            check=check,
            capture_output=True,
            text=True,
        )

    def git(self, repository: Path, *arguments: str) -> subprocess.CompletedProcess[str]:
        return self.run_command(("git", *arguments), cwd=repository)

    def make_fixture(self, root: Path) -> tuple[Path, Path]:
        project = root / "ProjectX"
        remote = root / "remote.git"
        scripts = project / "scripts"
        pages = project / "pages"
        scripts.mkdir(parents=True)
        pages.mkdir()

        shutil.copy2(PUBLISH_SCRIPT, scripts / PUBLISH_SCRIPT.name)
        (scripts / "deploy_sileo.sh").write_text(
            """#!/bin/sh
set -eu
project_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
if [ "${1:-}" = "--dry-run" ]; then
    echo "dry-run fixture"
    exit 0
fi
mkdir -p "$project_root/.deploy/repo" "$project_root/.deploy/tmp"
""",
            encoding="utf-8",
        )
        (scripts / "render_github_pages.py").write_text(
            """#!/bin/sh
set -eu
output=""
while [ "$#" -gt 0 ]; do
    case "$1" in
        --output) output=$2; shift 2 ;;
        *) shift ;;
    esac
done
[ -n "$output" ]
if [ -n "${PUBLISH_FIXTURE_WAIT_FILE:-}" ]; then
    : > "$PUBLISH_FIXTURE_WAIT_FILE"
    while :; do sleep 1; done
fi
version=${PUBLISH_FIXTURE_VERSION:-1.0.0}
printf '%s\n' "$version" > "$output/index.html"
printf '%s\n' 'fixture package' > "$output/Packages"
printf '%s\n' "version=$version"
printf '%s\n' 'sha256=fixture-sha256'
""",
            encoding="utf-8",
        )
        for executable in (
            scripts / PUBLISH_SCRIPT.name,
            scripts / "deploy_sileo.sh",
            scripts / "render_github_pages.py",
        ):
            executable.chmod(0o755)

        (pages / "index.html").write_text("fixture\n", encoding="utf-8")
        (pages / "depiction.json").write_text("{}\n", encoding="utf-8")
        (project / ".gitignore").write_text(".deploy/\n", encoding="utf-8")

        self.run_command(("git", "init", "--quiet", "--initial-branch=main"), cwd=project)
        self.git(project, "config", "user.name", "Publication Test")
        self.git(project, "config", "user.email", "publication@example.invalid")
        self.git(project, "add", ".")
        self.git(project, "commit", "--quiet", "-m", "fixture main")
        self.run_command(("git", "init", "--quiet", "--bare", str(remote)), cwd=root)
        self.git(project, "remote", "add", "origin", str(remote))
        self.git(project, "push", "--quiet", "-u", "origin", "main")
        return project, remote

    def publish(self, project: Path, **environment: str) -> subprocess.CompletedProcess[str]:
        return self.run_command(
            (str(project / "scripts" / PUBLISH_SCRIPT.name), "publish"),
            cwd=project,
            env=environment,
            check=False,
        )

    def test_first_publish_and_no_change_repeat_preserve_main(self):
        with tempfile.TemporaryDirectory() as temporary:
            project, remote = self.make_fixture(Path(temporary))
            original_head = self.git(project, "rev-parse", "HEAD").stdout.strip()

            first = self.publish(project)
            self.assertEqual(first.returncode, 0, first.stderr)
            self.assertIn("published_version=1.0.0", first.stdout)
            self.assertEqual(
                self.run_command(
                    ("git", "--git-dir", str(remote), "show", "gh-pages:index.html"),
                    cwd=project,
                ).stdout,
                "1.0.0\n",
            )

            second = self.publish(project)
            self.assertEqual(second.returncode, 0, second.stderr)
            self.assertIn("already_published_version=1.0.0", second.stdout)
            self.assertEqual(self.git(project, "branch", "--show-current").stdout.strip(), "main")
            self.assertEqual(self.git(project, "rev-parse", "HEAD").stdout.strip(), original_head)
            self.assertEqual(self.git(project, "status", "--porcelain").stdout, "")

    def test_rejects_dirty_non_main_and_stale_main(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            project, remote = self.make_fixture(root)

            (project / "pages" / "index.html").write_text("dirty\n", encoding="utf-8")
            dirty = self.run_command(
                (str(project / "scripts" / PUBLISH_SCRIPT.name), "--dry-run", "publish"),
                cwd=project,
                check=False,
            )
            self.assertNotEqual(dirty.returncode, 0)
            self.assertIn("must be clean", dirty.stderr)
            self.git(project, "restore", "pages/index.html")

            self.git(project, "switch", "--quiet", "-c", "topic")
            non_main = self.run_command(
                (str(project / "scripts" / PUBLISH_SCRIPT.name), "--dry-run", "publish"),
                cwd=project,
                check=False,
            )
            self.assertNotEqual(non_main.returncode, 0)
            self.assertIn("main branch", non_main.stderr)
            self.git(project, "switch", "--quiet", "main")

            actor = root / "actor"
            self.run_command(
                ("git", "clone", "--quiet", "--branch", "main", str(remote), str(actor)),
                cwd=root,
            )
            self.git(actor, "config", "user.name", "Concurrent Publisher")
            self.git(actor, "config", "user.email", "concurrent@example.invalid")
            (actor / "remote-change").write_text("new main\n", encoding="utf-8")
            self.git(actor, "add", "remote-change")
            self.git(actor, "commit", "--quiet", "-m", "advance main")
            self.git(actor, "push", "--quiet", "origin", "main")

            stale = self.run_command(
                (str(project / "scripts" / PUBLISH_SCRIPT.name), "--dry-run", "publish"),
                cwd=project,
                check=False,
            )
            self.assertNotEqual(stale.returncode, 0)
            self.assertIn("exactly match origin/main", stale.stderr)

    def test_concurrent_gh_pages_update_rejects_non_fast_forward_push(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            project, remote = self.make_fixture(root)
            first = self.publish(project)
            self.assertEqual(first.returncode, 0, first.stderr)

            template = root / "git-template"
            hooks = template / "hooks"
            hooks.mkdir(parents=True)
            pre_push = hooks / "pre-push"
            pre_push.write_text(
                """#!/bin/sh
set -eu
remote_url=$2
race_dir=$(mktemp -d)
trap 'rm -rf "$race_dir"' EXIT HUP INT TERM
git clone --quiet --branch gh-pages "$remote_url" "$race_dir"
printf '%s\n' race > "$race_dir/concurrent-update"
git -C "$race_dir" add concurrent-update
git -C "$race_dir" -c user.name='Race Test' -c user.email='race@example.invalid' \
    commit --quiet -m 'concurrent pages update'
git -C "$race_dir" -c core.hooksPath=/dev/null push --quiet origin HEAD:gh-pages
""",
                encoding="utf-8",
            )
            pre_push.chmod(0o755)

            raced = self.publish(
                project,
                PUBLISH_FIXTURE_VERSION="2.0.0",
                GIT_TEMPLATE_DIR=str(template),
            )
            self.assertNotEqual(raced.returncode, 0)
            self.assertIn("rejected", raced.stderr)
            self.assertEqual(
                self.run_command(
                    ("git", "--git-dir", str(remote), "show", "gh-pages:index.html"),
                    cwd=project,
                ).stdout,
                "1.0.0\n",
            )
            self.run_command(
                ("git", "--git-dir", str(remote), "show", "gh-pages:concurrent-update"),
                cwd=project,
            )

    def test_remote_main_advance_after_pages_commit_stops_push(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            project, remote = self.make_fixture(root)
            template = root / "git-template"
            hooks = template / "hooks"
            hooks.mkdir(parents=True)
            post_commit = hooks / "post-commit"
            post_commit.write_text(
                """#!/bin/sh
set -eu
remote_url=$(git remote get-url origin)
race_dir=$(mktemp -d)
trap 'rm -rf "$race_dir"' EXIT HUP INT TERM
git clone --quiet --branch main "$remote_url" "$race_dir"
printf '%s\n' advanced > "$race_dir/concurrent-main-update"
git -C "$race_dir" add concurrent-main-update
git -C "$race_dir" -c core.hooksPath=/dev/null \
    -c user.name='Main Race Test' -c user.email='main-race@example.invalid' \
    commit --quiet -m 'advance main during pages commit'
git -C "$race_dir" -c core.hooksPath=/dev/null push --quiet origin HEAD:main
""",
                encoding="utf-8",
            )
            post_commit.chmod(0o755)

            raced = self.publish(project, GIT_TEMPLATE_DIR=str(template))
            self.assertNotEqual(raced.returncode, 0)
            self.assertIn("exactly match origin/main", raced.stderr)
            pages_ref = self.run_command(
                ("git", "--git-dir", str(remote), "show-ref", "--verify", "refs/heads/gh-pages"),
                cwd=project,
                check=False,
            )
            self.assertNotEqual(pages_ref.returncode, 0)
            self.run_command(
                (
                    "git",
                    "--git-dir",
                    str(remote),
                    "show",
                    "main:concurrent-main-update",
                ),
                cwd=project,
            )

    def test_termination_stops_publication_and_cleans_temporary_repository(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            project, remote = self.make_fixture(root)
            ready = root / "renderer-ready"
            environment = os.environ.copy()
            environment["PUBLISH_FIXTURE_WAIT_FILE"] = str(ready)
            process = subprocess.Popen(
                (str(project / "scripts" / PUBLISH_SCRIPT.name), "publish"),
                cwd=project,
                env=environment,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
                start_new_session=True,
            )
            deadline = time.monotonic() + 10
            while not ready.exists() and process.poll() is None and time.monotonic() < deadline:
                time.sleep(0.05)
            self.assertTrue(ready.exists(), "publisher did not reach the renderer wait point")

            os.killpg(process.pid, signal.SIGTERM)
            _, stderr = process.communicate(timeout=10)
            self.assertNotEqual(process.returncode, 0, stderr)
            pages_ref = self.run_command(
                ("git", "--git-dir", str(remote), "show-ref", "--verify", "refs/heads/gh-pages"),
                cwd=project,
                check=False,
            )
            self.assertNotEqual(pages_ref.returncode, 0)
            temporary_repositories = list((project / ".deploy" / "tmp").glob("github-pages.*"))
            self.assertEqual(temporary_repositories, [])


if __name__ == "__main__":
    unittest.main()
