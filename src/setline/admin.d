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

module setline.admin;

import std.json : parseJSON;
import std.socket;

import setline.config : parseRoute;
import setline.constants;
import setline.http;
import setline.jsonview;
import setline.state;

void handleAdmin(Socket client, string method, string path, string request) {
  if (!isAuthorized(request)) {
    sendResponse(client, 401, "Unauthorized", "missing or invalid token");
    return;
  }

  if (path == adminPrefix ~ "/routes" && method == "GET") {
    sendJson(client, routesJson(routesSnapshot()));
    return;
  }

  if (path == adminPrefix ~ "/routes" && method == "PUT") {
    try {
      auto route = parseRoute(parseJSON(bodyOf(request)));
      upsertRoute(route);
      sendJson(client, routeJson(route));
    }
    catch (Exception e) {
      sendResponse(client, 400, "Bad Request", e.msg);
    }
    return;
  }

  sendResponse(client, 404, "Not Found", "unknown admin endpoint");
}

bool isAuthorized(string request) {
  auto token = adminToken();
  if (token.length == 0) {
    return true;
  }
  return headerValue(request, "X-Setline-Token") == token;
}
