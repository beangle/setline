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
import std.conv : to;
import std.json;
import std.string : indexOf, strip;

import vibe.core.net : TCPConnection;
import vibe.core.stream : IOMode;

import setline.util : toLowerAscii;

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

  /// 从 `target` 中去掉 query string 后的路径，用于路由匹配；响应头中为空。
  string path;

  /// 响应状态行中的状态码，例如 `200`、`101`；请求头中为 `0`。
  int statusCode;

  /// `Host` 头字段原值，可能包含端口，例如 `example.com:8080`。
  string host;

  /// 是否出现了 `Content-Length` 头字段。
  bool hasContentLength;

  /// `Content-Length` 的数值；只有 `hasContentLength` 为 true 时才有意义。
  size_t contentLength;

  /// `Transfer-Encoding` 是否包含 `chunked`。
  bool transferChunked;

  /// `Connection` 是否包含 `upgrade`。
  bool connectionUpgrade;

  /// `Upgrade` 是否为 `websocket`。
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

  while (true) {
    auto received = socket.read(buffer[], IOMode.once);
    if (received <= 0) {
      break;
    }
    data.put(cast(string) buffer[0 .. received]);
    auto current = data.data;
    auto headerEnd = current.indexOf("\r\n\r\n");
    if (headerEnd < 0) {
      continue;
    }

    auto bodyStart = cast(size_t) headerEnd + 4;
    return parseHttpHead(current[0 .. bodyStart], cast(ubyte[]) current[bodyStart .. $].dup);
  }
  return HttpHead();
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

/** 读取完整 HTTP 请求，主要供需要解析请求体的管理接口使用。

    普通代理路径不调用这个函数，因为代理目标是基于 URL 的快速透传；只有 `__setline`
    管理接口需要读取 JSON body 来修改运行时路由配置，所以这里按 `Content-Length`
    补齐请求体。当前管理接口不支持 chunked body。
*/
string readHttpRequest(TCPConnection socket) {
  auto request = readHttpHead(socket);
  if (request.head.length == 0) {
    return "";
  }
  return completeHttpRequest(socket, request);
}

/** 在已有请求头基础上补齐 `Content-Length` 指定的请求体。

    这个函数刻意不做业务解析，只负责把已经读到的 body 前缀和剩余 body 拼回一个完整
    请求字符串。调用方应确保该请求确实适合完整落入内存；透明代理的大多数请求应继续
    使用 `readHttpHead` 加流式转发。
*/
string completeHttpRequest(TCPConnection socket, HttpHead request) {
  auto body = appender!string();
  body.put(cast(string) request.bufferedBody);
  auto contentLength = request.hasContentLength ? request.contentLength : parseContentLength(request.head);
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

/** 从 HTTP 头部中解析 `Content-Length`。

    参数可以是完整请求、完整响应，或只包含头部的字符串；函数会按 CRLF 分行并忽略
    字段名大小写。未找到时返回 0，调用者需要结合实际场景区分“没有 body”和“长度为 0”。
*/
size_t parseContentLength(string headers) {
  size_t contentLength;
  foreachHeaderLine(headers, delegate bool(string line) {
    auto pos = line.indexOf(":");
    if (pos < 0) {
      return true;
    }
    if (line[0 .. pos].strip.toLowerAscii == "content-length") {
      contentLength = line[pos + 1 .. $].strip.to!size_t;
      return false;
    }
    return true;
  });
  return contentLength;
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
        result.hasContentLength = true;
        result.contentLength = value.to!size_t;
        break;
      case "transfer-encoding":
        result.transferChunked = headerValueContains(value, "chunked");
        break;
      case "connection":
        result.connectionUpgrade = headerValueContains(value, "upgrade");
        break;
      case "upgrade":
        result.upgradeWebSocket = value.toLowerAscii == "websocket";
        break;
      default:
        break;
    }
    return true;
  });
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

/** 返回常见 HTTP 状态码的 reason phrase。 */
string statusReason(int status) {
  switch (status) {
    case 200: return "OK";
    case 201: return "Created";
    case 202: return "Accepted";
    case 204: return "No Content";
    case 301: return "Moved Permanently";
    case 302: return "Found";
    case 304: return "Not Modified";
    case 400: return "Bad Request";
    case 401: return "Unauthorized";
    case 403: return "Forbidden";
    case 404: return "Not Found";
    case 405: return "Method Not Allowed";
    case 429: return "Too Many Requests";
    case 500: return "Internal Server Error";
    case 502: return "Bad Gateway";
    case 503: return "Service Unavailable";
    default: return "Status";
  }
}
