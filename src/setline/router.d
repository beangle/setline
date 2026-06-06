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

module setline.router;

import std.algorithm : sort, startsWith;
import std.exception : enforce;
import std.typecons : Nullable, nullable;

import setline.constants;
import setline.model;

void validateRoute(Route route) {
  enforce(route.prefix.length > 0 && route.prefix[0] == '/', "route prefix must start with /");
  enforce(!route.prefix.startsWith(adminPrefix), "route prefix conflicts with admin API");
}

void sortRoutes(ref Route[] routes) {
  sort!((a, b) => a.prefix.length > b.prefix.length)(routes);
}

Nullable!Route findRoute(Route[] routes, string path) {
  foreach (route; routes) {
    if (matchesRoute(path, route.prefix)) {
      return nullable(route);
    }
  }
  return Nullable!Route.init;
}

Nullable!Backend selectBackend(ref Route[] routes, string path) {
  foreach (i, route; routes) {
    if (!matchesRoute(path, route.prefix) || route.backends.length == 0) {
      continue;
    }

    auto backend = route.backends[route.nextBackend % route.backends.length];
    routes[i].nextBackend = (route.nextBackend + 1) % route.backends.length;
    return nullable(backend);
  }
  return Nullable!Backend.init;
}

void upsertRoute(ref Route[] routes, Route route) {
  validateRoute(route);
  foreach (i, existing; routes) {
    if (existing.prefix == route.prefix) {
      routes[i] = route;
      sortRoutes(routes);
      return;
    }
  }
  routes ~= route;
  sortRoutes(routes);
}

bool matchesRoute(string path, string prefix) {
  if (prefix == "/") {
    return true;
  }
  return path == prefix || path.startsWith(prefix ~ "/");
}
