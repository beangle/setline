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
import std.conv : to;
import std.exception : enforce;
import std.json : JSONValue, parseJSON;
import std.string : indexOf, lastIndexOf, startsWith, strip;

import vibe.core.net : TCPConnection;

import setline.config : normalizeRouteHost, normalizeRoutePrefix, parseRoutes, parseSingleRoute;
import setline.health;
import setline.http;
import setline.jsonview;
import setline.model : HostRoutes, Route;
import setline.proxy;
import setline.state;
import setline.util : adminPrefix, escapeHtml, isListedAddress, isLoopbackAddress, toLowerAscii;

/** 处理 `_setline` 管理接口请求。

    管理接口的方向不同，安全边界也不同：

    - **写**（`PUT` / `DELETE` 路由）：只接受**本机**请求。改路由等于改流量走向，不对外开放。
      它只挂在管理监听上（见 `docs/configuration.md`）。
    - **读**（`GET` 路由表、状态页、`status.json`）：**本机**来源，或来源地址写在
      `peerReaders` 里的远端读方。准入只看地址，全程没有凭据：路由表的跨机读方是另一个
      setline（`agent.peers[].url`），给它配一份要在两台机器上同步的秘密，换不来比源地址
      更实在的东西，却让「谁能读」变成两处配置。读也不看 Host——本机调用方可能就是按公开
      主机名访问的；代价是「前置代理没 deny `/_setline`」的泄露路径只对读成立，而那条路径
      本来就要靠代理侧的 deny 关掉（见 docs/haproxy-integration.md）。

    哪些读走哪个监听由 `setline.server` 决定：数据面 `listen` 只把 `GET /_setline/routes`
    （peer 协议，`setline.util.peerRoutesPath`）转发到这里，状态页与 `status.json` 只在管理口
    上——它们没有跨机消费者，含监听地址、超时和计数器，挂在数据面上只会放大暴露面。

    **写的「本机」= TCP 对端是回环，且请求的 Host 也是回环名**（见 {@link isLocalAdminRequest}）。
    只看对端不够：`远端 → 本机 haproxy/nginx → setline` 时对端就是 `127.0.0.1`，但请求带着浏览器
    看到的主机名。加上 Host 这一维之后，这类转发请求进不了写接口——改路由等于改流量走向，
    值得多一道不依赖代理配置的判定。读没有这一维：它只看来源地址。

    管理接口是当前少数需要完整读取 request body 的路径：GET 返回内存路由表快照，PUT 用
    JSON body 新增或替换一条路由。普通业务代理请求不会进入这里，因此不会因为管理接口的
    body 解析策略影响透明代理的流式转发。
*/
void handleAdmin(TCPConnection client, string method, string target, string request) {
  auto path = requestPath(target);
  // 写要求「回环对端 + 回环 Host」（见 isLocalAdminRequest）；读只看来源地址，多一个
  // peerReaders 名单。
  auto writableFromLocal = isLocalAdminRequest(client, request);
  auto readableFromLocal = isLocalhost(client);
  auto fromPeerReader = isTrustedReader(client);
  if ((path == adminPrefix ~ "/status" || path == adminPrefix ~ "/status.html") && method == "GET") {
    if (!isReadAllowed(readableFromLocal, fromPeerReader)) {
      rejectUnlistedReader(client);
      return;
    }
    sendRaw(client, "200 OK", "text/html; charset=utf-8", statusHtml());
    return;
  }

  if (path == adminPrefix ~ "/status.json" && method == "GET") {
    if (!isReadAllowed(readableFromLocal, fromPeerReader)) {
      rejectUnlistedReader(client);
      return;
    }
    sendJson(client, statusJson());
    return;
  }

  if (path == adminPrefix ~ "/routes" && method == "GET") {
    if (!isReadAllowed(readableFromLocal, fromPeerReader)) {
      rejectUnlistedReader(client);
      return;
    }
    sendJson(client, hostRoutesJson(routesSnapshot()));
    return;
  }

  if (path == adminPrefix ~ "/routes" && method == "PUT") {
    if (!isLocalRouteUpdateAllowed(writableFromLocal)) {
      rejectRemoteRouteUpdate(client);
      return;
    }
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
    if (!isLocalRouteUpdateAllowed(writableFromLocal)) {
      rejectRemoteRouteUpdate(client);
      return;
    }
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
    if (!isLocalRouteUpdateAllowed(writableFromLocal)) {
      rejectRemoteRouteUpdate(client);
      return;
    }
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

/** 判断当前请求是否允许执行本地路由更新（写接口只认本机，与 token 无关）。 */
bool isLocalRouteUpdateAllowed(bool fromLocalhost) {
  return fromLocalhost;
}

/** 回写一条 403，说明写接口只接受本机请求。 */
void rejectRemoteRouteUpdate(TCPConnection client) {
  sendResponse(client, 403, "Forbidden", "route updates are only allowed from localhost");
}

/** 判定请求是否算「本机」：TCP 对端是回环，且请求声明的主机也是回环名。

    第二维借用 micdn `getOrigin` 的口径：先看代理声明的 `X-Forwarded-Host`，再看 `Host`。
    经本机代理转发的远端请求，这两个里至少有一个是浏览器看到的公开主机名，于是不再算本机
    ——写接口拒绝，也不被当成读方。

    代理可以改写 Host / 删掉转发头来伪装，所以这是**纵深防御**，不是安全边界；真正的边界是
    不让代理指向管理口（见 docs/configuration.md、docs/haproxy-integration.md）。
*/
bool isLocalAdminRequest(TCPConnection client, string request) {
  return isLocalhost(client) && isLoopbackRequestHost(request);
}

/** 请求声明的主机是否为回环名：优先 `X-Forwarded-Host`（代理声明），其次 `Host`。 */
bool isLoopbackRequestHost(string request) {
  auto declared = headerValue(request, "X-Forwarded-Host");
  auto hostPort = declared.length > 0 ? declared : headerValue(request, "Host");
  return isLoopbackHostName(hostPort);
}

/** `host[:port]` 是否为回环名：`127.0.0.1`、`[::1]`、`::1`、`localhost`，忽略端口与大小写。

    没有 Host（HTTP/1.0 或刻意省略）一律不算本机：管理接口不欢迎这种请求。
*/
bool isLoopbackHostName(string hostPort) {
  auto name = hostNameOf(hostPort);
  return name == "127.0.0.1" || name == "::1" || name == "localhost";
}

/** 从 `host[:port]` 取主机名：去掉端口与 IPv6 方括号，转小写；解析不出来返回空串。 */
string hostNameOf(string hostPort) {
  auto value = hostPort.strip;
  if (value.length == 0) return "";
  if (value[0] == '[') {
    auto close = value.indexOf(']');
    return close > 0 ? value[1 .. close].toLowerAscii : "";
  }
  auto colon = value.indexOf(':');
  // 单个冒号才是 host:port；多个冒号是不带方括号的 IPv6 字面量（没有端口可拆）。
  if (colon >= 0 && colon == value.lastIndexOf(':')) {
    return value[0 .. colon].toLowerAscii;
  }
  return value.toLowerAscii;
}

/** 从管理接口 target 中读取并规范化 host 参数。 */
string routeHostFromTarget(string target) {
  auto host = queryValue(target, "host");
  enforce(host.length > 0, "host is required");
  return normalizeRouteHost(host);
}

/**
 * 读接口（`GET` 路由表、状态页、`status.json`）的准入：**本机来源，或地址在 `peerReaders`
 * 里的读方**。所有读接口共用这一条规则，没有例外、也没有第二种凭据。
 *
 * 两个参数分别是 {@link isLocalhost} 与 {@link isTrustedReader} 的结果——做成纯函数是为了
 * 能在单测里覆盖四种组合：TCP 对端地址在单测里伪造不了。两端都不需要凭据：拨得动
 * localhost 的本来就在这台机器上（basctl 因此不需要存任何东西），远端读方按地址放行。
 */
bool isReadAllowed(bool fromLocalhost, bool fromPeerReader) {
  return fromLocalhost || fromPeerReader;
}

/** 回写一条 403，说明读接口只接受本机来源或 `peerReaders` 里的地址。

    这里不用 404 装作端点不存在：peer 协议写在文档里，读方是需要可诊断答案的机器，而
    「路径存在但来源不在名单里」并不比「路径不存在」多泄露什么。
*/
void rejectUnlistedReader(TCPConnection client) {
  sendResponse(client, 403, "Forbidden",
    "route reads are only allowed from localhost or a peerReaders address");
}

/** 判断连接对端是否为 localhost。 */
bool isLocalhost(TCPConnection client) {
  return isLoopbackAddress(client.remoteAddress.toAddressString());
}

/** 判断连接对端是否为 `peerReaders` 里列出的读方。 */
bool isTrustedReader(TCPConnection client) {
  return isListedAddress(client.remoteAddress.toAddressString(), peerReaders());
}

/** 从 request target 的 query string 中读取指定参数。

    不做 URL 解码：管理接口用到的 `host` / `prefix` 都是 ASCII 路径片段，客户端（basctl /
    curl）不会对它们做百分号编码；真要传特殊字符应该写进 JSON body（`PUT /routes/all`）。
*/

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
  auto admin = adminListenAddress();
  html.put("<dt>admin listen</dt><dd>" ~ escapeHtml(admin.host) ~ ":" ~
    admin.port.to!string ~ "</dd>");
  html.put("<dt>active connections</dt><dd>" ~ activeConnections().to!string ~ "</dd>");
  html.put("<dt>active requests</dt><dd>" ~ activeRequests().to!string ~ "</dd>");
  html.put("<dt>max connections</dt><dd>" ~ maxConnections().to!string ~ "</dd>");
  html.put("<dt>connect timeout</dt><dd>" ~ connectTimeoutMillis().to!string ~ " ms</dd>");
  html.put("<dt>pool hits</dt><dd>" ~ poolHitCount().to!string ~ "</dd>");
  html.put("<dt>upstream connects</dt><dd>" ~ upstreamConnectCount().to!string ~ "</dd>");
  html.put("<dt>upstream connections</dt><dd>" ~ leasedUpstreamCount().to!string ~ " leased / " ~
    idleUpstreamCount().to!string ~ " idle</dd>");
  html.put("<dt>upstream timeouts</dt><dd>" ~ upstreamTimeoutCount().to!string ~ "</dd>");
  html.put("<dt>unhealthy transitions</dt><dd>" ~ unhealthyTransitionCount().to!string ~ "</dd>");
  html.put("<dt>websocket tunnels</dt><dd>" ~ activeWebSockets().to!string ~ " active / " ~
    webSocketTunnelCount().to!string ~ " total</dd>");
  html.put("<dt>websocket idle timeouts</dt><dd>" ~
    webSocketIdleTimeoutCount().to!string ~ "</dd>");
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
  // 这里不报管理口地址：status.json 是给机器读的（采集机、面板），管理入口属于本机排障
  // 信息，只留在状态页 HTML 和启动日志里。
  root["activeConnections"] = JSONValue(activeConnections());
  root["activeRequests"] = JSONValue(cast(long) activeRequests());
  root["maxConnections"] = JSONValue(maxConnections());
  root["connectTimeoutMillis"] = JSONValue(connectTimeoutMillis());
  root["healthCheck"] = healthJson();
  root["activeWebSockets"] = JSONValue(cast(long) activeWebSockets());
  root["counters"] = countersJson();
  root["routeHostCount"] = JSONValue(routes.length);
  root["routeCount"] = JSONValue(routeCount(routes));
  root["routes"] = statusRoutesJson(routes);
  return JSONValue(root);
}

/** 返回连接池、请求与健康事件的累计计数，用于 status.json 观测。 */
JSONValue countersJson() {
  JSONValue[string] item;
  item["poolHits"] = JSONValue(cast(long) poolHitCount());
  item["upstreamConnects"] = JSONValue(cast(long) upstreamConnectCount());
  item["upstreamLeased"] = JSONValue(cast(long) leasedUpstreamCount());
  item["upstreamIdle"] = JSONValue(cast(long) idleUpstreamCount());
  item["upstreamTimeouts"] = JSONValue(cast(long) upstreamTimeoutCount());
  item["unhealthyTransitions"] = JSONValue(cast(long) unhealthyTransitionCount());
  item["webSocketTunnels"] = JSONValue(cast(long) webSocketTunnelCount());
  item["webSocketIdleTimeouts"] = JSONValue(cast(long) webSocketIdleTimeoutCount());
  item["webSocketBytesToUpstream"] = JSONValue(cast(long) webSocketBytesToUpstream());
  item["webSocketBytesToClient"] = JSONValue(cast(long) webSocketBytesToClient());
  JSONValue[string] ports;
  foreach (port, count; portRequestCounts()) {
    ports[port.to!string] = JSONValue(cast(long) count);
  }
  item["portRequests"] = JSONValue(ports);
  return JSONValue(item);
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
