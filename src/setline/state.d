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

import setline.model;
import setline.router;

__gshared private Route[] gRoutes;
__gshared private RouteTree gRouteTree;
__gshared private string gAdminToken;
__gshared private int gConnectTimeoutMillis = 3000;
shared private size_t gMaxConnections = 65535;
shared private size_t gActiveConnections;

void initialize(Config config) {
  synchronized {
    gRoutes = config.routes.dup;
    sortRoutes(gRoutes);
    gRouteTree = buildRouteTree(gRoutes);
    gAdminToken = config.adminToken;
    gConnectTimeoutMillis = config.connectTimeoutMillis;
  }
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
    return setline.router.selectBackend(gRouteTree, path);
  }
}

void upsertRoute(Route route) {
  synchronized {
    setline.router.upsertRoute(gRoutes, gRouteTree, route);
  }
}

Route[] routesSnapshot() {
  synchronized {
    return gRoutes.dup;
  }
}
