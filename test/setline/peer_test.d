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
import std.file : exists, mkdirRecurse, readText, rmdirRecurse, write;
import std.path : buildPath;

import setline.edge;
import setline.model;
import setline.peer;

@("peer derives routes url and backend address") unittest {
  assert(peerRoutesUrl(peerWithUrl("http://10.0.1.10:8080"))
    == "http://10.0.1.10:8080/__setline/routes");
  assert(peerRoutesUrl(peerWithUrl("http://10.0.1.10:8080/"))
    == "http://10.0.1.10:8080/__setline/routes");
  assert(peerRoutesUrl(peerWithUrl("http://10.0.1.10:8080/__setline/routes"))
    == "http://10.0.1.10:8080/__setline/routes");
  assert(peerAddress(peerWithUrl("http://10.0.1.10:8080")) == "10.0.1.10");
  assert(peerAddress(peerWithUrl("10.0.1.10:8080")) == "10.0.1.10");
  assert(peerAddress(peerWithUrl("http://[fe80::1]:8080")) == "[fe80::1]");
  assert(peerAddress(peerWithUrl("http://app.example.com/__setline/routes")) == "app.example.com");
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
    "10.0.1.10", "app1");
  services = mergePeerTable(services,
    parsePeerRoutes(`{"app.example.com":[{"prefix":"/api/edu","ports":[9002,9003]}]}`), "10.0.1.11", "app2");
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
    `{"prefix":"/api/edu","port":9002}]}`), "10.0.1.10", "app");
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
    mkdirRecurse(buildPath(root, name, "__setline"));
  }
  write(buildPath(root, "peerA", "__setline", "routes"),
    `{"app.example.com":[{"prefix":"/api/edu","port":9002}]}`);
  write(buildPath(root, "peerB", "__setline", "routes"),
    `{"app.example.com":[{"prefix":"/api/edu","port":9002}]}`);

  AgentConfig agent;
  agent.type = "haproxy";
  agent.peers = [
    PeerConfig("peerA", "http://10.0.1.10:8080", ""),
    PeerConfig("peerB", "http://10.0.1.11:8080", ""),
  ];
  // 本地读取路由表，避免单测依赖网络。
  auto fetcher = (PeerConfig peer, string token) {
    return parsePeerRoutes(readText(buildPath(root, peer.name, "__setline", "routes")));
  };

  auto services = collectPeerServices(agent, fetcher);
  assert(services.length == 1);
  assert(services[0].instances.length == 2);

  auto rendered = renderProxyConfig(services, agent.type, agent.bind);
  assert(rendered.canFind("backend be_peerA_app_example_com_api_edu"));
  assert(rendered.canFind("server peerA_app_example_com_api_edu_0 10.0.1.10:9002 check"));
  assert(rendered.canFind("server peerA_app_example_com_api_edu_1 10.0.1.11:9002 check"));
  assert(!rendered.canFind("\ndefaults"));
}

@("peer renders nginx fragment with include hint") unittest {
  BackendService[] services;
  services = mergePeerTable(services, parsePeerRoutes(`{"app.example.com":[{"prefix":"/api","port":9001}]}`),
    "10.0.1.10", "app");
  sortServices(services);

  auto rendered = renderProxyConfig(services, "nginx", "*:8080");
  assert(rendered.canFind("upstream"));
  assert(rendered.canFind("listen 8080;"));
  assert(rendered.canFind("Include this file inside the nginx http {} block."));
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
