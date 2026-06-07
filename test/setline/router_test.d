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
    Route("/api", [9001]),
    Route("/m/edu/learning", [5173]),
    Route("/m/edu", [9002])
  ];
  sortRoutes(routes);
  auto tree = buildRouteTree(routes);

  auto matched = findRoute(tree, "/m/edu/learning/src/App.vue");
  assert(!matched.isNull);
  assert(matched.get.prefix == "/m/edu/learning");
}

@("router tree matches path segments") unittest {
  Route[] routes = [
    Route("/api", [9001]),
    Route("/api/a", [9002])
  ];
  sortRoutes(routes);
  auto tree = buildRouteTree(routes);

  assert(findRoute(tree, "/api").get.ports[0] == 9001);
  assert(findRoute(tree, "/api/users").get.ports[0] == 9001);
  assert(findRoute(tree, "/api/a").get.ports[0] == 9002);
  assert(findRoute(tree, "/api/a/users").get.ports[0] == 9002);
  assert(findRoute(tree, "/api/abc").get.ports[0] == 9001);
  assert(findRoute(tree, "/apiology").isNull);
}

@("router tree uses root route fallback") unittest {
  Route[] routes = [
    Route("/", [9000]),
    Route("/api", [9001])
  ];
  auto tree = buildRouteTree(routes);

  assert(findRoute(tree, "/other").get.prefix == "/");
  assert(selectPort(tree, "/other") == 9000);
  assert(selectPort(tree, "/api/users") == 9001);
}

@("router tree ignores repeated slashes") unittest {
  Route[] routes = [
    Route("/api/a", [9002])
  ];
  auto tree = buildRouteTree(routes);

  assert(findRoute(tree, "//api//a///users").get.prefix == "/api/a");
  assert(selectPort(tree, "//api//a///users") == 9002);
}

@("router tree selects random port from route") unittest {
  Route[] routes = [
    Route("/api", [9001, 9002])
  ];
  sortRoutes(routes);
  auto tree = buildRouteTree(routes);

  foreach (_; 0 .. 8) {
    auto port = selectPort(tree, "/api/users");
    assert(port == 9001 || port == 9002);
  }
}

@("router tree skips unavailable ports") unittest {
  Route[] routes = [
    Route("/api", [9001, 9002])
  ];
  auto tree = buildRouteTree(routes);

  assert(selectPort(tree, "/api/users", port => port == 9002) == 9002);
  assert(selectPort(tree, "/api/users", port => false) == 0);
  assert(selectPort(tree, "/missing") == 0);
}
