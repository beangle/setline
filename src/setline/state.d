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

module setline.state;

import core.atomic : atomicLoad, atomicOp, atomicStore, cas;

import setline.config : saveRoutes, sortHostRoutes;
import setline.health;
import setline.model;
import setline.router;

__gshared private HostRoutes[] gRoutes;
__gshared private RouteTree[string] gRouteTrees;
__gshared private string[] gPeerReaders;
__gshared private string gConfigPath;
__gshared private ListenAddress gListenAddress;
__gshared private ListenAddress gAdminListenAddress;
__gshared private int gConnectTimeoutMillis = 3000;
__gshared private int gReadTimeoutMillis = 15000;
__gshared private bool gReusePort;
__gshared private int gUpstreamIdleTimeoutMillis = 30_000;
__gshared private int gWebSocketIdleTimeoutMillis;
// 观测计数器：事件循环单线程更新，status.json 只读快照，不做同步。
__gshared private size_t gPoolHits;
__gshared private size_t gUpstreamConnects;
__gshared private size_t gUpstreamTimeouts;
__gshared private size_t[ushort] gPortRequests;
__gshared private size_t gWebSocketTunnels;
__gshared private size_t gWebSocketIdleTimeouts;
__gshared private size_t gWebSocketBytesToUpstream;
__gshared private size_t gWebSocketBytesToClient;
shared private size_t gMaxConnections = 65535;
shared private size_t gActiveConnections;
shared private size_t gActiveRequests;
shared private size_t gActiveWebSockets;

/** 初始化运行时状态。

    路由表、监听地址和超时配置只在启动或 localhost 管理接口中低频替换。请求处理路径直接
    读取当前快照，不使用 `synchronized`，避免每个资源请求都排队经过全局锁。
*/
void initialize(Config config, string configPath = "") {
  gRoutes = cloneHostRoutes(config.routes);
  sortHostRoutes(gRoutes);
  gRouteTrees = buildRouteTrees(gRoutes);
  gPeerReaders = config.peerReaders;
  gConfigPath = configPath;
  gListenAddress = config.listen;
  gAdminListenAddress = config.adminListen;
  gConnectTimeoutMillis = config.connectTimeoutMillis;
  gReadTimeoutMillis = config.readTimeoutMillis;
  gReusePort = config.reusePort;
  gUpstreamIdleTimeoutMillis = config.upstreamIdleTimeoutMillis;
  gWebSocketIdleTimeoutMillis = config.webSocketIdleTimeoutMillis;
  gPoolHits = 0;
  gUpstreamConnects = 0;
  gUpstreamTimeouts = 0;
  gPortRequests = null;
  gWebSocketTunnels = 0;
  gWebSocketIdleTimeouts = 0;
  gWebSocketBytesToUpstream = 0;
  gWebSocketBytesToClient = 0;
  initializeHealth(config);
  atomicStore(gMaxConnections, config.maxConnections);
  atomicStore(gActiveConnections, 0);
  atomicStore(gActiveRequests, 0);
  atomicStore(gActiveWebSockets, 0);
}

/** 返回允许跨机读取路由表与状态页的来源地址。 */
const(string)[] peerReaders() {
  return gPeerReaders;
}

/** 返回当前上游端口连接超时时间。 */
int connectTimeoutMillis() {
  return gConnectTimeoutMillis;
}

/** 返回当前上游读取不活动超时时间。 */
int readTimeoutMillis() {
  return gReadTimeoutMillis;
}

/** 返回同端口多实例是否启用 SO_REUSEPORT。 */
bool reusePort() {
  return gReusePort;
}

/** 返回空闲上游连接被回收前的等待时间。 */
int upstreamIdleTimeoutMillis() nothrow {
  return gUpstreamIdleTimeoutMillis;
}

/** 返回 WebSocket 隧道空闲超时（毫秒）；0 表示不主动断开。 */
int webSocketIdleTimeoutMillis() {
  return gWebSocketIdleTimeoutMillis;
}

/** 记录一条 WebSocket 隧道建立（101 之后开始双向透传）。 */
void noteWebSocketOpen() {
  gWebSocketTunnels++;
  atomicOp!"+="(gActiveWebSockets, 1);
}

/** 记录一条 WebSocket 隧道结束（任一端关闭或出错）。 */
void noteWebSocketClose() {
  atomicOp!"-="(gActiveWebSockets, 1);
}

/** 记录一条 WebSocket 隧道因空闲超时被主动断开。 */
void noteWebSocketIdleTimeout() {
  gWebSocketIdleTimeouts++;
}

/** 记录一个客户端到后端的隧道字节（不含 101 握手本身）。 */
void noteWebSocketBytesToUpstream(size_t bytes) {
  gWebSocketBytesToUpstream += bytes;
}

/** 记录一个后端到客户端的隧道字节。 */
void noteWebSocketBytesToClient(size_t bytes) {
  gWebSocketBytesToClient += bytes;
}

/** 记录一次从空闲池取到上游连接。 */
void notePoolHit() {
  gPoolHits++;
}

/** 记录一次新建上游 TCP 连接。 */
void noteUpstreamConnect() {
  gUpstreamConnects++;
}

/** 记录一次上游读超时。 */
void noteUpstreamTimeout() {
  gUpstreamTimeouts++;
}

/** 记录一次落到某个后端端口的代理请求。 */
void noteRequestPort(ushort port) {
  gPortRequests[port]++;
}

/** 返回空闲池命中次数。 */
size_t poolHitCount() {
  return gPoolHits;
}

/** 返回新建上游连接次数。 */
size_t upstreamConnectCount() {
  return gUpstreamConnects;
}

/** 返回上游读超时次数。 */
size_t upstreamTimeoutCount() {
  return gUpstreamTimeouts;
}

/** 返回每端口代理请求数快照。 */
size_t[ushort] portRequestCounts() {
  size_t[ushort] copy;
  foreach (port, count; gPortRequests) {
    copy[port] = count;
  }
  return copy;
}

/** 返回累计建立的 WebSocket 隧道数。 */
size_t webSocketTunnelCount() {
  return gWebSocketTunnels;
}

/** 返回当前仍然打开的 WebSocket 隧道数。 */
size_t activeWebSockets() nothrow {
  return atomicLoad(gActiveWebSockets);
}

/** 返回因空闲超时被断开的隧道数。 */
size_t webSocketIdleTimeoutCount() {
  return gWebSocketIdleTimeouts;
}

/** 返回隧道里客户端发往后端的累计字节数。 */
size_t webSocketBytesToUpstream() {
  return gWebSocketBytesToUpstream;
}

/** 返回隧道里后端发往客户端的累计字节数。 */
size_t webSocketBytesToClient() {
  return gWebSocketBytesToClient;
}

/** 返回当前监听地址配置。 */
ListenAddress listenAddress() {
  return gListenAddress;
}

/** 返回管理监听地址。 */
ListenAddress adminListenAddress() {
  return gAdminListenAddress;
}

/** 标记一个正在处理的请求开始；优雅退出要等到它结束。 */
void requestStarted() nothrow {
  atomicOp!"+="(gActiveRequests, 1);
}

/** 标记一个正在处理的请求结束。 */
void requestFinished() nothrow {
  atomicOp!"-="(gActiveRequests, 1);
}

/** 返回当前正在处理的请求数（不含等待下一次请求的空闲 keep-alive 连接）。 */
size_t activeRequests() nothrow {
  return atomicLoad(gActiveRequests);
}

/** 返回允许的最大活跃连接数。 */
size_t maxConnections() {
  return atomicLoad(gMaxConnections);
}

/** 返回当前活跃连接数。 */
size_t activeConnections() {
  return atomicLoad(gActiveConnections);
}

/** 尝试占用一个活跃连接名额。 */
bool tryAcquireConnection() {
  while (true) {
    auto current = atomicLoad(gActiveConnections);
    if (current >= atomicLoad(gMaxConnections)) {
      return false;
    }
    if (cas(&gActiveConnections, current, current + 1)) {
      return true;
    }
  }
}

/** 释放一个已占用的活跃连接名额。 */
void releaseConnection() {
  while (true) {
    auto current = atomicLoad(gActiveConnections);
    if (current == 0) {
      return;
    }
    if (cas(&gActiveConnections, current, current - 1)) {
      return;
    }
  }
}

/** 按 host 和 path 选择一个健康端口。 */
ushort selectPort(string host, string path) {
  return selectPortForHost(host, path, port => isPortHealthy(port));
}

/** 按 host 和 path 选择一个未被本次请求尝试过的健康端口。 */
ushort selectPortExcept(string host, string path, ushort[] skipped) {
  return selectPortForHost(host, path, delegate bool(ushort port) {
    if (!isPortHealthy(port)) {
      return false;
    }
    foreach (item; skipped) {
      if (item == port) {
        return false;
      }
    }
    return true;
  });
}

/** 判断 host 和 path 是否有匹配路由。 */
bool hasRoute(string host, string path) {
  return hasRouteForHost(host, path);
}

/** 判断一个端口是否仍然是该 host/path 上可选的健康端口。

    客户端连接亲和会跨请求保留上游连接，但路由表可能在两次请求之间被改掉（管理接口或
    `--sync-map`），端口也可能被健康检查摘掉，所以复用之前要按当前路由复核一次。
*/
bool isRoutedPort(string host, string path, ushort port) {
  return selectPortForHost(host, path, delegate bool(ushort candidate) {
    return candidate == port && isPortHealthy(candidate);
  }) == port;
}

/** 按 host 选择端口，必要时查找 `*` fallback。

    fallback 只在精确 host 没有匹配 path 路由时生效。如果精确 host 下有路由但没有健康
    端口，则返回空结果，让调用方按明确配置返回 503，而不是把请求送到默认应用。
*/
private ushort selectPortForHost(string host, string path, PortPredicate available) {
  auto exact = host in gRouteTrees;
  auto selected = selectPortFromTree(exact, path, available);
  if (selected != 0 || routeExists(exact, path)) {
    return selected;
  }

  auto fallback = "*" in gRouteTrees;
  return selectPortFromTree(fallback, path, available);
}

private bool hasRouteForHost(string host, string path) {
  auto exact = host in gRouteTrees;
  if (routeExists(exact, path)) {
    return true;
  }

  auto fallback = "*" in gRouteTrees;
  return routeExists(fallback, path);
}

private ushort selectPortFromTree(RouteTree* tree, string path, PortPredicate available) {
  return tree is null ? 0 : setline.router.selectPort(*tree, path, available);
}

private bool routeExists(RouteTree* tree, string path) {
  return tree !is null && !setline.router.findRoute(*tree, path).isNull;
}

/** 新增或替换指定 host 下的一条路由。 */
void upsertRoute(string host, Route route) {
  auto groups = cloneHostRoutes(gRoutes);
  upsertHostRoute(groups, host, route);
  auto trees = buildRouteTrees(groups);
  persistRoutes(groups);
  gRoutes = groups;
  gRouteTrees = trees;
  syncPortHealth(groups);
}

/** 删除指定 host 下的一条路由。 */
bool deleteRoute(string host, string prefix) {
  auto groups = cloneHostRoutes(gRoutes);
  if (!deleteHostRoute(groups, host, prefix)) {
    return false;
  }
  auto trees = buildRouteTrees(groups);
  persistRoutes(groups);
  gRoutes = groups;
  gRouteTrees = trees;
  syncPortHealth(groups);
  return true;
}

/** 清空指定 host 的所有路由。 */
void clearRoutes(string host) {
  auto groups = cloneHostRoutes(gRoutes);
  clearHostRoutes(groups, host);
  auto trees = buildRouteTrees(groups);
  persistRoutes(groups);
  gRoutes = groups;
  gRouteTrees = trees;
  syncPortHealth(groups);
}

/** 替换指定 host 的完整路由集合。 */
void replaceRoutes(string host, Route[] routes) {
  sortRoutes(routes);
  auto groups = cloneHostRoutes(gRoutes);
  replaceHostRoutes(groups, host, routes);
  auto trees = buildRouteTrees(groups);
  persistRoutes(groups);
  gRoutes = groups;
  gRouteTrees = trees;
  syncPortHealth(groups);
}

/** 返回当前运行时路由表的深拷贝快照。 */
HostRoutes[] routesSnapshot() {
  return cloneHostRoutes(gRoutes);
}

private void persistRoutes(HostRoutes[] routes) {
  auto path = configPath();
  if (path.length > 0) {
    saveRoutes(path, routes);
  }
}

private RouteTree[string] buildRouteTrees(HostRoutes[] groups) {
  RouteTree[string] trees;
  foreach (group; groups) {
    trees[group.host] = buildRouteTree(group.routes);
  }
  return trees;
}

private HostRoutes[] cloneHostRoutes(HostRoutes[] groups) {
  HostRoutes[] copy;
  foreach (group; groups) {
    copy ~= HostRoutes(group.host, cloneRoutes(group.routes));
  }
  return copy;
}

private Route[] cloneRoutes(Route[] routes) {
  Route[] copy;
  foreach (route; routes) {
    copy ~= Route(route.prefix, route.ports.dup);
  }
  return copy;
}

private void upsertHostRoute(ref HostRoutes[] groups, string host, Route route) {
  foreach (i, group; groups) {
    if (group.host == host) {
      validateRoute(route);
      foreach (j, existing; groups[i].routes) {
        if (existing.prefix == route.prefix) {
          groups[i].routes[j] = route;
          sortRoutes(groups[i].routes);
          return;
        }
      }
      groups[i].routes ~= route;
      sortRoutes(groups[i].routes);
      return;
    }
  }
  groups ~= HostRoutes(host, [route]);
  sortHostRoutes(groups);
}

private bool deleteHostRoute(ref HostRoutes[] groups, string host, string prefix) {
  foreach (i, group; groups) {
    if (group.host != host) {
      continue;
    }
    Route[] routes;
    bool removed;
    foreach (route; group.routes) {
      if (route.prefix == prefix) {
        removed = true;
      } else {
        routes ~= route;
      }
    }
    if (!removed) {
      return false;
    }
    if (routes.length == 0) {
      groups = groups[0 .. i] ~ groups[i + 1 .. $];
    } else {
      sortRoutes(routes);
      groups[i].routes = routes;
    }
    return true;
  }
  return false;
}

private void clearHostRoutes(ref HostRoutes[] groups, string host) {
  foreach (i, group; groups) {
    if (group.host == host) {
      groups = groups[0 .. i] ~ groups[i + 1 .. $];
      return;
    }
  }
}

private void replaceHostRoutes(ref HostRoutes[] groups, string host, Route[] routes) {
  sortRoutes(routes);
  foreach (i, group; groups) {
    if (group.host == host) {
      if (routes.length == 0) {
        groups = groups[0 .. i] ~ groups[i + 1 .. $];
      } else {
        groups[i].routes = routes.dup;
      }
      return;
    }
  }
  if (routes.length > 0) {
    groups ~= HostRoutes(host, routes.dup);
    sortHostRoutes(groups);
  }
}

/** 返回启动时使用的配置文件路径。 */
string configPath() {
  return gConfigPath;
}
