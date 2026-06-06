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

module setline.server;

import core.thread;
import std.algorithm : startsWith;
import std.array : split;
import std.socket;
import std.string : indexOf;

import setline.admin;
import setline.constants;
import setline.http;
import setline.model;
import setline.proxy;
import setline.state;

void serve(ListenAddress listenAddress) {
  auto listener = new TcpSocket(AddressFamily.INET);
  listener.setOption(SocketOptionLevel.SOCKET, SocketOption.REUSEADDR, true);
  listener.bind(new InternetAddress(listenAddress.host, listenAddress.port));
  listener.listen(128);

  while (true) {
    auto client = listener.accept();
    auto worker = new Thread({
      scope (exit) {
        client.close();
      }
      handleClient(client);
    });
    worker.isDaemon = true;
    worker.start();
  }
}

void handleClient(Socket client) {
  auto request = readHttpRequest(client);
  if (request.length == 0) {
    return;
  }

  auto firstLineEnd = request.indexOf("\r\n");
  if (firstLineEnd < 0) {
    sendResponse(client, 400, "Bad Request", "malformed request");
    return;
  }

  auto parts = request[0 .. firstLineEnd].split(" ");
  if (parts.length < 3) {
    sendResponse(client, 400, "Bad Request", "malformed request line");
    return;
  }

  auto method = parts[0];
  auto target = parts[1];
  auto path = requestPath(target);

  if (path.startsWith(adminPrefix)) {
    handleAdmin(client, method, path, request);
    return;
  }

  auto route = findRoute(path);
  if (route.isNull) {
    sendResponse(client, 404, "Not Found", "no route for " ~ path);
    return;
  }

  try {
    auto matched = route.get;
    if (matched.wireResponse.length > 0) {
      sendPrepared(client, matched.wireResponse);
      return;
    }

    auto backend = selectBackend(path);
    if (backend.isNull) {
      sendResponse(client, 502, "Bad Gateway", "route has no backend");
      return;
    }
    if (shouldUseWebSocketTunnel(request)) {
      forwardWebSocket(client, request, backend.get);
      return;
    }
    forward(client, request, backend.get);
  }
  catch (Exception e) {
    sendResponse(client, 502, "Bad Gateway", e.msg);
  }
}
