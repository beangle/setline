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

module setline.jsonview;

import std.conv : to;
import std.json;

import setline.model;

JSONValue routeJson(Route route) {
  JSONValue[string] item;
  item["prefix"] = JSONValue(route.prefix);
  if (route.backends.length == 1)  {
    item["port"] = JSONValue(route.backends[0].port);
  } else {
    JSONValue[] ports;
    foreach (backend; route.backends) {
      ports ~= JSONValue(backend.port);
    }
    item["ports"] = JSONValue(ports);
  }
  return JSONValue(item);
}

JSONValue routesJson(Route[] routes) {
  JSONValue[] items;
  foreach (route; routes) {
    items ~= routeJson(route);
  }
  return JSONValue(items);
}
