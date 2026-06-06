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

module setline.router_test;

import setline.model;
import setline.router;

@("router longest prefix matches nested path") unittest {
  Route[] routes = [
    Route("/api", [Backend("127.0.0.1", 9001)]),
    Route("/m/edu/learning", [Backend("127.0.0.1", 5173)]),
    Route("/m/edu", [Backend("127.0.0.1", 9002)])
  ];
  sortRoutes(routes);
  auto tree = buildRouteTree(routes);

  auto matched = findRoute(tree, "/m/edu/learning/src/App.vue");
  assert(!matched.isNull);
  assert(matched.get.prefix == "/m/edu/learning");
}

@("router tree matches path segments") unittest {
  Route[] routes = [
    Route("/api", [Backend("127.0.0.1", 9001)]),
    Route("/api/a", [Backend("127.0.0.1", 9002)])
  ];
  sortRoutes(routes);
  auto tree = buildRouteTree(routes);

  assert(findRoute(tree, "/api").get.backends[0].port == 9001);
  assert(findRoute(tree, "/api/users").get.backends[0].port == 9001);
  assert(findRoute(tree, "/api/a").get.backends[0].port == 9002);
  assert(findRoute(tree, "/api/a/users").get.backends[0].port == 9002);
  assert(findRoute(tree, "/api/abc").get.backends[0].port == 9001);
  assert(findRoute(tree, "/apiology").isNull);
}

@("router tree selects random backend from route") unittest {
  Route[] routes = [
    Route("/api", [Backend("127.0.0.1", 9001), Backend("127.0.0.1", 9002)])
  ];
  sortRoutes(routes);
  auto tree = buildRouteTree(routes);

  foreach (_; 0 .. 8) {
    auto port = selectBackend(tree, "/api/users").get.port;
    assert(port == 9001 || port == 9002);
  }
}

@("router tree skips unavailable backends") unittest {
  Route[] routes = [
    Route("/api", [Backend("127.0.0.1", 9001), Backend("127.0.0.1", 9002)])
  ];
  auto tree = buildRouteTree(routes);

  assert(selectBackend(tree, "/api/users", backend => backend.port == 9002).get.port == 9002);
  assert(selectBackend(tree, "/api/users", backend => false).isNull);
}
