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

import std.array : appender, split;
import std.conv : to;
import std.json;
import std.string : indexOf, strip;

import vibe.core.net : TCPConnection;
import vibe.core.stream : IOMode;

import setline.ascii : toLowerAscii;

/** 表示一次 HTTP 请求已经读取到的头部，以及读头时顺带收到的请求体字节。

    setline 的普通代理路径只需要先理解请求行和头部，用 URL 做路由判断；请求体不在
    这里解析，也不提前完整读入内存。由于 TCP 是字节流，读取到 `\r\n\r\n` 时可能已经
    同时收到了部分请求体，所以用 `bufferedBody` 保存这段多读出来的数据，后续转发时
    原样补给上游，避免丢失 POST/PUT 或 WebSocket 握手后紧跟的数据。
*/
struct HttpRequestHead {
  string head;
  ubyte[] bufferedBody;
}

/** 读取 HTTP 请求头，并保留已经到达的请求体前缀。

    这是透明代理的入口约束：路由只依赖请求行里的 URL 和请求头，不主动消费完整
    request body。这样可以让大文件上传、表单提交、流式请求和 WebSocket 初始数据都
    在后续代理阶段边读边写，避免因为代理层缓冲整个 body 而造成延迟和内存压力。

    Returns:
      `head` 为空表示连接关闭或没有读到完整请求头；否则 `head` 总是包含结尾的
      `\r\n\r\n`，`bufferedBody` 为读头过程中额外收到的字节。
*/
HttpRequestHead readHttpHead(TCPConnection socket) {
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
    return HttpRequestHead(current[0 .. bodyStart], cast(ubyte[]) current[bodyStart .. $].dup);
  }
  return HttpRequestHead();
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
string completeHttpRequest(TCPConnection socket, HttpRequestHead request) {
  auto body = appender!string();
  body.put(cast(string) request.bufferedBody);
  auto contentLength = parseContentLength(request.head);
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
  foreach (line; headers.split("\r\n")) {
    auto pos = line.indexOf(":");
    if (pos < 0) {
      continue;
    }
    if (line[0 .. pos].strip.toLowerAscii == "content-length") {
      return line[pos + 1 .. $].strip.to!size_t;
    }
  }
  return 0;
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
  auto headerEnd = request.indexOf("\r\n\r\n");
  if (headerEnd < 0) {
    return "";
  }
  foreach (line; request[0 .. headerEnd].split("\r\n")) {
    auto pos = line.indexOf(":");
    if (pos >= 0 && line[0 .. pos].strip.toLowerAscii == name.toLowerAscii) {
      return line[pos + 1 .. $].strip;
    }
  }
  return "";
}

/** 判断请求是否声明 WebSocket 升级。

    WebSocket 在收到 101 响应后不再是普通 HTTP 响应体模型，代理必须切换为双向字节
    隧道；否则只转发握手头会导致浏览器看到 101 后后续没有任何数据。
*/
bool isWebSocketUpgrade(string request) {
  return headerContains(request, "Connection", "upgrade") &&
    headerValue(request, "Upgrade").toLowerAscii == "websocket";
}

bool headerContains(string request, string name, string token) {
  foreach (part; headerValue(request, name).split(",")) {
    if (part.strip.toLowerAscii == token.toLowerAscii) {
      return true;
    }
  }
  return false;
}

/** 判断响应状态是否为 `101 Switching Protocols`。

    该判断用于 WebSocket 握手后的分支选择。只有上游确实返回 101 时才进入双向 tunnel；
    如果后端返回普通错误响应，则把响应头交给浏览器后关闭连接。
*/
bool isSwitchingProtocols(string response) {
  auto firstLineEnd = response.indexOf("\r\n");
  if (firstLineEnd < 0) {
    return false;
  }

  auto parts = response[0 .. firstLineEnd].split(" ");
  return parts.length >= 2 && parts[1] == "101";
}

/** 读取 HTTP 响应头，并保留头后已经到达的响应体前缀。

    返回值可能包含 `\r\n\r\n` 后的少量 body 字节。普通响应转发会先把这段数据发给
    浏览器，再根据 `Content-Length`、`Transfer-Encoding: chunked` 或连接关闭继续转发
    剩余数据，避免首包中的 body 被丢弃。
*/
string readHttpResponseHead(TCPConnection socket) {
  ubyte[8192] buffer;
  auto data = appender!string();

  while (true) {
    auto received = socket.read(buffer[], IOMode.once);
    if (received <= 0) {
      break;
    }
    data.put(cast(string) buffer[0 .. received]);
    if (data.data.indexOf("\r\n\r\n") >= 0) {
      break;
    }
  }
  return data.data;
}

/** 从完整 HTTP 消息中取出 body 字符串。

    这是管理接口和测试用的轻量工具，不参与普通代理路径的流式 body 转发。
*/
string bodyOf(string request) {
  auto pos = request.indexOf("\r\n\r\n");
  return pos < 0 ? "" : request[pos + 4 .. $];
}

void sendJson(TCPConnection socket, JSONValue value) {
  auto body = value.toString();
  sendRaw(socket, "200 OK", "application/json", body);
}

void sendResponse(TCPConnection socket, int code, string reason, string body) {
  sendRaw(socket, code.to!string ~ " " ~ reason, "text/plain; charset=utf-8", body ~ "\n");
}

void sendRaw(TCPConnection socket, string status, string contentType, string body) {
  string[string] headers;
  sendRaw(socket, status, contentType, body, headers);
}

void sendRaw(TCPConnection socket, string status, string contentType, string body, string[string] extraHeaders) {
  sendPrepared(socket, buildHttpResponse(status, contentType, body, extraHeaders));
}

void sendPrepared(TCPConnection socket, string response) {
  sendPrepared(socket, cast(const(ubyte)[]) response);
}

void sendPrepared(TCPConnection socket, const(ubyte)[] response) {
  socket.write(response);
}

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
