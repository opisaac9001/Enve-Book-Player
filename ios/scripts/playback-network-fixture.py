from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import re
import struct
from threading import Lock
import time

RATE = 48_000
PCM_SIZE = RATE * 2 * 120
HEADER = (
    b"RIFF" + struct.pack("<I", 36 + PCM_SIZE) + b"WAVEfmt "
    + struct.pack("<IHHIIHH", 16, 1, 1, RATE, RATE * 2, 2, 16)
    + b"data" + struct.pack("<I", PCM_SIZE)
)
AUDIO = HEADER + bytes(PCM_SIZE)
states = {}
lock = Lock()


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def do_GET(self):
        parts = self.path.split("?")[0].strip("/").split("/")
        key = parts[1] if len(parts) > 1 else ""
        with lock:
            state = states.setdefault(key, {"mode": "online", "bytes": 0, "requests": 0})
        if parts[0] == "control":
            with lock:
                if len(parts) > 2:
                    state["mode"] = parts[2]
                data = json.dumps(state).encode()
            self.send_response(200)
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)
            return
        if parts[0] != "stream":
            self.send_error(404)
            return
        with lock:
            state["requests"] += 1
            offline = state["mode"] == "drop"
        if offline:
            self.send_error(503)
            return
        start, end = 0, len(AUDIO) - 1
        byte_range = re.match(r"bytes=(\d+)-(\d*)", self.headers.get("Range", ""))
        if byte_range:
            start = int(byte_range[1])
            end = min(int(byte_range[2]) if byte_range[2] else end, end)
        if start >= len(AUDIO):
            self.send_error(416)
            return
        self.send_response(206 if byte_range else 200)
        self.send_header("Content-Type", "audio/wav")
        self.send_header("Accept-Ranges", "bytes")
        self.send_header("Content-Length", str(end - start + 1))
        self.send_header("Cache-Control", "no-store")
        if byte_range:
            self.send_header("Content-Range", f"bytes {start}-{end}/{len(AUDIO)}")
        self.end_headers()
        try:
            while start <= end:
                with lock:
                    mode = state["mode"]
                if mode == "drop":
                    self.close_connection = True
                    return
                if mode == "stall":
                    time.sleep(0.05)
                    continue
                chunk = AUDIO[start:min(end + 1, start + 9_600)]
                self.wfile.write(chunk)
                self.wfile.flush()
                start += len(chunk)
                with lock:
                    state["bytes"] += len(chunk)
                if end - start > 9_600:
                    time.sleep(0.08)
        except (BrokenPipeError, ConnectionResetError):
            pass


if __name__ == "__main__":
    ThreadingHTTPServer(("127.0.0.1", 18763), Handler).serve_forever()
