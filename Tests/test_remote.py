"""Exercise the exact SSH helper against temporary fixtures, never real logins."""
import importlib.util
import json
import os
from pathlib import Path
import tempfile
import unittest
import sys
from unittest.mock import patch

sys.dont_write_bytecode = True

SOURCE = Path(__file__).resolve().parents[1] / "Sources/Cswitch/Resources/remote.py"
spec = importlib.util.spec_from_file_location("remote", SOURCE)
remote = importlib.util.module_from_spec(spec)
spec.loader.exec_module(remote)


class RemoteTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.root_patch = patch.object(remote, "ROOT", self.root)
        self.root_patch.start()
        self.addCleanup(self.root_patch.stop)
        self.platform_patch = patch.object(remote.platform, "system", return_value="Linux")
        self.platform_patch.start()
        self.addCleanup(self.platform_patch.stop)
        self.env_patch = patch.dict(os.environ, {}, clear=True)
        self.env_patch.start()
        self.addCleanup(self.env_patch.stop)
        (self.root / ".claude").mkdir()
        self.config = self.root / ".claude.json"
        self.credentials = self.root / ".claude/.credentials.json"
        self.old_identity = {"accountUuid": "old", "emailAddress": "old@example.com"}
        self.config.write_text(json.dumps({"oauthAccount": self.old_identity, "projects": {"work": {"trusted": True}}, "mcpServers": {"github": {"command": "tool"}}}))
        self.credentials.write_text(json.dumps({"claudeAiOauth": {"accessToken": "old", "refreshToken": "old-refresh"}, "mcpOAuth": {"github": "preserve"}}))
        self.target = {"identity": {"accountUuid": "new", "emailAddress": "new@example.com"}, "oauth": {"accessToken": "new", "refreshToken": "new-refresh"}}

    def test_status_does_not_read_credentials(self):
        self.credentials.unlink()
        status = remote.run({"operation": "status"})
        self.assertEqual(status["identity"], self.old_identity)

    def test_status_reports_claude_login_without_tokens(self):
        executable = self.root / ".local/bin/claude"
        executable.parent.mkdir(parents=True)
        executable.write_text("#!/bin/sh\n"
            "case \"$*\" in\n"
            "  --version) echo '2.1.303 (Claude Code)';;\n"
            "  'auth status --help') echo 'Usage: claude auth status [options]';;\n"
            "  'auth status --json') echo '{\"loggedIn\": true, \"authMethod\": \"claude.ai\", \"email\": \"new@example.com\", \"orgId\": \"org\", \"token\": \"secret\"}';;\n"
            "esac\n")
        executable.chmod(0o700)
        status = remote.run({"operation": "status"})
        self.assertEqual(status["version"], "2.1.303")
        self.assertEqual(status["login"], {"loggedIn": True, "authMethod": "claude.ai", "email": "new@example.com", "orgId": "org"})

    def test_status_skips_claude_without_auth_command(self):
        executable = self.root / ".local/bin/claude"
        executable.parent.mkdir(parents=True)
        marker = self.root / "prompted"
        executable.write_text("#!/bin/sh\n"
            "case \"$*\" in\n"
            "  --version) echo '1.0.0 (Claude Code)';;\n"
            "  *--help) echo 'Usage: claude [options] [prompt]';;\n"
            f"  *) touch '{marker}';;\n"
            "esac\n")
        executable.chmod(0o700)
        status = remote.run({"operation": "status"})
        self.assertIsNone(status["login"])
        self.assertFalse(marker.exists())

    def test_switch_preserves_shared_state_and_permissions(self):
        config = json.loads(self.config.read_text())
        config["cachedUsageUtilization"] = {"accountUuid": "old", "utilization": 100}
        self.config.write_text(json.dumps(config))
        capture = remote.run({"operation": "capture"})
        remote.run({"operation": "activate", "secret": self.target, "expectedFingerprint": capture["fingerprint"]})
        self.assertEqual(json.loads(self.config.read_text())["projects"], {"work": {"trusted": True}})
        self.assertIn("github", json.loads(self.config.read_text())["mcpServers"])
        self.assertNotIn("cachedUsageUtilization", json.loads(self.config.read_text()))
        credentials = json.loads(self.credentials.read_text())
        self.assertEqual(credentials["mcpOAuth"], {"github": "preserve"})
        self.assertEqual(credentials["claudeAiOauth"], self.target["oauth"])
        self.assertEqual(self.credentials.stat().st_mode & 0o777, 0o600)
        self.assertEqual(remote.run({"operation": "status"})["identity"], self.target["identity"])
        self.assertFalse(list(self.root.rglob("*.lock")))

    def test_refuses_changed_credentials(self):
        capture = remote.run({"operation": "capture"})
        self.credentials.write_text(json.dumps({"claudeAiOauth": {"accessToken": "rotated"}}))
        before = self.credentials.read_bytes()
        with self.assertRaisesRegex(ValueError, "Nothing was changed"):
            remote.run({"operation": "activate", "secret": self.target, "expectedFingerprint": capture["fingerprint"]})
        self.assertEqual(self.credentials.read_bytes(), before)

    def test_rolls_back_after_configuration_failure(self):
        capture = remote.run({"operation": "capture"})
        before = self.credentials.read_bytes()
        real_write = remote.atomic_write

        def fail_config(path, data):
            if path == self.config:
                raise OSError("disk full")
            real_write(path, data)

        with patch.object(remote, "atomic_write", side_effect=fail_config):
            with self.assertRaisesRegex(ValueError, "original credential was restored"):
                remote.run({"operation": "activate", "secret": self.target, "expectedFingerprint": capture["fingerprint"]})
        self.assertEqual(self.credentials.read_bytes(), before)
        self.assertEqual(json.loads(self.config.read_text())["oauthAccount"], self.old_identity)

    def test_rejects_symlink_state(self):
        original = self.root / "real-credentials"
        self.credentials.rename(original)
        self.credentials.symlink_to(original)
        with self.assertRaisesRegex(ValueError, "Symlinked"):
            remote.run({"operation": "capture"})

    def test_rejects_custom_profile(self):
        with patch.dict(os.environ, {"CLAUDE_CONFIG_DIR": "/elsewhere"}):
            with self.assertRaisesRegex(ValueError, "custom CLAUDE_CONFIG_DIR"):
                remote.run({"operation": "capture"})


if __name__ == "__main__":
    unittest.main()
