# ABOUTME: Runs gallery-server.py's own code with the timing of a race fixed, so a bats test can
# ABOUTME: replay it every time: a server that exits the moment it is told to stop.
import importlib.util
import sys
import threading
import time
from pathlib import Path

gallery_py, command, root = sys.argv[1:4]
sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location("gallery_server", gallery_py)
gallery = importlib.util.module_from_spec(spec)
spec.loader.exec_module(gallery)
root = Path(root).resolve()


class StopAtOnce(threading.Event):
    """Holds the thread that sets it for a second, so the server's main thread stops and exits
    before that thread does anything more."""

    def set(self):
        super().set()
        time.sleep(1)


if command == "serve-stopping-at-once":
    # A server of another version whose main thread wins every race with a request thread that
    # tells it to stop.
    init = gallery.Gallery.__init__

    def init_stopping_at_once(self, *args):
        init(self, *args)
        self.stop = StopAtOnce()

    gallery.Gallery.__init__ = init_stopping_at_once
    gallery.serve(root, "0.0.0-other")
else:
    sys.exit("no such command: %s" % command)
