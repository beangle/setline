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

import std.algorithm : startsWith;
import std.array : split;
import std.string : indexOf;

import vibe.core.core : runEventLoop;
import vibe.core.net : TCPConnection, listenTCP;

import setline.admin;
import setline.constants;
import setline.http;
import setline.model;
import setline.proxy;
import setline.state;

/** 启动本地 TCP 监听并进入 vibe-core 事件循环。

    每个客户端连接由 vibe-core task 处理，避免旧的线程模型在大量 Vite 资源并发请求时
    阻塞后续连接。这里不暴露 HTTP server 框架抽象，是因为 setline 需要精确控制请求头、
    request body、响应体和 WebSocket 升级后的字节透传。
*/
void serve(ListenAddress listenAddress) {
  listenTCP(listenAddress.port, (TCPConnection client) @trusted nothrow {
    try {
      scope (exit) {
        closeQuietly(client);
      }
      if (!tryAcquireConnection()) {
        sendResponse(client, 503, "Service Unavailable", "too many active connections");
        return;
      }
      scope (exit) {
        releaseConnection();
      }
      handleClient(client);
    } catch (Throwable) {
    }
  }, listenAddress.host);
  runEventLoop();
}

/** 关闭客户端连接并忽略关闭过程中的异常。

    连接可能已经被普通代理、WebSocket 隧道或异常路径提前关闭。入口层统一调用该函数，
    可以简化各分支清理逻辑，并避免关闭失败影响事件循环继续处理新连接。
*/
void closeQuietly(TCPConnection client) nothrow {
  try {
    client.close();
  } catch (Throwable) {
  }
}

/** 处理一个浏览器连接上的单个 HTTP 请求。

    setline 当前按短连接模型处理请求：读取请求头后先用 URL path 做管理接口或代理路由判断，
    普通代理路径不提前读取完整 request body，而是把已经读到的 body 前缀交给代理函数继续
    流式透传。这个入口也负责在 WebSocket Upgrade 请求命中后切换到专门的隧道转发路径。
*/
void handleClient(TCPConnection client) {
  auto request = readHttpHead(client);
  if (request.head.length == 0) {
    return;
  }

  auto firstLineEnd = request.head.indexOf("\r\n");
  if (firstLineEnd < 0) {
    sendResponse(client, 400, "Bad Request", "malformed request");
    return;
  }

  auto parts = request.head[0 .. firstLineEnd].split(" ");
  if (parts.length < 3) {
    sendResponse(client, 400, "Bad Request", "malformed request line");
    return;
  }

  auto method = parts[0];
  auto target = parts[1];
  auto path = requestPath(target);

  if (path.startsWith(adminPrefix)) {
    handleAdmin(client, method, path, completeHttpRequest(client, request));
    return;
  }

  try {
    auto backend = selectBackend(path);
    if (backend.isNull) {
      sendResponse(client, 404, "Not Found", "no route for " ~ path);
      return;
    }
    if (shouldUseWebSocketTunnel(request.head)) {
      forwardWebSocket(client, request.head, request.bufferedBody, backend.get);
      return;
    }
    forward(client, request.head, request.bufferedBody, backend.get);
  }
  catch (Exception e) {
    sendResponse(client, 502, "Bad Gateway", e.msg);
  }
}
