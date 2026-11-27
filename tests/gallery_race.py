# ABOUTME: Runs gallery-server.py's own code with the timing of a race fixed, so a bats test can
# ABOUTME: replay it every time: a server that exits the moment a run asks it to stop, and a run
# ABOUTME: that read a server's health before another run replaced that server, and a record that lands
# ABOUTME: in a run's status log while the server readies it for a record of its own.
import importlib.util
import subprocess
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
elif command == "ensure-after-another":
    # Reads the running server's health, lets another run's ensure replace that server, then goes
    # on with the health it read. Prints the pid of the server the other run left.
    health = gallery.control(root, "health")
    other = subprocess.run([sys.executable, "-I", gallery_py, "ensure", "--root", str(root)])
    if other.returncode != 0:
        sys.exit("the other run's ensure exited %d" % other.returncode)
    print(gallery.control(root, "health")["pid"])
    control = gallery.control
    read_earlier = [health]

    def control_after_another(root, command, timeout=2):
        if command == "health" and read_earlier:
            return read_earlier.pop()
        return control(root, command, timeout)

    gallery.control = control_after_another
    sys.exit(gallery.ensure(root))
elif command == "trim-as-a-record-lands":
    # Readies the status log of the run folder given as the root for a record (drop_cut_off_record),
    # with the record given after it landing just after the trim reads the log, as a provider that no
    # token holds the run for appends one while a frame's delete or Retry readies the log.
    status_path = str(root / "status")
    record = sys.argv[4].encode()
    real_open = open

    class RecordLandsAfterRead:
        def __init__(self, f):
            self.f = f
            self.landed = False

        def __enter__(self):
            return self

        def __exit__(self, *exc):
            self.f.close()

        def read(self, *args):
            data = self.f.read(*args)
            if not self.landed:
                self.landed = True
                with real_open(status_path, "ab") as provider:
                    provider.write(record)
            return data

        def __getattr__(self, name):
            return getattr(self.f, name)

    def open_status(path, *args, **kwargs):
        f = real_open(path, *args, **kwargs)
        return RecordLandsAfterRead(f) if path == status_path else f

    gallery.open = open_status
    gallery.drop_cut_off_record(root)
else:
    sys.exit("no such command: %s" % command)
