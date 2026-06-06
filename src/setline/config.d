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
import std.string : indexOf;

import setline.model;
import setline.router : sortRoutes, validateRoute;

/** 从 JSON 文件加载 setline 配置。

    配置文件不存在时返回空路由表，便于本地开发先启动代理再通过管理接口动态增加路由。
    加载到的路由会立即按前缀长度排序，运行期查找时可以直接从最长前缀开始匹配。
*/
Config loadConfig(string path) {
  if (!exists(path)) {
    stderr.writefln("Config %s not found, using empty route table", path);
    return Config.init;
  }

  return parseConfigFile(path);
}

/** 检查 JSON 配置文件并返回解析后的配置。

    该入口用于命令行 `-c` / `--check`。和运行时加载不同，检查模式要求配置文件必须存在；
    缺失、JSON 格式错误、字段类型错误或路由非法都会通过异常报告给命令行入口。
*/
Config checkConfig(string path) {
  enforce(exists(path), "config file not found: " ~ path);
  return parseConfigFile(path);
}

Config parseConfigFile(string path) {
  Config config;
  auto root = parseJSON(readText(path));
  if ("listen" in root.object) {
    config.listen = parseListen(root["listen"]);
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
  if ("healthCheck" in root.object) {
    config.healthCheck = parseHealthConfig(root["healthCheck"]);
  }
  if ("routes" in root.object) {
    config.routes = parseRoutes(root["routes"]);
  }
  sortRoutes(config.routes);
  return config;
}

/** 解析监听地址。

    支持三种形式：`8080`、`*:8080`、`host:port`。裸端口默认绑定 `127.0.0.1`；
    `*` 映射为 `0.0.0.0`，用于显式监听所有 IPv4 地址。后端仍固定为本机端口。
*/
ListenAddress parseListen(JSONValue value) {
  if (value.type == JSONType.integer) {
    return ListenAddress("127.0.0.1", parsePort(value.integer, "listen port"));
  }

  enforce(value.type == JSONType.string, "listen must be port or host:port");
  return parseListen(value.str);
}

ListenAddress parseListen(string value) {
  auto colon = value.indexOf(":");
  if (colon < 0) {
    return ListenAddress("127.0.0.1", parsePort(value, "listen port"));
  }

  auto parts = value.split(":");
  enforce(parts.length == 2, "listen must be host:port");
  auto host = parts[0] == "*" ? "0.0.0.0" : parts[0];
  return ListenAddress(host, parsePort(parts[1], "listen port"));
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

Route[] parseRoutes(JSONValue value) {
  enforce(value.type == JSONType.object, "routes must be object");
  Route[] routes;
  foreach (prefix, ports; value.object) {
    routes ~= parseRoute(prefix, ports);
  }
  sortRoutes(routes);
  return routes;
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
  return Backend("127.0.0.1", parsePort(port, "backend port"));
}

HealthConfig parseHealthConfig(JSONValue value) {
  auto obj = value.object;
  HealthConfig config;
  if ("intervalMillis" in obj) {
    config.intervalMillis = cast(int) obj["intervalMillis"].integer;
  }
  if ("timeoutMillis" in obj) {
    config.timeoutMillis = cast(int) obj["timeoutMillis"].integer;
  }
  if ("unhealthyThreshold" in obj) {
    config.unhealthyThreshold = cast(int) obj["unhealthyThreshold"].integer;
  }
  if ("healthyThreshold" in obj) {
    config.healthyThreshold = cast(int) obj["healthyThreshold"].integer;
  }
  enforce(config.intervalMillis > 0, "healthCheck.intervalMillis must be positive");
  enforce(config.timeoutMillis > 0, "healthCheck.timeoutMillis must be positive");
  enforce(config.unhealthyThreshold > 0, "healthCheck.unhealthyThreshold must be positive");
  enforce(config.healthyThreshold > 0, "healthCheck.healthyThreshold must be positive");
  return config;
}

ushort parsePort(string value, string name) {
  return parsePort(value.to!long, name);
}

ushort parsePort(long value, string name) {
  enforce(value > 0 && value <= ushort.max, name ~ " must be 1..65535");
  return cast(ushort) value;
}
