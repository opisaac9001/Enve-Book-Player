import base64
import argparse
import json
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


def token():
    payload = json.dumps({"exp": int(time.time()) + 3600, "type": "access"}).encode()
    return "e30." + base64.urlsafe_b64encode(payload).decode().rstrip("=") + ".fixture"


class Handler(BaseHTTPRequestHandler):
    lock = threading.Lock()
    expired = False
    refresh_count = 0
    library_count = 0
    access_token = token()

    def log_message(self, *args):
        pass

    def reply(self, status, payload):
        body = json.dumps(payload).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        try:
            self.wfile.write(body)
        except (BrokenPipeError, ConnectionResetError):
            pass

    def user(self):
        return {"id": "fixture-user", "username": "fixture-user", "type": "user",
                "accessToken": self.access_token, "refreshToken": "fixture-refresh",
                "mediaProgress": [], "bookmarks": [], "permissions": {"accessAllLibraries": True}}

    def do_GET(self):
        if self.path == "/fixture/stats":
            with self.lock:
                counts = {"refresh": self.refresh_count, "libraries": self.library_count}
            self.reply(200, counts)
        elif self.path == "/status":
            self.reply(200, {"isInit": True, "authMethods": ["local"]})
        elif self.path.startswith("/api/") and self.expired:
            self.reply(401, {})
        elif self.path == "/api/libraries":
            with self.lock:
                type(self).library_count += 1
            self.reply(200, {"libraries": [{"id": "fixture", "name": "Recovery fixture", "mediaType": "book"}]})
        elif self.path.startswith("/api/libraries/fixture/items"):
            self.reply(200, {"results": [], "total": 0, "limit": 50, "page": 0})
        elif self.path == "/api/me":
            self.reply(200, self.user())
        else:
            self.reply(200, {})

    def do_POST(self):
        if self.path == "/fixture/expire":
            with self.lock:
                type(self).expired = True
                type(self).refresh_count = 0
            self.reply(200, {})
        elif self.path == "/auth/refresh":
            with self.lock:
                type(self).refresh_count += 1
            time.sleep(20)
            self.reply(200, {"user": self.user()})
        elif self.path in ("/login", "/api/authorize"):
            self.reply(200, {"user": self.user()})
        else:
            self.reply(404, {})


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--port", type=int, default=0)
    server = ThreadingHTTPServer(("127.0.0.1", parser.parse_args().port), Handler)
    print(json.dumps({"url": f"http://127.0.0.1:{server.server_port}"}), flush=True)
    server.serve_forever()
