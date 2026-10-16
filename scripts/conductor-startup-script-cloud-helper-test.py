#!/usr/bin/env python3
"""Offline tests for the helper embedded in conductor-startup-script-cloud.sh."""

import argparse
import contextlib
import io
import json
import os
import pathlib
import re
import shutil
import subprocess
import sys
import tempfile
import types
import unittest
import urllib.error
from unittest import mock


ROOT = pathlib.Path(__file__).resolve().parents[1]
STARTUP_SCRIPT = ROOT / "scripts" / "conductor-startup-script-cloud.sh"
BASH = shutil.which("bash")
if not BASH:
    raise RuntimeError("bash is required to run the startup-script helper tests")
source = STARTUP_SCRIPT.read_text()


def marked_region(text, start_marker, end_marker, description):
    if text.count(start_marker) != 1 or text.count(end_marker) != 1:
        raise RuntimeError(f"could not find unique {description} markers in startup script")
    start = text.index(start_marker) + len(start_marker)
    end = text.index(end_marker)
    if end <= start:
        raise RuntimeError(f"{description} end marker precedes its start marker")
    return text[start:end]


HELPER_BLOCK = marked_region(
    source,
    "# BEGIN trunk-queue-status Python helper (offline tests extract this range)",
    "# END trunk-queue-status Python helper",
    "Trunk queue Python helper",
)
matches = list(re.finditer(r"<<'PYTHON'[^\n]*\n(.*?)\nPYTHON(?:\r?\n)", HELPER_BLOCK, re.DOTALL))
if len(matches) != 1:
    raise RuntimeError(f"expected one Python heredoc in marked helper block, found {len(matches)}")
HELPER_SOURCE = matches[0].group(1)
INSTALL_FUNCTIONS_SOURCE = marked_region(
    source,
    "# BEGIN trunk-queue-status install functions (offline tests extract this range)",
    "# END trunk-queue-status install functions",
    "Trunk queue install functions",
)
helper = types.ModuleType("trunk_queue_status")
exec(compile(HELPER_SOURCE, str(STARTUP_SCRIPT) + "<trunk-queue-status>", "exec"), helper.__dict__)


class RepositoryTests(unittest.TestCase):
    def test_repo_override_accepts_owner_name_and_custom_branch(self):
        args = argparse.Namespace(repo="octo/widgets.git", remote=None, target_branch="release/1.x")
        with mock.patch.object(helper, "git_output", return_value=""):
            repo, branch = helper.repository(args)
        self.assertEqual(repo, {"host": "github.com", "owner": "octo", "name": "widgets"})
        self.assertEqual(branch, "release/1.x")

    def test_repo_override_accepts_hosted_url(self):
        args = argparse.Namespace(
            repo="https://git.example.test/team/widgets.git", remote=None, target_branch="main"
        )
        with mock.patch.object(helper, "git_output", return_value=""):
            repo, branch = helper.repository(args)
        self.assertEqual(repo, {"host": "git.example.test", "owner": "team", "name": "widgets"})
        self.assertEqual(branch, "main")

    def test_remote_parsing_and_symbolic_default_branch(self):
        args = argparse.Namespace(repo=None, remote=None, target_branch=None)
        with mock.patch.object(
            helper, "git_output", side_effect=["origin\nupstream", "git@git.example.test:team/widgets.git", "origin/trunk"]
        ) as git_output:
            repo, branch = helper.repository(args)
        self.assertEqual(repo, {"host": "git.example.test", "owner": "team", "name": "widgets"})
        self.assertEqual(branch, "trunk")
        self.assertEqual(git_output.call_args_list[-1].args[0][0], "symbolic-ref")

    def test_explicit_remote_must_be_configured(self):
        args = argparse.Namespace(repo="team/widgets", remote="-option", target_branch="main")
        with mock.patch.object(helper, "git_output", return_value="origin") as git_output:
            with self.assertRaisesRegex(helper.StatusError, "is not configured"):
                helper.repository(args)
        git_output.assert_called_once_with(["remote"])

    def test_remote_default_branch_falls_back_to_advertised_head(self):
        args = argparse.Namespace(repo=None, remote=None, target_branch=None)
        with mock.patch.object(
            helper,
            "git_output",
            side_effect=["origin", "https://github.com/team/widgets.git", "", "ref: refs/heads/develop\tHEAD\nabc123\tHEAD"],
        ):
            repo, branch = helper.repository(args)
        self.assertEqual(repo["name"], "widgets")
        self.assertEqual(branch, "develop")

    def test_repo_override_does_not_use_an_unrelated_remote_default(self):
        args = argparse.Namespace(repo="other/widgets", remote=None, target_branch=None)
        with mock.patch.object(
            helper, "git_output", side_effect=["origin", "https://github.com/team/widgets.git"]
        ):
            with self.assertRaisesRegex(helper.StatusError, "pass --target-branch"):
                helper.repository(args)

    def test_matching_repo_override_can_use_remote_default(self):
        args = argparse.Namespace(repo="team/widgets", remote=None, target_branch=None)
        with mock.patch.object(
            helper, "git_output", side_effect=["origin", "https://github.com/team/widgets.git", "origin/main"]
        ):
            repo, branch = helper.repository(args)
        self.assertEqual(repo["owner"], "team")
        self.assertEqual(branch, "main")

    def test_matching_repo_override_ignores_identity_casing(self):
        args = argparse.Namespace(
            repo="GITHUB.COM/TEAM/WIDGETS", remote=None, target_branch=None
        )
        with mock.patch.object(
            helper, "git_output", side_effect=["origin", "https://github.com/team/widgets.git", "origin/main"]
        ):
            repo, branch = helper.repository(args)
        self.assertEqual(repo, {"host": "GITHUB.COM", "owner": "TEAM", "name": "WIDGETS"})
        self.assertEqual(branch, "main")

    def test_ssh_alias_remote_requires_an_explicit_api_host(self):
        args = argparse.Namespace(repo=None, remote=None, target_branch="main")
        with mock.patch.object(
            helper, "git_output", side_effect=["origin", "git@github-deploy:team/widgets.git"]
        ):
            with self.assertRaisesRegex(helper.StatusError, "may be an SSH alias.*--repo"):
                helper.repository(args)

    def test_explicit_host_override_on_ssh_alias_keeps_remote_default_branch(self):
        args = argparse.Namespace(repo="github.com/team/widgets", remote=None, target_branch=None)
        with mock.patch.object(
            helper,
            "git_output",
            side_effect=["origin", "git@github-deploy:team/widgets.git", "origin/main"],
        ) as git_output:
            repo, branch = helper.repository(args)
        self.assertEqual(repo, {"host": "github.com", "owner": "team", "name": "widgets"})
        self.assertEqual(branch, "main")
        self.assertEqual(git_output.call_args_list[-1].args[0][0], "symbolic-ref")

    def test_ls_remote_disables_ssh_prompts_using_git_config(self):
        config = types.SimpleNamespace(stdout="ssh -i /tmp/deploy-key", returncode=0)
        command = types.SimpleNamespace(stdout="", returncode=0)
        with mock.patch.dict(helper.os.environ, {}, clear=True):
            with mock.patch.object(helper.subprocess, "run", side_effect=[config, command]) as run:
                helper.git_output(["ls-remote", "origin", "HEAD"])
        self.assertEqual(run.call_args_list[0].args[0], ["git", "config", "--get", "core.sshCommand"])
        env = run.call_args_list[1].kwargs["env"]
        self.assertEqual(env["GIT_TERMINAL_PROMPT"], "0")
        self.assertEqual(env["GIT_SSH_COMMAND"], "ssh -i /tmp/deploy-key -o BatchMode=yes")

    def test_ls_remote_preserves_environment_ssh_command(self):
        completed = types.SimpleNamespace(stdout="", returncode=0)
        with mock.patch.dict(helper.os.environ, {"GIT_SSH_COMMAND": "ssh -i /tmp/key"}):
            with mock.patch.object(helper.subprocess, "run", return_value=completed) as run:
                helper.git_output(["ls-remote", "origin", "HEAD"])
        self.assertEqual(run.call_count, 1)
        self.assertEqual(run.call_args.kwargs["env"]["GIT_SSH_COMMAND"], "ssh -i /tmp/key -o BatchMode=yes")

    def test_core_ssh_command_takes_precedence_over_git_ssh(self):
        config = types.SimpleNamespace(stdout="ssh -i /tmp/config-key", returncode=0)
        completed = types.SimpleNamespace(stdout="", returncode=0)
        with mock.patch.dict(helper.os.environ, {"GIT_SSH": "/usr/bin/plink"}, clear=True):
            with mock.patch.object(helper.subprocess, "run", side_effect=[config, completed]) as run:
                helper.git_output(["ls-remote", "origin", "HEAD"])
        env = run.call_args_list[1].kwargs["env"]
        self.assertEqual(env["GIT_SSH"], "/usr/bin/plink")
        self.assertEqual(env["GIT_SSH_COMMAND"], "ssh -i /tmp/config-key -o BatchMode=yes")

    def test_non_openssh_core_command_takes_precedence_without_openssh_options(self):
        config = types.SimpleNamespace(stdout="/usr/bin/plink", returncode=0)
        completed = types.SimpleNamespace(stdout="", returncode=0)
        with mock.patch.dict(helper.os.environ, {"GIT_SSH": "/usr/bin/other-ssh"}, clear=True):
            with mock.patch.object(helper.subprocess, "run", side_effect=[config, completed]) as run:
                helper.git_output(["ls-remote", "origin", "HEAD"])
        env = run.call_args_list[1].kwargs["env"]
        self.assertEqual(env["GIT_SSH"], "/usr/bin/other-ssh")
        self.assertEqual(env["GIT_SSH_COMMAND"], "/usr/bin/plink")

    def test_non_openssh_git_ssh_is_preserved_without_openssh_options(self):
        missing_config = types.SimpleNamespace(stdout="", returncode=1)
        completed = types.SimpleNamespace(stdout="", returncode=0)
        with mock.patch.dict(helper.os.environ, {"GIT_SSH": "/usr/bin/plink"}, clear=True):
            with mock.patch.object(helper.subprocess, "run", side_effect=[missing_config, completed]) as run:
                helper.git_output(["ls-remote", "origin", "HEAD"])
        env = run.call_args_list[1].kwargs["env"]
        self.assertEqual(env["GIT_SSH"], "/usr/bin/plink")
        self.assertNotIn("GIT_SSH_COMMAND", env)

    def test_non_network_git_calls_preserve_ssh_configuration(self):
        completed = types.SimpleNamespace(stdout="origin", returncode=0)
        with mock.patch.dict(
            helper.os.environ,
            {"GIT_SSH_COMMAND": "ssh -i /tmp/key", "GIT_SSH": "/tmp/custom-ssh"},
        ):
            with mock.patch.object(helper.subprocess, "run", return_value=completed) as run:
                self.assertEqual(helper.git_output(["remote"]), "origin")
        self.assertEqual(run.call_count, 1)
        env = run.call_args.kwargs["env"]
        self.assertEqual(env["GIT_SSH_COMMAND"], "ssh -i /tmp/key")
        self.assertEqual(env["GIT_SSH"], "/tmp/custom-ssh")
        self.assertEqual(env["GIT_TERMINAL_PROMPT"], "0")

    def test_invalid_list_limits_fail_before_repository_lookup(self):
        cases = (
            (["--limit", "-1"], "--limit must be zero or greater"),
            (["--max-pages", "0"], "--max-pages must be greater than zero"),
        )
        for args, message in cases:
            stderr = io.StringIO()
            with self.subTest(args=args), mock.patch.object(helper.sys, "argv", ["trunk-queue-status", *args]):
                with mock.patch.dict(helper.os.environ, {"TRUNK_API_TOKEN": "token"}):
                    with mock.patch.object(helper, "repository") as repository:
                        with contextlib.redirect_stderr(stderr):
                            self.assertEqual(helper.run(), 1)
                repository.assert_not_called()
            self.assertIn(message, stderr.getvalue())


class ApiTests(unittest.TestCase):
    def test_pagination_collects_pages(self):
        first = {"pullRequests": [{"prNumber": 1}], "nextCursor": "page-2"}
        second = {"pullRequests": [{"prNumber": 2}], "nextCursor": None}
        with mock.patch.object(helper, "request_json", side_effect=[first, second]) as request:
            records = list(helper.list_all({"owner": "team", "name": "repo", "host": "github.com"}, "main", "token"))
        self.assertEqual([record["prNumber"] for record in records], [1, 2])
        self.assertNotIn("cursor", request.call_args_list[0].args[1])
        self.assertEqual(request.call_args_list[1].args[1]["cursor"], "page-2")

    def test_pagination_stops_on_repeated_cursor(self):
        page = {"pullRequests": [], "nextCursor": "repeat"}
        with mock.patch.object(helper, "request_json", side_effect=[page, page]):
            with self.assertRaisesRegex(helper.StatusError, "repeated a pagination cursor"):
                list(helper.list_all({"owner": "team", "name": "repo", "host": "github.com"}, "main", "token"))

    def test_default_page_limit_keeps_collected_queue_and_reports_incomplete(self):
        repo = {"host": "github.com", "owner": "team", "name": "repo"}
        queue = {"queue": {"state": "running"}}
        page = {
            "pullRequests": [{
                "prNumber": 4,
                "state": "testing",
                "isCurrentlySubmittedToQueue": True,
                "prTitle": "Collected active PR",
            }],
            "nextCursor": "page-2",
        }
        output = io.StringIO()
        with mock.patch.object(helper, "request_json", side_effect=[queue, page]) as request:
            with contextlib.redirect_stdout(output):
                status = helper.print_queue(repo, "main", "token", max_pages=1)
        self.assertEqual(status, 3)
        rendered = output.getvalue()
        self.assertIn("#4 [testing] Collected active PR", rendered)
        self.assertIn("INCOMPLETE: scanned 1 pages", rendered)
        self.assertIn("history ordering and selection cover only scanned pages", rendered)
        self.assertEqual(request.call_count, 2)

    def test_version_flag_identifies_the_installed_helper_snapshot(self):
        output = io.StringIO()
        with mock.patch.object(helper.sys, "argv", ["trunk-queue-status", "--version"]):
            with contextlib.redirect_stdout(output):
                with self.assertRaises(SystemExit) as exited:
                    helper.main()
        self.assertEqual(exited.exception.code, 0)
        self.assertEqual(output.getvalue().strip(), "trunk-queue-status 1.0.0")

    def test_install_failure_without_python_is_optional_without_token_and_fatal_with_token(self):
        for token, expected_row, expected_failed in (
            (None, "trunk-queue-status | WARN | helper provisioning failed", "FAILED=0"),
            ("setup-test-token", "trunk-queue-status | FAIL | requested helper provisioning failed", "FAILED=1"),
        ):
            with self.subTest(token_configured=token is not None):
                script = "\n".join((
                    "WORK=/tmp/trunk-queue-status-offline-test",
                    "FAILED=0",
                    "log() { :; }",
                    "record() { printf '%s | %s | %s\\n' \"$2\" \"$1\" \"$3\"; }",
                    INSTALL_FUNCTIONS_SOURCE,
                    "trunk_queue_status_stage",
                    "printf 'FAILED=%s\\n' \"$FAILED\"",
                ))
                with tempfile.TemporaryDirectory() as empty_path:
                    env = {"PATH": empty_path}
                    if token is not None:
                        env["TRUNK_API_TOKEN"] = token
                    result = subprocess.run(
                        [BASH, "-c", script],
                        env=env,
                        stdout=subprocess.PIPE,
                        stderr=subprocess.PIPE,
                        text=True,
                        check=False,
                    )
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertIn(expected_row, result.stdout)
                self.assertIn(expected_failed, result.stdout)

    def test_install_success_is_exercised_offline(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            root = pathlib.Path(temp_dir)
            work = root / "work"
            work.mkdir()
            fake_bin = root / "bin"
            fake_bin.mkdir()
            fake_python = fake_bin / "python3"
            fake_python.write_text("#!/bin/sh\nexit 0\n")
            fake_python.chmod(0o755)
            script = "\n".join((
                f"WORK={str(work)!r}",
                "log() { :; }",
                "record() { printf '%s | %s | %s\\n' \"$2\" \"$1\" \"$3\"; }",
                "note_placement() { :; }",
                "install_bin() { printf '%s\\n' \"/usr/local/bin/$2\"; }",
                INSTALL_FUNCTIONS_SOURCE,
                "trunk_queue_status_install",
            ))
            result = subprocess.run(
                [BASH, "-c", script],
                env={"PATH": str(fake_bin) + os.pathsep + os.environ.get("PATH", "")},
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
                check=False,
            )
            helper_path = work / "trunk-queue-status"
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn(
                "trunk-queue-status | PASS | installed read-only Trunk API helper at /usr/local/bin/trunk-queue-status",
                result.stdout,
            )
            self.assertTrue(helper_path.is_file())
            self.assertTrue(helper_path.stat().st_mode & 0o111)
            self.assertTrue(helper_path.read_text().startswith("#!/usr/bin/env python3\n"))

    def test_unbounded_scan_follows_all_pages(self):
        pages = [
            {"pullRequests": [{"prNumber": 1}], "nextCursor": "page-2"},
            {"pullRequests": [{"prNumber": 2}], "nextCursor": None},
        ]
        with mock.patch.object(helper, "request_json", side_effect=pages) as request:
            records = list(helper.list_all({"owner": "team", "name": "repo", "host": "github.com"}, "main", "token", max_pages=None))
        self.assertEqual([record["prNumber"] for record in records], [1, 2])
        self.assertEqual(request.call_count, 2)

    def test_pagination_rejects_malformed_records_and_cursor(self):
        repo = {"owner": "team", "name": "repo", "host": "github.com"}
        for page, message in (
            ({"pullRequests": ["not an object"]}, "malformed pull request"),
            ({"pullRequests": [{"state": "merged"}]}, "invalid PR number"),
            ({"pullRequests": [{"state": []}]}, "invalid PR details"),
            ({"pullRequests": [], "nextCursor": 42}, "invalid pagination cursor"),
        ):
            with self.subTest(page=page), mock.patch.object(helper, "request_json", return_value=page):
                with self.assertRaisesRegex(helper.StatusError, message):
                    list(helper.list_all(repo, "main", "token"))

    def test_queue_output_keeps_all_active_and_limits_history(self):
        repo = {"host": "github.com", "owner": "team", "name": "repo"}
        queue = {"queue": {"state": "running", "concurrency": 2}}
        page = {"pullRequests": [
            {"prNumber": 12, "state": "testing", "isCurrentlySubmittedToQueue": True, "prTitle": "Active one"},
            {"prNumber": 11, "state": "pending", "prTitle": "Active fallback"},
            {"prNumber": 10, "state": "merged", "isCurrentlySubmittedToQueue": False, "prTitle": "History one"},
            {"prNumber": 9, "state": "failed", "isCurrentlySubmittedToQueue": False, "prTitle": "History two"},
        ], "nextCursor": None}
        output = io.StringIO()
        with mock.patch.object(helper, "request_json", side_effect=[queue, page]):
            with contextlib.redirect_stdout(output):
                helper.print_queue(repo, "main", "token", history_limit=1)
        rendered = output.getvalue()
        self.assertIn("Queue: state: running, concurrency: 2", rendered)
        self.assertIn("Active (testing or waiting) (2):", rendered)
        self.assertIn("#12 [testing] Active one", rendered)
        self.assertIn("#11 [pending] Active fallback", rendered)
        self.assertIn("Recent and concluded history (1 shown of 2):", rendered)
        self.assertIn("#10 [merged] History one", rendered)
        self.assertNotIn("History two", rendered)
        self.assertIn("pass --all", rendered)

        output = io.StringIO()
        with mock.patch.object(helper, "request_json", side_effect=[queue, page]):
            with contextlib.redirect_stdout(output):
                helper.print_queue(repo, "main", "token", history_limit=None)
        rendered = output.getvalue()
        self.assertIn("Recent and concluded history (2):", rendered)
        self.assertIn("#9 [failed] History two", rendered)
        self.assertNotIn("omitted", rendered)

    def test_history_limit_keeps_most_recent_state_changes(self):
        repo = {"host": "github.com", "owner": "team", "name": "repo"}
        queue = {"queue": {"state": "running"}}
        page = {"pullRequests": [
            {"prNumber": 1, "state": "merged", "stateChangedAt": "2026-01-01T00:00:00Z"},
            {"prNumber": 2, "state": "failed", "stateChangedAt": "2026-01-02T00:00:00Z"},
        ], "nextCursor": None}
        output = io.StringIO()
        with mock.patch.object(helper, "request_json", side_effect=[queue, page]):
            with contextlib.redirect_stdout(output):
                helper.print_queue(repo, "main", "token", history_limit=1)
        rendered = output.getvalue()
        self.assertIn("Recent and concluded history (1 shown of 2):", rendered)
        self.assertIn("#2 [failed]", rendered)
        self.assertNotIn("#1 [merged]", rendered)

    def test_pr_output_includes_timeline_links_and_accepts_null_optionals(self):
        repo = {"host": "github.com", "owner": "team", "name": "repo"}
        data = {"submittedPullRequest": {
            "prNumber": 7,
            "state": "failed",
            "isCurrentlySubmittedToQueue": False,
            "prTitle": None,
            "prAuthor": None,
            "prBaseBranch": None,
            "timeline": [{
                "timestamp": "2026-10-15T12:00:00Z",
                "state": "testing",
                "testRun": {"status": "passed", "testBranch": "trunk/test/7"},
                "testsPassed": {"testBranchUrl": "https://github.com/team/repo/tree/test/7"},
                "failure": {"failureCausingStatuses": [{"name": "lint", "url": "https://example.test/check/1"}]},
            }],
        }}
        output = io.StringIO()
        with mock.patch.object(helper, "request_json", return_value=data):
            with contextlib.redirect_stdout(output):
                helper.print_pr(repo, "main", 7, "token")
        rendered = output.getvalue()
        self.assertIn("PR #7 [failed; history]", rendered)
        self.assertIn("Test branch: trunk/test/7", rendered)
        self.assertIn("Tested branch: https://github.com/team/repo/tree/test/7", rendered)
        self.assertIn("Failed check: lint — https://example.test/check/1", rendered)

    def test_pr_output_accepts_missing_and_null_timeline(self):
        repo = {"host": "github.com", "owner": "team", "name": "repo"}
        for data in ({"prNumber": 7, "state": "merged"}, {"prNumber": 7, "state": "merged", "timeline": None}):
            output = io.StringIO()
            with self.subTest(data=data), mock.patch.object(helper, "request_json", return_value=data):
                with contextlib.redirect_stdout(output):
                    helper.print_pr(repo, "main", 7, "token")
            self.assertIn("Timeline (0 events):", output.getvalue())

    def test_pr_output_replaces_explicitly_null_timeline_values(self):
        repo = {"host": "github.com", "owner": "team", "name": "repo"}
        data = {
            "prNumber": 7,
            "state": "merged",
            "timeline": [{"timestamp": None, "state": None}],
        }
        output = io.StringIO()
        with mock.patch.object(helper, "request_json", return_value=data):
            with contextlib.redirect_stdout(output):
                helper.print_pr(repo, "main", 7, "token")
        self.assertIn("time unknown — unknown", output.getvalue())

    def test_redirect_handler_refuses_to_forward_api_request(self):
        handler = helper.NoRedirectHandler()
        opener = helper.urllib.request.build_opener(helper.NoRedirectHandler)
        redirect_handlers = [
            candidate for candidate in opener.handlers
            if isinstance(candidate, helper.urllib.request.HTTPRedirectHandler)
        ]
        self.assertIsInstance(redirect_handlers[0], helper.NoRedirectHandler)
        with self.assertRaises(urllib.error.HTTPError) as caught:
            handler.redirect_request(
                types.SimpleNamespace(full_url="https://api.trunk.io/v1/getQueue"),
                io.BytesIO(),
                302,
                "Found",
                {},
                "https://redirect.example.test/",
            )
        self.assertEqual(caught.exception.code, 302)

    def test_http_error_redacts_token(self):
        token = "secret-token-value"
        error_body = io.BytesIO(json.dumps({"message": "bad " + token}).encode())
        error = urllib.error.HTTPError(
            "https://api.trunk.io/v1/listPullRequests", 500, "failed", {},
            error_body,
        )
        with mock.patch.object(helper, "open_no_redirect", side_effect=error):
            with self.assertRaises(helper.StatusError) as caught:
                helper.request_json("listPullRequests", {}, token)
        self.assertIn("[redacted]", str(caught.exception))
        self.assertNotIn(token, str(caught.exception))
        self.assertTrue(error_body.closed)

    def test_http_protocol_errors_are_reported_as_network_failures(self):
        with mock.patch.object(
            helper, "open_no_redirect", side_effect=helper.http.client.IncompleteRead(b"partial")
        ):
            with self.assertRaisesRegex(helper.StatusError, "network request to api.trunk.io failed"):
                helper.request_json("getQueue", {}, "token")

    def test_safe_text_removes_unicode_controls_and_redacts_token(self):
        token = "visible-secret"
        rendered = helper.safe_text("safe\u009bhidden\u202e" + token, token)
        self.assertEqual(rendered, "safe hidden [redacted]")

    def test_http_auth_error_is_actionable_without_echoing_token(self):
        token = "another-secret"
        error = urllib.error.HTTPError("url", 401, "unauthorized", {}, io.BytesIO(token.encode()))
        with mock.patch.object(helper, "open_no_redirect", side_effect=error):
            with self.assertRaisesRegex(helper.StatusError, "HTTP 401") as caught:
                helper.request_json("getQueue", {}, token)
        self.assertNotIn(token, str(caught.exception))

    def test_invalid_json_and_non_object_responses_are_rejected(self):
        for response_body, message in ((b"not json", "invalid JSON"), (b"[]", "unexpected response")):
            response = io.BytesIO(response_body)
            response.__enter__ = lambda: response
            response.__exit__ = lambda *args: None
            with self.subTest(body=response_body), mock.patch.object(helper, "open_no_redirect", return_value=response):
                with self.assertRaisesRegex(helper.StatusError, message):
                    helper.request_json("getQueue", {}, "token")

    def test_queue_and_timeline_types_are_validated(self):
        repo = {"host": "github.com", "owner": "team", "name": "repo"}
        with mock.patch.object(helper, "request_json", return_value={"queue": []}):
            with self.assertRaisesRegex(helper.StatusError, "queue object"):
                helper.print_queue(repo, "main", "token")
        with mock.patch.object(helper, "request_json", return_value={"prNumber": 7, "timeline": {}}):
            with self.assertRaisesRegex(helper.StatusError, "invalid timeline"):
                helper.print_pr(repo, "main", 7, "token")

    def test_unexpected_error_handler_redacts_token(self):
        token = "catch-all-secret"
        original_main = helper.main

        def broken_main():
            raise RuntimeError("unexpected failure with " + token)

        helper.main = broken_main
        stderr = io.StringIO()
        try:
            with mock.patch.dict(helper.os.environ, {"TRUNK_API_TOKEN": token}), contextlib.redirect_stderr(stderr):
                self.assertEqual(helper.run(), 1)
        finally:
            helper.main = original_main
        self.assertIn("[redacted]", stderr.getvalue())
        self.assertNotIn(token, stderr.getvalue())


if __name__ == "__main__":
    unittest.main()
