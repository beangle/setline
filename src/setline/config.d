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
import std.file : exists, readText, rename, write;
import std.json;
import std.stdio : stderr;
import std.string : indexOf, stripRight;

import setline.model;
import setline.router : sortRoutes, validateRoute;
import setline.util : toLowerAscii;

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

/** 将运行时路由写回配置文件的顶层 `routes` 字段。 */
void saveRoutes(string path, HostRoutes[] routes) {
  JSONValue root;
  if (exists(path)) {
    root = parseJSON(readText(path));
    enforce(root.type == JSONType.object, "config root must be object");
  } else {
    JSONValue[string] rootObject;
    root = JSONValue(rootObject);
  }

  root["routes"] = hostRoutesConfigJson(routes);
  auto tmpPath = path ~ ".tmp";
  write(tmpPath, root.toString() ~ "\n");
  rename(tmpPath, path);
}

/** 将 host 分组路由转换为配置文件中的 `routes` JSON 对象。 */
JSONValue hostRoutesConfigJson(HostRoutes[] routes) {
  JSONValue[string] routesObject;
  foreach (group; routes) {
    routesObject[group.host] = routesConfigJson(group.routes);
  }
  return JSONValue(routesObject);
}

/** 将单个 host 下的路由列表转换为 `prefix -> port(s)` JSON 对象。 */
JSONValue routesConfigJson(Route[] routes) {
  JSONValue[string] routesObject;
  foreach (route; routes) {
    routesObject[route.prefix] = routePortsConfigJson(route);
  }
  return JSONValue(routesObject);
}

/** 将路由端口列表转换为单个端口或端口数组。 */
JSONValue routePortsConfigJson(Route route) {
  if (route.ports.length == 1) {
    return JSONValue(route.ports[0]);
  }

  JSONValue[] ports;
  foreach (port; route.ports) {
    ports ~= JSONValue(port);
  }
  return JSONValue(ports);
}

/** 解析已经存在的 JSON 配置文件。 */
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
    config.routes = parseHostRoutes(root["routes"]);
  }
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

/** 解析字符串形式的监听地址。 */
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
  route.prefix = normalizeRoutePrefix(prefix);
  route.ports = parsePorts(ports);
  validateRoute(route);
  return route;
}

/** 规范化路由前缀，除根路径外移除尾部 `/`。 */
string normalizeRoutePrefix(string prefix) {
  auto normalized = prefix.stripRight("/");
  return normalized.length == 0 ? "/" : normalized;
}

/** 解析一个 host 下的 `prefix -> port(s)` 路由对象。 */
Route[] parseRoutes(JSONValue value) {
  enforce(value.type == JSONType.object, "routes must be object");
  Route[] routes;
  foreach (prefix, ports; value.object) {
    routes ~= parseRoute(prefix, ports);
  }
  sortRoutes(routes);
  return routes;
}

/** 解析按 host 分组的路由配置。 */
HostRoutes[] parseHostRoutes(JSONValue value) {
  enforce(value.type == JSONType.object, "routes must be host object");
  HostRoutes[] groups;
  foreach (host, routes; value.object) {
    HostRoutes group;
    group.host = normalizeRouteHost(host);
    group.routes = parseRoutes(routes);
    groups ~= group;
  }
  sortHostRoutes(groups);
  return groups;
}

/** 规范化配置中的路由 host，禁止携带端口。 */
string normalizeRouteHost(string host) {
  auto normalized = host.toLowerAscii;
  enforce(normalized.length > 0, "route host must not be empty");
  enforce(normalized == "*" || normalized.indexOf(":") < 0, "route host must not include port");
  return normalized;
}

/** 规范化请求中的 Host 头，去掉端口并支持缺省 fallback。 */
string normalizeRequestHost(string host) {
  if (host.length == 0) {
    return "*";
  }
  auto colon = host.indexOf(":");
  return normalizeRouteHost(colon < 0 ? host : host[0 .. colon]);
}

/** 按 host 名称排序路由分组。 */
void sortHostRoutes(ref HostRoutes[] groups) {
  import std.algorithm : sort;
  // 精确 host 优先展示，fallback 放在最后，便于人工阅读保存后的配置。
  sort!((a, b) => a.host == "*" ? false : b.host == "*" ? true : a.host < b.host)(groups);
}

/** 解析管理接口提交的单条路由对象。 */
Route parseSingleRoute(JSONValue value) {
  auto routes = parseRoutes(value);
  enforce(routes.length == 1, "route object must contain exactly one route");
  return routes[0];
}

/** 解析端口或端口数组。

    简化配置后，不再接受完整 backend URL。端口就是路由的全部后端信息，连接时统一映射到
    `127.0.0.1:<port>`。
*/
ushort[] parsePorts(JSONValue value) {
  if (value.type == JSONType.integer) {
    return [parsePort(value.integer, "route port")];
  }

  enforce(value.type == JSONType.array, "route value must be port or ports");
  ushort[] ports;
  foreach (portValue; value.array) {
    enforce(portValue.type == JSONType.integer, "route ports must be integers");
    ports ~= parsePort(portValue.integer, "route port");
  }
  enforce(ports.length > 0, "route ports must not be empty");
  return ports;
}

/** 解析健康检查配置并校验阈值。 */
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

/** 解析字符串端口并校验范围。 */
ushort parsePort(string value, string name) {
  return parsePort(value.to!long, name);
}

/** 校验并转换端口号。 */
ushort parsePort(long value, string name) {
  enforce(value > 0 && value <= ushort.max, name ~ " must be 1..65535");
  return cast(ushort) value;
}
