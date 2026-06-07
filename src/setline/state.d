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

import setline.config : saveRoutes;
import setline.health;
import setline.model;
import setline.router;

__gshared private Route[] gRoutes;
__gshared private RouteTree gRouteTree;
__gshared private string gAdminToken;
__gshared private string gConfigPath;
__gshared private ListenAddress gListenAddress;
__gshared private int gConnectTimeoutMillis = 3000;
shared private size_t gMaxConnections = 65535;
shared private size_t gActiveConnections;

void initialize(Config config, string configPath = "") {
  synchronized {
    gRoutes = config.routes.dup;
    sortRoutes(gRoutes);
    gRouteTree = buildRouteTree(gRoutes);
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

Nullable!Backend selectBackend(string path) {
  synchronized {
    return setline.router.selectBackend(gRouteTree, path, backend => isBackendHealthy(backend));
  }
}

Nullable!Backend selectBackendExcept(string path, Backend[] skipped) {
  synchronized {
    return setline.router.selectBackend(gRouteTree, path, delegate bool(Backend backend) {
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

bool hasRoute(string path) {
  synchronized {
    return !setline.router.findRoute(gRouteTree, path).isNull;
  }
}

void upsertRoute(Route route) {
  Route[] routes;
  RouteTree tree;
  synchronized {
    routes = gRoutes.dup;
    setline.router.upsertRoute(routes, tree, route);
    persistRoutes(routes);
    gRoutes = routes;
    gRouteTree = tree;
  }
  syncBackendHealth(routes);
}

bool deleteRoute(string prefix) {
  Route[] routes;
  RouteTree tree;
  bool removed;
  synchronized {
    foreach (route; gRoutes) {
      if (route.prefix == prefix) {
        removed = true;
      } else {
        routes ~= route;
      }
    }
    if (!removed) {
      return false;
    }
    sortRoutes(routes);
    tree = buildRouteTree(routes);
    persistRoutes(routes);
    gRoutes = routes;
    gRouteTree = tree;
  }
  syncBackendHealth(routes);
  return true;
}

void clearRoutes() {
  synchronized {
    persistRoutes(null);
    gRoutes = null;
    gRouteTree = RouteTree.init;
  }
  syncBackendHealth(null);
}

void replaceRoutes(Route[] routes) {
  sortRoutes(routes);
  auto tree = buildRouteTree(routes);
  synchronized {
    persistRoutes(routes);
    gRoutes = routes.dup;
    gRouteTree = tree;
  }
  syncBackendHealth(routes);
}

Route[] routesSnapshot() {
  synchronized {
    return gRoutes.dup;
  }
}

void persistRoutes(Route[] routes) {
  auto path = configPath();
  if (path.length > 0) {
    saveRoutes(path, routes);
  }
}

string configPath() {
  synchronized {
    return gConfigPath;
  }
}
