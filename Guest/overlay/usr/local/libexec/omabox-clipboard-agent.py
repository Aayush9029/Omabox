#!/usr/bin/env python3

import json
import os
from pathlib import Path
import selectors
import shutil
import signal
import socket
import stat
import struct
import subprocess
import sys
import tempfile
import time


PORT = 4040
MAX_TEXT_BYTES = 65_536
MAX_WIRE_BYTES = 524_288
IO_TIMEOUT = 3.0
FRAME_TIMEOUT = 10.0
LOCAL_HEADER = struct.Struct("!QB")
READY = b'{"type":"ready","version":1}\n'


class ProtocolError(ValueError):
    pass


def unique_object(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ProtocolError("Duplicate JSON field")
        result[key] = value
    return result


def reject_constant(value):
    raise ProtocolError("Invalid JSON constant")


def validate_text(text):
    if not isinstance(text, str):
        raise ProtocolError("Clipboard text must be a string")
    try:
        encoded = text.encode("utf-8")
    except UnicodeError as error:
        raise ProtocolError("Invalid clipboard encoding") from error
    if len(encoded) > MAX_TEXT_BYTES:
        raise ProtocolError("Clipboard text exceeds the size limit")
    return encoded


def decode_frame(frame):
    if not frame or len(frame) > MAX_WIRE_BYTES:
        raise ProtocolError("Invalid frame length")
    try:
        message = json.loads(
            frame.decode("utf-8"),
            object_pairs_hook=unique_object,
            parse_constant=reject_constant,
        )
    except (UnicodeError, ValueError, RecursionError) as error:
        raise ProtocolError("Invalid JSON frame") from error
    if not isinstance(message, dict) or set(message) != {"type", "text"}:
        raise ProtocolError("Unexpected clipboard fields")
    if message["type"] != "clipboard":
        raise ProtocolError("Unknown message type")
    validate_text(message["text"])
    return message["text"]


def encode_clipboard(text):
    validate_text(text)
    return json.dumps(
        {"type": "clipboard", "text": text}, ensure_ascii=False, separators=(",", ":")
    ).encode("utf-8") + b"\n"


class FrameReader:
    def __init__(self):
        self.buffer = bytearray()
        self.started_at = None

    def feed(self, data):
        messages = []
        for fragment in data.splitlines(keepends=True):
            self.buffer.extend(fragment)
            if len(self.buffer) > MAX_WIRE_BYTES + 1:
                raise ProtocolError("Frame exceeds the size limit")
            if self.buffer.endswith(b"\n"):
                messages.append(decode_frame(self.buffer[:-1]))
                self.buffer.clear()
                self.started_at = None
            elif self.started_at is None:
                self.started_at = time.monotonic()
        return messages

    def check_deadline(self):
        if self.started_at is not None and time.monotonic() - self.started_at > FRAME_TIMEOUT:
            raise ProtocolError("Incomplete frame timed out")


class ClipboardState:
    def __init__(self):
        self.initialized = False
        self.current_text = None
        self.last_host_write = 0

    def host_applied(self, text, timestamp):
        self.current_text = text
        self.last_host_write = timestamp

    def guest_changed(self, text, timestamp):
        first_event = not self.initialized
        self.initialized = True
        if timestamp <= self.last_host_write:
            return None
        previous = self.current_text
        self.current_text = text
        if first_event or text is None or text == previous:
            return None
        return text


def read_clipboard_input():
    descriptor = sys.stdin.fileno()
    result = bytearray()
    deadline = time.monotonic() + IO_TIMEOUT
    try:
        os.set_blocking(descriptor, False)
        with selectors.DefaultSelector() as selector:
            selector.register(descriptor, selectors.EVENT_READ)
            while True:
                remaining = deadline - time.monotonic()
                if remaining <= 0 or not selector.select(remaining):
                    return None
                chunk = os.read(descriptor, MAX_TEXT_BYTES + 1 - len(result))
                if not chunk:
                    return result.decode("utf-8")
                result.extend(chunk)
                if len(result) > MAX_TEXT_BYTES:
                    return None
    except (OSError, UnicodeError):
        return None


def clipboard_has_text():
    if os.environ.get("CLIPBOARD_STATE", "data") != "data":
        return False
    mime_type = os.environ.get("CLIPBOARD_TYPE")
    return not mime_type or mime_type.startswith("text/") or mime_type in {
        "UTF8_STRING", "STRING", "TEXT", "COMPOUND_TEXT",
    }


def emit_clipboard_change(socket_path):
    timestamp = time.monotonic_ns()
    text = read_clipboard_input() if clipboard_has_text() else None
    os.close(sys.stdin.fileno())
    payload = LOCAL_HEADER.pack(timestamp, text is not None)
    if text is not None:
        payload += validate_text(text)
    try:
        with socket.socket(socket.AF_UNIX, socket.SOCK_DGRAM) as sender:
            sender.settimeout(IO_TIMEOUT)
            sender.sendto(payload, socket_path)
    except OSError:
        pass


def decode_change(payload, flags=0):
    if flags & getattr(socket, "MSG_TRUNC", 0) or len(payload) < LOCAL_HEADER.size:
        raise ProtocolError("Invalid clipboard notification")
    timestamp, available = LOCAL_HEADER.unpack(payload[: LOCAL_HEADER.size])
    data = payload[LOCAL_HEADER.size :]
    if available not in (0, 1) or len(data) > MAX_TEXT_BYTES or (not available and data):
        raise ProtocolError("Invalid clipboard notification")
    try:
        return timestamp, data.decode("utf-8") if available else None
    except UnicodeError as error:
        raise ProtocolError("Invalid clipboard notification encoding") from error


def write_clipboard(text):
    subprocess.run(
        ["wl-copy", "--type", "text/plain;charset=utf-8"],
        input=validate_text(text),
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        timeout=IO_TIMEOUT,
        check=True,
    )


def runtime_directory():
    configured = os.environ.get("RUNTIME_DIRECTORY")
    if configured:
        path = Path(configured)
    else:
        runtime = os.environ.get("XDG_RUNTIME_DIR")
        if not runtime:
            raise RuntimeError("A graphical session runtime directory is required")
        path = Path(runtime) / "omabox-clipboard"
        path.mkdir(mode=0o700, exist_ok=True)
    attributes = path.lstat()
    if not stat.S_ISDIR(attributes.st_mode) or attributes.st_uid != os.getuid():
        raise RuntimeError("Clipboard runtime directory is not owned by this user")
    if stat.S_IMODE(attributes.st_mode) & 0o077:
        raise RuntimeError("Clipboard runtime directory must be private")
    return path


def stop_watcher(watcher):
    if watcher.poll() is None:
        try:
            os.killpg(watcher.pid, signal.SIGTERM)
            watcher.wait(timeout=IO_TIMEOUT)
        except subprocess.TimeoutExpired:
            os.killpg(watcher.pid, signal.SIGKILL)
            watcher.wait()
        except ProcessLookupError:
            watcher.wait()


def serve_connection(peer, directory):
    peer.settimeout(IO_TIMEOUT)
    with tempfile.TemporaryDirectory(prefix="connection-", dir=directory) as temporary:
        socket_path = str(Path(temporary) / "changes")
        with socket.socket(socket.AF_UNIX, socket.SOCK_DGRAM) as notifications:
            notifications.bind(socket_path)
            # A text-filtered watcher omits image selections, which can hide the initial baseline.
            watcher = subprocess.Popen(
                [
                    "wl-paste", "--watch", sys.executable, str(Path(__file__).resolve()),
                    "--clipboard-change", socket_path,
                ],
                stdin=subprocess.DEVNULL,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                start_new_session=True,
            )
            try:
                state = ClipboardState()
                frames = FrameReader()
                with selectors.DefaultSelector() as selector:
                    selector.register(notifications, selectors.EVENT_READ)
                    if not selector.select(timeout=IO_TIMEOUT) or watcher.poll() is not None:
                        raise ProtocolError("Clipboard watcher did not initialize")
                    payload, _, flags, _ = notifications.recvmsg(MAX_TEXT_BYTES + LOCAL_HEADER.size)
                    timestamp, text = decode_change(payload, flags)
                    state.guest_changed(text, timestamp)
                    peer.sendall(READY)
                    selector.register(peer, selectors.EVENT_READ)
                    while watcher.poll() is None:
                        for key, _ in selector.select(timeout=1.0):
                            if key.fileobj is peer:
                                data = peer.recv(16_384)
                                if not data:
                                    return
                                for text in frames.feed(data):
                                    if text != state.current_text:
                                        write_clipboard(text)
                                        state.host_applied(text, time.monotonic_ns())
                            else:
                                payload, _, flags, _ = notifications.recvmsg(
                                    MAX_TEXT_BYTES + LOCAL_HEADER.size
                                )
                                timestamp, text = decode_change(payload, flags)
                                changed = state.guest_changed(text, timestamp)
                                if changed is not None:
                                    peer.sendall(encode_clipboard(changed))
                        frames.check_deadline()
            finally:
                stop_watcher(watcher)


def run_server():
    if not os.environ.get("WAYLAND_DISPLAY"):
        raise RuntimeError("A Wayland graphical session is required")
    if not hasattr(socket, "AF_VSOCK"):
        raise RuntimeError("The guest kernel must support virtio-vsock")
    if not all(shutil.which(command) for command in ("wl-copy", "wl-paste")):
        raise RuntimeError("Install wl-clipboard to enable clipboard sharing")
    directory = runtime_directory()
    with socket.socket(socket.AF_VSOCK, socket.SOCK_STREAM) as listener:
        listener.bind((socket.VMADDR_CID_ANY, PORT))
        listener.listen(1)
        while True:
            peer, address = listener.accept()
            with peer:
                if address[0] != socket.VMADDR_CID_HOST:
                    continue
                try:
                    serve_connection(peer, directory)
                except (OSError, ProtocolError, subprocess.SubprocessError):
                    print("Clipboard connection ended; waiting for the host.", file=sys.stderr)


def self_test():
    import threading
    import unittest
    from unittest.mock import Mock, patch

    class ClipboardTests(unittest.TestCase):
        def test_utf8_round_trip_and_embedded_newlines(self):
            text = 'Hello 🌍\n\r\t"\\\x00'
            self.assertEqual(decode_frame(encode_clipboard(text)[:-1]), text)

        def test_split_frame_and_coalesced_messages(self):
            payload = encode_clipboard("first 🌍") + encode_clipboard("second")
            reader = FrameReader()
            actual = []
            for byte in payload:
                actual.extend(reader.feed(bytes([byte])))
            self.assertEqual(actual, ["first 🌍", "second"])
            self.assertEqual(FrameReader().feed(payload), actual)

        def test_text_limit_measures_utf8_bytes(self):
            self.assertEqual(len(validate_text("🌍" * 16_384)), MAX_TEXT_BYTES)
            with self.assertRaises(ProtocolError):
                validate_text("🌍" * 16_384 + "x")

        def test_escaped_content_fits_wire_limit(self):
            text = "\x00" * MAX_TEXT_BYTES
            encoded = encode_clipboard(text)
            self.assertLessEqual(len(encoded), MAX_WIRE_BYTES)
            self.assertEqual(FrameReader().feed(encoded), [text])

        def test_invalid_frames(self):
            invalid = [
                b"", b"[]", b"null", b"\xff", b'{"type":"unknown","text":"x"}',
                b'{"type":"clipboard","text":4}', b'{"type":"clipboard"}',
                b'{"type":"clipboard","text":"x","extra":true}',
                b'{"type":"clipboard","text":"x","text":"y"}',
                b'{"type":"clipboard","text":"\\ud800"}',
                b'{"type":"clipboard","text":NaN}',
                b"[" * 2_000 + b"]" * 2_000,
            ]
            for frame in invalid:
                with self.subTest(frame=frame[:60]), self.assertRaises(ProtocolError):
                    decode_frame(frame)

        def test_unterminated_oversized_frame(self):
            with self.assertRaises(ProtocolError):
                FrameReader().feed(b"x" * (MAX_WIRE_BYTES + 2))

        def test_incomplete_frame_deadline(self):
            reader = FrameReader()
            reader.feed(b"{")
            reader.started_at = time.monotonic() - FRAME_TIMEOUT - 1
            with self.assertRaises(ProtocolError):
                reader.check_deadline()

        def test_existing_clipboard_is_never_sent_on_connect(self):
            for existing in [None, "", "existing text"]:
                state = ClipboardState()
                self.assertIsNone(state.guest_changed(existing, 1))
                self.assertEqual(state.guest_changed("new text", 2), "new text")

        def test_dedup_preserves_repeated_copy_after_different_text(self):
            state = ClipboardState()
            state.guest_changed(None, 1)
            self.assertEqual(state.guest_changed("A", 2), "A")
            self.assertIsNone(state.guest_changed("A", 3))
            self.assertEqual(state.guest_changed("B", 4), "B")
            self.assertEqual(state.guest_changed("A", 5), "A")

        def test_host_echo_and_stale_events_are_suppressed(self):
            state = ClipboardState()
            state.guest_changed(None, 1)
            state.host_applied("from host", 10)
            self.assertIsNone(state.guest_changed("older guest copy", 9))
            self.assertEqual(state.current_text, "from host")
            self.assertIsNone(state.guest_changed("from host", 11))
            self.assertEqual(state.guest_changed("new guest copy", 12), "new guest copy")

        def test_reconnection_has_a_fresh_baseline(self):
            original = ClipboardState()
            original.guest_changed("old", 1)
            original.guest_changed("new", 2)
            reconnected = ClipboardState()
            self.assertIsNone(reconnected.guest_changed("new", 3))

        def test_local_notification_limits(self):
            payload = LOCAL_HEADER.pack(100, 1) + b"x" * MAX_TEXT_BYTES
            self.assertEqual(decode_change(payload), (100, "x" * MAX_TEXT_BYTES))
            for invalid in [b"x", payload + b"x", LOCAL_HEADER.pack(1, 2), LOCAL_HEADER.pack(1, 0) + b"x"]:
                with self.assertRaises(ProtocolError):
                    decode_change(invalid)
            with self.assertRaises(ProtocolError):
                decode_change(payload, getattr(socket, "MSG_TRUNC", 0x20))

        def test_helper_preserves_original_event_and_rejects_invalid_content(self):
            with tempfile.TemporaryDirectory(prefix="ob-", dir="/tmp") as directory:
                socket_path = str(Path(directory) / "changes")
                environment = dict(os.environ)
                with socket.socket(socket.AF_UNIX, socket.SOCK_DGRAM) as receiver:
                    receiver.bind(socket_path)
                    receiver.settimeout(IO_TIMEOUT)
                    for state, mime_type, data, expected in [
                        ("data", "text/plain", b"original guest text\n", "original guest text\n"),
                        ("nil", "", b"", None),
                        ("sensitive", "text/plain", b"secret", None),
                        ("data", "image/svg+xml", b"<svg></svg>", None),
                        ("data", "text/plain", b"x" * (MAX_TEXT_BYTES + 1), None),
                        ("data", "text/plain", b"\xff", None),
                    ]:
                        environment["CLIPBOARD_STATE"] = state
                        environment["CLIPBOARD_TYPE"] = mime_type
                        subprocess.run(
                            [sys.executable, str(Path(__file__).resolve()), "--clipboard-change", socket_path],
                            env=environment,
                            input=data,
                            stdout=subprocess.DEVNULL,
                            timeout=IO_TIMEOUT + 1,
                            check=True,
                        )
                        _, text = decode_change(receiver.recv(MAX_TEXT_BYTES + LOCAL_HEADER.size))
                        self.assertEqual(text, expected)

        def test_sensitive_and_nontext_events_are_not_read(self):
            for state, mime_type, expected in [
                ("sensitive", "text/plain", False), ("nil", "text/plain", False),
                ("clear", "text/plain", False), ("data", "image/png", False),
                ("data", "text/plain", True), ("data", "", True),
            ]:
                with patch.dict(os.environ, {"CLIPBOARD_STATE": state, "CLIPBOARD_TYPE": mime_type}):
                    self.assertEqual(clipboard_has_text(), expected)

        def test_connection_handshake_and_bidirectional_clipboard(self):
            module = sys.modules[__name__]
            watcher = Mock()
            watcher.poll.return_value = None
            paths = []
            applied = []
            errors = []
            clipboard_written = threading.Event()
            watcher_started = threading.Event()

            def start_watcher(command, **options):
                paths.append(command[-1])
                watcher_started.set()
                return watcher

            def apply_clipboard(text):
                applied.append(text)
                clipboard_written.set()

            def serve(peer, directory):
                try:
                    serve_connection(peer, directory)
                except Exception as error:
                    errors.append(error)
                finally:
                    peer.close()

            with tempfile.TemporaryDirectory(prefix="ob-", dir="/tmp") as directory:
                with socket.socket(socket.AF_UNIX, socket.SOCK_DGRAM) as sender:
                    peer, host = socket.socketpair()
                    host.settimeout(IO_TIMEOUT)
                    with patch.object(subprocess, "Popen", side_effect=start_watcher), patch.object(
                        module, "write_clipboard", side_effect=apply_clipboard
                    ), patch.object(module, "stop_watcher"):
                        worker = threading.Thread(target=serve, args=(peer, directory), daemon=True)
                        worker.start()
                        try:
                            self.assertTrue(watcher_started.wait(IO_TIMEOUT))
                            host.settimeout(0.03)
                            with self.assertRaises(socket.timeout):
                                host.recv(len(READY))
                            host.settimeout(IO_TIMEOUT)
                            sender.sendto(LOCAL_HEADER.pack(1, 1) + b"existing", paths[0])
                            self.assertEqual(host.recv(len(READY)), READY)
                            sender.sendto(LOCAL_HEADER.pack(2, 1) + b"guest copy", paths[0])
                            self.assertEqual(host.recv(4096), encode_clipboard("guest copy"))
                            host.sendall(encode_clipboard("host copy"))
                            self.assertTrue(clipboard_written.wait(IO_TIMEOUT))
                            self.assertEqual(applied, ["host copy"])
                        finally:
                            host.close()
                            worker.join(IO_TIMEOUT + 1)
                        self.assertFalse(worker.is_alive())
                        self.assertEqual(errors, [])

        def test_missing_initial_callback_disconnects_without_ready(self):
            module = sys.modules[__name__]
            watcher = Mock()
            watcher.poll.return_value = None
            peer, host = socket.socketpair()
            try:
                with tempfile.TemporaryDirectory(prefix="ob-", dir="/tmp") as directory:
                    with patch.object(subprocess, "Popen", return_value=watcher), patch.object(
                        module, "stop_watcher"
                    ), patch.object(module, "IO_TIMEOUT", 0.03):
                        with self.assertRaisesRegex(ProtocolError, "did not initialize"):
                            serve_connection(peer, directory)
                peer.close()
                self.assertEqual(host.recv(4096), b"")
            finally:
                peer.close()
                host.close()

    suite = unittest.defaultTestLoader.loadTestsFromTestCase(ClipboardTests)
    return 0 if unittest.TextTestRunner(verbosity=2).run(suite).wasSuccessful() else 1


if __name__ == "__main__":
    if sys.argv[1:] == ["--self-test"]:
        raise SystemExit(self_test())
    if len(sys.argv) == 3 and sys.argv[1] == "--clipboard-change":
        emit_clipboard_change(sys.argv[2])
    elif len(sys.argv) == 1:
        try:
            run_server()
        except (OSError, RuntimeError) as error:
            print(f"Clipboard bridge could not start: {error}", file=sys.stderr)
            raise SystemExit(1)
    else:
        print("Usage: omabox-clipboard-agent.py [--self-test]", file=sys.stderr)
        raise SystemExit(2)
