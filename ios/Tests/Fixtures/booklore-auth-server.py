import json
import os
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


class Handler(BaseHTTPRequestHandler):
    lock = threading.Lock()
    refresh_count = 0
    reject_refresh = False
    delay_unauthorized = False
    unauthorized_count = 0

    def log_message(self, *args):
        pass

    def reply(self, status, payload):
        body = json.dumps(payload).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if self.path == "/fixture/requests":
            with self.lock:
                count = type(self).refresh_count
            self.reply(200, {"refresh": count})
        elif self.path == "/api/v1/users/me":
            authorized = self.headers.get("Authorization") == "Bearer rotated-access"
            if not authorized:
                with self.lock:
                    type(self).unauthorized_count += 1
                    delayed = type(self).delay_unauthorized and type(self).unauthorized_count > 1
                if delayed:
                    time.sleep(0.4)
            self.reply(200 if authorized else 401, {})
        else:
            self.reply(404, {})

    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers.get("Content-Length", 0))))
        tokens = {"accessToken": "rotated-access", "refreshToken": "rotated-refresh"}
        if self.path == "/fixture/reset":
            with self.lock:
                type(self).refresh_count = 0
                type(self).reject_refresh = body["rejectRefresh"]
                type(self).delay_unauthorized = body.get("delayUnauthorized", False)
                type(self).unauthorized_count = 0
            self.reply(200, {})
        elif self.path == "/api/v1/auth/refresh":
            with self.lock:
                type(self).refresh_count += 1
                rejected = type(self).reject_refresh
            valid = body.get("refreshToken") in ("fixture-refresh", "rotated-refresh")
            valid = valid and self.headers.get("Authorization") is None
            time.sleep(0.1)
            self.reply(401 if rejected or not valid else 200, tokens if valid else {})
        elif self.path == "/api/v1/auth/login":
            valid = body == {"username": "fixture-user", "password": "fixture-password"}
            valid = valid and self.headers.get("Authorization") is None
            self.reply(200 if valid else 401, tokens if valid else {})
        else:
            self.reply(404, {})


if __name__ == "__main__":
    server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    print(json.dumps({"url": f"http://127.0.0.1:{server.server_port}", "pid": os.getpid()}), flush=True)
    server.serve_forever()
