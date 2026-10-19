"""Ephemeral Linux SSH helper. A single JSON request arrives over stdin.

No installation, dependencies, shell interpolation of credentials, or token logs.
The only writes are Claude's active credential and oauthAccount identity on a
user-requested switch. Settings, MCP logins, history and plugins are preserved.
"""
import contextlib
import hashlib
import json
import os
from pathlib import Path
import platform
import shutil
import sys
import tempfile
import threading
import time

ROOT = Path.home()


def paths():
    directory = ROOT / ".claude"
    custom = os.environ.get("CLAUDE_CONFIG_DIR")
    if custom and Path(custom).expanduser() != directory:
        raise ValueError("This device uses a custom CLAUDE_CONFIG_DIR. Use its default Claude profile for now.")
    config = ROOT / ".claude.json"
    if not config.exists() and (directory / ".claude.json").exists():
        config = directory / ".claude.json"
    return directory, config, directory / ".credentials.json"


def read(path):
    if path.is_symlink():
        raise ValueError("Symlinked Claude state files are not supported; no changes were made.")
    raw = path.read_bytes()
    if len(raw) > 2 * 1024 * 1024:
        raise ValueError("Claude state file is unexpectedly large.")
    value = json.loads(raw)
    if not isinstance(value, dict):
        raise ValueError("Claude state must be a JSON object.")
    return raw, value


def read_optional(path):
    if path.is_symlink():
        raise ValueError("Symlinked Claude state files are not supported; no changes were made.")
    return read(path) if path.exists() else (None, {})


def identity(config):
    value = config.get("oauthAccount")
    if not isinstance(value, dict) or not value.get("accountUuid") or not value.get("emailAddress"):
        raise ValueError("Sign in to Claude Code on this device first.")
    return value


def valid_secret(secret):
    if not isinstance(secret, dict):
        raise ValueError("Invalid saved account.")
    oauth = secret.get("oauth")
    if not isinstance(oauth, dict) or not isinstance(oauth.get("accessToken"), str) or not oauth["accessToken"]:
        raise ValueError("No subscription credential found.")
    identity({"oauthAccount": secret.get("identity")})
    return secret


def snapshot():
    _, config_path, credential_path = paths()
    config_raw, config = read_optional(config_path)
    credential_raw, credentials = read_optional(credential_path)
    secret = None
    if credentials.get("claudeAiOauth") is not None:
        secret = valid_secret({"identity": identity(config), "oauth": credentials.get("claudeAiOauth")})
    fingerprint = hashlib.sha256((b"present:" + config_raw if config_raw is not None else b"missing") + b"\x00" + (b"present:" + credential_raw if credential_raw is not None else b"missing")).hexdigest()
    return config_raw, config, credential_raw, credentials, secret, fingerprint


@contextlib.contextmanager
def locks():
    directory, config, _ = paths()
    directory.mkdir(mode=0o700, parents=True, exist_ok=True)
    targets = [directory / ".oauth_refresh.lock", Path(str(directory) + ".lock"), Path(str(config) + ".lock")]
    held = []
    stop = threading.Event()

    def heartbeat():
        while not stop.wait(2):
            for path in held[:]:
                try:
                    os.utime(path, None)
                except OSError:
                    pass

    thread = threading.Thread(target=heartbeat, daemon=True)
    thread.start()
    deadline = time.monotonic() + 6
    try:
        for path in targets:
            while True:
                try:
                    path.mkdir(mode=0o700)
                    held.append(path)
                    break
                except FileExistsError:
                    if time.monotonic() >= deadline:
                        raise ValueError("Claude is updating its credentials. Wait a few seconds and retry.")
                    time.sleep(0.15)
        yield
    finally:
        stop.set()
        thread.join(timeout=1)
        for path in reversed(held):
            try:
                path.rmdir()
            except OSError:
                pass


def atomic_write(path, raw):
    fd, temp = tempfile.mkstemp(prefix=".cswitch-", dir=path.parent)
    try:
        os.fchmod(fd, 0o600)
        with os.fdopen(fd, "wb") as output:
            output.write(raw)
            output.flush()
            os.fsync(output.fileno())
        os.replace(temp, path)
    finally:
        if os.path.exists(temp):
            os.unlink(temp)


def run(request):
    if platform.system() != "Linux":
        raise ValueError("Remote devices currently support Linux over SSH.")
    operation = request.get("operation")
    if operation == "status":
        _, config_path, _ = paths()
        account = None
        if config_path.exists():
            _, config = read(config_path)
            try:
                account = identity(config)
            except ValueError:
                pass
        executable = shutil.which("claude")
        if not executable:
            for candidate in [ROOT / ".local/bin/claude", Path("/usr/local/bin/claude")]:
                if candidate.is_file() and os.access(candidate, os.X_OK):
                    executable = str(candidate)
                    break
        return {"identity": account, "claudePath": executable}
    if operation == "capture":
        with locks():
            *_, secret, fingerprint = snapshot()
        return {"secret": secret, "fingerprint": fingerprint}
    if operation == "activate":
        secret = valid_secret(request.get("secret"))
        with locks():
            config_raw, config, credential_raw, credentials, _, fingerprint = snapshot()
            if fingerprint != request.get("expectedFingerprint"):
                raise ValueError("Claude changed its login while switching. Nothing was changed; retry.")
            _, config_path, credential_path = paths()
            config["oauthAccount"] = secret["identity"]
            credentials["claudeAiOauth"] = secret["oauth"]
            atomic_write(credential_path, json.dumps(credentials).encode())
            try:
                atomic_write(config_path, json.dumps(config).encode())
            except Exception:
                try:
                    if credential_raw is None:
                        credential_path.unlink(missing_ok=True)
                    else:
                        atomic_write(credential_path, credential_raw)
                except Exception:
                    raise ValueError("Switch rollback failed. Sign in again on this device before using Claude Code.")
                raise ValueError("Switch failed; the original credential was restored.")
            *_, applied, _ = snapshot()
            if applied != secret:
                raise ValueError("Could not verify the switch. Check this device's Claude login.")
        return {"identity": secret["identity"]}
    raise ValueError("Unknown Cswitch operation.")


def main():
    try:
        raw = sys.stdin.buffer.read(1024 * 1024 + 1)
        if len(raw) > 1024 * 1024:
            raise ValueError("Request too large.")
        request = json.loads(raw)
        if not isinstance(request, dict):
            raise ValueError("Invalid request.")
        print(json.dumps({"ok": True, "result": run(request)}))
    except (ValueError, FileNotFoundError) as error:
        # JSON decoding exceptions can contain source material; never echo them.
        message = "Claude state is missing or unreadable. Sign in on this device first."
        if isinstance(error, ValueError) and not isinstance(error, json.JSONDecodeError):
            message = str(error)
        print(json.dumps({"ok": False, "error": message}))
    except Exception:
        print(json.dumps({"ok": False, "error": "Could not access Claude state on this device. Check file permissions and retry."}))


if __name__ == "__main__":
    main()
