#!/usr/bin/env python3
# Copyright (C) 2026 Beangle
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program.  If not, see <https://www.gnu.org/licenses/>.

import argparse
import base64
import hashlib
import socket
import threading
import time
from urllib.parse import parse_qs, urlsplit

LARGE_BODIES = {}

# RFC 6455 规定的握手魔术串。
WEBSOCKET_GUID = b"258EAFA5-E914-47DA-95CA-C5AB0DC85B11"


class BackendState:
    def __init__(self):
        self.lock = threading.Lock()
        self.accepts = 0
        self.requests = 0

    def reset(self):
        with self.lock:
            self.accepts = 0
            self.requests = 0

    def counts(self):
        with self.lock:
            return self.accepts, self.requests


def receive_head(connection, buffered):
    while b"\r\n\r\n" not in buffered:
        chunk = connection.recv(4096)
        if not chunk:
            return None, buffered
        buffered += chunk
    raw_head, buffered = buffered.split(b"\r\n\r\n", 1)
    lines = raw_head.split(b"\r\n")
    headers = {}
    for line in lines[1:]:
        if b":" in line:
            name, value = line.split(b":", 1)
            headers[name.strip().lower()] = value.strip()
    return (lines[0], headers), buffered


def receive_body(connection, headers, buffered):
    length = int(headers.get(b"content-length", b"0"))
    while len(buffered) < length:
        chunk = connection.recv(min(65536, length - len(buffered)))
        if not chunk:
            break
        buffered += chunk
    return buffered[:length], buffered[length:]


def response(status, body=b"", content_type=b"text/plain", extra=b""):
    return (
        b"HTTP/1.1 " + status + b"\r\n"
        b"Content-Type: " + content_type + b"\r\n"
        b"Content-Length: " + str(len(body)).encode() + b"\r\n"
        b"Connection: keep-alive\r\n" + extra + b"\r\n" + body
    )


def large_body(size):
    if size not in LARGE_BODIES:
        LARGE_BODIES[size] = b"x" * size
    return LARGE_BODIES[size]


def handle(connection, state, request_log=None):
    connection.settimeout(40)
    buffered = b""
    try:
        while True:
            parsed, buffered = receive_head(connection, buffered)
            if parsed is None:
                return
            request_line, headers = parsed
            if request_log:
                with open(request_log, "ab") as log:
                    log.write(request_line + b"\n")
                    for name, value in sorted(headers.items()):
                        log.write(b"  " + name + b": " + value + b"\n")
            parts = request_line.split(b" ")
            if len(parts) < 2:
                return
            method, target = parts[0], parts[1]
            path = urlsplit(target.decode("ascii")).path
            query = parse_qs(urlsplit(target.decode("ascii")).query)
            with state.lock:
                state.requests += 1

            if headers.get(b"expect", b"").lower() == b"100-continue":
                connection.sendall(b"HTTP/1.1 100 Continue\r\n\r\n")
            body, buffered = receive_body(connection, headers, buffered)
            if method == b"HEAD":
                connection.sendall(
                    b"HTTP/1.1 200 OK\r\nContent-Length: 7\r\nConnection: keep-alive\r\n\r\n"
                )
            elif path == "/__reset":
                state.reset()
                connection.sendall(response(b"204 No Content"))
            elif path == "/__connections":
                accepts, requests = state.counts()
                payload = f"accepts={accepts}\nrequests={requests}\n".encode()
                connection.sendall(response(b"200 OK", payload))
            elif path == "/expect":
                connection.sendall(response(b"200 OK", b"expect-ok"))
            elif path == "/hints":
                payload = b"hints-ok"
                connection.sendall(
                    b"HTTP/1.1 103 Early Hints\r\nLink: </style.css>; rel=preload\r\n\r\n"
                    + response(b"200 OK", payload)
                )
            elif path == "/hints-separate":
                connection.sendall(
                    b"HTTP/1.1 103 Early Hints\r\nLink: </style.css>; rel=preload\r\n\r\n"
                )
                time.sleep(0.05)
                connection.sendall(response(b"200 OK", b"hints-separate-ok"))
            elif path == "/stall":
                time.sleep(30)
                connection.sendall(response(b"200 OK", b"stalled"))
            elif path == "/slow":
                # 用于优雅退出：请求要慢到 SIGTERM 时仍在途中。
                time.sleep(int(query.get("ms", ["200"])[0]) / 1000.0)
                connection.sendall(response(b"200 OK", b"slow-ok"))
            elif path == "/ws":
                # WebSocket 隧道：握手成功后双向透传字节。`idle=1` 时收到什么都不回，
                # 用来验证 setline 的空闲超时；默认回显，用来验证两个方向都通。
                #
                # 握手必须是真的：haproxy 3.0 会自己校验 `Sec-WebSocket-Key`（缺了回 400）
                # 和 101 里的 `Sec-WebSocket-Accept`（缺了或算错回 502），此时请求根本到不了
                # setline。101 之后的帧格式 setline 不解释，这里也就只按裸字节回显。
                key = headers.get(b"sec-websocket-key", b"")
                if headers.get(b"upgrade", b"").lower() != b"websocket" or not key:
                    connection.sendall(response(b"400 Bad Request", b"upgrade required"))
                    continue
                accept = base64.b64encode(hashlib.sha1(key + WEBSOCKET_GUID).digest())
                connection.sendall(
                    b"HTTP/1.1 101 Switching Protocols\r\n"
                    b"Upgrade: websocket\r\n"
                    b"Connection: Upgrade\r\n"
                    b"Sec-WebSocket-Accept: " + accept + b"\r\n\r\n"
                )
                if buffered and not query.get("idle"):
                    connection.sendall(buffered)
                buffered = b""
                while True:
                    chunk = connection.recv(4096)
                    if not chunk:
                        return
                    if not query.get("idle"):
                        connection.sendall(b"echo:" + chunk)
            elif path == "/no-length":
                connection.sendall(
                    b"HTTP/1.1 200 OK\r\nConnection: close\r\n\r\nno-length-ok"
                )
                return
            elif path == "/status/204":
                connection.sendall(b"HTTP/1.1 204 No Content\r\nConnection: keep-alive\r\n\r\n")
            elif path == "/status/304":
                connection.sendall(b"HTTP/1.1 304 Not Modified\r\nConnection: keep-alive\r\n\r\n")
            elif path == "/large":
                size = int(query.get("bytes", ["1048576"])[0])
                connection.sendall(response(b"200 OK", large_body(size), b"application/octet-stream"))
            else:
                connection.sendall(response(b"200 OK", b"ok"))
    except (OSError, ValueError) as error:
        if request_log:
            with open(request_log, "ab") as log:
                log.write(b"handler-error: " + repr(error).encode() + b"\n")
        return
    finally:
        try:
            connection.close()
        except OSError:
            pass


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--port", type=int, required=True)
    parser.add_argument("--ready-file", required=True)
    parser.add_argument("--request-log")
    args = parser.parse_args()
    state = BackendState()
    listener = socket.socket()
    listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    listener.bind(("127.0.0.1", args.port))
    listener.listen()
    with open(args.ready_file, "w", encoding="ascii") as ready:
        ready.write("ready\n")
    try:
        while True:
            connection, _ = listener.accept()
            with state.lock:
                state.accepts += 1
            threading.Thread(
                target=handle, args=(connection, state, args.request_log), daemon=True
            ).start()
    finally:
        listener.close()


if __name__ == "__main__":
    main()
