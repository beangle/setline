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

module setline.config;

import std.algorithm : startsWith;
import std.array : split;
import std.conv : to;
import std.exception : enforce;
import std.file : exists, readText;
import std.json;
import std.stdio : stderr;
import std.string : indexOf;

import setline.http : buildHttpResponse, statusReason;
import setline.model;
import setline.router : sortRoutes, validateRoute;

/** 从 JSON 文件加载 setline 配置。

    配置文件不存在时返回空路由表，便于本地开发先启动代理再通过管理接口动态增加路由。
    加载到的路由会立即按前缀长度排序，运行期查找时可以直接从最长前缀开始匹配。
*/
Config loadConfig(string path) {
  Config config;

  if (!exists(path)) {
    stderr.writefln("Config %s not found, using empty route table", path);
    return config;
  }

  auto root = parseJSON(readText(path));
  if ("listen" in root.object) {
    config.listen = parseListen(root["listen"].str);
  }
  if ("adminToken" in root.object) {
    config.adminToken = root["adminToken"].str;
  }
  if ("connectTimeoutMillis" in root.object) {
    config.connectTimeoutMillis = cast(int) root["connectTimeoutMillis"].integer;
    enforce(config.connectTimeoutMillis > 0, "connectTimeoutMillis must be positive");
  }
  if ("maxConnections" in root.object) {
    config.maxConnections = cast(size_t) root["maxConnections"].integer;
    enforce(config.maxConnections > 0, "maxConnections must be positive");
  }
  if ("routes" in root.object) {
    foreach (item; root["routes"].array) {
      config.routes ~= parseRoute(item);
    }
  }
  sortRoutes(config.routes);
  return config;
}

/** 解析监听地址。

    setline 当前不是公网反向代理，也不承担内核透明代理职责，所以监听地址被限制为本机。
    格式固定为 `host:port`，这样可以让后续代理身份头里的端口推导保持明确。
*/
ListenAddress parseListen(string value) {
  auto parts = value.split(":");
  enforce(parts.length == 2, "listen must be host:port");
  enforce(isLocalHost(parts[0]), "listen host must be local");
  return ListenAddress(parts[0], parts[1].to!ushort);
}

/** 解析单条路由配置。

    路由只能在直接响应、单后端、多后端三种模式中选择一种。这里显式拒绝 `stripPrefix`，
    是为了保持项目目标清晰：setline 按 URL 决定转发目的，但不会改写浏览器发来的 URL。
*/
Route parseRoute(JSONValue value) {
  auto obj = value.object;
  enforce("prefix" in obj, "route.prefix is required");
  enforce(!("stripPrefix" in obj), "stripPrefix is not supported");
  auto hasDirectResponse = ("directResponse" in obj) !is null;
  auto hasBackend = ("backend" in obj) !is null;
  auto hasBackends = ("backends" in obj) !is null;
  enforce(hasDirectResponse || hasBackend || hasBackends,
    "route.directResponse, route.backend, or route.backends is required");
  enforce(cast(int) hasDirectResponse + cast(int) hasBackend + cast(int) hasBackends == 1,
    "route must define exactly one of directResponse, backend, or backends");

  Route route;
  route.prefix = obj["prefix"].str;
  if (hasDirectResponse) {
    route.response = parseDirectResponse(obj["directResponse"]);
    route.wireResponse = buildHttpResponse(
      route.response.status.to!string ~ " " ~ statusReason(route.response.status),
      route.response.contentType,
      route.response.body,
      route.response.headers);
  } else if (hasBackend)  {
    route.backends = [parseBackend(obj["backend"].str)];
  } else {
    foreach (backendValue; obj["backends"].array) {
      route.backends ~= parseBackend(backendValue.str);
    }
    enforce(route.backends.length > 0, "route.backends must not be empty");
  }
  validateRoute(route);
  return route;
}

/** 解析直接响应配置。

    直接响应允许配置状态码、Content-Type、body 和少量附加头。`Content-Length`、
    `Connection`、`Content-Type` 这类由响应构造函数统一控制，避免配置覆盖基础协议头。
*/
DirectResponse parseDirectResponse(JSONValue value) {
  auto obj = value.object;

  DirectResponse response;
  response.status = ("status" in obj) ? cast(int) obj["status"].integer : 200;
  response.contentType = ("contentType" in obj) ? obj["contentType"].str : response.contentType;
  response.body = ("body" in obj) ? obj["body"].str : "";

  if ("headers" in obj) {
    foreach (name, headerValueJson; obj["headers"].object) {
      response.headers[name] = headerValueJson.str;
    }
  }

  enforce(response.status >= 100 && response.status <= 599, "directResponse.status must be 100..599");
  return response;
}

/** 解析后端地址。

    目前只支持本机明文 HTTP 后端，格式为 `http://host:port`。即使配置里带了 path，也只取
    authority 部分；请求路径仍然使用浏览器原始请求行中的路径，确保代理不做 URL 改写。
*/
Backend parseBackend(string raw) {
  enforce(raw.startsWith("http://"), "only http:// backends are supported");
  auto authority = raw["http://".length .. $];
  auto slashIndex = authority.indexOf("/");
  if (slashIndex >= 0) {
    authority = authority[0 .. slashIndex];
  }

  auto parts = authority.split(":");
  enforce(parts.length == 2, "backend must be http://host:port");
  enforce(isLocalHost(parts[0]), "backend host must be local");
  return Backend(parts[0], parts[1].to!ushort);
}

/** 判断主机名是否属于当前允许的本机范围。

    这是项目约束的一部分：setline 服务本地前端开发和本机后端聚合，不开放到任意远端主机。
*/
bool isLocalHost(string host) {
  return host == "127.0.0.1" || host == "localhost";
}
