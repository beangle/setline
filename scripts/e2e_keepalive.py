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

"""给 scripts/e2e.sh 用的最小 keep-alive 客户端。

每个连接在自己的线程里顺序发 N 个请求（不 pipelining），用来验证「一条客户端连接一条
上游连接」的亲和：稳态下上游新建连接数应当等于连接数，而不是随请求数增长。

两段进度都往标准输出打，供 e2e.sh 用行匹配等待：

- `opened=<连接数>`：所有连接都拿到第一个响应了，此时每条连接都握着一条上游连接；
- `requests=<总数>`：请求发完了，连接还挂着（`--hold-millis` 才会关）。

请求必须打到 e2e 自测后端的 `/ok` 这类 `Content-Length` 明确的响应上：这里只按长度读
body，不解析 chunked 和连接关闭界定。
"""

import argparse
import socket
import sys
import threading
import time


def read_response(sock):
    """读一个完整响应并返回状态码，只支持 Content-Length 界定。"""
    data = b""
    while b"\r\n\r\n" not in data:
        chunk = sock.recv(65536)
        if not chunk:
            raise RuntimeError("connection closed before the response head")
        data += chunk
    head, _, body = data.partition(b"\r\n\r\n")
    lines = head.split(b"\r\n")
    status = int(lines[0].split()[1])
    length = 0
    for line in lines[1:]:
        name, _, value = line.partition(b":")
        if name.strip().lower() == b"content-length":
            length = int(value.strip())
    remaining = length - len(body)
    while remaining > 0:
        chunk = sock.recv(min(65536, remaining))
        if not chunk:
            raise RuntimeError("connection closed inside the response body")
        remaining -= len(chunk)
    return status


def worker(args, opened, requests_done, errors):
    try:
        sock = socket.create_connection((args.host, args.port), timeout=5)
        sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
        request = ("GET %s HTTP/1.1\r\nHost: %s\r\n\r\n"
                   % (args.path, args.host_header)).encode("ascii")
        for index in range(args.requests):
            sock.sendall(request)
            status = read_response(sock)
            if status != 200:
                raise RuntimeError("unexpected status %d" % status)
            if index == 0:
                opened.release()
        requests_done.release()
        if args.hold_millis > 0:
            time.sleep(args.hold_millis / 1000.0)
        sock.close()
    except Exception as error:  # noqa: BLE001 - 报告给 e2e.sh，不在这里退出进程
        errors.append(str(error))
        # 让主线程不等超时：两个闸门都放行。
        opened.release()
        requests_done.release()


def main():
    parser = argparse.ArgumentParser(description="keep-alive requests for scripts/e2e.sh")
    parser.add_argument("--port", type=int, required=True)
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--host-header", default="local.test")
    parser.add_argument("--path", default="/ok")
    parser.add_argument("--connections", type=int, default=4)
    parser.add_argument("--requests", type=int, default=100)
    parser.add_argument("--hold-millis", type=int, default=0)
    parser.add_argument("--timeout-millis", type=int, default=10000)
    args = parser.parse_args()

    opened = threading.Semaphore(0)
    requests_done = threading.Semaphore(0)
    errors = []
    threads = []
    for _ in range(args.connections):
        thread = threading.Thread(target=worker,
                                  args=(args, opened, requests_done, errors), daemon=True)
        thread.start()
        threads.append(thread)

    wait_seconds = args.timeout_millis / 1000.0
    for _ in range(args.connections):
        if not opened.acquire(timeout=wait_seconds):
            print("error=timed out waiting for the first response", file=sys.stderr)
            return 1
    if errors:
        print("error=%s" % errors[0], file=sys.stderr)
        return 1
    print("opened=%d" % args.connections, flush=True)

    for _ in range(args.connections):
        if not requests_done.acquire(timeout=wait_seconds):
            print("error=timed out waiting for requests", file=sys.stderr)
            return 1
    if errors:
        print("error=%s" % errors[0], file=sys.stderr)
        return 1
    print("requests=%d" % (args.connections * args.requests), flush=True)

    for thread in threads:
        thread.join(timeout=wait_seconds)
    return 0


if __name__ == "__main__":
    sys.exit(main())
