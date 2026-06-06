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
import std.array : split;
import std.conv : to;
import std.string : indexOf;

import vibe.core.core : runTask;
import vibe.core.net : TCPConnection, connectTCP;
import vibe.core.stream : IOMode;

import setline.http : headerContains, headerValue, isSwitchingProtocols, isWebSocketUpgrade, parseContentLength,
  readHttpResponseHead, sendPrepared;
import setline.model;
import setline.state : connectTimeoutMillis;

/** backend TCP 连接失败。

    这个异常只表示代理尚未和 backend 建立连接，请求头和请求体都还没有发送给上游。调用方
    可以在同一路由下尝试其他 backend，而不会造成非幂等请求被重复提交。
*/
class BackendConnectException : Exception {
  this(Backend backend, string message) {
    super("connect " ~ backend.host ~ ":" ~ backend.port.to!string ~ " failed: " ~ message);
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

    这个函数是 setline 的核心透明代理路径：请求头按原始字节顺序发送给上游，只在没有
    任何上游代理身份头时补充 `Forwarded` / `X-Forwarded-*`，请求体和响应体都采用流式
    透传。这里不做 URL 改写、不缓存、不压缩、不解释业务内容，目标是让浏览器与 backend
    之间的 HTTP 语义尽量保持一致。

    响应体的转发策略由响应头决定：有 `Content-Length` 时按长度补齐，chunked 响应按
    chunk 边界转发，没有明确长度时一直转发到上游关闭连接。
*/
void forward(TCPConnection client, string request, const(ubyte)[] bufferedBody, Backend backend) {
  auto upstream = connectBackend(backend);
  scope (exit) {
    upstream.close();
  }

  auto forwarded = withProxyHeaders(client, request);
  sendPrepared(upstream, forwarded);
  if (bufferedBody.length > 0) {
    sendPrepared(upstream, bufferedBody);
  }
  relayRequestBody(client, upstream, forwarded, bufferedBody);

  auto response = readHttpResponseHead(upstream);
  if (response.length == 0) {
    return;
  }

  sendPrepared(client, cast(const(ubyte)[]) response);

  auto headerEnd = response.indexOf("\r\n\r\n");
  if (headerEnd < 0) {
    return;
  }
  if (requestMethod(request) == "HEAD" || responseHasNoBody(response)) {
    return;
  }

  auto headers = response[0 .. headerEnd];
  auto bodySize = response.length - cast(size_t) headerEnd - 4;
  if (headerValue(response, "Content-Length").length > 0) {
    auto contentLength = parseContentLength(headers);
    relayBytes(upstream, client, contentLength > bodySize ? contentLength - bodySize : 0);
  } else if (headerContains(response, "Transfer-Encoding", "chunked")) {
    relayChunked(upstream, client, cast(const(ubyte)[]) response[headerEnd + 4 .. $]);
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
void forwardWebSocket(TCPConnection client, string request, const(ubyte)[] bufferedBody, Backend backend) {
  auto upstream = connectBackend(backend);

  auto forwarded = withProxyHeaders(client, request);
  sendPrepared(upstream, forwarded);
  if (bufferedBody.length > 0) {
    sendPrepared(upstream, bufferedBody);
  }

  auto responseHead = readHttpResponseHead(upstream);
  if (responseHead.length == 0) {
    upstream.close();
    throw new Exception("backend closed websocket handshake");
  }

  sendPrepared(client, cast(const(ubyte)[]) responseHead);
  if (!isSwitchingProtocols(responseHead)) {
    upstream.close();
    return;
  }

  tunnel(client, upstream);
}

/** 判断请求是否需要走 WebSocket 隧道路径。

    这个小函数保留为路由层的语义入口，使 `server.d` 不需要知道 WebSocket 的具体头部
    判断规则；真正的规则仍集中在 HTTP 头工具函数中。
*/
bool shouldUseWebSocketTunnel(string request) {
  return isWebSocketUpgrade(request);
}

/** 建立到 backend 的 TCP 连接。

    连接失败被包装为 `BackendConnectException`，让 server 层可以精确地区分“尚未接触
    backend，可以换一个端口重试”和“已经开始代理字节，不应该自动重放请求”这两种情况。
*/
TCPConnection connectBackend(Backend backend) {
  try {
    return connectTCP(backend.host, backend.port, null, 0, connectTimeoutMillis().msecs);
  } catch (Exception e) {
    throw new BackendConnectException(backend, e.msg);
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
  string request,
  const(ubyte)[] bufferedBody
) {
  if (headerValue(request, "Content-Length").length > 0) {
    auto contentLength = parseContentLength(request);
    relayBytes(source, target, contentLength > bufferedBody.length ? contentLength - bufferedBody.length : 0);
  } else if (headerContains(request, "Transfer-Encoding", "chunked")) {
    relayChunked(source, target, bufferedBody);
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
    的 chunk。每次新读到的数据都会立即写给目标连接，内部累计的字符串只用于判断 chunked
    消息是否已经完整结束。
*/
void relayChunked(TCPConnection source, TCPConnection target, const(ubyte)[] body) {
  auto initial = cast(string) body;
  if (chunkedBodyComplete(initial)) return;

  ubyte[8192] buffer;
  auto data = initial;
  while (true) {
    auto received = source.read(buffer[], IOMode.once);
    if (received <= 0) {
      return;
    }
    auto chunk = cast(string) buffer[0 .. received];
    data ~= chunk;
    sendPrepared(target, buffer[0 .. received]);
    if (chunkedBodyComplete(data)) {
      return;
    }
  }
}

/** 判断一段 chunked body 是否已经包含终止 chunk 和可选 trailer。

    该函数只做边界识别，不返回解码后的实体内容。代理不需要理解业务 body，只需要知道
    什么时候可以停止从上游继续读取，避免等待已经完成的资源而拖慢浏览器后续请求。
*/
bool chunkedBodyComplete(string body) {
  size_t pos;
  while (true) {
    auto lineEnd = body[pos .. $].indexOf("\r\n");
    if (lineEnd < 0) return false;

    auto size = parseChunkSize(body[pos .. pos + lineEnd]);
    pos += cast(size_t) lineEnd + 2;
    if (size == 0) {
      if (body.length < pos + 2) return false;
      if (body[pos .. pos + 2] == "\r\n") return true;
      return body[pos .. $].indexOf("\r\n\r\n") >= 0;
    }

    if (body.length < pos + size + 2) return false;
    if (body[pos + size .. pos + size + 2] != "\r\n") return false;
    pos += size + 2;
  }
}

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

/** 返回请求行中的 HTTP 方法。

    主要用于识别 HEAD 请求。HEAD 响应即使带有 `Content-Length`，也不应该继续读取响应体。
*/
string requestMethod(string request) {
  auto firstSpace = request.indexOf(" ");
  return firstSpace < 0 ? "" : request[0 .. firstSpace];
}

/** 在没有既有代理身份头时补充标准代理头。

    项目里的“透明”指浏览器和 backend 之间的 HTTP 行为尽量透明，不再等同于绝对不改头。
    如果请求已经包含 `Forwarded` 或 `X-Forwarded-For`，说明 setline 前面可能已经有 HAProxy、
    Nginx 或其他第一线代理，setline 会完全保留这些头，避免覆盖真实链路信息。只有浏览器
    直接访问 setline、请求中没有代理身份头时，才根据当前连接补充客户端 IP、scheme、host
    和 port，便于 backend 获得真实访问上下文。
*/
string withProxyHeaders(TCPConnection client, string request) {
  if (hasProxyHeaders(request)) {
    return request;
  }

  auto headerEnd = request.indexOf("\r\n\r\n");
  if (headerEnd < 0) {
    return request;
  }

  auto clientAddress = client.remoteAddress.toAddressString();
  auto host = headerValue(request, "Host");
  auto port = forwardedPort(client, host);
  return request[0 .. headerEnd] ~ "\r\n" ~
    "Forwarded: for=" ~ clientAddress ~ ";proto=http;host=" ~ host ~ "\r\n" ~
    "X-Forwarded-For: " ~ clientAddress ~ "\r\n" ~
    "X-Forwarded-Proto: http\r\n" ~
    "X-Forwarded-Host: " ~ host ~ "\r\n" ~
    "X-Forwarded-Port: " ~ port ~ request[headerEnd .. $];
}

/** 判断请求中是否已经存在上游代理身份信息。

    `Forwarded` 是 RFC 7239 定义的标准头；`X-Forwarded-For` 是实际部署中最常见的事实标准。
    任意一个存在时，setline 都认为链路身份已经由更靠前的代理负责，不再追加或改写。
*/
bool hasProxyHeaders(string request) {
  return headerValue(request, "Forwarded").length > 0 || headerValue(request, "X-Forwarded-For").length > 0;
}

/** 推导写入 `X-Forwarded-Port` 的端口。

    优先使用浏览器请求里的 Host 端口，因为它代表用户显式访问的代理服务地址；Host 没有
    端口时退回到当前监听连接的本地端口。当前项目只处理明文 HTTP 入口，因此 proto 固定为
    `http`，未来如果在 setline 本身终止 TLS，再统一扩展 scheme 判断。
*/
string forwardedPort(TCPConnection client, string host) {
  auto colon = host.indexOf(":");
  if (colon >= 0) {
    return host[colon + 1 .. $];
  }
  return client.localAddress.port.to!string;
}

/** 判断响应状态是否按 HTTP 规则没有响应体。

    1xx、204、304 以及 HEAD 请求响应不能按普通 body 继续读取。这里处理的是状态码本身；
    HEAD 请求由调用方结合原始请求方法单独判断。
*/
bool responseHasNoBody(string response) {
  auto firstLineEnd = response.indexOf("\r\n");
  if (firstLineEnd < 0) return false;

  auto parts = response[0 .. firstLineEnd].split(" ");
  if (parts.length < 2) return false;

  auto status = parts[1].to!int;
  return (status >= 100 && status < 200) || status == 204 || status == 304;
}

@("proxy detects complete chunked body") unittest {
  assert(chunkedBodyComplete("4\r\nWiki\r\n5\r\npedia\r\n0\r\n\r\n"));
  assert(chunkedBodyComplete("4;name=value\r\nWiki\r\n0\r\nExpires: now\r\n\r\n"));
  assert(!chunkedBodyComplete("4\r\nWiki\r\n5\r\nped"));
}

@("proxy detects responses without body") unittest {
  assert(responseHasNoBody("HTTP/1.1 304 Not Modified\r\n\r\n"));
  assert(responseHasNoBody("HTTP/1.1 204 No Content\r\n\r\n"));
  assert(!responseHasNoBody("HTTP/1.1 200 OK\r\n\r\n"));
}

@("proxy detects existing proxy headers") unittest {
  assert(hasProxyHeaders("GET / HTTP/1.1\r\nForwarded: for=127.0.0.1\r\n\r\n"));
  assert(hasProxyHeaders("GET / HTTP/1.1\r\nX-Forwarded-For: 127.0.0.1\r\n\r\n"));
  assert(!hasProxyHeaders("GET / HTTP/1.1\r\nHost: localhost\r\n\r\n"));
}

@("proxy suppresses backend connect exception trace") unittest {
  auto e = new BackendConnectException(Backend("127.0.0.1", 9001), "refused");
  assert(e.info !is null);
  assert(e.info.toString.length == 0);
}
