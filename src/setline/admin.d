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

import vibe.core.net : TCPConnection;

import setline.config : parseRoute;
import setline.constants;
import setline.http;
import setline.jsonview;
import setline.state;

/** 处理 `__setline` 管理接口请求。

    管理接口是当前少数需要完整读取 request body 的路径：GET 返回内存路由表快照，PUT 用
    JSON body 新增或替换一条路由。普通业务代理请求不会进入这里，因此不会因为管理接口的
    body 解析策略影响透明代理的流式转发。
*/
void handleAdmin(TCPConnection client, string method, string path, string request) {
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

/** 校验管理接口 token。

    未配置 token 时默认允许本机管理，方便开发场景；一旦配置 `adminToken`，请求必须携带
    `X-Setline-Token`。该校验只保护管理 API，不参与普通代理请求。
*/
bool isAuthorized(string request) {
  auto token = adminToken();
  if (token.length == 0) {
    return true;
  }
  return headerValue(request, "X-Setline-Token") == token;
}
