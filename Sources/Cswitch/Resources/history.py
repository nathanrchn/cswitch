"""Read-only Linux transcript usage collector. Emits metadata, never messages.

The Mac supplies file sizes/mtimes from its cache; unchanged files aren't read.
No cache, daemon, configuration or credential is written on the server.
"""
import datetime
import json
import math
import os
from pathlib import Path
import platform
import sys


def count(value):
    if value is None:
        return 0
    if isinstance(value, bool) or not isinstance(value, (int, float)) or not math.isfinite(value) or value < 0 or value > 10**12 or int(value) != value:
        raise ValueError("Invalid count")
    return int(value)


def record(row):
    if row.get("type") != "assistant":
        return None
    message = row.get("message")
    if not isinstance(message, dict) or not isinstance(message.get("usage"), dict) or not isinstance(message.get("model"), str):
        return None
    identifier = message.get("id")
    if isinstance(identifier, str) and identifier:
        identifier = "m:" + identifier
    elif isinstance(row.get("requestId"), str) and row["requestId"]:
        identifier = "r:" + row["requestId"]
    else:
        raise ValueError("Missing response ID")
    timestamp = datetime.datetime.fromisoformat(row["timestamp"].replace("Z", "+00:00")).timestamp()
    usage = message["usage"]
    creation = usage.get("cache_creation") or {}
    five = count(creation.get("ephemeral_5m_input_tokens"))
    hour = count(creation.get("ephemeral_1h_input_tokens"))
    value = {"id": identifier, "timestamp": timestamp, "model": message["model"],
             "input": count(usage.get("input_tokens")), "output": count(usage.get("output_tokens")),
             "cacheRead": count(usage.get("cache_read_input_tokens")), "cache5m": five, "cache1h": hour,
             "cacheUnknown": max(0, count(usage.get("cache_creation_input_tokens")) - five - hour),
             "fast": usage.get("speed") == "fast"}
    return value if total(value) > 0 else None


def total(value):
    return sum(value[key] for key in ("input", "output", "cacheRead", "cache5m", "cache1h", "cacheUnknown"))


def run(request):
    if platform.system() != "Linux":
        raise ValueError("History devices currently support Linux over SSH.")
    root = Path.home() / ".claude"
    custom = os.environ.get("CLAUDE_CONFIG_DIR")
    if custom and Path(custom).expanduser() != root:
        raise ValueError("This device uses a custom CLAUDE_CONFIG_DIR.")
    projects = root / "projects"
    if root.is_symlink() or projects.is_symlink():
        raise ValueError("Symlinked history directories are not supported.")
    known = request.get("known", {})
    files = {}
    unreadable = 0
    if not projects.exists():
        return {"files": files, "unreadable": 0}
    def walk_error(_):
        nonlocal unreadable
        unreadable += 1
    for directory, dirs, names in os.walk(projects, followlinks=False, onerror=walk_error):
        dirs[:] = [name for name in dirs if not (Path(directory) / name).is_symlink()]
        for name in names:
            path = Path(directory) / name
            if path.suffix != ".jsonl" or path.is_symlink():
                continue
            try:
                info = path.stat()
                relative = str(path.relative_to(projects))
                stamp = {"size": info.st_size, "modified": info.st_mtime}
                if known.get(relative) == stamp:
                    continue
                records = {}
                file_unreadable = 0
                with path.open("rb") as source:
                    while True:
                        line = source.readline(32 * 1024 * 1024 + 1)
                        if not line:
                            break
                        if len(line) > 32 * 1024 * 1024:
                            while line and not line.endswith(b"\n"):
                                line = source.readline(32 * 1024 * 1024 + 1)
                            file_unreadable += 1
                            continue
                        try:
                            parsed = json.loads(line)
                            value = record(parsed) if isinstance(parsed, dict) else None
                            if value:
                                previous = records.get(value["id"])
                                if previous is None or (total(value), value["output"], -value["cacheUnknown"]) > (total(previous), previous["output"], -previous["cacheUnknown"]):
                                    records[value["id"]] = value
                        except (ValueError, TypeError, KeyError, AttributeError, OverflowError):
                            # A file being appended may end with a partial JSON line.
                            if line.endswith(b"\n"):
                                file_unreadable += 1
                files[relative] = {"stamp": stamp, "records": list(records.values()), "unreadable": file_unreadable}
            except OSError:
                unreadable += 1
    return {"files": files, "unreadable": unreadable}


try:
    payload = sys.stdin.buffer.read(8 * 1024 * 1024 + 1)
    if len(payload) > 8 * 1024 * 1024:
        raise ValueError("History cache manifest is too large.")
    result = run(json.loads(payload))
    print(json.dumps({"ok": True, "result": result}, separators=(",", ":")))
except Exception:
    print(json.dumps({"ok": False, "error": "Could not read this device's Claude Code history. Check SSH access and history file permissions."}))
