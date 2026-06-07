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

import std.array : appender, split;
import std.base64 : Base64;
import std.conv : to;
import std.exception : enforce;
import std.json : JSONValue, parseJSON;
import std.string : indexOf, startsWith;

import vibe.core.net : TCPConnection;

import setline.config : normalizeRouteHost, normalizeRoutePrefix, parseRoutes, parseSingleRoute;
import setline.health;
import setline.http;
import setline.jsonview;
import setline.model : HostRoutes, Route;
import setline.state;
import setline.util : adminPrefix, escapeHtml;

/** 处理 `__setline` 管理接口请求。

    管理接口是当前少数需要完整读取 request body 的路径：GET 返回内存路由表快照，PUT 用
    JSON body 新增或替换一条路由。普通业务代理请求不会进入这里，因此不会因为管理接口的
    body 解析策略影响透明代理的流式转发。
*/
void handleAdmin(TCPConnection client, string method, string target, string request) {
  auto path = requestPath(target);
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

  if (path == adminPrefix ~ "/routes" && method == "GET") {
    if (!isAuthorized(request)) {
      sendResponse(client, 401, "Unauthorized", "missing or invalid token");
      return;
    }
    sendJson(client, hostRoutesJson(routesSnapshot()));
    return;
  }

  if (path == adminPrefix ~ "/routes" && method == "PUT") {
    if (!isLocalRouteUpdateAllowed(client)) return;
    try {
      auto host = routeHostFromTarget(target);
      auto route = parseSingleRoute(parseJSON(bodyOf(request)));
      upsertRoute(host, route);
      sendJson(client, routeJson(route));
    }
    catch (Exception e) {
      sendResponse(client, 400, "Bad Request", e.msg);
    }
    return;
  }

  if (path == adminPrefix ~ "/routes" && method == "DELETE") {
    if (!isLocalRouteUpdateAllowed(client)) return;
    try {
      auto host = routeHostFromTarget(target);
      auto prefix = queryValue(target, "prefix");
      if (prefix.length == 0) {
        clearRoutes(host);
      } else {
        auto normalized = normalizeRoutePrefix(prefix);
        enforce(deleteRoute(host, normalized), "route not found: " ~ host ~ normalized);
      }
      sendJson(client, hostRoutesJson(routesSnapshot()));
    }
    catch (Exception e) {
      sendResponse(client, 400, "Bad Request", e.msg);
    }
    return;
  }

  if (path == adminPrefix ~ "/routes/all" && method == "PUT") {
    if (!isLocalRouteUpdateAllowed(client)) return;
    try {
      auto host = routeHostFromTarget(target);
      auto root = parseJSON(bodyOf(request));
      enforce("routes" in root.object, "routes is required");
      replaceRoutes(host, parseRoutes(root["routes"]));
      sendJson(client, hostRoutesJson(routesSnapshot()));
    }
    catch (Exception e) {
      sendResponse(client, 400, "Bad Request", e.msg);
    }
    return;
  }

  sendResponse(client, 404, "Not Found", "unknown admin endpoint");
}

/** 判断当前连接是否允许执行本地路由更新。 */
bool isLocalRouteUpdateAllowed(TCPConnection client) {
  if (isLocalhost(client)) {
    return true;
  }
  sendResponse(client, 403, "Forbidden", "route updates are only allowed from localhost");
  return false;
}

/** 从管理接口 target 中读取并规范化 host 参数。 */
string routeHostFromTarget(string target) {
  auto host = queryValue(target, "host");
  enforce(host.length > 0, "host is required");
  return normalizeRouteHost(host);
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

/** 判断连接对端是否为 localhost。 */
bool isLocalhost(TCPConnection client) {
  return isLocalhostAddress(client.remoteAddress.toAddressString());
}

/** 判断地址字符串是否表示本机回环地址。 */
bool isLocalhostAddress(string address) {
  return address == "127.0.0.1" || address == "::1" || address == "::ffff:127.0.0.1";
}

/** 从 request target 的 query string 中读取指定参数。 */
string queryValue(string target, string name) {
  auto queryStart = target.indexOf("?");
  if (queryStart < 0) {
    return "";
  }

  foreach (part; target[queryStart + 1 .. $].split("&")) {
    auto equals = part.indexOf("=");
    if (equals < 0) {
      if (part == name) {
        return "";
      }
      continue;
    }
    if (part[0 .. equals] == name) {
      return part[equals + 1 .. $];
    }
  }
  return "";
}

/** 校验 status 页面使用的 Basic Auth。

    status 页面面向浏览器访问，使用 Basic Auth 比自定义 token 头更方便。用户名固定为
    `setline`，密码复用 `adminToken`；未配置 token 时按开发模式放行。
*/
bool isBasicAuthorized(string request) {
  return isBasicAuthorized(request, adminToken());
}

/** 校验指定 token 下的 Basic Auth 请求。 */
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

/** 返回 Basic Auth 挑战响应。 */
void sendBasicChallenge(TCPConnection client) {
  string[string] headers;
  headers["WWW-Authenticate"] = `Basic realm="setline status"`;
  sendRaw(client, "401 Unauthorized", "text/plain; charset=utf-8", "authentication required\n", headers);
}

/** 渲染状态页面 HTML。 */
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
    ".state{display:inline-flex;align-items:center;gap:6px;margin-right:12px}" ~
    ".dot{width:8px;height:8px;border-radius:50%;display:inline-block}" ~
    ".online{color:#147d3f}.online .dot{background:#1f9d55}" ~
    ".offline{color:#b42318}.offline .dot{background:#d92d20}" ~
    "</style></head><body><main>");
  html.put("<h1>setline status</h1>");
  html.put("<section><dl>");
  html.put("<dt>listen</dt><dd>" ~ escapeHtml(listen.host) ~ ":" ~ listen.port.to!string ~ "</dd>");
  html.put("<dt>active connections</dt><dd>" ~ activeConnections().to!string ~ "</dd>");
  html.put("<dt>max connections</dt><dd>" ~ maxConnections().to!string ~ "</dd>");
  html.put("<dt>connect timeout</dt><dd>" ~ connectTimeoutMillis().to!string ~ " ms</dd>");
  html.put("<dt>route hosts</dt><dd>" ~ routes.length.to!string ~ "</dd>");
  html.put("<dt>route count</dt><dd>" ~ routeCount(routes).to!string ~ "</dd>");
  html.put("</dl></section>");
  foreach (group; routes) {
    html.put("<section><h2>" ~ escapeHtml(group.host) ~ "</h2>");
    html.put("<table><thead><tr><th>prefix</th><th>ports</th></tr></thead><tbody>");
    foreach (route; group.routes) {
      html.put("<tr><td>" ~ escapeHtml(route.prefix) ~ "</td><td>");
      foreach (port; route.ports) {
        html.put(portHealthHtml(port));
      }
      html.put("</td></tr>");
    }
    html.put("</tbody></table></section>");
  }
  html.put("</main></body></html>");
  return html.data;
}

/** 返回状态接口 JSON。 */
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
  root["healthCheck"] = healthJson();
  root["routeHostCount"] = JSONValue(routes.length);
  root["routeCount"] = JSONValue(routeCount(routes));
  root["routes"] = statusRoutesJson(routes);
  return JSONValue(root);
}

/** 返回健康检查配置 JSON。 */
JSONValue healthJson() {
  auto config = healthConfig();
  JSONValue[string] item;
  item["intervalMillis"] = JSONValue(config.intervalMillis);
  item["timeoutMillis"] = JSONValue(config.timeoutMillis);
  item["unhealthyThreshold"] = JSONValue(config.unhealthyThreshold);
  item["healthyThreshold"] = JSONValue(config.healthyThreshold);

  return JSONValue(item);
}

/** 返回按 host 分组的状态路由 JSON。 */
JSONValue statusRoutesJson(HostRoutes[] groups) {
  JSONValue[string] items;
  foreach (group; groups) {
    JSONValue[] routes;
    foreach (route; group.routes) {
      routes ~= statusRouteJson(route);
    }
    items[group.host] = JSONValue(routes);
  }
  return JSONValue(items);
}

/** 返回单条状态路由 JSON。 */
JSONValue statusRouteJson(Route route) {
  JSONValue[string] item;
  item["prefix"] = JSONValue(route.prefix);

  JSONValue[] ports;
  foreach (routePort; route.ports) {
    JSONValue[string] port;
    port["port"] = JSONValue(routePort);
    port["healthy"] = JSONValue(isPortHealthy(routePort));
    ports ~= JSONValue(port);
  }
  item["ports"] = JSONValue(ports);
  return JSONValue(item);
}

/** 统计 host 分组下的路由总数。 */
size_t routeCount(HostRoutes[] groups) {
  size_t count;
  foreach (group; groups) {
    count += group.routes.length;
  }
  return count;
}

/** 渲染单个端口的健康状态标签。 */
string portHealthHtml(ushort port) {
  auto online = isPortHealthy(port);
  auto state = online ? "online" : "offline";
  return "<span class=\"state " ~ state ~ "\"><span class=\"dot\"></span>" ~
    port.to!string ~ " " ~ state ~ "</span>";
}
