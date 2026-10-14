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

"""给 scripts/e2e.sh 用的最小 WebSocket 探针。

不实现帧格式、掩码和 ping/pong：setline 在 101 之后只做字节透传，所以这里也只收发裸字节，
足够验证隧道的两个方向。

握手必须是完整合法的：haproxy 3.0 会自己校验请求里的 `Sec-WebSocket-Key`，缺了直接回
400，setline 根本收不到这个请求。
"""

import argparse
import base64
import os
import socket
import sys
import time


def handshake(args):
    connection = socket.create_connection((args.host, args.port), timeout=5)
    key = base64.b64encode(os.urandom(16))
    head = (
        "GET %s HTTP/1.1\r\nHost: %s\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
        "Sec-WebSocket-Key: %s\r\nSec-WebSocket-Version: 13\r\n\r\n"
        % (args.path, args.host_header, key.decode("ascii"))
    )
    connection.sendall(head.encode("ascii"))
    buffered = b""
    while b"\r\n\r\n" not in buffered:
        chunk = connection.recv(4096)
        if not chunk:
            fail("handshake: connection closed before the response head")
        buffered += chunk
    raw_head, buffered = buffered.split(b"\r\n\r\n", 1)
    status = raw_head.split(b"\r\n", 1)[0].decode("ascii", "replace")
    if "101" not in status:
        fail("handshake: expected 101, got %s" % status)
    return connection, buffered


def fail(message):
    print(message, file=sys.stderr)
    sys.exit(1)


def run_echo(args):
    connection, buffered = handshake(args)
    message = args.message.encode("ascii")
    expected = b"echo:" + message
    connection.sendall(message)
    got = buffered
    deadline = time.time() + 5
    while expected not in got and time.time() < deadline:
        chunk = connection.recv(4096)
        if not chunk:
            break
        got += chunk
    connection.close()
    if expected not in got:
        fail("echo: expected %r, got %r" % (expected, got))
    print("echo ok (%d bytes back)" % len(got))


def run_idle(args):
    connection, _ = handshake(args)
    started = time.time()
    connection.settimeout(args.expect_millis / 1000.0 + 5)
    try:
        while True:
            chunk = connection.recv(4096)
            if not chunk:
                break
    except socket.timeout:
        fail("idle: tunnel stayed open longer than %d ms" % args.expect_millis)
    elapsed_millis = (time.time() - started) * 1000
    connection.close()
    if abs(elapsed_millis - args.expect_millis) > args.slack_millis:
        fail(
            "idle: closed after %.0f ms, expected %d ms +- %d ms"
            % (elapsed_millis, args.expect_millis, args.slack_millis)
        )
    print("idle ok (closed after %.0f ms)" % elapsed_millis)


def run_hold(args):
    connection, _ = handshake(args)
    connection.settimeout(1.0)
    deadline = time.time() + args.seconds
    while time.time() < deadline:
        try:
            if not connection.recv(4096):
                print("hold: peer closed the tunnel")
                return
        except socket.timeout:
            continue
    fail("hold: tunnel still open after %d s" % args.seconds)


def run_stream(args):
    """只在一个方向上有流量时，隧道不能被空闲超时误杀。

    `--path '/ws?idle=1'` 的后端握手后一个字节都不回，所以「上游 -> 客户端」始终静默，
    只有客户端在按 `--gap-millis` 发数据。隧道若按单个方向计空闲，就会在这里被断开。
    """
    connection, _ = handshake(args)
    connection.settimeout(0.05)
    started = time.time()
    for index in range(args.count):
        connection.sendall(b"m%d" % index)
        try:
            if not connection.recv(4096):
                fail("stream: tunnel closed after %d/%d sends" % (index, args.count))
        except socket.timeout:
            pass
        time.sleep(args.gap_millis / 1000.0)
    connection.close()
    print("stream ok (%d sends over %.0f ms)" % (args.count, (time.time() - started) * 1000))


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("mode", choices=["echo", "idle", "hold", "stream"])
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, required=True)
    parser.add_argument("--path", default="/ws")
    parser.add_argument("--host-header", default="local.test")
    parser.add_argument("--message", default="probe")
    parser.add_argument("--expect-millis", type=int, default=500)
    parser.add_argument("--slack-millis", type=int, default=400)
    parser.add_argument("--seconds", type=float, default=30)
    parser.add_argument("--count", type=int, default=8)
    parser.add_argument("--gap-millis", type=int, default=200)
    args = parser.parse_args()

    if args.mode == "echo":
        run_echo(args)
    elif args.mode == "idle":
        run_idle(args)
    elif args.mode == "stream":
        run_stream(args)
    else:
        run_hold(args)


if __name__ == "__main__":
    main()
