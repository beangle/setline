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

module setline.peer_test;

import std.algorithm : canFind;
import std.exception : assertThrown;
import std.file : exists, mkdirRecurse, readText, remove, rmdirRecurse, write;
import std.path : buildPath;

import setline.config : parseConfigFile;
import setline.control : ControlConfig;
import setline.edge;
import setline.model;
import setline.peer;

@("peer derives routes url and backend address") unittest {
  assert(peerRoutesUrl(peerWithUrl("http://10.0.1.10:8080"))
    == "http://10.0.1.10:8080/_setline/routes");
  assert(peerRoutesUrl(peerWithUrl("http://10.0.1.10:8080/"))
    == "http://10.0.1.10:8080/_setline/routes");
  assert(peerRoutesUrl(peerWithUrl("http://10.0.1.10:8080/_setline/routes"))
    == "http://10.0.1.10:8080/_setline/routes");
  assert(peerAddress(peerWithUrl("http://10.0.1.10:8080")) == "10.0.1.10");
  assert(peerAddress(peerWithUrl("10.0.1.10:8080")) == "10.0.1.10");
  assert(peerAddress(peerWithUrl("http://[fe80::1]:8080")) == "[fe80::1]");
  assert(peerAddress(peerWithUrl("http://app.example.com/_setline/routes")) == "app.example.com");
  // 回源主机只从 url 推导，推导不出来就是配置错误，没有 address 这种兜底。
  assertThrown!Exception(peerAddress(peerWithUrl("file:///tmp/peer")));
  assertThrown!Exception(peerAddress(peerWithUrl("/tmp/peer")));
}

/** 构造只带 url 的 peer，用于地址/URL 推导测试。 */
PeerConfig peerWithUrl(string url) {
  PeerConfig peer;
  peer.url = url;
  return peer;
}

@("peer parses routes payload") unittest {
  auto groups = parsePeerRoutes(`{"app.example.com":[{"prefix":"/api/edu","ports":[9002,9003]},` ~
    `{"prefix":"/","port":9090}],"*":[{"prefix":"/","port":9090}]}`);
  assert(groups.length == 2);
  auto app = groups[0].host == "app.example.com" ? groups[0] : groups[1];
  assert(app.routes.length == 2);
  assert(app.routes[0].ports == [9002, 9003]);
  assert(app.routes[1].prefix == "/");
}

@("peer merges same route across peers") unittest {
  BackendService[] services;
  services = mergePeerTable(services, parsePeerRoutes(`{"app.example.com":[{"prefix":"/api/edu","port":9002}]}`),
    "10.0.1.10");
  services = mergePeerTable(services,
    parsePeerRoutes(`{"app.example.com":[{"prefix":"/api/edu","ports":[9002,9003]}]}`), "10.0.1.11");
  sortServices(services);

  assert(services.length == 1);
  assert(services[0].contentPath == "/api/edu");
  assert(services[0].instances.length == 3);
  assert(services[0].instances[0].host == "10.0.1.10");
  assert(services[0].instances[2].host == "10.0.1.11");
  assert(services[0].instances[2].port == 9003);
}

@("peer orders longest prefix first") unittest {
  BackendService[] services;
  services = mergePeerTable(services, parsePeerRoutes(`{"h":[{"prefix":"/api","port":1},{"prefix":"/","port":9},` ~
    `{"prefix":"/api/edu","port":9002}]}`), "10.0.1.10");
  sortServices(services);
  assert(services[0].contentPath == "/api/edu");
  assert(services[1].contentPath == "/api");
  assert(services[2].contentPath == "/");
}

@("peer collects services from configured peers") unittest {
  auto root = "/tmp/setline-peer-collect-test";
  if (exists(root)) rmdirRecurse(root);
  scope (exit) if (exists(root)) rmdirRecurse(root);

  foreach (name; ["peerA", "peerB"]) {
    mkdirRecurse(buildPath(root, name, "_setline"));
  }
  write(buildPath(root, "peerA", "_setline", "routes"),
    `{"app.example.com":[{"prefix":"/api/edu","port":9002}]}`);
  write(buildPath(root, "peerB", "_setline", "routes"),
    `{"app.example.com":[{"prefix":"/api/edu","port":9002}]}`);

  AgentConfig agent;
  agent.type = "haproxy";
  agent.peers = [
    PeerConfig("peerA", "http://10.0.1.10:8080"),
    PeerConfig("peerB", "http://10.0.1.11:8080"),
  ];
  // 本地读取路由表，避免单测依赖网络。
  auto fetcher = (PeerConfig peer) {
    return parsePeerRoutes(readText(buildPath(root, peer.name, "_setline", "routes")));
  };

  auto services = collectPeerServices(agent, fetcher);
  assert(services.length == 1);
  assert(services[0].instances.length == 2);

  auto rendered = renderHaproxyBackends(services);
  // 标识只看 host + 前缀：两个 peer 的同一条路由合并成一个后端，谁先谁后都不该进名字。
  assert(rendered.canFind("backend b_app_example_com_api_edu"));
  assert(rendered.canFind("server app_example_com_api_edu_0 10.0.1.10:9002 check"));
  assert(rendered.canFind("server app_example_com_api_edu_1 10.0.1.11:9002 check"));
  assert(!rendered.canFind("\ndefaults"));
}

@("peer renders nginx upstreams and locations") unittest {
  BackendService[] services;
  services = mergePeerTable(services, parsePeerRoutes(`{"app.example.com":[{"prefix":"/api","port":9001}]}`),
    "10.0.1.10");
  sortServices(services);

  // 片段不带监听段：upstream 进 http{}，location 进主配置的 server{}。
  auto upstreams = renderNginxUpstreams(services);
  assert(upstreams.canFind("upstream app_example_com_api"));
  assert(!upstreams.canFind("listen "));

  auto locations = renderNginxLocations(services, "app.example.com");
  assert(locations.canFind("location /api {"));
  assert(locations.canFind("proxy_pass http://app_example_com_api;"));
}

@("peer writes snippet only when changed") unittest {
  auto path = "/tmp/setline-peer-snippet-test/out.conf";
  if (exists("/tmp/setline-peer-snippet-test")) rmdirRecurse("/tmp/setline-peer-snippet-test");
  scope (exit) if (exists("/tmp/setline-peer-snippet-test")) rmdirRecurse("/tmp/setline-peer-snippet-test");

  assert(writeSnippet(path, "one\n") == true);
  assert(readText(path) == "one\n");
  assert(writeSnippet(path, "one\n") == false);
  assert(writeSnippet(path, "two\n") == true);
  assert(readText(path) == "two\n");
}

@("peer renders local routes for a single-host agent") unittest {
  auto routes = parsePeerRoutes(`{"localhost":[{"prefix":"/tools","port":20000}],` ~
    `"*":[{"prefix":"/","port":9090}]}`);

  // 单机部署：路由表里的端口就在本机，回源主机固定 127.0.0.1。
  auto services = collectLocalServices(routes);
  assert(services.length == 2);
  auto tools = services[0].contentPath == "/tools" ? services[0] : services[1];
  assert(tools.instances.length == 1);
  assert(tools.instances[0].host == localBackendHost);
  assert(tools.instances[0].port == 20000);

  AgentConfig agent;
  agent.type = "haproxy";
  agent.output = "/tmp/setline-conf/local";
  auto snippets = renderAgentSnippets(agent, routes);
  assert(snippets.length == 2);
  assert(snippets[0].path == "/tmp/setline-conf/local/haproxy/setline.cfg");
  assert(snippets[0].text.canFind("backend b_localhost_tools"));
  assert(snippets[0].text.canFind("server localhost_tools_0 127.0.0.1:20000 check"));
  assert(snippets[1].path == "/tmp/setline-conf/local/haproxy/setline.map");
  assert(snippets[1].text.canFind("localhost~/tools b_localhost_tools"));
}

@("single-host agent renders business ports, never the setline listen port") unittest {
  auto path = "/tmp/setline-peer-local-listen-test.json";
  write(path, `{"listen":"*:18090",` ~
    `"routes":{"app.example.com":{"/api/edu":[9002,9003]}}}`);
  scope (exit) if (exists(path)) remove(path);

  // 数据面片段只认业务端口：haproxy 直接回源，setline 的 listen 只是控制面。
  ControlConfig control;
  control.agent.type = "haproxy";
  control.agent.output = "/tmp/setline-conf/local-listen";
  auto config = parseConfigFile(path, control);
  auto snippets = renderAgentSnippets(config.agent, config.routes);
  assert(snippets[0].text.canFind("server app_example_com_api_edu_0 127.0.0.1:9002 check"));
  assert(snippets[0].text.canFind("server app_example_com_api_edu_1 127.0.0.1:9003 check"));
  foreach (snippet; snippets) assert(!snippet.text.canFind("18090"));

  auto nginx = layoutSnippets(collectLocalServices(config.routes), "nginx",
    "/tmp/setline-conf/local-listen");
  assert(nginx.length == 2);
  foreach (snippet; nginx) assert(!snippet.text.canFind("18090"));
}

@("peer renders rules-only snippets without a listener") unittest {
  BackendService[] services;
  services = mergePeerTable(services, parsePeerRoutes(`{"app.example.com":[{"prefix":"/api/edu","port":9002}],` ~
    `"*":[{"prefix":"/","port":9090}]}`), "10.0.1.10");
  services = sortServices(services);

  auto haproxy = layoutSnippets(services, "haproxy", "/tmp/setline-conf");
  assert(haproxy.length == 2);
  assert(haproxy[0].path == "/tmp/setline-conf/haproxy/setline.cfg");
  assert(haproxy[0].text.canFind("backend b_app_example_com_api_edu"));
  assert(!haproxy[0].text.canFind("\nfrontend "));
  assert(!haproxy[0].text.canFind("bind "));
  assert(haproxy[1].path == "/tmp/setline-conf/haproxy/setline.map");
  assert(haproxy[1].text.canFind("app.example.com~/api/edu b_app_example_com_api_edu"));
  assert(haproxy[1].text.canFind("\n/ b_default\n"));

  auto nginx = layoutSnippets(services, "nginx", "/tmp/setline-conf");
  assert(nginx.length == 3);
  assert(nginx[0].path == "/tmp/setline-conf/nginx/setline.conf");
  assert(nginx[0].text.canFind("upstream app_example_com_api_edu"));
  assert(!nginx[0].text.canFind("listen "));
  assert(nginx[1].path == "/tmp/setline-conf/nginx/setline.app.example.com.conf");
  assert(nginx[1].text.canFind("location /api/edu {"));
  assert(nginx[2].path == "/tmp/setline-conf/nginx/setline.default.conf");
  assert(nginx[2].text.canFind("location / {"));
}

@("peer keeps snippet names relative when output root is unset") unittest {
  BackendService[] services;
  services = mergePeerTable(services, parsePeerRoutes(`{"app.example.com":[{"prefix":"/api","port":9001}]}`),
    "10.0.1.10");
  services = sortServices(services);

  // 没有 output 根目录 = 片段打到标准输出：路径只剩文件名，标题行才不会带一串目录。
  auto haproxy = layoutSnippets(services, "haproxy", "");
  assert(haproxy.length == 2);
  assert(haproxy[0].path == "setline.cfg");
  assert(haproxy[1].path == "setline.map");
  assert(haproxy[1].text.canFind("map_beg(setline.map)"));

  auto nginx = layoutSnippets(services, "nginx", "");
  assert(nginx.length == 2);
  assert(nginx[0].path == "setline.conf");
  assert(nginx[1].path == "setline.app.example.com.conf");

  assertThrown!Exception(layoutSnippets(services, "caddy", "/tmp/setline-conf"));
}
