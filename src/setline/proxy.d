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

import core.time : seconds;
import std.array : split;
import std.conv : to;
import std.string : indexOf;

import vibe.core.core : runTask;
import vibe.core.net : TCPConnection, connectTCP;
import vibe.core.stream : IOMode;

import setline.http : headerContains, headerValue, isSwitchingProtocols, isWebSocketUpgrade, parseContentLength,
  readHttpResponseHead, sendPrepared;
import setline.model;

void forward(TCPConnection client, string request, const(ubyte)[] bufferedBody, Backend backend) {
  auto upstream = connectTCP(backend.host, backend.port, null, 0, 5.seconds);
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

void forwardWebSocket(TCPConnection client, string request, const(ubyte)[] bufferedBody, Backend backend) {
  auto upstream = connectTCP(backend.host, backend.port, null, 0, 5.seconds);

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

bool shouldUseWebSocketTunnel(string request) {
  return isWebSocketUpgrade(request);
}

void tunnel(TCPConnection client, TCPConnection upstream) {
  runTask(&relayToClient, upstream, client);

  relay(client, upstream);
  upstream.close();
  client.close();
}

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

string requestMethod(string request) {
  auto firstSpace = request.indexOf(" ");
  return firstSpace < 0 ? "" : request[0 .. firstSpace];
}

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

bool hasProxyHeaders(string request) {
  return headerValue(request, "Forwarded").length > 0 || headerValue(request, "X-Forwarded-For").length > 0;
}

string forwardedPort(TCPConnection client, string host) {
  auto colon = host.indexOf(":");
  if (colon >= 0) {
    return host[colon + 1 .. $];
  }
  return client.localAddress.port.to!string;
}

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
