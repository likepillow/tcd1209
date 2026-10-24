"""Single transport owner: USB I/O is independent of decoding and disk I/O."""
from collections import deque
import queue
import threading


class ReceivePipeline:
    def __init__(self, factory, dll, recorder=None, *, budget=64 << 20):
        self.factory, self.dll, self.recorder = factory, dll, recorder
        self.budget = budget
        self.condition = threading.Condition()
        self.transfers = deque()
        self.queued_bytes = self.peak_bytes = 0
        self.commands = queue.Queue(maxsize=16)
        self.stop_requested = threading.Event()
        self.closing = threading.Event()
        self.opened = threading.Event()
        self.failure = self.recording_error = None
        self.thread = threading.Thread(target=self._run, name='SPIF transport', daemon=True)

    def __enter__(self):
        self.thread.start()
        self.opened.wait()
        if self.failure:
            self.close()
            raise OSError(self.failure)
        return self

    def _run(self):
        try:
            with self.factory(self.dll) as usb:
                self.opened.set()
                while not self.closing.is_set():
                    try:
                        request = self.commands.get_nowait()
                    except queue.Empty:
                        request = None
                    if request is not None:
                        wire, result, completed = request
                        try:
                            result.append(usb.write(wire))
                        except Exception as error:
                            result.append(error)
                        finally:
                            completed.set()
                    # Reserve one maximum transfer before receiving it. Existing
                    # bytes are never evicted. Pressure causes the controller to
                    # STOP; inability to drain is surfaced, not called lossless.
                    with self.condition:
                        if self.queued_bytes + 65536 > self.budget:
                            self.stop_requested.set()
                            self.condition.wait(.01)
                            continue
                    transfer = usb.read()
                    if transfer.data and self.recorder is not None:
                        try:
                            self.recorder.append(transfer.data)
                        except (OSError, BufferError) as error:
                            self.recording_error = self.recording_error or str(error)
                            self.stop_requested.set()
                    with self.condition:
                        # Empty timeout messages are coalesced; no evidence bytes
                        # are dropped and at least one timeout remains observable.
                        if (transfer.idle_timeout and self.transfers
                                and self.transfers[-1].idle_timeout):
                            continue
                        self.transfers.append(transfer)
                        self.queued_bytes += len(transfer.data)
                        self.peak_bytes = max(self.peak_bytes, self.queued_bytes)
                        if self.queued_bytes >= self.budget*.90:
                            self.stop_requested.set()
                        self.condition.notify_all()
                    if not transfer.success and not transfer.idle_timeout:
                        break
        except Exception as error:
            self.failure = str(error)
        finally:
            self.opened.set()
            with self.condition:
                self.condition.notify_all()

    def write(self, wire):
        completed, result = threading.Event(), []
        self.commands.put_nowait((wire, result, completed))
        while not completed.wait(.05):
            if not self.thread.is_alive():
                raise OSError(self.failure or 'USB transport stopped before command write')
        if isinstance(result[0], Exception):
            raise result[0]
        return result[0]

    def read(self):
        with self.condition:
            while not self.transfers:
                if not self.thread.is_alive():
                    raise OSError(self.failure or 'USB transport stopped')
                self.condition.wait(.05)
            transfer = self.transfers.popleft()
            self.queued_bytes -= len(transfer.data)
            self.condition.notify_all()
            return transfer

    def close(self):
        self.closing.set()
        with self.condition:
            self.condition.notify_all()
        self.thread.join()

    def __exit__(self, *_):
        self.close()
