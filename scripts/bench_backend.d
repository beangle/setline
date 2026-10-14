/* Copyright (C) 2026 Beangle
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program.  If not, see <https://www.gnu.org/licenses/>.
 */

/** bench.sh 用的最小静态后端。

    只服务基准：固定响应，不解释业务语义。线程模型是「一连接一线程」，没有解释器
    的 GIL，所以不会先于被测的 setline 饱和——`scripts/e2e_backend.py` 是 Python
    写的，高并发下 GIL 会先成为瓶颈，用它测扩展性只会得到假结果。

    支持的端点（与 bench.sh 的用法对应）：
    - `GET /ok`（任意路径）：返回 `ok`；
    - `GET /large?bytes=N`：返回 N 字节；
    - `GET /__connections`：返回 `accepts=<累计 accept 数>`；
    - `GET /__reset`：清零 accept 计数。

    头部读取与 setline 一样按增量扫描：只扫上一轮的 3 个重叠字节加新数据，避免
    长头造成 O(n²)。
*/
module bench_backend;

import core.atomic : atomicLoad, atomicOp, atomicStore;
import core.thread : Thread;
import std.conv : to;
import std.getopt : getopt;
import std.socket : AddressFamily, InternetAddress, ProtocolType, Socket, SocketOption,
  SocketOptionLevel, SocketType;
import std.stdio : File, writeln;

shared long gAccepts;

enum size_t maxHeadSize = 64 * 1024;

/** `\r\n\r\n`，头部终止符。 */
private enum ubyte[4] crlfcrlf = ['\r', '\n', '\r', '\n'];

/** 活着的连接线程。必须持有引用：`Thread` 对象（还有闭包里捕获的 Socket）一旦
    被 GC 回收，连接就会被顺手析构，客户端看到 RST。 */
Thread[] gThreads;

/** 找到 `\r\n\r\n` 的起始下标，未找到返回 -1；从 `scanFrom` 起扫，避免重复扫描。 */
ptrdiff_t headerEnd(const(ubyte)[] data, size_t scanFrom) {
  if (data.length < crlfcrlf.length) {
    return -1;
  }
  for (size_t i = scanFrom; i + crlfcrlf.length <= data.length; ++i) {
    if (data[i] == crlfcrlf[0] && data[i + 1] == crlfcrlf[1] && data[i + 2] == crlfcrlf[2]
        && data[i + 3] == crlfcrlf[3]) {
      return cast(ptrdiff_t) i;
    }
  }
  return -1;
}

bool asciiEqualIgnoreCase(const(ubyte)[] haystack, string needle) {
  if (haystack.length != needle.length) {
    return false;
  }
  foreach (i, ubyte c; haystack) {
    auto lower = (c >= 'A' && c <= 'Z') ? cast(ubyte)(c + 32) : c;
    char expected = needle[i];
    if (expected >= 'A' && expected <= 'Z') {
      expected = cast(char)(expected + 32);
    }
    if (lower != expected) {
      return false;
    }
  }
  return true;
}

bool containsIgnoreCase(const(ubyte)[] haystack, string needle) {
  if (needle.length == 0 || haystack.length < needle.length) {
    return false;
  }
  for (size_t i = 0; i + needle.length <= haystack.length; ++i) {
    if (asciiEqualIgnoreCase(haystack[i .. i + needle.length], needle)) {
      return true;
    }
  }
  return false;
}

long toLong(const(ubyte)[] value) {
  long result = 0;
  foreach (ubyte c; value) {
    if (c < '0' || c > '9') {
      return -1;
    }
    result = result * 10 + (c - '0');
  }
  return result;
}

void sendAll(Socket socket, const(ubyte)[] data) {
  size_t sent;
  while (sent < data.length) {
    auto written = socket.send(data[sent .. $]);
    if (written <= 0) {
      return;
    }
    sent += written;
  }
}

/** 处理一条连接上的所有 keep-alive 请求。 */
void serveConnection(Socket connection) {
  scope(exit) connection.close();
  connection.setOption(SocketOptionLevel.TCP, SocketOption.TCP_NODELAY, 1);
  ubyte[] buffer;
  ubyte[16384] chunk;
  size_t scanFrom;

  while (true) {
    ptrdiff_t end = -1;
    while (end < 0) {
      auto got = connection.receive(chunk[]);
      if (got <= 0) {
        return;
      }
      buffer ~= chunk[0 .. got];
      end = headerEnd(buffer, scanFrom);
      if (end < 0) {
        if (buffer.length >= 3) {
          scanFrom = buffer.length - 3;
        }
        if (buffer.length > maxHeadSize) {
          return;
        }
      }
    }

    auto headSize = cast(size_t) end + 4;
    auto head = buffer[0 .. headSize];
    auto rest = buffer[headSize .. $];
    buffer = null;
    scanFrom = 0;

    // 请求行
    auto lineEnd = size_t.max;
    foreach (i, ubyte c; head) {
      if (i + 1 < head.length && head[i] == '\r' && head[i + 1] == '\n') {
        lineEnd = i;
        break;
      }
    }
    if (lineEnd == size_t.max) {
      return;
    }
    auto requestLine = head[0 .. lineEnd];
    auto firstSpace = size_t.max;
    auto secondSpace = size_t.max;
    foreach (i, ubyte c; requestLine) {
      if (c == ' ') {
        if (firstSpace == size_t.max) {
          firstSpace = i;
        } else if (secondSpace == size_t.max) {
          secondSpace = i;
          break;
        }
      }
    }
    if (secondSpace == size_t.max) {
      return;
    }
    auto target = requestLine[firstSpace + 1 .. secondSpace];
    auto httpVersion = requestLine[secondSpace + 1 .. $];

    // 头字段
    bool close = false;
    bool keepAliveHeader = false;
    long contentLength = -1;
    size_t cursor = lineEnd + 2;
    while (cursor < head.length) {
      auto nextEnd = size_t.max;
      for (size_t i = cursor; i + 1 < head.length; ++i) {
        if (head[i] == '\r' && head[i + 1] == '\n') {
          nextEnd = i;
          break;
        }
      }
      if (nextEnd == size_t.max || nextEnd == cursor) {
        break;
      }
      auto line = head[cursor .. nextEnd];
      cursor = nextEnd + 2;
      auto colon = size_t.max;
      foreach (i, ubyte c; line) {
        if (c == ':') {
          colon = i;
          break;
        }
      }
      if (colon == size_t.max) {
        continue;
      }
      auto name = line[0 .. colon];
      auto value = line[colon + 1 .. $];
      while (value.length > 0 && (value[0] == ' ' || value[0] == '\t')) {
        value = value[1 .. $];
      }
      if (asciiEqualIgnoreCase(name, "connection")) {
        close = close || containsIgnoreCase(value, "close");
        keepAliveHeader = keepAliveHeader || containsIgnoreCase(value, "keep-alive");
      } else if (asciiEqualIgnoreCase(name, "content-length")) {
        contentLength = toLong(value);
      }
    }

    bool keepAlive = asciiEqualIgnoreCase(httpVersion, "HTTP/1.1") ? !close : keepAliveHeader;

    // 丢弃 request body，保证下一条请求从正确位置开始。
    if (contentLength > 0) {
      long remaining = contentLength;
      if (rest.length > 0) {
        auto drop = rest.length < remaining ? rest.length : cast(size_t) remaining;
        remaining -= drop;
      }
      while (remaining > 0) {
        auto got = connection.receive(chunk[]);
        if (got <= 0) {
          return;
        }
        remaining -= got;
      }
    }

    // 响应
    auto path = target;
    if (path.length > 0 && path[0] == '/') {
      path = path[1 .. $];
    }
    ubyte[] body;
    if (containsIgnoreCase(path, "__reset")) {
      atomicStore(gAccepts, 0L);
      body = cast(ubyte[]) "ok".dup;
    } else if (containsIgnoreCase(path, "__connections")) {
      body = cast(ubyte[]) ("accepts=" ~ atomicLoad(gAccepts).to!string ~ "\n").dup;
    } else if (containsIgnoreCase(path, "large")) {
      long bytes = -1;
      auto query = path.length;
      foreach (i, ubyte c; path) {
        if (c == '?') {
          query = i;
          break;
        }
      }
      if (query < path.length) {
        auto queryText = path[query + 1 .. $];
        foreach (i; 0 .. queryText.length) {
          if (queryText.length - i >= 6 && asciiEqualIgnoreCase(queryText[i .. i + 6], "bytes=")) {
            bytes = toLong(queryText[i + 6 .. $]);
            break;
          }
        }
      }
      if (bytes < 0) {
        bytes = 0;
      }
      body = new ubyte[cast(size_t) bytes];
      body[] = 'a';
    } else {
      body = cast(ubyte[]) "ok".dup;
    }

    auto header = "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: "
      ~ body.length.to!string ~ "\r\nConnection: " ~ (keepAlive ? "keep-alive" : "close")
      ~ "\r\n\r\n";
    // 头和体一次写出：分两次 send 会被 Nagle 攒住等延迟 ACK。
    auto payload = new ubyte[header.length + body.length];
    foreach (i, char ch; header) {
      payload[i] = cast(ubyte) ch;
    }
    payload[header.length .. $] = body;
    sendAll(connection, payload);

    if (!keepAlive) {
      return;
    }
    // 上一次多读进来的字节属于下一条请求。
    buffer = rest.dup;
    scanFrom = 0;
  }
}
/** 每条连接一条线程。

    线程创建必须放在这个函数里：闭包按引用捕获局部变量，若直接在 accept 循环里写
    闭包，各轮可能捕获同一个变量，两个线程会去服务同一个 socket。
*/
void startConnection(Socket connection) {
  auto thread = new Thread({ serveConnection(connection); });
  thread.isDaemon = true;
  thread.start();
  gThreads ~= thread;
  if (gThreads.length >= 512) {
    size_t kept;
    foreach (ref t; gThreads) {
      if (t.isRunning) {
        gThreads[kept++] = t;
      } else {
        t.join();
      }
    }
    gThreads.length = kept;
  }
}

void main(string[] args) {
  ushort port;
  string readyFile;
  getopt(args, "port", &port, "ready-file", &readyFile);

  auto listener = new Socket(AddressFamily.INET, SocketType.STREAM, ProtocolType.TCP);
  listener.setOption(SocketOptionLevel.SOCKET, SocketOption.REUSEADDR, 1);
  listener.bind(new InternetAddress("127.0.0.1", port));
  listener.listen(1024);
  if (readyFile.length > 0) {
    auto ready = File(readyFile, "w");
    ready.writeln("ready");
    ready.close();
  }

  while (true) {
    atomicOp!"+="(gAccepts, 1L);
    startConnection(listener.accept());
  }
}
