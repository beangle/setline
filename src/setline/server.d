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

import core.atomic : atomicLoad, atomicOp;
import core.stdc.signal : SIG_IGN;
import core.sys.posix.signal :
  SA_RESTART, SIGINT, SIGPIPE, SIGTERM, sigaction, sigaction_t, sigemptyset, sigset_t;
import core.time : MonoTime, msecs;
import std.algorithm : startsWith;
import std.stdio : stderr;
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

/** 处理一个 client 连接上的 HTTP 请求。

    前置 proxy 到 setline 的连接可以顺序复用：每次完整代理一个请求和响应后，如果两端
    HTTP 头都允许 keep-alive 且响应体边界明确，则继续读取同一连接上的下一次请求。这里
    不支持 HTTP pipelining；前置 proxy 应等待上一轮响应完成后再发送下一轮请求。

    整条客户端连接共用一条专属上游连接（`UpstreamLease`）。连接关闭时把还健康的上游连接
    交回空闲池；连接空闲太久则由回收 task 提前交回，避免一条光挂着的客户端连接白占一条
    上游连接（见 `docs/roadmap.md` 的 P1-7）。
*/
void handleClient(TCPConnection client) {
  auto lease = new UpstreamLease;
  auto idleTask = beginLease(lease);
  scope (exit) {
    finishLease(lease, idleTask);
  }
  while (handleRequest(client, lease)) {
  }
}
/** 处理管理监听上的一个连接。

    管理面单独开监听时，数据面和它的入口完全不同：这里只服务 `__setline` 下的接口，其余
    路径一律 404，绝不再走一遍路由表——否则「绑 `*` 的管理口」会顺带把数据面也暴露出去。
    管理接口是一问一答的低频控制面，和代理路径一样，处理完一个请求就关连接。
*/
private void handleAdminClient(TCPConnection client) nothrow {
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
    client.tcpNoDelay = true;
    handleAdminRequest(client);
  } catch (Throwable) {
  }
}

/** 在管理监听上读一个请求并交给管理接口；其余路径回 404。 */
private void handleAdminRequest(TCPConnection client) {
  HttpHead request;
  try {
    request = readHttpHead(client);
  } catch (HttpHeadTooLargeException) {
    sendResponse(client, 400, "Bad Request", "HTTP head too large");
    return;
  }
  if (request.head.length == 0) {
    return;
  }
  if (request.method.length == 0 || request.target.length == 0) {
    sendResponse(client, 400, "Bad Request", "malformed request line");
    return;
  }
  if (request.invalidFraming) {
    sendResponse(client, 400, "Bad Request", "invalid message framing");
    return;
  }
  if (!request.path.startsWith(adminPrefix)) {
    sendResponse(client, 404, "Not Found", "this listener only serves " ~ adminPrefix);
    return;
  }

  requestStarted();
  scope (exit) {
    requestFinished();
  }
  handleAdmin(client, request.method, request.target, completeHttpRequest(client, request));
}
/** 选择本次请求的上游端口：优先本客户端连接已经连上的那个。

    亲和端口在两次请求之间可能已经不在路由表里（管理接口改了路由、`--sync-map` 同步了新
    映射）或者被健康检查摘掉，所以要按当前路由复核一次；不可用就回落到常规的按路由选择。
    已经失败过的端口不再重试，交给下面的失败重试循环换端口。
*/
private ushort selectRequestPort(string host, string path, ushort[] tried, UpstreamLease lease) {
  if (lease.port != 0 && isRoutedPort(host, path, lease.port)) {
    bool skipped;
    foreach (item; tried) {
      if (item == lease.port) {
        skipped = true;
      }
    }
    if (!skipped) {
      return lease.port;
    }
  }
  return selectPortExcept(host, path, tried);
}

/** 处理一个 HTTP 请求，并返回当前 client 连接是否继续复用。 */
bool handleRequest(TCPConnection client, UpstreamLease lease) {
  HttpHead request;
  try {
    request = readHttpHead(client);
  } catch (HttpHeadTooLargeException) {
    sendResponse(client, 400, "Bad Request", "HTTP head too large");
    return false;
  }
  if (request.head.length == 0) {
    return false;
  }

  if (request.method.length == 0 || request.target.length == 0) {
    sendResponse(client, 400, "Bad Request", "malformed request line");
    return false;
  }

  // 只有「手里真的有一个请求要处理」才算在途；空转等下一次请求的 keep-alive 连接不算，
  // 否则优雅退出永远等不到 0。
  requestStarted();
  bool requestCounted = true;
  scope (exit) {
    if (requestCounted) {
      requestFinished();
    }
  }

  if (request.invalidFraming) {
    sendResponse(client, 400, "Bad Request", "invalid message framing");
    return false;
  }

  auto path = request.path;

  if (path.startsWith(adminPrefix)) {
    handleAdmin(client, request.method, request.target, completeHttpRequest(client, request));
    return false;
  }

  string routeHost;
  try {
    routeHost = normalizeRequestHost(request.host);
  } catch (Exception e) {
    sendResponse(client, 400, "Bad Request", e.msg);
    return false;
  }

  auto started = MonoTime.currTime;
  try {
    ushort[] tried;
    Exception lastConnectFailure;
    while (true) {
      auto port = selectRequestPort(routeHost, path, tried, lease);
      if (port == 0) {
        int status;
        if (tried.length > 0 && lastConnectFailure !is null) {
          status = 502;
          sendResponse(client, 502, "Bad Gateway", lastConnectFailure.msg);
        } else if (hasRoute(routeHost, path)) {
          status = 503;
          sendResponse(client, 503, "Service Unavailable",
            "no healthy port for " ~ routeHost ~ path);
        } else {
          status = 404;
          sendResponse(client, 404, "Not Found", "no route for " ~ routeHost ~ path);
        }
        logAccess(request, routeHost, path, 0, status, started);
        return false;
      }
      try {
        noteRequestPort(port);
        if (request.upgradeWebSocket) {
          forwardWebSocket(client, request, port);
          return false;
        }
        auto outcome = forward(client, request, port, lease);
        logAccess(request, routeHost, path, port, outcome.status, started);
        return outcome.keepAlive;
      } catch (PortConnectException e) {
        tried ~= port;
        lastConnectFailure = e;
      } catch (UpstreamReadTimeoutException e) {
        logAccess(request, routeHost, path, port, 504, started);
        if (!e.finalResponseStarted) {
          sendResponse(client, 504, "Gateway Timeout", e.msg);
        }
        return false;
      } catch (ClientDisconnectedException) {
        logAccess(request, routeHost, path, port, 0, started);
        return false;
      }
    }
  }
  catch (Exception e) {
    if (hasRoute(routeHost, path)) {
      sendResponse(client, 502, "Bad Gateway", e.msg);
      logAccess(request, routeHost, path, 0, 502, started);
    } else {
      sendResponse(client, 404, "Not Found", "no route for " ~ routeHost ~ path);
      logAccess(request, routeHost, path, 0, 404, started);
    }
    return false;
  }
}

/** 可选访问日志（`accessLog` 打开时每请求一行），默认关闭，正常靠前置代理的日志。

    `port` 为 0 表示尚未选中后端（无路由、无健康端口或连接全失败）。`status` 为 0 表示
    没有拿到最终响应（上游提前关闭或客户端中途断开）。
*/
void logAccess(HttpHead request, string host, string path, ushort port, int status,
    MonoTime started) {
  if (!accessLogEnabled()) return;
  auto durationMillis = (MonoTime.currTime - started).total!"msecs";
  stderr.writefln("setline access host=%s method=%s path=%s port=%s status=%s duration_ms=%s",
    host.length > 0 ? host : "-", request.method, path, port, status, durationMillis);
}
