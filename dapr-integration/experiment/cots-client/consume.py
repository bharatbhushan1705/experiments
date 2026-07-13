# Receive Pulsar messages as HTTP POSTs from the Dapr consumer sidecar.
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import base64, itertools, json, os, time

log_every = int(os.environ.get('LOG_EVERY', '10'))
count = itertools.count(1)

class Handler(BaseHTTPRequestHandler):
    def do_POST(self):
        body = self.rfile.read(int(self.headers.get('Content-Length') or 0))
        # dapr delivers the raw pulsar payload base64-wrapped in a cloudevent
        try:
            event = json.loads(body)
            msg = base64.b64decode(event['data_base64']).decode() if 'data_base64' in event else event.get('data', body.decode(errors='replace'))
        except Exception:
            msg = body.decode(errors='replace')
        n = next(count)
        if n == 1 or n % log_every == 0:
            print('#%d' % n, time.strftime('%H:%M:%S'), self.path, msg, flush=True)
        self.send_response(200)
        self.end_headers()

    def do_GET(self):
        self.send_response(200)
        self.end_headers()

    def log_message(self, *args):
        pass

print('listening on :8080', flush=True)
ThreadingHTTPServer(('0.0.0.0', 8080), Handler).serve_forever()
