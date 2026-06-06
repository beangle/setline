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

import std.array : split;
import std.conv : to;
import std.exception : enforce;
import std.file : exists, readText;
import std.json;
import std.stdio : stderr;

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
    foreach (prefix, ports; root["routes"].object) {
      config.routes ~= parseRoute(prefix, ports);
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

/** 解析配置文件中的单条路由。

    配置文件中的 `routes` 是对象，key 为路径前缀，value 为端口或端口数组。后端固定为
    `127.0.0.1:<port>`，符合本项目只代理本机服务的约束。
*/
Route parseRoute(string prefix, JSONValue ports) {
  Route route;
  route.prefix = prefix;
  route.backends = parseBackends(ports);
  validateRoute(route);
  return route;
}

/** 解析管理接口提交的单条路由。

    管理接口保留 JSON object 形式，但字段收缩为 `prefix` 加 `port` 或 `ports`。这里显式
    拒绝旧的 `backend`、`backends`、`directResponse` 和 `stripPrefix`，避免配置语义回退到
    通用反向代理。
*/
Route parseRoute(JSONValue value) {
  auto obj = value.object;
  enforce("prefix" in obj, "route.prefix is required");
  enforce(!("backend" in obj), "route.backend is not supported; use port");
  enforce(!("backends" in obj), "route.backends is not supported; use ports");
  enforce(!("directResponse" in obj), "directResponse is not supported");
  enforce(!("stripPrefix" in obj), "stripPrefix is not supported");
  auto hasPort = ("port" in obj) !is null;
  auto hasPorts = ("ports" in obj) !is null;
  enforce(hasPort || hasPorts, "route.port or route.ports is required");
  enforce(cast(int) hasPort + cast(int) hasPorts == 1, "route must define exactly one of port or ports");

  Route route;
  route.prefix = obj["prefix"].str;
  route.backends = parseBackends(hasPort ? obj["port"] : obj["ports"]);
  validateRoute(route);
  return route;
}

/** 解析端口或端口数组为本机后端列表。

    简化配置后，不再接受完整 backend URL。所有端口都映射到 `127.0.0.1:<port>`，请求路径
    仍然使用浏览器原始请求行中的路径，确保代理不做 URL 改写。
*/
Backend[] parseBackends(JSONValue value) {
  if (value.type == JSONType.integer) {
    return [parseBackend(value.integer)];
  }

  enforce(value.type == JSONType.array, "route value must be port or ports");
  Backend[] backends;
  foreach (portValue; value.array) {
    enforce(portValue.type == JSONType.integer, "route ports must be integers");
    backends ~= parseBackend(portValue.integer);
  }
  enforce(backends.length > 0, "route ports must not be empty");
  return backends;
}

Backend parseBackend(long port) {
  enforce(port > 0 && port <= ushort.max, "backend port must be 1..65535");
  return Backend("127.0.0.1", cast(ushort) port);
}

/** 判断主机名是否属于当前允许的本机范围。

    这是项目约束的一部分：setline 服务本地前端开发和本机后端聚合，不开放到任意远端监听。
*/
bool isLocalHost(string host) {
  return host == "127.0.0.1" || host == "localhost";
}
