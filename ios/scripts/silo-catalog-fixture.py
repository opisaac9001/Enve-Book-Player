#!/usr/bin/env python3
import argparse
import json
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse, parse_qs

state = {"requests": [], "mode": "ready", "count": 120}
user = {"id": "7", "username": "fixture", "email": "", "role": "user", "permissions": [],
        "download_allowed": True, "password_change_required": False}


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def do_GET(self):
        self.handle_request()

    def do_POST(self):
        self.handle_request()

    def handle_request(self):
        url = urlparse(self.path)
        query = parse_qs(url.query)
        body = self.rfile.read(int(self.headers.get("Content-Length", 0)))
        if url.path == "/__fixture/state":
            return self.reply(state)
        if url.path == "/__fixture/mode":
            state["mode"] = json.loads(body)["mode"]
            state["requests"] = []
            return self.reply({})
        state["requests"].append({"path": url.path, "query": query})
        if url.path in ["/api/v2/auth/login", "/api/v2/auth/refresh"]:
            return self.reply({"access_token": "fixture-access", "refresh_token": "fixture-refresh",
                               "expires_in": 3600, "user": user})
        if url.path == "/api/v2/account/me":
            return self.reply(user)
        if url.path == "/api/v2/profiles":
            return self.reply({"items": [{"id": "fixture-profile", "name": "Fixture", "is_primary": True}],
                               "avatar_upload_enabled": False, "max_advisory_age_supported": True,
                               "require_advisory_age_supported": True})
        if url.path == "/api/v2/user/libraries":
            return self.reply({"items": [{"id": str(i), "name": f"Silo Fixture {i}", "type": "audiobooks",
                                          "sort_order": i, "box_sets_enabled": False} for i in [3, 4]]})
        if url.path == "/api/v2/catalog":
            if state["mode"] == "failure":
                return self.problem(503)
            if state["mode"] == "slow":
                time.sleep(3)
            lib = query.get("library_id", ["3"])[0]
            items = [{"content_id": f"audiobook:{lib}-{i:03}", "type": "audiobook",
                      "title": f"Silo Fixture {lib} Book {i:03}", "genres": [], "keywords": [],
                      "duration_seconds": 600, "status": "matched"} for i in range(state["count"])]
            search = query.get("q", [""])[0].lower()
            items = [x for x in items if search in x["title"].lower()]
            start = int(query.get("cursor", ["0"])[0])
            limit = int(query.get("limit", ["50"])[0])
            end = min(start + limit, len(items))
            page = {"has_more": end < len(items)}
            if page["has_more"]:
                page["next_cursor"] = str(end)
            return self.reply({"items": items[start:end], "page": page, "total": len(items), "total_exact": True})
        if url.path.endswith("/collections"):
            return self.reply({"items": [], "collections": [], "page": {"has_more": False}})
        if url.path.endswith("/progress") or url.path.endswith("/activity"):
            return self.reply({"items": [], "page": {"has_more": False}})
        return self.problem(404)

    def problem(self, status):
        self.reply({"type": "https://siloserver.org/docs/api/v2/problems/fixture",
                    "title": "Fixture unavailable", "status": status, "detail": "Fixture failure"}, status)

    def reply(self, value, status=200):
        data = json.dumps(value).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json" if status == 200 else "application/problem+json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        try:
            self.wfile.write(data)
        except BrokenPipeError:
            pass


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--port", type=int, default=57881)
    parser.add_argument("--books-per-library", type=int, default=120)
    args = parser.parse_args()
    state["count"] = args.books_per_library
    ThreadingHTTPServer(("127.0.0.1", args.port), Handler).serve_forever()
