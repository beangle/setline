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

import core.atomic : atomicLoad, atomicStore, cas;

import setline.config : saveRoutes, sortHostRoutes;
import setline.health;
import setline.model;
import setline.router;

__gshared private HostRoutes[] gRoutes;
__gshared private RouteTree[string] gRouteTrees;
__gshared private string gAdminToken;
__gshared private string gConfigPath;
__gshared private ListenAddress gListenAddress;
__gshared private int gConnectTimeoutMillis = 3000;
shared private size_t gMaxConnections = 65535;
shared private size_t gActiveConnections;

/** 初始化运行时状态。

    路由表、监听地址和超时配置只在启动或 localhost 管理接口中低频替换。请求处理路径直接
    读取当前快照，不使用 `synchronized`，避免每个资源请求都排队经过全局锁。
*/
void initialize(Config config, string configPath = "") {
  gRoutes = cloneHostRoutes(config.routes);
  sortHostRoutes(gRoutes);
  gRouteTrees = buildRouteTrees(gRoutes);
  gAdminToken = config.adminToken;
  gConfigPath = configPath;
  gListenAddress = config.listen;
  gConnectTimeoutMillis = config.connectTimeoutMillis;
  initializeHealth(config);
  atomicStore(gMaxConnections, config.maxConnections);
  atomicStore(gActiveConnections, 0);
}

/** 返回管理接口使用的 token。 */
string adminToken() {
  return gAdminToken;
}

/** 返回当前上游端口连接超时时间。 */
int connectTimeoutMillis() {
  return gConnectTimeoutMillis;
}

/** 返回当前监听地址配置。 */
ListenAddress listenAddress() {
  return gListenAddress;
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
