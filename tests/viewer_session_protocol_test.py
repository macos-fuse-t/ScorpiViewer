#!/usr/bin/env python3
"""Exercise the production native client against an isolated Unix WebSocket."""
import base64
import hashlib
import json
import pathlib
import queue
import select
import socket
import struct
import subprocess
import tempfile
import threading

ROOT = pathlib.Path(__file__).resolve().parents[1]


def exact(conn, length):
    result = b""
    while len(result) < length:
        data = conn.recv(length - len(result))
        if not data:
            raise EOFError()
        result += data
    return result


def receive(conn):
    first, second = exact(conn, 2)
    assert first & 0x0F == 1 and second & 0x80
    length = second & 0x7F
    if length == 126:
        length = struct.unpack("!H", exact(conn, 2))[0]
    assert length <= 4096
    mask = exact(conn, 4)
    data = exact(conn, length)
    return json.loads(bytes(byte ^ mask[i % 4] for i, byte in enumerate(data)))


def send(conn, value):
    data = json.dumps(value).encode()
    header = bytes([0x81, len(data)]) if len(data) < 126 else b"\x81\x7e" + struct.pack("!H", len(data))
    conn.sendall(header + data)


def handshake(conn):
    data = b""
    while not data.endswith(b"\r\n\r\n"):
        data += exact(conn, 1)
    lines = data.decode().split("\r\n")
    assert lines[0] == "GET /v1/vms/vm_abcdefghijkl/viewer/ws HTTP/1.1"
    headers = dict(line.lower().split(": ", 1) for line in lines[1:] if ": " in line)
    assert headers["sec-websocket-protocol"] == "scorpi.viewer.v1"
    # Preserve the original case of the WebSocket key for the accept digest.
    key = next(line.split(": ", 1)[1] for line in lines if line.lower().startswith("sec-websocket-key:"))
    accept = base64.b64encode(hashlib.sha1((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").encode()).digest()).decode()
    conn.sendall(("HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
                  f"Sec-WebSocket-Accept: {accept}\r\nSec-WebSocket-Protocol: scorpi.viewer.v1\r\n\r\n").encode())


def main():
    with tempfile.TemporaryDirectory(prefix="viewer-session-", dir="/tmp") as directory:
        binary = pathlib.Path(directory) / "harness"
        subprocess.run(["clang", "-fobjc-arc", "-I/usr/local/include", "-I" + str(ROOT / "ScorpiViewer"),
                        "-framework", "Foundation", str(ROOT / "tests/viewer_session_harness.m"),
                        str(ROOT / "ScorpiViewer/ViewerSessionClient.m"), str(ROOT / "libs/libwebsockets.a"),
                        "-o", str(binary)], check=True, capture_output=True)
        path = str(pathlib.Path(directory) / "daemon.sock")
        listener = socket.socket(socket.AF_UNIX)
        listener.bind(path)
        listener.listen(2)
        listener.settimeout(6)
        observed, failures = queue.Queue(), queue.Queue()
        close_first = threading.Event()

        def server():
            try:
                for connection_number in range(2):
                    with listener.accept()[0] as conn:
                        conn.settimeout(6)
                        handshake(conn)
                        count = 3 if connection_number == 0 else 2
                        for index in range(count):
                            message = receive(conn)
                            assert set(message) == {"type", "seq", "focused", "clipboard_enabled"}
                            assert message["type"] == "viewer.state" and message["seq"] == index + 1
                            observed.put((connection_number, message))
                            send(conn, {"type": "viewer.state.ack", "seq": message["seq"]})
                            state = "ready" if message["focused"] and message["clipboard_enabled"] else "paused"
                            send(conn, {"type": "clipboard.status", "seq": message["seq"], "state": state})
                        if connection_number == 0:
                            assert close_first.wait(6)
                            conn.shutdown(socket.SHUT_RDWR)
            except BaseException as error:
                failures.put(error)

        thread = threading.Thread(target=server, daemon=True)
        thread.start()
        process = subprocess.Popen([str(binary), path], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                   stderr=subprocess.PIPE, text=True, bufsize=1)

        def line(expected):
            assert select.select([process.stdout], [], [], 6)[0], "native client did not report readiness"
            assert process.stdout.readline().strip() == expected

        def command(value):
            process.stdin.write(value + "\n")
            process.stdin.flush()

        def expect(connection, focused, enabled):
            number, message = observed.get(timeout=6)
            assert number == connection and message["focused"] == focused and message["clipboard_enabled"] == enabled

        try:
            line("ready"); expect(0, True, True)
            command("blur"); expect(0, False, True)
            command("focus"); line("ready"); expect(0, True, True)
            command("reconnect"); close_first.set()
            line("disconnected"); line("ready"); expect(1, True, True)
            command("disable"); expect(1, True, False)
            command("stop")
            assert process.wait(timeout=6) == 0, process.stderr.read()
            thread.join(timeout=6)
            assert not thread.is_alive()
            if not failures.empty():
                raise failures.get()
            print("Native Viewer state, focus, disable, readiness, and reconnect checks passed")
        finally:
            if process.poll() is None:
                process.kill(); process.wait()
            listener.close()


if __name__ == "__main__":
    main()
