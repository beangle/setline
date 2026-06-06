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

struct HttpRequestHead {
  string head;
  ubyte[] bufferedBody;
}

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

string readHttpRequest(TCPConnection socket) {
  auto request = readHttpHead(socket);
  if (request.head.length == 0) {
    return "";
  }
  return completeHttpRequest(socket, request);
}

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

string requestPath(string target) {
  auto queryStart = target.indexOf("?");
  return queryStart < 0 ? target : target[0 .. queryStart];
}

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

bool isSwitchingProtocols(string response) {
  auto firstLineEnd = response.indexOf("\r\n");
  if (firstLineEnd < 0) {
    return false;
  }

  auto parts = response[0 .. firstLineEnd].split(" ");
  return parts.length >= 2 && parts[1] == "101";
}

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
