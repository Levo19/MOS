import sys, functools
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
class Q(SimpleHTTPRequestHandler):
    def log_message(self, *a): pass
port = int(sys.argv[1]); root = sys.argv[2]
ThreadingHTTPServer(('127.0.0.1', port), functools.partial(Q, directory=root)).serve_forever()
