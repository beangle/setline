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
    Route("/api"),
    Route("/m/edu/learning"),
    Route("/m/edu")
  ];
  sortRoutes(routes);

  auto matched = findRoute(routes, "/m/edu/learning/src/App.vue");
  assert(!matched.isNull);
  assert(matched.get.prefix == "/m/edu/learning");
}
