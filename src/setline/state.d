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

import std.typecons : Nullable;

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

void initialize(Config config, string configPath = "") {
  synchronized {
    gRoutes = cloneHostRoutes(config.routes);
    sortHostRoutes(gRoutes);
    gRouteTrees = buildRouteTrees(gRoutes);
    gAdminToken = config.adminToken;
    gConfigPath = configPath;
    gListenAddress = config.listen;
    gConnectTimeoutMillis = config.connectTimeoutMillis;
  }
  initializeHealth(config);
  atomicStore(gMaxConnections, config.maxConnections);
  atomicStore(gActiveConnections, 0);
}

string adminToken() {
  synchronized {
    return gAdminToken;
  }
}

int connectTimeoutMillis() {
  synchronized {
    return gConnectTimeoutMillis;
  }
}

ListenAddress listenAddress() {
  synchronized {
    return gListenAddress;
  }
}

size_t maxConnections() {
  return atomicLoad(gMaxConnections);
}

size_t activeConnections() {
  return atomicLoad(gActiveConnections);
}

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

Nullable!Backend selectBackend(string host, string path) {
  synchronized {
    return selectBackendForHost(host, path, backend => isBackendHealthy(backend));
  }
}

Nullable!Backend selectBackendExcept(string host, string path, Backend[] skipped) {
  synchronized {
    return selectBackendForHost(host, path, delegate bool(Backend backend) {
      if (!isBackendHealthy(backend)) {
        return false;
      }
      foreach (item; skipped) {
        if (item == backend) {
          return false;
        }
      }
      return true;
    });
  }
}

bool hasRoute(string host, string path) {
  synchronized {
    return hasRouteForHost(host, path);
  }
}

/** 按 host 选择后端，必要时查找 `*` fallback。

    fallback 只在精确 host 没有匹配 path 路由时生效。如果精确 host 下有路由但没有健康
    backend，则返回空结果，让调用方按明确配置返回 503，而不是把请求送到默认应用。
*/
private Nullable!Backend selectBackendForHost(string host, string path, BackendPredicate available) {
  auto exact = host in gRouteTrees;
  auto selected = selectBackendFromTree(exact, path, available);
  if (!selected.isNull || routeExists(exact, path)) {
    return selected;
  }

  auto fallback = "*" in gRouteTrees;
  return selectBackendFromTree(fallback, path, available);
}

private bool hasRouteForHost(string host, string path) {
  auto exact = host in gRouteTrees;
  if (routeExists(exact, path)) {
    return true;
  }

  auto fallback = "*" in gRouteTrees;
  return routeExists(fallback, path);
}

private Nullable!Backend selectBackendFromTree(RouteTree* tree, string path, BackendPredicate available) {
  return tree is null ? Nullable!Backend.init : setline.router.selectBackend(*tree, path, available);
}

private bool routeExists(RouteTree* tree, string path) {
  return tree !is null && !setline.router.findRoute(*tree, path).isNull;
}

void upsertRoute(string host, Route route) {
  HostRoutes[] groups;
  RouteTree[string] trees;
  synchronized {
    groups = cloneHostRoutes(gRoutes);
    upsertHostRoute(groups, host, route);
    trees = buildRouteTrees(groups);
    persistRoutes(groups);
    gRoutes = groups;
    gRouteTrees = trees;
  }
  syncBackendHealth(groups);
}

bool deleteRoute(string host, string prefix) {
  HostRoutes[] groups;
  RouteTree[string] trees;
  bool removed;
  synchronized {
    groups = cloneHostRoutes(gRoutes);
    removed = deleteHostRoute(groups, host, prefix);
    if (!removed) {
      return false;
    }
    trees = buildRouteTrees(groups);
    persistRoutes(groups);
    gRoutes = groups;
    gRouteTrees = trees;
  }
  syncBackendHealth(groups);
  return true;
}

void clearRoutes(string host) {
  HostRoutes[] groups;
  RouteTree[string] trees;
  synchronized {
    groups = cloneHostRoutes(gRoutes);
    clearHostRoutes(groups, host);
    trees = buildRouteTrees(groups);
    persistRoutes(groups);
    gRoutes = groups;
    gRouteTrees = trees;
  }
  syncBackendHealth(groups);
}

void replaceRoutes(string host, Route[] routes) {
  HostRoutes[] groups;
  RouteTree[string] trees;
  sortRoutes(routes);
  synchronized {
    groups = cloneHostRoutes(gRoutes);
    replaceHostRoutes(groups, host, routes);
    trees = buildRouteTrees(groups);
    persistRoutes(groups);
    gRoutes = groups;
    gRouteTrees = trees;
  }
  syncBackendHealth(groups);
}

HostRoutes[] routesSnapshot() {
  synchronized {
    return cloneHostRoutes(gRoutes);
  }
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
    copy ~= Route(route.prefix, route.backends.dup);
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

string configPath() {
  synchronized {
    return gConfigPath;
  }
}
