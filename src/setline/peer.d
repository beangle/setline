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

module setline.peer;

import std.algorithm : canFind, sort;
import std.exception : enforce;
import std.file : exists, mkdirRecurse, readText, rename, write;
import std.functional : toDelegate;
import std.json;
import std.path : baseName, buildPath, dirName, stripExtension;
import std.string : indexOf, stripRight;

import setline.config : normalizeRouteHost, normalizeRoutePrefix, parsePort;
import setline.edge : BackendInstance, BackendService, fetchText, hostsOf, loadBackendsJson,
  parseBackends, renderHaproxyBackends, renderHaproxyMap, renderNginxLocations, renderNginxUpstreams,
  renderProxyConfig;
import setline.model : AgentConfig, HostRoutes, PeerConfig, Route;
import setline.util : adminPrefix;

/** 计算 peer 路由表接口 URL；给出的既可以是 setline 基地址，也可以是完整的 routes URL。 */
string peerRoutesUrl(PeerConfig peer) {
  enforce(peer.url.length > 0, "agent.peers[].url must not be empty");
  if (peer.url.canFind(adminPrefix ~ "/routes")) return peer.url;
  return peer.url.stripRight("/") ~ adminPrefix ~ "/routes";
}

/** 计算 peer 在边缘代理上的后端主机，也就是 URL 的主机部分（不含端口和路径）。

    `url` 一个字段承担两个方向：它既是拉取路由表的管理入口，也是边缘代理回源的地址。
    这里丢弃端口，因为 URL 端口是管理端口，而业务端口由每条路由自带。
*/
string peerAddress(PeerConfig peer) {
  auto rest = peer.url;
  auto scheme = rest.indexOf("://");
  if (scheme >= 0) rest = rest[scheme + 3 .. $];
  auto slash = rest.indexOf("/");
  if (slash >= 0) rest = rest[0 .. slash];
  enforce(rest.length > 0,
    "cannot derive backend host from agent.peers[].url, which needs a host: " ~ peer.url);
  if (rest[0] == '[') {
    auto close = rest.indexOf("]");
    enforce(close > 0, "invalid IPv6 host in agent.peers[].url: " ~ peer.url);
    return rest[0 .. close + 1];
  }
  auto colon = rest.indexOf(":");
  return colon < 0 ? rest : rest[0 .. colon];
}

/** 读取单个 peer 的路由表，必要时带上 `X-Setline-Token`。 */
HostRoutes[] fetchPeerRoutes(PeerConfig peer, string defaultToken = "") {
  auto token = peer.token.length > 0 ? peer.token : defaultToken;
  string[] headers;
  if (token.length > 0) headers ~= "X-Setline-Token: " ~ token;
  return parsePeerRoutes(fetchText(peerRoutesUrl(peer), headers));
}

/** 解析 `GET /__setline/routes` 的响应，形状为 `host -> [{prefix, port|ports}]`。 */
HostRoutes[] parsePeerRoutes(string text) {
  auto root = parseJSON(text);
  enforce(root.type == JSONType.object, "peer routes must be object");
  HostRoutes[] groups;
  foreach (host, routesValue; root.object) {
    enforce(routesValue.type == JSONType.array, "peer routes entry must be array");
    HostRoutes group;
    group.host = normalizeRouteHost(host);
    Route[] routes;
    foreach (item; routesValue.array) {
      enforce(item.type == JSONType.object, "peer route must be object");
      Route route;
      route.prefix = normalizeRoutePrefix(requiredPeerString(item, "prefix"));
      route.ports = parsePeerPorts(item);
      routes ~= route;
    }
    group.routes = routes;
    groups ~= group;
  }
  return groups;
}

/** 解析一条 peer 路由的端口：单端口 `port` 或端口数组 `ports`。 */
ushort[] parsePeerPorts(JSONValue item) {
  ushort[] ports;
  if ("port" in item.object) {
    enforce(item["port"].type == JSONType.integer, "peer route port must be integer");
    ports ~= parsePort(item["port"].integer, "peer route port");
  }
  if ("ports" in item.object) {
    enforce(item["ports"].type == JSONType.array, "peer route ports must be array");
    foreach (value; item["ports"].array) {
      enforce(value.type == JSONType.integer, "peer route ports must be integers");
      ports ~= parsePort(value.integer, "peer route port");
    }
  }
  enforce(ports.length > 0, "peer route must contain port or ports");
  return ports;
}

/** 读取 peer 对象中的必填字符串字段。 */
string requiredPeerString(JSONValue value, string key) {
  enforce(key in value.object, key ~ " is required");
  enforce(value[key].type == JSONType.string, key ~ " must be string");
  return value[key].str;
}

/** 读取所有 peer 的路由表并合并成边缘代理服务列表。

    `fetcher` 用来读取单个 peer 的路由表，默认走 HTTP；测试可以注入本地实现，避免依赖网络。
*/
BackendService[] collectPeerServices(AgentConfig agent,
    HostRoutes[] delegate(PeerConfig, string) fetcher = toDelegate(&fetchPeerRoutes)) {
  enforce(agent.peers.length > 0, "agent.peers must not be empty");
  BackendService[] services;
  foreach (peer; agent.peers) {
    auto host = peerAddress(peer);
    auto name = peer.name.length > 0 ? peer.name : host;
    services = mergePeerTable(services, fetcher(peer, agent.token), host, name);
  }
  return sortServices(services);
}

/** 把一个 peer 的路由表并入服务列表；相同 host + prefix 的服务共用一组实例。 */
BackendService[] mergePeerTable(BackendService[] services, HostRoutes[] tables, string host,
    string namePrefix) {
  foreach (group; tables) {
    foreach (route; group.routes) {
      auto index = findService(services, group.host, route.prefix);
      if (index < 0) {
        BackendService service;
        service.name = namePrefix ~ " " ~ group.host ~ " " ~ route.prefix;
        service.host = group.host;
        service.contentPath = route.prefix;
        services ~= service;
        index = cast(ptrdiff_t) services.length - 1;
      }
      foreach (port; route.ports) {
        addInstance(services[index], host, port);
      }
    }
  }
  return services;
}

/** 查找已合并的 host + prefix 服务，未命中返回 -1。 */
ptrdiff_t findService(BackendService[] services, string host, string contentPath) {
  foreach (i, service; services) {
    if (service.host == host && service.contentPath == contentPath) return cast(ptrdiff_t) i;
  }
  return -1;
}

/** 追加一个后端实例，重复的 host:port 只保留一份。 */
void addInstance(ref BackendService service, string host, ushort port) {
  foreach (instance; service.instances) {
    if (instance.host == host && instance.port == port) return;
  }
  service.instances ~= BackendInstance(host, port);
}

/** 按最长前缀优先排序服务，并让每个服务的实例顺序稳定。 */
BackendService[] sortServices(BackendService[] services) {
  foreach (ref service; services) {
    sort!((a, b) => a.host == b.host ? a.port < b.port : a.host < b.host)(service.instances);
  }
  sort!((a, b) {
    if (a.contentPath.length != b.contentPath.length) {
      return a.contentPath.length > b.contentPath.length;
    }
    if (a.host != b.host) return a.host < b.host;
    return a.name < b.name;
  })(services);
  return services;
}

/** 一份要写出的片段文件；`path` 为空表示只打印，不落盘。 */
struct Snippet {
  string path;
  string text;
}

/** 按数据来源取得后端服务：`peers` 合并，或 `remote` registry bundle（二者互斥）。 */
BackendService[] collectAgentServices(AgentConfig agent) {
  if (agent.peers.length > 0) return collectPeerServices(agent);
  enforce(agent.url.length > 0, "agent.remote is required");
  return parseBackends(loadBackendsJson(agent));
}

/** 渲染 agent 要写出的全部片段。

    `bind` 非空时只输出一份自包含片段（片段自己持有监听）；`bind` 留空时只输出规则与
    后端定义，监听段归代理主配置，文件布局见 docs/haproxy-integration.md 与
    docs/nginx-integration.md。
*/
Snippet[] renderAgentSnippets(AgentConfig agent) {
  enforce(agent.type.length > 0, "agent.type is required");
  return layoutSnippets(collectAgentServices(agent), agent.type, agent.output, agent.bind);
}

/** 把服务列表排布成片段文件；规则模式下文件名由 `output` 派生。 */
Snippet[] layoutSnippets(BackendService[] services, string kind, string output, string bind) {
  if (bind.length > 0) {
    return [Snippet(output, renderProxyConfig(services, kind, bind))];
  }
  auto stem = output.length > 0 ? stripExtension(baseName(output)) : "setline";
  auto dir = output.length > 0 ? dirName(output) : "";
  if (kind == "haproxy") {
    auto mapPath = joinPath(dir, stem ~ ".map");
    return [
      Snippet(output, renderHaproxyBackends(services)),
      Snippet(mapPath, renderHaproxyMap(services, mapPath)),
    ];
  }
  if (kind != "nginx") throw new Exception("render kind must be haproxy or nginx");
  Snippet[] snippets = [Snippet(output, renderNginxUpstreams(services))];
  foreach (host; hostsOf(services)) {
    auto name = host == "*" ? stem ~ ".default.conf" : stem ~ "." ~ host ~ ".conf";
    snippets ~= Snippet(joinPath(dir, name), renderNginxLocations(services, host));
  }
  return snippets;
}

/** 拼接片段路径；目录为空时（只打印到标准输出）只用文件名。 */
string joinPath(string dir, string name) {
  return dir.length > 0 ? buildPath(dir, name) : name;
}

/** 原子写出片段；内容未变化时不触碰原文件，返回是否发生写入。 */
bool writeSnippet(string path, string text) {
  enforce(path.length > 0, "snippet path must not be empty");
  if (exists(path) && readText(path) == text) return false;
  auto parent = dirName(path);
  if (parent.length > 0 && !exists(parent)) mkdirRecurse(parent);
  auto tmpPath = path ~ ".tmp";
  write(tmpPath, text);
  rename(tmpPath, path);
  return true;
}
