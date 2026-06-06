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

import core.thread;
import std.array : join, split;
import std.conv : to;
import std.exception : enforce;
import std.socket;
import std.string : indexOf, strip;

import setline.ascii : toLowerAscii;
import setline.http : headerContains, headerValue, isSwitchingProtocols, isWebSocketUpgrade, parseContentLength,
  readHttpResponseHead, sendPrepared;
import setline.model;

void forward(Socket client, string request, Backend backend) {
  auto upstream = new TcpSocket(AddressFamily.INET);
  scope (exit) {
    upstream.close();
  }

  upstream.connect(new InternetAddress(backend.host, backend.port));
  auto forwarded = replaceHeader(request, "Host", backend.host ~ ":" ~ backend.port.to!string);
  forwarded = replaceHeader(forwarded, "Connection", "close");
  sendPrepared(upstream, forwarded);

  auto response = readHttpResponseHead(upstream);
  if (response.length == 0) {
    return;
  }

  sendPrepared(client, cast(const(ubyte)[]) response);

  auto headerEnd = response.indexOf("\r\n\r\n");
  if (headerEnd < 0) {
    return;
  }

  auto headers = response[0 .. headerEnd];
  auto bodySize = response.length - cast(size_t) headerEnd - 4;
  if (headerValue(response, "Content-Length").length > 0) {
    auto contentLength = parseContentLength(headers);
    relayBytes(upstream, client, contentLength > bodySize ? contentLength - bodySize : 0);
  } else if (headerContains(response, "Transfer-Encoding", "chunked")) {
    relayUntilClose(upstream, client);
  } else {
    relayUntilClose(upstream, client);
  }
}

void forwardWebSocket(Socket client, string request, Backend backend) {
  auto upstream = new TcpSocket(AddressFamily.INET);
  upstream.connect(new InternetAddress(backend.host, backend.port));

  auto forwarded = replaceHeader(request, "Host", backend.host ~ ":" ~ backend.port.to!string);
  sendPrepared(upstream, forwarded);

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

void tunnel(Socket client, Socket upstream) {
  auto upstreamToClient = new Thread({
    relay(upstream, client);
    shutdownSocket(client);
  });
  upstreamToClient.isDaemon = true;
  upstreamToClient.start();

  relay(client, upstream);
  shutdownSocket(upstream);
  upstreamToClient.join();
  upstream.close();
}

void relay(Socket source, Socket target) {
  ubyte[8192] buffer;
  while (true) {
    auto received = source.receive(buffer[]);
    if (received <= 0) {
      return;
    }
    sendPrepared(target, buffer[0 .. received]);
  }
}

void relayBytes(Socket source, Socket target, size_t bytes) {
  ubyte[8192] buffer;
  auto remaining = bytes;
  while (remaining > 0) {
    auto limit = remaining < buffer.length ? remaining : buffer.length;
    auto received = source.receive(buffer[0 .. limit]);
    if (received <= 0) {
      return;
    }
    sendPrepared(target, buffer[0 .. received]);
    remaining -= received;
  }
}

void relayUntilClose(Socket source, Socket target) {
  ubyte[8192] buffer;
  while (true) {
    auto received = source.receive(buffer[]);
    if (received <= 0) {
      return;
    }
    sendPrepared(target, buffer[0 .. received]);
  }
}

void shutdownSocket(Socket socket) {
  try {
    socket.shutdown(SocketShutdown.BOTH);
  } catch (Exception) {
  }
}

string replaceHeader(string request, string name, string value) {
  auto headerEnd = request.indexOf("\r\n\r\n");
  enforce(headerEnd >= 0, "missing headers");

  auto lines = request[0 .. headerEnd].split("\r\n");
  bool replaced;
  foreach (i, line; lines) {
    auto pos = line.indexOf(":");
    if (pos >= 0 && line[0 .. pos].strip.toLowerAscii == name.toLowerAscii) {
      lines[i] = name ~ ": " ~ value;
      replaced = true;
    }
  }
  if (!replaced) {
    lines ~= name ~ ": " ~ value;
  }
  return lines.join("\r\n") ~ request[headerEnd .. $];
}
