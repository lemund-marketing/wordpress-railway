"""Servidor HTTP de teste: serve /srv só com HTTP Basic Auth (AUTH_USER/AUTH_PASS), como a pasta de download."""
import base64
import http.server
import os

ESPERADO = "Basic " + base64.b64encode(
    f"{os.environ['AUTH_USER']}:{os.environ['AUTH_PASS']}".encode()
).decode()


class Handler(http.server.SimpleHTTPRequestHandler):
    def __init__(self, *args, **kwargs):
        super().__init__(*args, directory="/srv", **kwargs)

    def _autorizado(self):
        if self.headers.get("Authorization") == ESPERADO:
            return True
        self.send_response(401)
        self.send_header("WWW-Authenticate", 'Basic realm="pacote"')
        self.send_header("Content-Length", "0")
        self.end_headers()
        return False

    def do_GET(self):
        if self._autorizado():
            super().do_GET()

    def do_HEAD(self):
        if self._autorizado():
            super().do_HEAD()


http.server.ThreadingHTTPServer(("", 8000), Handler).serve_forever()
