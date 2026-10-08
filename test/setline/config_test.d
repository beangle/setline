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

module setline.config_test;

import std.file : remove, write;
import std.exception : assertThrown;
import std.json : JSONValue, parseJSON;

import setline.config;
import setline.model;

@("config parses listen shorthand") unittest {
  auto byNumber = parseListen(JSONValue(8080));
  assert(byNumber.host == "127.0.0.1");
  assert(byNumber.port == 8080);

  auto byString = parseListen("9090");
  assert(byString.host == "127.0.0.1");
  assert(byString.port == 9090);

  auto wildcard = parseListen("*:8080");
  assert(wildcard.host == "0.0.0.0");
  assert(wildcard.port == 8080);

  auto explicit = parseListen("127.0.0.1:7070");
  assert(explicit.host == "127.0.0.1");
  assert(explicit.port == 7070);
}

@("config normalizes route prefixes") unittest {
  assert(normalizeRoutePrefix("/") == "/");
  assert(normalizeRoutePrefix("/m/edu/learning/") == "/m/edu/learning");
  assert(normalizeRoutePrefix("/m/edu/learning///") == "/m/edu/learning");

  auto route = parseRoute("/api/", JSONValue(9001));
  assert(route.prefix == "/api");
}

@("config parses single route object") unittest {
  auto route = parseSingleRoute(parseJSON(`{"/api/edu/":[9002,9003]}`));
  assert(route.prefix == "/api/edu");
  assert(route.ports == [9002, 9003]);

  assertThrown!Exception(parseSingleRoute(parseJSON(`{"/api":9001,"/m":9002}`)));
}

@("config keeps large default connection limit") unittest {
  auto path = "/tmp/setline-config-defaults-test.json";
  write(path, `{"listen":"127.0.0.1:8080","routes":{}}`);
  scope (exit) remove(path);

  auto config = loadConfig(path);
  assert(config.connectTimeoutMillis == 3000);
  assert(config.maxConnections == 65535);
}

@("config check requires existing file") unittest {
  assertThrown!Exception(checkConfig("/tmp/setline-config-missing-test.json"));
}

@("config check accepts valid file") unittest {
  auto path = "/tmp/setline-config-check-test.json";
  write(path, `{"listen":"127.0.0.1:8080","routes":{"local.example.com":{"/api":9001}}}`);
  scope (exit) remove(path);

  auto config = checkConfig(path);
  assert(config.listen.port == 8080);
  assert(config.routes.length == 1);
}

@("config parses connection protection settings") unittest {
  auto path = "/tmp/setline-config-protection-test.json";
  write(path,
    `{"connectTimeoutMillis":1500,"maxConnections":128,` ~
    `"healthCheck":{"intervalMillis":2000,"timeoutMillis":300,"unhealthyThreshold":3,"healthyThreshold":2},` ~
    `"routes":{}}`);
  scope (exit) remove(path);

  auto config = loadConfig(path);
  assert(config.connectTimeoutMillis == 1500);
  assert(config.maxConnections == 128);
  assert(config.healthCheck.intervalMillis == 2000);
  assert(config.healthCheck.timeoutMillis == 300);
  assert(config.healthCheck.unhealthyThreshold == 3);
  assert(config.healthCheck.healthyThreshold == 2);
}

@("config parses agent settings") unittest {
  auto path = "/tmp/setline-config-agent-test.json";
  write(path,
    `{"agent":{"type":"nginx","remote":"https://registry.example.com/latest.json","workDir":"/var/lib/setline-agent"},` ~
    `"routes":{}}`);
  scope (exit) remove(path);

  auto config = loadConfig(path);
  assert(config.agent.type == "nginx");
  assert(config.agent.url == "https://registry.example.com/latest.json");
  assert(config.agent.workDir == "/var/lib/setline-agent");
}

@("config parses route ports") unittest {
  auto path = "/tmp/setline-config-routes-test.json";
  write(path, `{"routes":{"local.example.com":{"/api":9001,"/api/edu":[9002,9003]}}}`);
  scope (exit) remove(path);

  auto config = loadConfig(path);
  assert(config.routes.length == 1);
  assert(config.routes[0].host == "local.example.com");
  assert(config.routes[0].routes[0].prefix == "/api/edu");
  assert(config.routes[0].routes[0].ports[0] == 9002);
  assert(config.routes[0].routes[0].ports[1] == 9003);
  assert(config.routes[0].routes[1].prefix == "/api");
  assert(config.routes[0].routes[1].ports[0] == 9001);
}

@("config normalizes route prefixes from file") unittest {
  auto path = "/tmp/setline-config-normalized-routes-test.json";
  write(path, `{"routes":{"local.example.com":{"/api/":9001,"/api/edu/":[9002,9003]}}}`);
  scope (exit) remove(path);

  auto config = loadConfig(path);
  assert(config.routes[0].routes[0].prefix == "/api/edu");
  assert(config.routes[0].routes[1].prefix == "/api");
}

@("config saves routes while preserving other fields") unittest {
  auto path = "/tmp/setline-config-save-routes-test.json";
  write(path,
    `{"listen":"127.0.0.1:8080","adminToken":"secret","routes":{"local.example.com":{"/old":9000}}}`);
  scope (exit) remove(path);

  saveRoutes(path, [
    HostRoutes("local.example.com", [
      Route("/api", [9001]),
      Route("/api/edu", [
        9002,
        9003
      ])
    ])
  ]);

  auto config = loadConfig(path);
  assert(config.adminToken == "secret");
  assert(config.routes.length == 1);
  assert(config.routes[0].host == "local.example.com");
  assert(config.routes[0].routes[0].prefix == "/api/edu");
  assert(config.routes[0].routes[1].prefix == "/api");
}

@("config normalizes route hosts") unittest {
  assert(normalizeRouteHost("LOCAL1.EXAMPLE.COM") == "local1.example.com");
  assert(normalizeRouteHost("*") == "*");
  assert(normalizeRequestHost("LOCAL1.EXAMPLE.COM:8080") == "local1.example.com");
  assert(normalizeRequestHost("") == "*");
  assertThrown!Exception(normalizeRouteHost("local1.example.com:8080"));
}

@("config parses agent peers and sync") unittest {
  auto path = "/tmp/setline-config-agent-peers-test.json";
  write(path,
    `{"agent":{"type":"haproxy","output":"/etc/haproxy/setline.cfg","bind":"*:8080",` ~
    `"token":"shared","sync":{"mode":"interval","intervalMillis":15000},` ~
    `"peers":[{"name":"app1","url":"http://10.0.1.10:8080"},` ~
    `{"url":"http://10.0.1.11:8080","token":"peer2"}]},"routes":{}}`);
  scope (exit) remove(path);

  auto config = loadConfig(path);
  assert(config.agent.type == "haproxy");
  assert(config.agent.output == "/etc/haproxy/setline.cfg");
  assert(config.agent.bind == "*:8080");
  assert(config.agent.token == "shared");
  assert(config.agent.sync.mode == "interval");
  assert(config.agent.sync.intervalMillis == 15000);
  assert(config.agent.peers.length == 2);
  assert(config.agent.peers[0].name == "app1");
  assert(config.agent.peers[0].url == "http://10.0.1.10:8080");
  assert(config.agent.peers[1].token == "peer2");
}

@("config rejects bad agent sync mode") unittest {
  auto path = "/tmp/setline-config-agent-badsync-test.json";
  write(path, `{"agent":{"type":"nginx","peers":[{"url":"http://10.0.1.10:8080"}],` ~
    `"sync":{"mode":"sometimes"}},"routes":{}}`);
  scope (exit) remove(path);
  assertThrown!Exception(loadConfig(path));
}

@("config rejects peer url without derivable address") unittest {
  auto path = "/tmp/setline-config-agent-noaddress-test.json";
  write(path, `{"agent":{"type":"nginx","peers":[{"url":"file:///tmp/peer"}]},"routes":{}}`);
  scope (exit) remove(path);
  assertThrown!Exception(loadConfig(path));

  write(path, `{"agent":{"type":"nginx","peers":[{"url":"/tmp/peer"}]},"routes":{}}`);
  assertThrown!Exception(loadConfig(path));
}

@("config rejects unknown peer fields") unittest {
  auto path = "/tmp/setline-config-agent-badpeer-test.json";
  // 曾经的 address 字段已经取消：回源主机只从 url 推导，写了必须报错而不是被忽略。
  write(path, `{"agent":{"type":"nginx","peers":[{"url":"http://10.0.1.10:8080","address":"10.0.1.10"}]},` ~
    `"routes":{}}`);
  scope (exit) remove(path);
  assertThrown!Exception(loadConfig(path));

  write(path, `{"agent":{"type":"nginx","peers":[{"url":"http://10.0.1.10:8080","port":80}]},"routes":{}}`);
  assertThrown!Exception(loadConfig(path));
}

@("config allows single-host agent without peers") unittest {
  auto path = "/tmp/setline-config-agent-local-test.json";
  write(path, `{"listen":"127.0.0.1:8080","agent":{"type":"haproxy",` ~
    `"output":"/var/lib/setline/haproxy/setline.cfg"},"routes":{}}`);
  scope (exit) remove(path);

  auto config = loadConfig(path);
  assert(config.agent.type == "haproxy");
  assert(config.agent.output == "/var/lib/setline/haproxy/setline.cfg");
  assert(config.agent.peers.length == 0);
  assert(usesLocalRoutes(config.agent));
}

@("config rejects single-host agent without output or type") unittest {
  auto path = "/tmp/setline-config-agent-local-bad-test.json";
  scope (exit) remove(path);

  // 单机模式必须有 output：否则每次改路由都会把片段重新打到标准输出。
  write(path, `{"agent":{"type":"nginx"},"routes":{}}`);
  assertThrown!Exception(loadConfig(path));

  // 有 output 也不能省 type：由它决定渲染 haproxy 还是 nginx。
  write(path, `{"agent":{"output":"/tmp/setline.conf"},"routes":{}}`);
  assertThrown!Exception(loadConfig(path));
}

@("config rejects misspelled agent type") unittest {
  auto path = "/tmp/setline-config-agent-badtype-test.json";
  write(path, `{"agent":{"type":"nginux","remote":"https://registry.example.com/latest.json"},"routes":{}}`);
  scope (exit) remove(path);
  assertThrown!Exception(loadConfig(path));
}

@("config allows rules-only agent without bind") unittest {
  auto path = "/tmp/setline-config-agent-nobind-test.json";
  write(path, `{"agent":{"type":"nginx","output":"/var/lib/setline/nginx/setline.conf",` ~
    `"peers":[{"url":"http://10.0.1.10:8080"}]},"routes":{}}`);
  scope (exit) remove(path);
  assert(loadConfig(path).agent.bind == "");
}

@("config rejects agent with both remote and peers") unittest {
  auto path = "/tmp/setline-config-agent-both-test.json";
  write(path, `{"agent":{"type":"nginx","remote":"https://registry.example.com/latest.json",` ~
    `"peers":[{"url":"http://10.0.1.10:8080"}]},"routes":{}}`);
  scope (exit) remove(path);
  assertThrown!Exception(loadConfig(path));
}
