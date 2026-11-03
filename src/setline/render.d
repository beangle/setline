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

module setline.render;

import std.algorithm : sort;
import std.file : exists, mkdirRecurse, readText, rename, write;
import std.path : baseName, buildPath, dirName;
import std.stdio : stdout;

import setline.edge : BackendInstance, BackendService, hostsOf, renderHaproxyBackends,
  renderHaproxyMap, renderNginxLocations, renderNginxUpstreams;
import setline.model : AgentConfig, HostRoutes, Route;

/** 一份要写出的片段文件；`path` 为空表示只打印，不落盘。 */
struct Snippet {
  string path;
  string text;
}

/** 单机部署时本机后端的回源主机：路由表里的端口都在这台机器上。 */
enum localBackendHost = "127.0.0.1";

/** 把本机路由表转成服务列表（单机部署形态）。 */
BackendService[] collectLocalServices(HostRoutes[] routes) {
  return sortServices(mergeRouteTable([], routes, localBackendHost));
}

/** 合并路由表；相同 host + prefix 的服务共用一组实例。 */
private BackendService[] mergeRouteTable(BackendService[] services, HostRoutes[] tables, string host) {
  foreach (group; tables) {
    foreach (route; group.routes) {
      auto index = findService(services, group.host, route.prefix);
      if (index < 0) {
        BackendService service;
        service.host = group.host;
        service.contentPath = route.prefix;
        services ~= service;
        index = cast(ptrdiff_t) services.length - 1;
      }
      foreach (port; route.ports)
        addInstance(services[index], host, port);
    }
  }
  return services;
}

private ptrdiff_t findService(BackendService[] services, string host, string contentPath) {
  foreach (i, service; services)
    if (service.host == host && service.contentPath == contentPath)
      return cast(ptrdiff_t) i;
  return -1;
}

private void addInstance(ref BackendService service, string host, ushort port) {
  foreach (instance; service.instances)
    if (instance.host == host && instance.port == port)
      return;
  service.instances ~= BackendInstance(host, port);
}

/** 按最长前缀优先排序服务（前缀长度相同看 host，再看路径），并让实例顺序稳定。 */
private BackendService[] sortServices(BackendService[] services) {
  foreach (ref service; services)
    sort!((a, b) => a.host == b.host ? a.port < b.port : a.host < b.host)(service.instances);
  sort!((a, b) {
    if (a.contentPath.length != b.contentPath.length)
      return a.contentPath.length > b.contentPath.length;
    if (a.host != b.host) return a.host < b.host;
    return a.contentPath < b.contentPath;
  })(services);
  return services;
}

/** 渲染 agent 要写出的全部片段；数据来源是 bashub 下载的 routes 缓存。 */
Snippet[] renderAgentSnippets(AgentConfig agent, HostRoutes[] routes) {
  import std.exception : enforce;
  enforce(agent.type.length > 0, "agent.type is required");
  return layoutSnippets(collectLocalServices(routes), agent.type, agent.output);
}

private enum snippetStem = "setline";

/** 把服务列表排布成片段文件，全部落在 `outputRoot/<type>/` 下。 */
Snippet[] layoutSnippets(BackendService[] services, string kind, string outputRoot) {
  import std.exception : enforce;
  if (kind != "haproxy" && kind != "nginx") throw new Exception("render kind must be haproxy or nginx");
  auto dir = outputRoot.length > 0 ? buildPath(outputRoot, kind) : "";
  auto mainName = snippetStem ~ (kind == "haproxy" ? ".cfg" : ".conf");
  if (kind == "haproxy") {
    auto mapPath = joinPath(dir, snippetStem ~ ".map");
    return [
      Snippet(joinPath(dir, mainName), renderHaproxyBackends(services)),
      Snippet(mapPath, renderHaproxyMap(services)),
    ];
  }
  Snippet[] snippets = [Snippet(joinPath(dir, mainName), renderNginxUpstreams(services))];
  foreach (host; hostsOf(services)) {
    auto name = host == "*" ? snippetStem ~ ".default.conf" : snippetStem ~ "." ~ host ~ ".conf";
    snippets ~= Snippet(joinPath(dir, name), renderNginxLocations(services, host));
  }
  return snippets;
}

private string joinPath(string dir, string name) {
  return dir.length > 0 ? buildPath(dir, name) : name;
}

private bool writeSnippet(string path, string text) {
  import std.exception : enforce;
  enforce(path.length > 0, "snippet path must not be empty");
  if (exists(path) && readText(path) == text) return false;
  auto parent = dirName(path);
  if (parent.length > 0 && !exists(parent)) mkdirRecurse(parent);
  auto tmpPath = path ~ ".tmp";
  write(tmpPath, text);
  rename(tmpPath, path);
  return true;
}

/** 写出一批片段；`outputRoot` 为空时打到标准输出。 */
void writeSnippets(Snippet[] snippets, string outputRoot) {
  if (outputRoot.length == 0) {
    foreach (snippet; snippets) {
      stdout.writefln("# ==== %s ====", baseName(snippet.path));
      stdout.write(snippet.text);
    }
    return;
  }
  foreach (snippet; snippets) {
    auto changed = writeSnippet(snippet.path, snippet.text);
    if (changed) stdout.writefln("setline agent wrote %s (updated)", snippet.path);
  }
}
