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
import std.string : indexOf;

import vibe.core.core : runEventLoop, runTask;
import vibe.core.net : TCPConnection, TCPListener, listenTCP;
import vibe.core.task : Task;

import setline.admin;
import setline.config : normalizeRequestHost;
import setline.health;
import setline.http;
import setline.model;
import setline.proxy;
import setline.state;
import setline.util : adminPrefix;

/** 启动本地 TCP 监听并进入 vibe-core 事件循环。

    每个客户端连接由 vibe-core task 处理，避免旧的线程模型在大量 Vite 资源并发请求时
    阻塞后续连接。这里不暴露 HTTP server 框架抽象，是因为 setline 需要精确控制请求头、
    request body、响应体和 WebSocket 升级后的字节透传。
*/
void serve(ListenAddress listenAddress) {
  auto listener = listenTCP(listenAddress.port, (TCPConnection client) @trusted nothrow {
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
  auto healthTask = runTask(&runHealthChecks);
  scope (exit) {
    shutdownServer(listener, healthTask);
  }
  runEventLoop();
}

/** 退出事件循环后释放 eventcore 持有的活动句柄。

    Ctrl+C 会让 vibe-core 的事件循环返回，但 TCP listener、仍在处理的 client 连接以及后台
    健康检查 task 可能还持有 eventcore handle。这里按固定顺序关闭它们，避免进程退出时
    输出 active handles leak 警告。
*/
void shutdownServer(ref TCPListener listener, ref Task healthTask) nothrow {
  try {
    listener.stopListening();
  } catch (Throwable) {
  }
  stopHealthChecks();
  try {
    if (healthTask && healthTask.running) {
      healthTask.interrupt();
    }
  } catch (Throwable) {
  }
}

/** 关闭客户端连接并忽略关闭过程中的异常。

    连接可能已经被普通代理、WebSocket 隧道或异常路径提前关闭。入口层统一调用该函数，
    可以简化各分支清理逻辑，并避免关闭失败影响事件循环继续处理新连接。
*/
void closeQuietly(ref TCPConnection client) nothrow {
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

  if (request.method.length == 0 || request.target.length == 0) {
    sendResponse(client, 400, "Bad Request", "malformed request line");
    return;
  }

  auto path = request.path;

  if (path.startsWith(adminPrefix)) {
    handleAdmin(client, request.method, request.target, completeHttpRequest(client, request));
    return;
  }

  string routeHost;
  try {
    routeHost = normalizeRequestHost(request.host);
  } catch (Exception e) {
    sendResponse(client, 400, "Bad Request", e.msg);
    return;
  }

  try {
    ushort[] tried;
    Exception lastConnectFailure;
    while (true) {
      auto port = selectPortExcept(routeHost, path, tried);
      if (port == 0) {
        if (tried.length > 0 && lastConnectFailure !is null) {
          sendResponse(client, 502, "Bad Gateway", lastConnectFailure.msg);
        } else if (hasRoute(routeHost, path)) {
          sendResponse(client, 503, "Service Unavailable",
            "no healthy port for " ~ routeHost ~ path);
        } else {
          sendResponse(client, 404, "Not Found", "no route for " ~ routeHost ~ path);
        }
        return;
      }
      try {
        if (request.upgradeWebSocket) {
          forwardWebSocket(client, request, port);
          return;
        }
        forward(client, request, port);
        return;
      } catch (PortConnectException e) {
        tried ~= port;
        lastConnectFailure = e;
      }
    }
  }
  catch (Exception e) {
    if (hasRoute(routeHost, path)) {
      sendResponse(client, 502, "Bad Gateway", e.msg);
    } else {
      sendResponse(client, 404, "Not Found", "no route for " ~ routeHost ~ path);
    }
  }
}
