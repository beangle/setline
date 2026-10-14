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

"""bench.sh 量头部解析开销用的最小客户端。

`ab` 把请求拼在 8KB 的固定缓冲里，头一超过约 8KB 就被截断（请求永远等不到
`\\r\\n\\r\\n`），所以撑不到 setline 的 64KB 上限。这里在一个 keep-alive 连接上
顺序发 N 个请求，每个带一个指定大小的 `X-Pad` 头；服务器 CPU 由 bench.sh 从
`/proc/<pid>/stat` 采样，客户端本身跑多快不重要。
"""

import argparse
import socket
import threading
import time


def parse_args():
    parser = argparse.ArgumentParser()
    parser.add_argument("--port", type=int, required=True)
    parser.add_argument("--host", default="local.test")
    parser.add_argument("--path", default="/ok")
    parser.add_argument("--pad-bytes", type=int, default=0)
    parser.add_argument("--requests", type=int, default=8000)
    parser.add_argument("--connections", type=int, default=1)
    return parser.parse_args()


def response_length(head):
    length = 0
    for line in head.split(b"\r\n")[1:]:
        if line.lower().startswith(b"content-length:"):
            length = int(line.split(b":", 1)[1])
    return length


def run_connection(args, request, count):
    connection = socket.create_connection(("127.0.0.1", args.port))
    connection.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
    buffered = b""
    for _ in range(count):
        connection.sendall(request)
        while True:
            end = buffered.find(b"\r\n\r\n")
            if end >= 0:
                size = end + 4 + response_length(buffered[:end])
                if len(buffered) >= size:
                    buffered = buffered[size:]
                    break
            chunk = connection.recv(65536)
            if not chunk:
                raise SystemExit("backend closed the connection early")
            buffered += chunk
    connection.close()


def main():
    args = parse_args()
    pad = ("X-Pad: " + "a" * args.pad_bytes + "\r\n") if args.pad_bytes > 0 else ""
    request = (
        "GET %s HTTP/1.1\r\nHost: %s\r\n%sConnection: keep-alive\r\n\r\n"
        % (args.path, args.host, pad)
    ).encode("ascii")

    per_connection = args.requests // args.connections
    started = time.monotonic()
    threads = [
        threading.Thread(target=run_connection, args=(args, request, per_connection))
        for _ in range(args.connections)
    ]
    for thread in threads:
        thread.start()
    for thread in threads:
        thread.join()
    elapsed_ms = round((time.monotonic() - started) * 1000)
    print("requests=%d elapsed_ms=%d" % (per_connection * args.connections, elapsed_ms))


if __name__ == "__main__":
    main()
