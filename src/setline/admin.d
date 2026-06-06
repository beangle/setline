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

import std.array : appender;
import std.base64 : Base64;
import std.conv : to;
import std.json : JSONValue, parseJSON;
import std.string : startsWith;

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
  if ((path == adminPrefix ~ "/status" || path == adminPrefix ~ "/status.html") && method == "GET") {
    if (!isBasicAuthorized(request)) {
      sendBasicChallenge(client);
      return;
    }
    sendRaw(client, "200 OK", "text/html; charset=utf-8", statusHtml());
    return;
  }

  if (path == adminPrefix ~ "/status.json" && method == "GET") {
    if (!isBasicAuthorized(request)) {
      sendBasicChallenge(client);
      return;
    }
    sendJson(client, statusJson());
    return;
  }

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

/** 校验 status 页面使用的 Basic Auth。

    status 页面面向浏览器访问，使用 Basic Auth 比自定义 token 头更方便。用户名固定为
    `setline`，密码复用 `adminToken`；未配置 token 时按开发模式放行。
*/
bool isBasicAuthorized(string request) {
  return isBasicAuthorized(request, adminToken());
}

bool isBasicAuthorized(string request, string token) {
  if (token.length == 0) {
    return true;
  }

  auto authorization = headerValue(request, "Authorization");
  if (!authorization.startsWith("Basic ")) {
    return false;
  }

  try {
    auto decoded = cast(string) Base64.decode(authorization["Basic ".length .. $]);
    return decoded == "setline:" ~ token;
  }
  catch (Exception) {
    return false;
  }
}

void sendBasicChallenge(TCPConnection client) {
  string[string] headers;
  headers["WWW-Authenticate"] = `Basic realm="setline status"`;
  sendRaw(client, "401 Unauthorized", "text/plain; charset=utf-8", "authentication required\n", headers);
}

string statusHtml() {
  auto listen = listenAddress();
  auto routes = routesSnapshot();
  auto html = appender!string();
  html.put(
    "<!doctype html><html><head><meta charset=\"utf-8\">" ~
    "<meta name=\"viewport\" content=\"width=device-width,initial-scale=1\">" ~
    "<title>setline status</title>" ~
    "<style>" ~
    "body{font-family:system-ui,sans-serif;margin:32px;color:#172026;background:#f7f8fa}" ~
    "main{max-width:920px;margin:auto}" ~
    "h1{font-size:24px;margin:0 0 20px}" ~
    "section{background:#fff;border:1px solid #d9dee3;border-radius:6px;margin:16px 0;padding:16px}" ~
    "dl{display:grid;grid-template-columns:180px 1fr;gap:8px 16px;margin:0}" ~
    "dt{color:#5b6670}dd{margin:0;font-family:ui-monospace,monospace}" ~
    "table{border-collapse:collapse;width:100%;font-size:14px}" ~
    "th,td{text-align:left;border-bottom:1px solid #e6e9ed;padding:8px}" ~
    "th{color:#5b6670;font-weight:600}" ~
    "</style></head><body><main>");
  html.put("<h1>setline status</h1>");
  html.put("<section><dl>");
  html.put("<dt>listen</dt><dd>" ~ escapeHtml(listen.host) ~ ":" ~ listen.port.to!string ~ "</dd>");
  html.put("<dt>active connections</dt><dd>" ~ activeConnections().to!string ~ "</dd>");
  html.put("<dt>max connections</dt><dd>" ~ maxConnections().to!string ~ "</dd>");
  html.put("<dt>connect timeout</dt><dd>" ~ connectTimeoutMillis().to!string ~ " ms</dd>");
  html.put("<dt>route count</dt><dd>" ~ routes.length.to!string ~ "</dd>");
  html.put("</dl></section>");
  html.put("<section><table><thead><tr><th>prefix</th><th>ports</th></tr></thead><tbody>");
  foreach (route; routes) {
    html.put("<tr><td>" ~ escapeHtml(route.prefix) ~ "</td><td>");
    foreach (i, backend; route.backends) {
      if (i > 0) html.put(", ");
      html.put(backend.port.to!string);
    }
    html.put("</td></tr>");
  }
  html.put("</tbody></table></section></main></body></html>");
  return html.data;
}

JSONValue statusJson() {
  auto listen = listenAddress();
  auto routes = routesSnapshot();

  JSONValue[string] root;
  JSONValue[string] listenJson;
  listenJson["host"] = JSONValue(listen.host);
  listenJson["port"] = JSONValue(listen.port);
  root["listen"] = JSONValue(listenJson);
  root["activeConnections"] = JSONValue(activeConnections());
  root["maxConnections"] = JSONValue(maxConnections());
  root["connectTimeoutMillis"] = JSONValue(connectTimeoutMillis());
  root["routeCount"] = JSONValue(routes.length);
  root["routes"] = routesJson(routes);
  return JSONValue(root);
}

string escapeHtml(string value) {
  auto escaped = appender!string();
  foreach (ch; value) {
    switch (ch) {
      case '&': escaped.put("&amp;"); break;
      case '<': escaped.put("&lt;"); break;
      case '>': escaped.put("&gt;"); break;
      case '"': escaped.put("&quot;"); break;
      default: escaped.put(ch); break;
    }
  }
  return escaped.data;
}
