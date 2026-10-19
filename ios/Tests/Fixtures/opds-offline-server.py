import argparse
import io
import json
import threading
import zipfile
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path


fixture = Path(__file__).parents[2] / "enveUITests/Fixtures/reader-interaction.epub"
output = io.BytesIO()
with zipfile.ZipFile(fixture) as source, zipfile.ZipFile(output, "w") as target:
    for entry in source.infolist():
        content = source.read(entry.filename)
        if entry.filename.endswith(".opf"):
            content = content.replace(b"Reader Interaction Regression", b"Enve Offline Verification")
        target.writestr(entry, content)
book = output.getvalue()
feed = b'''<?xml version="1.0" encoding="UTF-8"?>
<feed xmlns="http://www.w3.org/2005/Atom">
<id>urn:enve:offline-catalog</id><title>Enve Offline Verification Catalog</title>
<updated>2026-10-11T00:00:00Z</updated>
<link rel="self" type="application/atom+xml;profile=opds-catalog;kind=acquisition" href="/catalog.xml"/>
<entry><id>urn:enve:offline-book</id><title>Enve Offline Verification</title>
<updated>2026-10-11T00:00:00Z</updated><author><name>Enve Fixture</name></author>
<link rel="http://opds-spec.org/acquisition" type="application/epub+zip" href="/book.epub"/>
</entry></feed>'''


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def reply(self, status, content, mime):
        self.send_response(status)
        self.send_header("Content-Type", mime)
        self.send_header("Content-Length", str(len(content)))
        self.end_headers()
        self.wfile.write(content)

    def do_GET(self):
        if self.path == "/catalog.xml":
            self.reply(200, feed, "application/atom+xml;profile=opds-catalog;kind=acquisition")
        elif self.path == "/book.epub":
            self.reply(200, book, "application/epub+zip")
        else:
            self.reply(404, b"", "text/plain")

    def do_POST(self):
        if self.path == "/fixture/shutdown":
            self.reply(200, b"{}", "application/json")
            threading.Thread(target=self.server.shutdown, daemon=True).start()
        else:
            self.reply(404, b"", "text/plain")


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--port", type=int, default=0)
    server = ThreadingHTTPServer(("127.0.0.1", parser.parse_args().port), Handler)
    print(json.dumps({"url": f"http://127.0.0.1:{server.server_port}/catalog.xml"}), flush=True)
    try:
        server.serve_forever()
    finally:
        server.server_close()
