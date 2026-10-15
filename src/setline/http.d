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

module setline.http;

import std.array : appender;
import std.conv : ConvException, to;
import std.json;
import std.string : indexOf, strip;

import vibe.core.net : TCPConnection;
import vibe.core.stream : IOMode;

import setline.util : toLowerAscii;

/** 透明代理对单条请求/响应头的防御性字节上限。 */
enum size_t maxHttpHeadSize = 64 * 1024;

/** 头部超过防御性上限。请求入口据此返回 400；上游响应入口交给 502。 */
class HttpHeadTooLargeException : Exception {
  this(size_t limit) {
    super("HTTP head exceeds " ~ limit.to!string ~ " bytes");
  }
}

/** 管理接口允许整份读入内存的请求体上限。

    管理接口是唯一需要完整 body 的路径（`PUT` 单条路由 / 整体替换路由表），业务请求都
    走流式转发。给一个便宜的防御性上限，免得调用方（可能经本机代理转发的远端）用一个
    巨大的 `Content-Length` 把 setline 的内存吃掉。
*/
enum size_t maxAdminBodySize = 4 * 1024 * 1024;

/** 管理接口请求体超过防御性上限。 */
class RequestBodyTooLargeException : Exception {
  this(size_t limit) {
    super("request body exceeds " ~ limit.to!string ~ " bytes");
  }
}

/** 校验管理接口请求体长度；超限抛 {@link RequestBodyTooLargeException}。

    抽成纯函数是为了能在单测里覆盖边界，不必造一条真的 TCP 连接。
*/
void validateAdminBodySize(size_t contentLength) {
  if (contentLength > maxAdminBodySize) throw new RequestBodyTooLargeException(maxAdminBodySize);
}

/** 增量查找头部终止符的扫描器。

    `feed` 接收累计缓冲而不是新片段；每轮只扫描上一轮末尾的 3 个重叠字节加新数据，
    避免未以 `\\r\\n\\r\\n` 结尾的长头反复扫描整段造成 O(n²)。
*/
struct HttpHeadScanner {
  private size_t scanFrom;

  /// 找到终止符时返回其起始下标；未找到返回 -1；超过上限抛异常。
  ptrdiff_t feed(string data) {
    auto relativeEnd = data[scanFrom .. $].indexOf("\r\n\r\n");
    if (relativeEnd >= 0) {
      return cast(ptrdiff_t) scanFrom + relativeEnd;
    }
    if (data.length >= 3) {
      scanFrom = data.length - 3;
    } else {
      scanFrom = 0;
    }
    if (data.length > maxHttpHeadSize) {
      throw new HttpHeadTooLargeException(maxHttpHeadSize);
    }
    return -1;
  }
}

/** 表示一次已经读取到的 HTTP 头部，以及读头时顺带收到的 body 前缀。

    请求和响应都使用相同的头部读取规则：读到 `\r\n\r\n` 为止，头后已经到达的字节放在
    `bufferedBody`。代理层随后先转发这些前缀字节，再从 socket 继续流式转发剩余 body。
*/
struct HttpHead {
  /// 原始 HTTP 头部字节转成的字符串，包含结尾的 `\r\n\r\n`。
  string head;

  /// 读头时已经从 socket 多读到的 body 前缀；代理会先原样转发这部分。
  ubyte[] bufferedBody;

  /// 请求行中的 HTTP 方法，例如 `GET`、`POST`；响应头中为空。
  string method;

  /// 请求行中的 request target，例如 `/api/users?x=1`；响应头中为空。
  string target;

  /// HTTP 版本，例如 `HTTP/1.1`。
  string httpVersion;

  /// 从 `target` 中去掉 query string 后的路径，用于路由匹配；响应头中为空。
  string path;

  /// 响应状态行中的状态码，例如 `200`、`101`；请求头中为 `0`。
  int statusCode;

  /// `Host` 头字段原值，可能包含端口，例如 `example.com:8080`。
  string host;

  /// `Content-Length` 的数值；小于 0 表示没有可用的固定长度。
  /// 重复字段值不一致、任一字段非法，或同时出现 `chunked` 时都会保持小于 0。
  long contentLength = -1;

  /// 是否有可用的非负 `Content-Length`。
  @property bool hasContentLength() const {
    return contentLength >= 0;
  }

  /// `Transfer-Encoding` 是否包含 `chunked`。
  bool transferChunked;

  /// 请求/响应同时声明多种互相冲突的 body framing 时为 true。
  bool invalidFraming;

  /// `Connection` 是否包含 `close`。
  bool connectionClose;

  /// `Connection` 是否包含 `keep-alive`。
  bool connectionKeepAlive;

  /// 是否同时满足 `Connection: upgrade` 和 `Upgrade: websocket`。
  bool upgradeWebSocket;

}

/** 读取 HTTP 头，并保留已经到达的 body 前缀。

    这是透明代理的入口约束：请求路由只依赖请求行里的 URL 和请求头，不主动消费完整
    request body；响应转发也只先读响应头。这样可以让大文件上传、表单提交和响应体都
    在后续代理阶段边读边写，避免因为代理层缓冲整个 body 而造成延迟和内存压力。

    Returns:
      `head` 为空表示连接关闭或没有读到完整请求头；否则 `head` 总是包含结尾的
      `\r\n\r\n`，`bufferedBody` 为读头过程中额外收到的字节。
*/
HttpHead readHttpHead(TCPConnection socket) {
  ubyte[8192] buffer;
  auto data = appender!string();
  HttpHeadScanner scanner;

  while (true) {
    auto received = socket.read(buffer[], IOMode.once);
    if (received <= 0) {
      break;
    }
    data.put(cast(string) buffer[0 .. received]);
    auto current = data.data;
    auto headerEnd = scanner.feed(current);
    if (headerEnd < 0) {
      continue;
    }

    auto headSize = cast(size_t) headerEnd + 4;
    if (headSize > maxHttpHeadSize) {
      throw new HttpHeadTooLargeException(maxHttpHeadSize);
    }
    auto bodyStart = headSize;
    return parseHttpHead(current[0 .. bodyStart], cast(ubyte[]) current[bodyStart .. $].dup);
  }
  return HttpHead();
}

/** 从调用方维护的响应缓冲中取下一条 HTTP 响应头。

    1xx 中间响应没有响应体；头后的字节属于下一条响应，必须留在缓冲里。最终响应则把
    头后已经到达的字节作为 body 前缀交给调用方，并清空响应缓冲。101 是协议切换，按
    最终响应处理，后续字节不再属于 HTTP 消息解析。
*/
HttpHead takeResponseHead(ref string pending) {
  auto headerEnd = pending.indexOf("\r\n\r\n");
  if (headerEnd < 0) {
    return HttpHead();
  }

  auto bodyStart = cast(size_t) headerEnd + 4;
  auto response = parseHttpHead(pending[0 .. bodyStart]);
  auto remainder = pending[bodyStart .. $];
  if (isIntermediateResponse(response)) {
    pending = remainder;
    response.bufferedBody = null;
  } else {
    response.bufferedBody = cast(ubyte[]) remainder.dup;
    pending = "";
  }
  return response;
}

/** 读取一条响应头；调用方用 `pending` 保留同一次 read 中已经读到的后续字节。 */
HttpHead readResponseHead(TCPConnection socket, ref string pending) {
  ubyte[8192] buffer;
  HttpHeadScanner scanner;
  while (scanner.feed(pending) < 0) {
    auto received = socket.read(buffer[], IOMode.once);
    if (received <= 0) {
      return HttpHead();
    }
    pending ~= cast(string) buffer[0 .. received];
  }
  auto response = takeResponseHead(pending);
  if (response.head.length > maxHttpHeadSize) {
    throw new HttpHeadTooLargeException(maxHttpHeadSize);
  }
  return response;
}

/** 100、103 等中间响应；101 是最终的协议切换响应。 */
bool isIntermediateResponse(const HttpHead response) {
  return response.statusCode >= 100 && response.statusCode < 200
    && response.statusCode != 101;
}

/** 解析已有 HTTP 头字符串，并填充 `HttpHead` 的热路径字段。 */
HttpHead parseHttpHead(string head, ubyte[] bufferedBody = null) {
  HttpHead result;
  result.head = head;
  result.bufferedBody = bufferedBody;

  auto firstLineEnd = head.indexOf("\r\n");
  if (firstLineEnd < 0) {
    return result;
  }
  parseFirstLine(result, head[0 .. firstLineEnd]);
  parseHeaderFields(result);
  return result;
}

/** 在已有请求头基础上补齐 `Content-Length` 指定的请求体。

    这个函数刻意不做业务解析，只负责把已经读到的 body 前缀和剩余 body 拼回一个完整
    请求字符串。只有管理接口用它——透明代理的请求继续走 `readHttpHead` 加流式转发，不
    把 body 落进内存。

    `Content-Length` 超过 {@link maxAdminBodySize} 时抛 {@link RequestBodyTooLargeException}，
    调用方据此回 413 并关连接，不读 body。
*/
string completeHttpRequest(TCPConnection socket, HttpHead request) {
  auto body = appender!string();
  body.put(cast(string) request.bufferedBody);
  auto contentLength = request.hasContentLength ? cast(size_t) request.contentLength : 0;
  validateAdminBodySize(contentLength);
  if (contentLength > request.bufferedBody.length) {
    ubyte[8192] buffer;
    auto remaining = contentLength - request.bufferedBody.length;
    while (remaining > 0) {
      auto limit = remaining < buffer.length ? remaining : buffer.length;
      auto received = socket.read(buffer[0 .. limit], IOMode.once);
      if (received <= 0) {
        break;
      }
      body.put(cast(string) buffer[0 .. received]);
      remaining -= received;
    }
  }
  return request.head ~ body.data;
}

/** 返回用于路由匹配的路径部分。

    输入来自请求行中的 target，可能带有 query string。setline 的路由规则只匹配路径，
    不把 query 纳入最长前缀判断，从而避免同一个资源因为查询参数不同而落入不同路由。
*/
string requestPath(string target) {
  auto queryStart = target.indexOf("?");
  return queryStart < 0 ? target : target[0 .. queryStart];
}

/** 读取指定 HTTP 头字段的值。

    字段名按 ASCII 大小写不敏感比较；没有找到、请求头不完整或字段值为空时返回空串。
    当前代理只需要读取少数控制字段，因此保持简单线性扫描，避免为每个请求构造额外 map。
*/
string headerValue(string request, string name) {
  auto wanted = name.toLowerAscii;
  string found;
  foreachHeaderLine(request, delegate bool(string line) {
    auto pos = line.indexOf(":");
    if (pos >= 0 && line[0 .. pos].strip.toLowerAscii == wanted) {
      found = line[pos + 1 .. $].strip;
      return false;
    }
    return true;
  });
  return found;
}

/** 判断指定 HTTP 头字段是否包含逗号分隔 token。 */
bool headerContains(string request, string name, string token) {
  return headerValueContains(headerValue(request, name), token);
}

/** 判断逗号分隔的头字段值中是否包含指定 token。 */
bool headerValueContains(string value, string token) {
  auto wanted = token.toLowerAscii;
  size_t start;
  while (start <= value.length) {
    auto comma = value[start .. $].indexOf(",");
    auto end = comma < 0 ? value.length : start + cast(size_t) comma;
    if (value[start .. end].strip.toLowerAscii == wanted) {
      return true;
    }
    if (comma < 0) break;
    start = end + 1;
  }
  return false;
}

private bool foreachHeaderLine(string headers, scope bool delegate(string line) visitor) {
  auto headerEnd = headers.indexOf("\r\n\r\n");
  if (headerEnd < 0) {
    return false;
  }

  size_t start;
  while (start < headerEnd) {
    auto lineEnd = headers[start .. headerEnd].indexOf("\r\n");
    auto end = lineEnd < 0 ? cast(size_t) headerEnd : start + cast(size_t) lineEnd;
    if (!visitor(headers[start .. end])) {
      return false;
    }
    if (lineEnd < 0) {
      break;
    }
    start = end + 2;
  }
  return true;
}

private void parseFirstLine(ref HttpHead result, string line) {
  if (line.length >= 5 && line[0 .. 5] == "HTTP/") {
    auto versionEnd = line.indexOf(" ");
    if (versionEnd > 0) {
      result.httpVersion = line[0 .. versionEnd];
    }
    result.statusCode = parseStatusCode(line);
    return;
  }

  auto firstSpace = line.indexOf(" ");
  if (firstSpace < 0) {
    return;
  }
  auto secondSpace = line[firstSpace + 1 .. $].indexOf(" ");
  if (secondSpace < 0) {
    return;
  }
  auto targetStart = cast(size_t) firstSpace + 1;
  auto targetEnd = targetStart + cast(size_t) secondSpace;
  result.method = line[0 .. firstSpace];
  result.target = line[targetStart .. targetEnd];
  result.httpVersion = line[targetEnd + 1 .. $];
  result.path = requestPath(result.target);
}

private int parseStatusCode(string line) {
  auto statusStart = line.indexOf(" ");
  if (statusStart < 0) {
    return 0;
  }
  ++statusStart;
  auto statusEnd = line[statusStart .. $].indexOf(" ");
  auto end = statusEnd < 0 ? line.length : cast(size_t) statusStart + cast(size_t) statusEnd;
  return line[statusStart .. end].to!int;
}

private void parseHeaderFields(ref HttpHead result) {
  bool connectionUpgrade;
  bool websocketUpgrade;
  bool sawContentLength;
  bool sawTransferEncoding;

  foreachHeaderLine(result.head, delegate bool(string line) {
    auto pos = line.indexOf(":");
    if (pos < 0) {
      return true;
    }

    auto name = line[0 .. pos].strip.toLowerAscii;
    auto value = line[pos + 1 .. $].strip;
    switch (name) {
      case "host":
        result.host = value;
        break;
      case "content-length":
        long parsedLength;
        auto validLength = parseContentLengthValue(value, parsedLength);
        if (!sawContentLength) {
          result.contentLength = validLength ? parsedLength : -1;
          result.invalidFraming = result.invalidFraming || !validLength;
          sawContentLength = true;
        } else if (!validLength || !result.hasContentLength || parsedLength != result.contentLength) {
          result.contentLength = -1;
          result.invalidFraming = true;
        }
        break;
      case "transfer-encoding":
        sawTransferEncoding = true;
        result.transferChunked = headerValueContains(value, "chunked");
        break;
      case "connection":
        connectionUpgrade = connectionUpgrade || headerValueContains(value, "upgrade");
        result.connectionClose = result.connectionClose || headerValueContains(value, "close");
        result.connectionKeepAlive = result.connectionKeepAlive || headerValueContains(value, "keep-alive");
        break;
      case "upgrade":
        websocketUpgrade = websocketUpgrade || value.toLowerAscii == "websocket";
        break;
      default:
        break;
    }
    return true;
  });
  result.upgradeWebSocket = connectionUpgrade && websocketUpgrade;
  if (sawTransferEncoding) {
    result.invalidFraming = result.invalidFraming || sawContentLength || !result.transferChunked;
    result.contentLength = -1;
  }
}

/** 解析 `Content-Length` 的值。

    RFC 9110 规定它是 `1*DIGIT`：只接受纯十进制数字，不接受正负号、空白、`0x` 前缀，超出
    `long` 范围也算非法。这里必须自己按字符校验，不能让 `to!long` 代劳——它会接受 `+5`，
    甚至接受 `-1`；后者一旦被判成「合法但为负」，本该以 `invalidFraming` 拒绝的报文就会
    退化成「没有长度」，把请求/响应体边界变成连接关闭界定（`invalidFraming` 的判据见
    `parseHeaderFields`）。
*/
private bool parseContentLengthValue(string value, ref long length) {
  if (value.length == 0) {
    return false;
  }
  foreach (ch; value) {
    if (ch < '0' || ch > '9') {
      return false;
    }
  }
  try {
    length = value.to!long;
  } catch (ConvException) {
    return false;
  }
  return true;
}

/** 从完整 HTTP 消息中取出 body 字符串。

    这是管理接口和测试用的轻量工具，不参与普通代理路径的流式 body 转发。
*/
string bodyOf(string request) {
  auto pos = request.indexOf("\r\n\r\n");
  return pos < 0 ? "" : request[pos + 4 .. $];
}

/** 发送 JSON 响应。 */
void sendJson(TCPConnection socket, JSONValue value) {
  auto body = value.toString();
  sendRaw(socket, "200 OK", "application/json", body);
}

/** 发送纯文本错误或提示响应。 */
void sendResponse(TCPConnection socket, int code, string reason, string body) {
  sendRaw(socket, code.to!string ~ " " ~ reason, "text/plain; charset=utf-8", body ~ "\n");
}

/** 发送带默认头字段的 HTTP 响应。 */
void sendRaw(TCPConnection socket, string status, string contentType, string body) {
  string[string] headers;
  sendRaw(socket, status, contentType, body, headers);
}

/** 发送带额外头字段的 HTTP 响应。 */
void sendRaw(TCPConnection socket, string status, string contentType, string body, string[string] extraHeaders) {
  sendPrepared(socket, buildHttpResponse(status, contentType, body, extraHeaders));
}

/** 写出已经构造好的字符串响应。 */
void sendPrepared(TCPConnection socket, string response) {
  sendPrepared(socket, cast(const(ubyte)[]) response);
}

/** 写出已经构造好的字节响应。 */
void sendPrepared(TCPConnection socket, const(ubyte)[] response) {
  socket.write(response);
}

/** 构造完整 HTTP 响应文本。 */
string buildHttpResponse(string status, string contentType, string body, string[string] extraHeaders) {
  auto response =
    "HTTP/1.1 " ~ status ~ "\r\n" ~
    "Content-Type: " ~ contentType ~ "\r\n" ~
    "Content-Length: " ~ body.length.to!string ~ "\r\n" ~
    "Connection: close\r\n";

  foreach (name, value; extraHeaders) {
    auto lowerName = name.toLowerAscii;
    if (lowerName != "content-length" && lowerName != "connection" && lowerName != "content-type") {
      response ~= name ~ ": " ~ value ~ "\r\n";
    }
  }

  response ~= "\r\n" ~ body;
  return response;
}
