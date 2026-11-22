#!/usr/bin/env python3
"""skillz MCP surface — read-only, loopback by default, with a signed border.

Two routes matter:

  POST /mcp
      A small JSON-RPC surface over the active skill canon. No write methods.

  POST /namespace/<ns>/name/<name>
      The wan-ingress border. The ingress signs
      method, escaped path, namespace, SHA-256(body) and timestamp with
      HMAC-SHA256; this endpoint verifies the envelope before dispatching the
      same read-only surface. No border key means 503, not an open door.

GET /healthz, /readyz and /status are for local supervisors and humans.
"""

import argparse
import hashlib
import hmac
import json
import os
import re
import signal
import subprocess
import sys
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SKILLS = ROOT / "skills"
ARCHIVE = ROOT / "archive"
CACHE = ROOT / "cache"
LOCK = ROOT / "external.lock.json"
SOURCES = ROOT / "sources.lock.json"

VERSION = "1.1.0"
PROTOCOL_VERSION = "2025-06-18"
MAX_BODY = 1 << 20
MAX_SKEW = 300
NAME_RE = re.compile(r"^[a-z0-9][a-z0-9._-]{0,63}$")
BORDER_RE = re.compile(r"^/namespace/([^/]+)/name/([^/]+)$")
JUNK = {".git", "__pycache__", ".DS_Store"}


# ------------------------------------------------------------------- storage


def read_json(path, default=None):
    try:
        with open(path, "r", encoding="utf-8") as fh:
            return json.load(fh)
    except (OSError, json.JSONDecodeError):
        return default


def parse_frontmatter(text):
    lines = text.splitlines()
    if not lines or lines[0].strip() != "---":
        return {}
    try:
        end = lines.index("---", 1)
    except ValueError:
        return {}
    data = {}
    block = lines[1:end]
    i = 0
    while i < len(block):
        line = block[i]
        if not line.strip() or line.lstrip().startswith("#") or ":" not in line:
            i += 1
            continue
        if line.startswith((" ", "\t")):
            i += 1
            continue
        key, value = line.split(":", 1)
        key, value = key.strip(), value.strip()
        if value in (">", ">-", ">+", "|", "|-", "|+"):
            folded = value.startswith(">")
            buf = []
            i += 1
            while i < len(block) and block[i].startswith((" ", "\t")):
                buf.append(block[i].strip())
                i += 1
            data[key] = (" " if folded else "\n").join(buf).strip()
            continue
        if value[:1] in ("'", '"') and not (len(value) >= 2 and value[-1] == value[0]):
            quote = value[0]
            buf = [value[1:]]
            i += 1
            while i < len(block) and block[i].startswith((" ", "\t")):
                nxt = block[i].strip()
                if nxt.endswith(quote):
                    buf.append(nxt[:-1])
                    i += 1
                    break
                buf.append(nxt)
                i += 1
            data[key] = " ".join(buf).strip()
            continue
        if len(value) >= 2 and value[0] == value[-1] and value[0] in "'\"":
            value = value[1:-1]
        data[key] = value
        i += 1
    return data


def tree_files(root):
    out = {}
    for path in sorted(Path(root).rglob("*")):
        rel = path.relative_to(root)
        if any(part in JUNK for part in rel.parts):
            continue
        if rel.as_posix() == "skill.json" or not path.is_file():
            continue
        h = hashlib.sha256()
        with open(path, "rb") as fh:
            for chunk in iter(lambda: fh.read(1024 * 1024), b""):
                h.update(chunk)
        out[rel.as_posix()] = h.hexdigest()
    return out


def active_dirs():
    if not SKILLS.is_dir():
        return []
    return sorted(p for p in SKILLS.iterdir() if p.is_dir() and (p / "SKILL.md").is_file())


def archive_entries():
    out = []
    if not ARCHIVE.is_dir():
        return out
    for skill_dir in sorted(ARCHIVE.iterdir()):
        if not skill_dir.is_dir():
            continue
        for date_dir in sorted(skill_dir.iterdir()):
            if date_dir.is_dir() and (date_dir / "SKILL.md").is_file():
                out.append((skill_dir.name, date_dir.name, date_dir))
    return out


def skill_record(path, tier="active"):
    try:
        text = (path / "SKILL.md").read_text(encoding="utf-8")
    except OSError:
        text = ""
    fm = parse_frontmatter(text)
    manifest = read_json(path / "skill.json") or read_json(path / "ARCHIVE.json") or {}
    return {
        "name": fm.get("name") or path.name,
        "description": fm.get("description") or manifest.get("description") or "",
        "tier": tier,
        "tree_hash": manifest.get("tree_hash"),
        "sealed_at": manifest.get("sealed_at"),
        "archived_at": manifest.get("archived_at"),
        "files": sorted(manifest.get("files") or {}),
        "external": manifest.get("external") or [],
    }


def load_sources():
    data = read_json(SOURCES, {"schema": 1, "sources": {}}) or {}
    sources = data.get("sources")
    return sources if isinstance(sources, dict) else {}


def latest_commit(repo, ref):
    ref = (ref or "main").strip()
    candidates = [ref] if ref.startswith("refs/") else ["refs/heads/" + ref, "refs/tags/" + ref]
    error = ""
    for candidate in candidates:
        try:
            proc = subprocess.run(["git", "ls-remote", repo, candidate],
                                  capture_output=True, text=True, timeout=10)
        except (OSError, subprocess.TimeoutExpired) as exc:
            error = str(exc)
            continue
        if proc.returncode != 0:
            error = proc.stderr.strip()
            continue
        for line in proc.stdout.splitlines():
            parts = line.split()
            if len(parts) >= 2 and parts[1] == candidate:
                return parts[0], ""
    return None, error or ("ref %s not found" % ref)


_SYNC_CACHE = {"at": 0.0, "data": None}


def sync_status(force=False):
    now = time.time()
    if not force and _SYNC_CACHE["data"] is not None and now - _SYNC_CACHE["at"] < 30:
        return _SYNC_CACHE["data"]
    sources = load_sources()
    groups = {}
    for sid, entry in sources.items():
        groups.setdefault((entry.get("repo") or "", entry.get("ref") or "main"),
                          []).append((sid, entry))
    latest = {key: latest_commit(*key) for key in groups}
    rows = {}
    for key, items in groups.items():
        newest, error = latest[key]
        for sid, entry in items:
            pinned = entry.get("commit")
            if not newest:
                state = "unreachable"
            elif newest == pinned:
                state = "current"
            else:
                state = "drift"
            rows[sid] = {
                "state": state,
                "pinned": pinned,
                "latest": newest,
                "repo": entry.get("repo"),
                "skill": entry.get("skill"),
                "group": entry.get("group"),
                "error": error,
            }
    if not rows:
        overall = "empty"
    elif all(row["state"] == "current" for row in rows.values()):
        overall = "current"
    elif any(row["state"] == "unreachable" for row in rows.values()):
        overall = "unreachable"
    else:
        overall = "drift"
    data = {
        "state": overall,
        "checked_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "sources": rows,
    }
    _SYNC_CACHE.update({"at": now, "data": data})
    return data


def status_payload():
    cache_bytes = 0
    if CACHE.is_dir():
        for path in CACHE.rglob("*"):
            try:
                if path.is_file():
                    cache_bytes += path.stat().st_size
            except OSError:
                pass
    lock = read_json(LOCK, {"entries": {}}) or {"entries": {}}
    sync = sync_status()
    return {
        "ready": SKILLS.is_dir(),
        "active": len(active_dirs()),
        "archived": len(archive_entries()),
        "external": len(lock.get("entries") or {}),
        "sources": len(sync.get("sources") or {}),
        "sync": sync.get("state"),
        "cache_bytes": cache_bytes,
        "tiers": {"canon": "skills/", "apocrypha": "archive/",
                  "sources": "external/ + external.lock.json", "ephemera": "cache/"},
        "version": VERSION,
    }


def list_records(tier="active"):
    rows = []
    if tier in ("active", "all"):
        rows += [skill_record(p, "active") for p in active_dirs()]
    if tier in ("archive", "all"):
        for name, date, path in archive_entries():
            rec = skill_record(path, "archive")
            rec["name"] = name
            rec["date"] = date
            rows.append(rec)
    return rows


def read_skill(name):
    if not NAME_RE.match(name or ""):
        return None
    path = SKILLS / name
    if not path.is_dir() or not (path / "SKILL.md").is_file():
        return None
    text = (path / "SKILL.md").read_text(encoding="utf-8")
    rec = skill_record(path)
    rec["skill_md"] = text
    rec["files"] = sorted(tree_files(path))
    return rec


def search_skills(query):
    query = (query or "").lower()
    if not query:
        return []
    hits = []

    def scan(tier, name, path):
        try:
            text = (path / "SKILL.md").read_text(encoding="utf-8")
        except OSError:
            return
        fm = parse_frontmatter(text)
        if query in (fm.get("name") or name).lower():
            hits.append({"tier": tier, "name": name, "where": "name", "line": name})
        elif query in (fm.get("description") or "").lower():
            hits.append({"tier": tier, "name": name, "where": "description",
                         "line": (fm.get("description") or "").replace("\n", " ")[:200]})
        else:
            for line in text.splitlines():
                if query in line.lower():
                    hits.append({"tier": tier, "name": name, "where": "body",
                                 "line": line.strip()[:200]})
                    break

    for path in active_dirs():
        scan("active", path.name, path)
    for name, _date, path in archive_entries():
        scan("archive", name, path)
    return hits


# ---------------------------------------------------------------------- rpc


class RPCError(Exception):
    def __init__(self, code, message):
        super().__init__(message)
        self.code = code
        self.message = message


TOOLS = [
    {
        "name": "skills_status",
        "description": "Counts, tier sizes and readiness for the skillz collection.",
        "inputSchema": {"type": "object", "properties": {}},
    },
    {
        "name": "skills_list",
        "description": "List active (or archived) skills with descriptions and hashes.",
        "inputSchema": {"type": "object", "properties": {
            "tier": {"type": "string", "enum": ["active", "archive", "all"], "default": "active"}
        }},
    },
    {
        "name": "skills_read",
        "description": "Read one active skill: SKILL.md, file list and provenance.",
        "inputSchema": {"type": "object", "properties": {"name": {"type": "string"}},
                        "required": ["name"]},
    },
    {
        "name": "skills_search",
        "description": "Substring search across active and archived skills.",
        "inputSchema": {"type": "object", "properties": {"query": {"type": "string"}},
                        "required": ["query"]},
    },
    {
        "name": "sync_status",
        "description": "Pinned upstream sources and whether they have drifted.",
        "inputSchema": {"type": "object", "properties": {
            "refresh": {"type": "boolean", "default": False}
        }},
    },
]


def call_tool(name, arguments):
    arguments = arguments or {}
    if name == "skills_status":
        return status_payload()
    if name == "skills_list":
        return {"skills": list_records(arguments.get("tier") or "active")}
    if name == "skills_read":
        record = read_skill(arguments.get("name") or "")
        if record is None:
            raise RPCError(-32602, "unknown skill")
        return record
    if name == "skills_search":
        return {"hits": search_skills(arguments.get("query") or "")}
    if name == "sync_status":
        return sync_status(force=bool(arguments.get("refresh")))
    raise RPCError(-32602, "unknown tool")


def initialize_result():
    sync = sync_status()
    capabilities = {
        "skills": {"read": True, "list": True, "search": True, "status": True},
        "tools": {},
    }
    if sync["state"] in ("current", "empty"):
        capabilities["sync"] = {"current": True,
                                "sources": len(sync.get("sources") or {})}
    return {
        "protocolVersion": PROTOCOL_VERSION,
        "capabilities": capabilities,
        "serverInfo": {"name": "skillz", "version": VERSION},
    }


def dispatch(payload):
    """Return (http_status, response_dict_or_None)."""
    if not isinstance(payload, dict):
        return 400, {"jsonrpc": "2.0", "id": None,
                     "error": {"code": -32600, "message": "invalid request"}}
    jsonrpc = payload.get("jsonrpc")
    method = payload.get("method")
    req_id = payload.get("id")
    params = payload.get("params") or {}
    if jsonrpc != "2.0" or not isinstance(method, str):
        return 400, {"jsonrpc": "2.0", "id": req_id,
                     "error": {"code": -32600, "message": "invalid request"}}
    if "id" not in payload:
        # Notification: no response body.
        return 202, None

    def ok(result):
        return 200, {"jsonrpc": "2.0", "id": req_id, "result": result}

    try:
        if method == "initialize":
            return ok(initialize_result())
        if method == "skills/status":
            return ok(status_payload())
        if method == "sync/status":
            return ok(sync_status(force=bool(params.get("refresh"))))
        if method == "skills/list":
            tier = params.get("tier") or "active"
            if tier not in ("active", "archive", "all"):
                raise RPCError(-32602, "tier must be active, archive or all")
            return ok({"skills": list_records(tier)})
        if method == "skills/read":
            record = read_skill(params.get("name") or "")
            if record is None:
                raise RPCError(-32602, "unknown skill")
            return ok(record)
        if method == "skills/search":
            return ok({"hits": search_skills(params.get("query") or "")})
        if method == "tools/list":
            return ok({"tools": TOOLS})
        if method == "tools/call":
            result = call_tool(params.get("name"), params.get("arguments"))
            return ok({"content": [{"type": "text", "text": json.dumps(result, indent=2)}],
                       "structuredContent": result})
        raise RPCError(-32601, "method not found")
    except RPCError as exc:
        return 200, {"jsonrpc": "2.0", "id": req_id,
                     "error": {"code": exc.code, "message": exc.message}}


# --------------------------------------------------------------------- HTTP


class Handler(BaseHTTPRequestHandler):
    server_version = "skillz/" + VERSION
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *args):
        sys.stderr.write(json.dumps({
            "ts": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
            "event": "http",
            "client": self.client_address[0],
            "line": fmt % args,
        }) + "\n")

    def _send(self, status, body=None, content_type="application/json"):
        data = b"" if body is None else body
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        if data:
            self.wfile.write(data)

    def _json(self, status, payload):
        self._send(status, json.dumps(payload).encode("utf-8"))

    def _read_body(self):
        length = self.headers.get("Content-Length")
        if length is None:
            data = self.rfile.read(MAX_BODY + 1)
        else:
            try:
                n = int(length)
            except ValueError:
                raise ValueError("bad content-length")
            if n > MAX_BODY:
                raise ValueError("body too large")
            data = self.rfile.read(n)
        if len(data) > MAX_BODY:
            raise ValueError("body too large")
        return data

    def do_GET(self):
        path = self.path.split("?", 1)[0]
        if path == "/healthz":
            self._send(200, b"ok\n", "text/plain")
        elif path == "/readyz":
            if SKILLS.is_dir():
                self._send(200, b"ready\n", "text/plain")
            else:
                self._send(503, b"not ready\n", "text/plain")
        elif path == "/status":
            self._json(200, status_payload())
        else:
            self._json(404, {"error": "not found"})

    def do_POST(self):
        raw_path = self.path.split("?", 1)[0]
        try:
            body = self._read_body()
        except ValueError as exc:
            self._json(413 if "large" in str(exc) else 400, {"error": str(exc)})
            return

        if raw_path == "/mcp":
            self._dispatch_body(body, via="local")
            return

        match = BORDER_RE.match(raw_path)
        if match:
            try:
                self._border(raw_path, match, body)
            except Exception as exc:  # fail closed, but leave a trace
                sys.stderr.write(json.dumps({"ts": int(time.time()), "event": "border",
                                             "decision": "error", "error": str(exc)}) + "\n")
                self._json(500, {"error": "border_handler_error"})
            return

        self._json(404, {"error": "not found"})

    def _dispatch_body(self, body, via):
        try:
            payload = json.loads(body.decode("utf-8"))
        except (UnicodeDecodeError, json.JSONDecodeError):
            self._json(400, {"jsonrpc": "2.0", "id": None,
                             "error": {"code": -32700, "message": "parse error"}})
            return
        status, response = dispatch(payload)
        if response is None:
            self._send(status, b"")
            return
        self._json(status, response)

    def _border(self, raw_path, match, body):
        namespace = self.server.namespace
        path_ns, path_name = match.group(1), match.group(2)
        if not self.server.border_key:
            self._json(503, {"error": "border_unconfigured"})
            return
        header_ns = self.headers.get("X-Lab-Namespace") or ""
        signature = self.headers.get("X-Lab-Signature") or ""
        timestamp = self.headers.get("X-Lab-Timestamp") or ""
        if path_ns != namespace or header_ns != namespace:
            self._json(401, {"error": "namespace_mismatch"})
            return
        try:
            ts = int(timestamp)
        except ValueError:
            self._json(401, {"error": "bad_timestamp"})
            return
        if abs(time.time() - ts) > MAX_SKEW:
            self._json(401, {"error": "stale_timestamp"})
            return
        digest = hashlib.sha256(body).hexdigest()
        # wan-ingress builds the border path with Go's path.Join, which drops the
        # leading slash from the signed string while net/http puts it back in the
        # request target. Accept either form for the same path; the namespace and
        # body digest still bind the request.
        signed_paths = [raw_path]
        if raw_path.startswith("/"):
            signed_paths.append(raw_path[1:])
        matched = False
        for signed_path in signed_paths:
            mac = hmac.new(self.server.border_key, digestmod=hashlib.sha256)
            mac.update(("POST\n%s\n%s\n%s\n%s" % (signed_path, namespace, digest, timestamp)).encode("utf-8"))
            if hmac.compare_digest(mac.hexdigest(), signature):
                matched = True
                break
        if not matched:
            sys.stderr.write(json.dumps({"ts": int(time.time()), "event": "border",
                                         "decision": "refused", "reason": "bad_signature",
                                         "name": path_name}) + "\n")
            self._json(401, {"error": "bad_signature"})
            return
        sys.stderr.write(json.dumps({"ts": int(time.time()), "event": "border",
                                     "decision": "forward", "name": path_name}) + "\n")
        self._dispatch_body(body, via="border")


class Server(ThreadingHTTPServer):
    daemon_threads = True
    allow_reuse_address = True

    def __init__(self, addr, namespace, border_key):
        super().__init__(addr, Handler)
        self.namespace = namespace
        self.border_key = border_key


# --------------------------------------------------------------------- main


def main():
    parser = argparse.ArgumentParser(description="skillz read-only MCP server")
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=8090)
    parser.add_argument("--namespace", default="skillz")
    parser.add_argument("--border-key-file")
    parser.add_argument("--allow-non-loopback", action="store_true")
    args = parser.parse_args()

    if args.host not in ("127.0.0.1", "localhost", "::1") and not args.allow_non_loopback:
        sys.stderr.write("skillz: refusing non-loopback bind %s without --allow-non-loopback\n" % args.host)
        sys.exit(2)

    key = os.environ.get("SKILLZ_BORDER_KEY", "").strip()
    if args.border_key_file:
        try:
            key = Path(args.border_key_file).expanduser().read_text(encoding="utf-8").strip()
        except OSError as exc:
            sys.stderr.write("skillz: cannot read border key: %s\n" % exc)
            sys.exit(2)

    server = Server((args.host, args.port), args.namespace, key.encode("utf-8") if key else b"")

    def stop(_signum, _frame):
        raise SystemExit(0)

    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)
    sys.stderr.write(json.dumps({
        "ts": int(time.time()), "event": "listen", "host": args.host,
        "port": args.port, "namespace": args.namespace,
        "border": "configured" if key else "unconfigured",
    }) + "\n")
    try:
        server.serve_forever(poll_interval=0.2)
    finally:
        server.server_close()


if __name__ == "__main__":
    main()
