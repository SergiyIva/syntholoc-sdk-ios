"""Loopback origin for real URLSession/cache tests; no third party dependencies."""
import hashlib
import json
import pathlib
import sys
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

control = pathlib.Path(sys.argv[1])


def encode(value):
    return json.dumps(value, separators=(",", ":")).encode()


def sha(value):
    return hashlib.sha256(value).hexdigest()


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def do_GET(self):
        config = json.loads(control.read_text())
        with control.with_suffix(".requests").open("a") as stream:
            stream.write(self.path + "\n")
        if config.get("delay") and self.path.endswith("/manifest.json"):
            time.sleep(config["delay"])
        base = "/ota/v1/distributions/dist/channels/production/"
        version = config.get("version", 1)
        release_id = "release" + str(version)
        asset = encode(config.get("strings", {"hello": "Hello " + str(version), "empty": ""}))
        asset_hash = sha(asset)
        release = encode({
            "protocolVersion": 1, "distributionId": "dist", "releaseId": release_id,
            "catalogVersion": "v1", "createdAt": "2026-10-19T00:00:00.000Z", "sourceDigest": "a" * 64,
            "requiredBundles": ["app"], "locales": [{"localeKey": "en", "languageTag": "en", "assets": [{
                "id": "asset" + str(version), "bundle": "app", "namespace": "app", "format": "JSON_FLAT",
                "path": "assets/asset" + str(version) + "/" + asset_hash, "sha256": asset_hash,
                "bytes": len(asset), "contentType": "application/json"
            }]}]
        })
        etag = '"generation-' + str(config.get("generation", version)) + '"'
        code = config.get("status", 200)
        if code != 200:
            body = encode({"code": config.get("code", "OTA_KEY_INVALID")})
        elif self.path == base + "manifest.json":
            body = encode({
                "protocolVersion": 1, "distributionId": "dist", "channel": "production", "catalogVersion": "v1",
                "generation": config.get("generation", version), "recommendedCheckIntervalSeconds": 60,
                "release": {"id": release_id, "manifestPath": base + "releases/" + release_id + "/manifest.json",
                            "sha256": sha(release), "bytes": len(release)}
            })
            if self.headers.get("If-None-Match") == etag:
                code, body = 304, b""
        elif self.path == base + "releases/" + release_id + "/manifest.json":
            body = release
        elif self.path == base + "releases/" + release_id + "/assets/asset" + str(version) + "/" + asset_hash:
            body = b"corrupted" if config.get("badHash") else asset
        else:
            code, body = 404, encode({"code": "OTA_ASSET_UNKNOWN"})
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("ETag", etag)
        self.end_headers()
        try:
            self.wfile.write(body)
        except (BrokenPipeError, ConnectionResetError):
            pass


server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
print(server.server_port, flush=True)
server.serve_forever()
