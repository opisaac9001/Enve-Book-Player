#!/usr/bin/env python3
import argparse
import json
import math
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from threading import Event
from urllib.parse import parse_qs, urlparse

state = {"mode": "initial", "requests": [], "libraryMode": "ready", "blockedLibraryRequests": 0}
library_release = Event()
library_release.set()


def summary(book_id):
    return {
        "id": book_id,
        "title": "Hearth Fixture Cached" if book_id == 1 else f"Hearth Fixture Added {book_id - 1}",
        "primaryFileType": "EPUB",
        "primaryFileName": f"fixture-{book_id}.epub",
        "addedOn": f"2030-10-20T12:{book_id // 60:02d}:{book_id % 60:02d}Z",
        "readProgress": 0,
        "readStatus": "UNREAD",
        "authors": ["Fixture Author"],
    }


def legacy(book_id):
    book = summary(book_id)
    return {
        "id": book_id,
        "metadata": {"title": book["title"]},
        "primaryFile": {"bookType": "EPUB", "fileName": book["primaryFileName"]},
        "addedOn": book["addedOn"],
    }


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *_args):
        pass

    def do_POST(self):
        self.handle_request()

    def do_PUT(self):
        self.handle_request()

    def do_GET(self):
        self.handle_request()

    def handle_request(self):
        url = urlparse(self.path)
        query = parse_qs(url.query)
        body = self.rfile.read(int(self.headers.get("Content-Length", 0)))
        if url.path == "/__fixture/mode":
            state["mode"] = json.loads(body)["mode"]
            state["requests"] = []
            return self.reply({})
        if url.path == "/__fixture/state":
            return self.reply(state)
        if url.path == "/__fixture/libraries":
            state["libraryMode"] = json.loads(body)["mode"]
            state["blockedLibraryRequests"] = 0
            if state["libraryMode"] == "blocked":
                library_release.clear()
            else:
                library_release.set()
            return self.reply({})

        state["requests"].append({"path": url.path, "query": query, "method": self.command})
        ids = list(range(131, 0, -1)) if state["mode"] != "initial" else [1]
        if url.path.endswith(("/auth/login", "/auth/refresh")):
            return self.reply({"accessToken": "fixture-token"})
        if url.path.endswith("/users/me"):
            return self.reply({"id": 1, "username": "fixture", "name": "Fixture", "permissions": {"admin": True}})
        if url.path == "/api/v1/libraries":
            if state["libraryMode"] == "blocked":
                state["blockedLibraryRequests"] += 1
                if not library_release.wait(timeout=90):
                    return self.reply({}, 503)
            if state["libraryMode"] == "failure":
                return self.reply({}, 503)
            return self.reply([{"id": 1, "name": "Hearth Fixture", "allowedFormats": ["EPUB"]}])
        if url.path == "/api/v1/app/books":
            if state["mode"] == "failure" and query.get("size") == ["50"]:
                return self.reply({}, 503)
            page = int(query.get("page", ["0"])[0])
            size = int(query.get("size", ["50"])[0])
            window = ids[page * size:(page + 1) * size]
            return self.reply({
                "content": [summary(book_id) for book_id in window],
                "page": page,
                "size": size,
                "totalElements": len(ids),
                "totalPages": math.ceil(len(ids) / size),
                "hasNext": (page + 1) * size < len(ids),
                "hasPrevious": page > 0,
            })
        if url.path == "/api/v1/books/batch":
            return self.reply([legacy(int(book_id)) for book_id in query.get("ids", [""])[0].split(",") if book_id])
        if url.path == "/api/v1/libraries/1/book":
            return self.reply([legacy(book_id) for book_id in ids])
        if url.path.startswith("/api/v1/libraries/1/book/"):
            return self.reply(legacy(int(url.path.rsplit("/", 1)[1])))
        if "shel" in url.path or "collection" in url.path:
            return self.reply([])
        if url.path.endswith("/progress"):
            return self.reply({"readProgress": 0, "progress": 0, "percentage": 0, "readStatus": "UNREAD"})
        if self.command in ["PUT", "POST"]:
            return self.reply({})
        return self.reply({}, 404)

    def reply(self, value, code=200):
        data = json.dumps(value).encode()
        try:
            self.send_response(code)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)
        except (BrokenPipeError, ConnectionResetError):
            pass


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Local Grimmory fixture for Hearth refresh UI verification")
    parser.add_argument("--port", type=int, default=0)
    args = parser.parse_args()
    server = ThreadingHTTPServer(("127.0.0.1", args.port), Handler)
    print(f"Hearth fixture: http://127.0.0.1:{server.server_port}", flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        server.server_close()
