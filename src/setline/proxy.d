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

module setline.proxy;

import core.time : msecs;
import std.conv : to;
import std.string : indexOf;

import vibe.core.core : runTask;
import vibe.core.net : TCPConnection, connectTCP;
import vibe.core.stream : IOMode;

import setline.http : HttpHead, readHttpHead, sendPrepared;
import setline.model;
import setline.state : connectTimeoutMillis;

/** 本机上游端口 TCP 连接失败。

    这个异常只表示代理尚未和上游端口建立连接，请求头和请求体都还没有发送给上游。调用方
    可以在同一路由下尝试其他端口，而不会造成非幂等请求被重复提交。
*/
class PortConnectException : Exception {
  this(ushort port, string message) {
    super("connect 127.0.0.1:" ~ port.to!string ~ " failed: " ~ message);
    this.info = EmptyTraceInfo.instance;
  }
}

private class EmptyTraceInfo : Throwable.TraceInfo {
  override int opApply(scope int delegate(ref const(char[])) dg) const {
    return 0;
  }

  override int opApply(scope int delegate(ref size_t, ref const(char[])) dg) const {
    return 0;
  }

  override string toString() const {
    return null;
  }

  static EmptyTraceInfo instance() @trusted {
    static immutable EmptyTraceInfo value = new EmptyTraceInfo;
    return cast(EmptyTraceInfo) value;
  }
}

/** 将一个普通 HTTP 请求转发到匹配到的后端。

    这个函数是 setline 的核心透明代理路径：请求头按原始字节顺序发送给上游，请求体和
    响应体都采用流式透传。这里不做 URL 改写、不缓存、不压缩、不解释业务内容，目标是
    让浏览器与上游服务之间的 HTTP 语义尽量保持一致。

    响应体的转发策略由响应头决定：有 `Content-Length` 时按长度补齐，chunked 响应按
    chunk 边界转发，没有明确长度时一直转发到上游关闭连接。
*/
void forward(TCPConnection client, HttpHead request, ushort port) {
  auto upstream = connectPort(port);
  scope (exit) {
    upstream.close();
  }

  sendPrepared(upstream, request.head);
  if (request.bufferedBody.length > 0) {
    sendPrepared(upstream, request.bufferedBody);
  }
  relayRequestBody(client, upstream, request);

  auto response = readHttpHead(upstream);
  if (response.head.length == 0) {
    return;
  }

  sendPrepared(client, response.head);
  if (response.bufferedBody.length > 0) {
    sendPrepared(client, response.bufferedBody);
  }

  if (request.method == "HEAD" || responseHasNoBody(response)) {
    return;
  }

  if (response.hasContentLength) {
    auto contentLength = response.contentLength;
    auto bodySize = response.bufferedBody.length;
    relayBytes(upstream, client, contentLength > bodySize ? contentLength - bodySize : 0);
  } else if (response.transferChunked) {
    relayChunked(upstream, client, response.bufferedBody);
  } else {
    relayUntilClose(upstream, client);
  }
}

/** 将 WebSocket 握手转发给后端，并在 101 后切换为双向隧道。

    WebSocket 的 HTTP 阶段只持续到握手结束。浏览器收到 101 后，后续帧已经不再能按
    HTTP header/body 模型处理，因此这里必须把客户端和上游连接都交给 `tunnel`，让两边
    任意方向到达的字节都立即写到另一边。

    如果后端没有返回 101，则该响应被当作普通握手失败响应发回浏览器并关闭上游连接。
*/
void forwardWebSocket(TCPConnection client, HttpHead request, ushort port) {
  auto upstream = connectPort(port);

  sendPrepared(upstream, request.head);
  if (request.bufferedBody.length > 0) {
    sendPrepared(upstream, request.bufferedBody);
  }

  auto response = readHttpHead(upstream);
  if (response.head.length == 0) {
    upstream.close();
    throw new Exception("upstream closed websocket handshake");
  }

  sendPrepared(client, response.head);
  if (response.bufferedBody.length > 0) {
    sendPrepared(client, response.bufferedBody);
  }
  if (response.statusCode != 101) {
    upstream.close();
    return;
  }

  tunnel(client, upstream);
}

/** 建立到本机上游端口的 TCP 连接。

    连接失败被包装为 `PortConnectException`，让 server 层可以精确地区分“尚未接触
    上游服务，可以换一个端口重试”和“已经开始代理字节，不应该自动重放请求”这两种情况。
*/
TCPConnection connectPort(ushort port) {
  try {
    return connectTCP("127.0.0.1", port, null, 0, connectTimeoutMillis().msecs);
  } catch (Exception e) {
    throw new PortConnectException(port, e.msg);
  }
}

/** 在两个 TCP 连接之间建立双向字节转发。

    vibe-core 的 task 用于承载上游到浏览器方向，当前 task 负责浏览器到上游方向。任意一边
    读到 EOF 或出错后都会关闭目标连接，让另一边尽快退出，避免 WebSocket 或长连接残留。
*/
void tunnel(TCPConnection client, TCPConnection upstream) {
  runTask(&relayToClient, upstream, client);

  relay(client, upstream);
  upstream.close();
  client.close();
}

/** 从 source 转发到 target，并在异常或 EOF 后关闭 target。

    这是隧道中后台方向的保护壳。它不能把异常抛回调用方，因为该函数运行在独立 task 中；
    出错时关闭目标连接就是通知另一半隧道退出的机制。
*/
void relayToClient(TCPConnection source, TCPConnection target) nothrow {
  try {
    relay(source, target);
  } catch (Throwable) {
  }
  try {
    target.close();
  } catch (Throwable) {
  }
}

/** 持续把一个连接上的字节写到另一个连接。

    该函数不理解 HTTP、WebSocket 或 chunked 编码，只做字节复制。保持这种低层语义可以
    让 WebSocket、SSE 或其他升级后的协议尽量不受代理层影响。
*/
void relay(TCPConnection source, TCPConnection target) {
  ubyte[8192] buffer;
  while (true) {
    auto received = source.read(buffer[], IOMode.once);
    if (received <= 0) {
      return;
    }
    sendPrepared(target, buffer[0 .. received]);
  }
}

/** 按请求头声明把剩余 request body 转发给上游。

    `bufferedBody` 是读请求头时已经多读到的 body 前缀，调用方已经先把它写给上游。
    因此这里仅补齐剩余字节：`Content-Length` 按长度读，chunked 则按 chunk 结束标记读。
    如果请求没有 body 相关头部，则不会继续从浏览器读取，避免阻塞 GET 等普通请求。
*/
void relayRequestBody(
  TCPConnection source,
  TCPConnection target,
  HttpHead request
) {
  if (request.hasContentLength) {
    relayBytes(source, target,
      request.contentLength > request.bufferedBody.length ? request.contentLength - request.bufferedBody.length : 0);
  } else if (request.transferChunked) {
    relayChunked(source, target, request.bufferedBody);
  }
}

/** 按固定字节数转发数据。

    用于 `Content-Length` 明确的请求体或响应体。读取过程中如果连接提前关闭，则直接返回；
    代理不伪造剩余数据，也不尝试修复上游或客户端的半截消息。
*/
void relayBytes(TCPConnection source, TCPConnection target, size_t bytes) {
  ubyte[8192] buffer;
  auto remaining = bytes;
  while (remaining > 0) {
    auto limit = remaining < buffer.length ? remaining : buffer.length;
    auto received = source.read(buffer[0 .. limit], IOMode.once);
    if (received <= 0) {
      return;
    }
    sendPrepared(target, buffer[0 .. received]);
    remaining -= received;
  }
}

/** 一直转发到 source 关闭。

    该路径用于没有 `Content-Length` 且不是 chunked 的响应。HTTP/1.1 中这类响应通常以
    连接关闭作为 body 结束信号，因此代理只能跟随后端关闭连接，不能主动截断。
*/
void relayUntilClose(TCPConnection source, TCPConnection target) {
  ubyte[8192] buffer;
  while (true) {
    auto received = source.read(buffer[], IOMode.once);
    if (received <= 0) {
      return;
    }
    sendPrepared(target, buffer[0 .. received]);
  }
}

/** 转发 chunked 编码的数据直到读到最后一个 chunk。

    函数需要同时考虑初始响应头读取时已经带回来的 body 前缀，以及之后从连接中继续读到
    的 chunk。每次新读到的数据都会立即写给目标连接，内部只保留 chunk 边界解析状态，
    不累计完整 body。
*/
void relayChunked(TCPConnection source, TCPConnection target, const(ubyte)[] body) {
  ChunkedBodyTracker tracker;
  if (tracker.feed(body)) return;

  ubyte[8192] buffer;
  while (true) {
    auto received = source.read(buffer[], IOMode.once);
    if (received <= 0) {
      return;
    }
    sendPrepared(target, buffer[0 .. received]);
    if (tracker.feed(buffer[0 .. received])) {
      return;
    }
  }
}

/** 判断一段 chunked body 是否已经包含终止 chunk 和可选 trailer。

    该函数只做边界识别，不返回解码后的实体内容。代理不需要理解业务 body，只需要知道
    什么时候可以停止从上游继续读取，避免等待已经完成的资源而拖慢浏览器后续请求。
*/
bool chunkedBodyComplete(string body) {
  ChunkedBodyTracker tracker;
  return tracker.feed(cast(const(ubyte)[]) body);
}

/** 解析 chunk size 行中的十六进制长度。 */
size_t parseChunkSize(string line) {
  size_t size;
  foreach (ch; line) {
    if (ch == ';') break;
    if (ch >= '0' && ch <= '9') {
      size = size * 16 + cast(size_t)(ch - '0');
    } else if (ch >= 'a' && ch <= 'f') {
      size = size * 16 + cast(size_t)(ch - 'a' + 10);
    } else if (ch >= 'A' && ch <= 'F') {
      size = size * 16 + cast(size_t)(ch - 'A' + 10);
    } else {
      throw new Exception("invalid chunk size");
    }
  }
  return size;
}

/** 跟踪 chunked 消息边界。

    代理不需要读取或解析业务 body，只需要知道 chunked 消息何时结束。该状态机只保存当前
    行和剩余 chunk 字节数，避免大 body 通过代理时被累积到内存中。
*/
struct ChunkedBodyTracker {
  private enum State {
    sizeLine,
    sizeLineLf,
    data,
    dataCr,
    dataLf,
    trailerLine,
    trailerLineLf,
    complete
  }

  private State state;
  private string line;
  private size_t remaining;

  bool feed(const(ubyte)[] data) {
    size_t pos;
    while (pos < data.length && state != State.complete) {
      final switch (state) {
        case State.sizeLine:
          readLineByte(cast(char) data[pos], State.sizeLineLf);
          ++pos;
          break;
        case State.sizeLineLf:
          readLineFeed(cast(char) data[pos], &finishSizeLine);
          ++pos;
          break;
        case State.data:
          auto available = data.length - pos;
          auto consumed = remaining < available ? remaining : available;
          remaining -= consumed;
          pos += consumed;
          if (remaining == 0) {
            state = State.dataCr;
          }
          break;
        case State.dataCr:
          enforceByte(cast(char) data[pos], '\r', "chunk data must end with CRLF");
          state = State.dataLf;
          ++pos;
          break;
        case State.dataLf:
          enforceByte(cast(char) data[pos], '\n', "chunk data must end with CRLF");
          state = State.sizeLine;
          ++pos;
          break;
        case State.trailerLine:
          readLineByte(cast(char) data[pos], State.trailerLineLf);
          ++pos;
          break;
        case State.trailerLineLf:
          readLineFeed(cast(char) data[pos], &finishTrailerLine);
          ++pos;
          break;
        case State.complete:
          break;
      }
    }
    return state == State.complete;
  }

  private void readLineByte(char ch, State nextState) {
    if (ch == '\r') {
      state = nextState;
    } else {
      line ~= ch;
    }
  }

  private void readLineFeed(char ch, void delegate() finishLine) {
    enforceByte(ch, '\n', "chunk line must end with CRLF");
    finishLine();
  }

  private void finishSizeLine() {
    auto size = parseChunkSize(line);
    line = "";
    if (size == 0) {
      state = State.trailerLine;
    } else {
      remaining = size;
      state = State.data;
    }
  }

  private void finishTrailerLine() {
    if (line.length == 0) {
      state = State.complete;
    } else {
      line = "";
      state = State.trailerLine;
    }
  }
}

private void enforceByte(char actual, char expected, string message) {
  if (actual != expected) {
    throw new Exception(message);
  }
}

/** 判断响应状态是否按 HTTP 规则没有响应体。

    1xx、204、304 以及 HEAD 请求响应不能按普通 body 继续读取。这里处理的是状态码本身；
    HEAD 请求由调用方结合原始请求方法单独判断。
*/
bool responseHasNoBody(HttpHead response) {
  auto status = response.statusCode;
  return (status >= 100 && status < 200) || status == 204 || status == 304;
}
