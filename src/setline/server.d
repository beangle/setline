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

import vibe.core.core : disableDefaultSignalHandlers, exitEventLoop, runEventLoop, runTask, sleep;
import vibe.core.net : TCPConnection, TCPListener, TCPListenOptions, listenTCP;
import vibe.core.task : Task;

import setline.admin;
import setline.config : normalizeRequestHost;
import setline.health;
import setline.http;
import setline.model;
import setline.proxy;
import setline.state;
import setline.util : adminPrefix;

/** `serve()` 持有的监听句柄，drain 任务要能一次停掉全部监听。 */
private struct ServerListeners {
  TCPListener data;
  TCPListener admin;
}

/** 启动本地 TCP 监听并进入 vibe-core 事件循环。

    每个客户端连接由 vibe-core task 处理，避免旧的线程模型在大量 Vite 资源并发请求时
    阻塞后续连接。这里不暴露 HTTP server 框架抽象，是因为 setline 需要精确控制请求头、
    request body、响应体和 WebSocket 升级后的字节透传。

    `adminSeparated` 为真时再开一个只服务 `__setline` 的管理监听，数据面不再暴露管理接口。
    这样数据面可以稳定只绑回环，而管理面按需绑 `*` 供跨机采集。
*/
void serve(ListenAddress listenAddress, ListenAddress adminAddress, bool adminSeparated) {
  auto options = TCPListenOptions.defaults;
  if (reusePort()) {
    options |= TCPListenOptions.reusePort;
  }
  ServerListeners listeners;
  bool loopStarted;
  // 只兜启动阶段的失败：进入事件循环后监听句柄只能由 drain 任务停，事件循环退出后
  // eventcore 的 driver 已经销毁，再碰就是野指针（实测是退出段 SIGSEGV）。
  scope (exit) {
    if (!loopStarted && listeners.data) {
      listeners.data.stopListening();
    }
  }
  listeners.data = listenTCP(listenAddress.port, (TCPConnection client) @trusted nothrow {
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
      handleClient(client);
    } catch (Throwable) {
    }
  }, listenAddress.host, options);
  if (adminSeparated) {
    listeners.admin = listenTCP(adminAddress.port, (TCPConnection client) @trusted nothrow {
      handleAdminClient(client);
    }, adminAddress.host, options);
  }
  loopStarted = true;
  auto healthTask = runTask(&runHealthChecks);
  auto poolTask = runTask(&runUpstreamPoolJanitor);
  // 自己接管 SIGTERM/SIGINT：vibe-core 默认收到信号立刻结束事件循环，正在处理的
  // 请求会被直接丢掉；这里改成「停监听 -> 等在途请求 -> 关连接 -> 退出」。
  disableDefaultSignalHandlers();
  installShutdownSignals();
  auto drainTask = runTask(&drainForShutdown, &listeners);
  scope (exit) {
    shutdownServer(listeners, healthTask, poolTask, drainTask);
  }
  runEventLoop();
}

shared private int gShutdownSignals;

extern(C) private void onShutdownSignal(int) nothrow {
  atomicOp!"+="(gShutdownSignals, 1);
}

/** 安装 SIGTERM/SIGINT 处理器，并补回 SIGPIPE 忽略。

    `disableDefaultSignalHandlers()` 之后 vibe-core 的 `onBrokenPipe` 不再生效，不把
    SIGPIPE 设成忽略的话，写一个已被对端关闭的连接会直接杀掉进程。
*/
void installShutdownSignals() nothrow {
  sigset_t mask;
  sigemptyset(&mask);
  sigaction_t info;
  info.sa_handler = &onShutdownSignal;
  info.sa_mask = mask;
  info.sa_flags = SA_RESTART;
  sigaction(SIGINT, &info, null);
  sigaction(SIGTERM, &info, null);
  sigaction_t ignore;
  ignore.sa_handler = SIG_IGN;
  ignore.sa_mask = mask;
  ignore.sa_flags = 0;
  sigaction(SIGPIPE, &ignore, null);
}

/** 是否已经收到过终止信号。 */
bool shutdownRequested() nothrow {
  return atomicLoad(gShutdownSignals) > 0;
}

/** 是否收到第二次终止信号（表示「别等了，立即退出」）。 */
bool shutdownForced() nothrow {
  return atomicLoad(gShutdownSignals) > 1;
}

/** 收到终止信号后停监听、等在途请求跑完，再退出事件循环。

    这里拿的是 `serve` 里那些 listener 的指针，`stopListening()` 会就地把它标记成无效，也就
    不会被 `shutdownServer` 再释放一次 —— eventcore 的句柄被 release 两遍时，第二次会去读
    已经释放的 userData，直接踩成 segfault。

    不主动去关空闲的 keep-alive 连接：连接对象一旦被长期引用，eventcore 的句柄就会拖到
    进程退出才释放，反倒会漏 fd。停监听后不再有新请求进来，等在途请求归零直接退出即可，
    剩下的空闲连接随进程退出一起消失。

    硬超时不在这里做：systemd 的 `TimeoutStopSec` 是最后一道保险，第二次 SIGTERM/SIGINT
    则表示运维要求立刻退出。
*/
void drainForShutdown(ServerListeners* listeners) nothrow {
  try {
    while (!shutdownRequested()) {
      sleep(50.msecs);
    }
  } catch (Throwable) {
    return;
  }
  stopListeningQuietly(listeners);
  while (!shutdownForced() && activeRequests() > 0) {
    try {
      sleep(20.msecs);
    } catch (Throwable) {
      return;
    }
  }
  exitEventLoop();
}

/** 退出事件循环后释放 eventcore 持有的活动句柄。

    Ctrl+C 会让 vibe-core 的事件循环返回，但 TCP listener、仍在处理的 client 连接以及后台
    健康检查与空闲池巡检 task 可能还持有 eventcore handle。这里按固定顺序关闭它们，避免进程
    退出时输出 active handles leak 警告。
*/
void shutdownServer(ref ServerListeners listeners, ref Task healthTask, ref Task poolTask,
    ref Task drainTask) nothrow {
  stopListeningQuietly(&listeners);
  // 空闲池里没有请求在用，但句柄还活着，退出前关掉，避免 eventcore 打一堆泄漏告警。
  closeUpstreamPool();
  stopHealthChecks();
  try {
    if (healthTask && healthTask.running) {
      healthTask.interrupt();
    }
  } catch (Throwable) {
  }
  try {
    if (poolTask && poolTask.running) {
      poolTask.interrupt();
    }
  } catch (Throwable) {
  }
  try {
    if (drainTask && drainTask.running) {
      drainTask.interrupt();
    }
  } catch (Throwable) {
  }
}

/** 停掉全部监听；已经关掉或还没建起来的监听都是空操作。 */
private void stopListeningQuietly(ServerListeners* listeners) nothrow {
  try {
    if (listeners.data) {
      listeners.data.stopListening();
    }
  } catch (Throwable) {
  }
  try {
    if (listeners.admin) {
      listeners.admin.stopListening();
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

  // 管理接口拆到独立监听后，数据面不再认这些路径：它们落到下面的路由查找里，按「没有
  // 路由」返回 404（配置校验不允许路由以 __setline 开头）。
  if (!adminListenSeparated() && path.startsWith(adminPrefix)) {
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
          // 101 之后是长连接隧道，不再算「在途请求」：优雅退出等的是请求处理完，而隧道
          // 只能等对端关闭，不能让一次重启卡到 `TimeoutStopSec`。隧道本身另有活跃计数。
          scope void onTunnelStart() nothrow {
            requestFinished();
            requestCounted = false;
          }
          auto status = forwardWebSocket(client, request, port, &onTunnelStart);
          logAccess(request, routeHost, path, port, status, started);
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
      } catch (ResponseStartedException) {
        // 响应头已经写出去了（响应体被截断、隧道中途出错）。此时补发 502 只会把状态行和
        // 错误文本混进响应体，所以只记一行访问日志并截断连接，让失败如实暴露出来。
        logAccess(request, routeHost, path, port, 0, started);
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
