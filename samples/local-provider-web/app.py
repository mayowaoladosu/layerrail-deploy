from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        status = 200 if self.path in ("/", "/health") else 404
        body = json.dumps(
            {
                "status": "ok" if status == 200 else "not_found",
                "path": self.path,
                "deployment_id": os.environ.get("LRAIL_DEPLOYMENT_ID"),
                "provider": "local",
            },
            sort_keys=True,
        ).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, format, *args):
        print(f"sample-web {self.address_string()} {format % args}", flush=True)


if __name__ == "__main__":
    port = int(os.environ.get("PORT", "8000"))
    ThreadingHTTPServer(("0.0.0.0", port), Handler).serve_forever()
