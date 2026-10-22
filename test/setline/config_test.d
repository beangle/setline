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

import std.algorithm : canFind;
import std.conv : to;
import std.file : readText, remove, write;
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
  assert(config.readTimeoutMillis == 15000);
  assert(config.maxConnections == 65535);
  assert(!config.reusePort);
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
    `{"connectTimeoutMillis":1500,"readTimeoutMillis":900,"maxConnections":128,"reusePort":true,` ~
    `"healthCheck":{"intervalMillis":2000,"timeoutMillis":300,"unhealthyThreshold":3,"healthyThreshold":2},` ~
    `"routes":{}}`);
  scope (exit) remove(path);

  auto config = loadConfig(path);
  assert(config.connectTimeoutMillis == 1500);
  assert(config.readTimeoutMillis == 900);
  assert(config.maxConnections == 128);
  assert(config.reusePort);
  assert(config.healthCheck.intervalMillis == 2000);
  assert(config.healthCheck.timeoutMillis == 300);
  assert(config.healthCheck.unhealthyThreshold == 3);
  assert(config.healthCheck.healthyThreshold == 2);
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
    `{"listen":"127.0.0.1:8080","peerReaders":["10.0.1.7"],` ~
    `"routes":{"local.example.com":{"/old":9000}}}`);
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
  assert(config.peerReaders == ["10.0.1.7"]);
  assert(config.routes.length == 1);
  assert(config.routes[0].host == "local.example.com");
  assert(config.routes[0].routes[0].prefix == "/api/edu");
  assert(config.routes[0].routes[1].prefix == "/api");

  // 写回的配置是给人改、给 diff/grep 看的，所以直接检查文本：2 空格缩进、键排序、
  // 路径不转义成 `\/api\/edu`。读回来能对上只说明 JSON 合法，证明不了这几点。
  auto text = readText(path);
  assert(text.canFind("\n  \"listen\": \"127.0.0.1:8080\",\n"), text);
  assert(text.canFind("\n  \"peerReaders\": [\n    \"10.0.1.7\"\n  ],\n"), text);
  assert(text.canFind("\n      \"/api/edu\": [\n        9002,\n        9003\n      ]\n"), text);
  assert(!text.canFind(`\/`), text);
}

@("config pretty prints json with two space indentation") unittest {
  auto value = parseJSON(`{"b":{"x":[1,2]},"a":{},"c":[],"d":"--","e":true,"f":null}`);
  assert(prettyJson(value) ==
    `{
  "a": {},
  "b": {
    "x": [
      1,
      2
    ]
  },
  "c": [],
  "d": "--",
  "e": true,
  "f": null
}`);
}

@("config pretty prints paths and escapes quotes without escaping slashes") unittest {
  auto value = parseJSON(`{"/var/lib/setline":"a\"b\\c"}`);
  assert(prettyJson(value) ==
    `{
  "/var/lib/setline": "a\"b\\c"
}`);
}

@("config normalizes route hosts") unittest {
  assert(normalizeRouteHost("LOCAL1.EXAMPLE.COM") == "local1.example.com");
  assert(normalizeRouteHost("*") == "*");
  assert(normalizeRequestHost("LOCAL1.EXAMPLE.COM:8080") == "local1.example.com");
  assert(normalizeRequestHost("") == "*");
  assertThrown!Exception(normalizeRouteHost("local1.example.com:8080"));
}

@("config parses the peer readers allowed to read the route table") unittest {
  auto path = "/tmp/setline-config-peerreaders-test.json";
  scope (exit) remove(path);

  write(path, `{"listen":"*:8080","peerReaders":["10.0.1.7"," ::FFFF:10.0.1.8 ","fe80::1"],` ~
    `"routes":{}}`);
  auto config = loadConfig(path);
  // 写法归一化：去空白、转小写、去掉 IPv4-mapped 前缀，之后按文本比较。
  assert(config.peerReaders == ["10.0.1.7", "10.0.1.8", "fe80::1"]);

  write(path, `{"listen":"*:8080","routes":{}}`);
  assert(loadConfig(path).peerReaders.length == 0);
}

@("config rejects unusable peer readers") unittest {
  auto path = "/tmp/setline-config-peerreaders-bad-test.json";
  scope (exit) remove(path);

  // 主机名：配置解析会变成一次 DNS 查询，解析出来的地址和 TCP 对端也未必是同一个。
  write(path, `{"listen":"*:8080","peerReaders":["app1.internal"],"routes":{}}`);
  assertThrown!Exception(loadConfig(path));

  // CIDR：要按位比较，规则就不再是「一行地址」。
  write(path, `{"listen":"*:8080","peerReaders":["10.0.1.0/24"],"routes":{}}`);
  assertThrown!Exception(loadConfig(path));

  // 回环：本机来源本来就放行，列上它只会让经本机代理转发的请求也变成读方。
  write(path, `{"listen":"*:8080","peerReaders":["127.0.0.1"],"routes":{}}`);
  assertThrown!Exception(loadConfig(path));
  write(path, `{"listen":"*:8080","peerReaders":["::1"],"routes":{}}`);
  assertThrown!Exception(loadConfig(path));

  write(path, `{"listen":"*:8080","peerReaders":[],"routes":{}}`);
  assertThrown!Exception(loadConfig(path));
  write(path, `{"listen":"*:8080","peerReaders":"10.0.1.7","routes":{}}`);
  assertThrown!Exception(loadConfig(path));
  write(path, `{"listen":"*:8080","peerReaders":[7000],"routes":{}}`);
  assertThrown!Exception(loadConfig(path));

  write(path, `{"listen":"*:8080","peerReaders":["app1.internal","10.0.1.7"],"routes":{}}`);
  assertThrown!Exception(loadConfig(path));
}

@("config rejects agent parameters in the topology file") unittest {
  auto path = "/tmp/setline-config-agent-local-bad-test.json";
  scope (exit) remove(path);

  // agent 只存在于 setline.conf；setline.json 里出现任何 agent 都必须报错。
  write(path, `{"agent":{"peers":[]},"routes":{}}`);
  assertThrown!Exception(loadConfig(path));
  write(path, `{"agent":{},"routes":{}}`);
  assertThrown!Exception(loadConfig(path));
}

@("config rejects listen false in the service config") unittest {
  auto path = "/tmp/setline-config-listen-false-test.json";
  scope (exit) remove(path);

  // 纯渲染入口已经属于 setline-agent，setline 服务始终需要监听地址。
  write(path, `{"listen":false,"routes":{"app.example.com":{"/":9001}}}`);
  assertThrown!Exception(loadConfig(path));

  // `true` 同样不是合法值：能监听就必须写地址。
  write(path, `{"listen":true,"routes":{}}`);
  assertThrown!Exception(loadConfig(path));
}

@("config always gives the admin API its own listener") unittest {
  auto path = "/tmp/setline-config-adminlisten-test.json";
  scope (exit) remove(path);

  // 不写 adminListen 就用默认值：绑回环的 defaultAdminPort（写只在这个口上），数据面照旧
  // 只绑它自己的地址。
  write(path, `{"listen":"127.0.0.1:8080","routes":{}}`);
  auto defaulted = loadConfig(path);
  assert(defaulted.adminListen.host == "127.0.0.1");
  assert(defaulted.adminListen.port == defaultAdminPort);

  write(path, `{"listen":"127.0.0.1:8080","adminListen":"*:8081","routes":{}}`);
  auto explicitAddress = loadConfig(path);
  assert(explicitAddress.adminListen.host == "0.0.0.0");
  assert(explicitAddress.adminListen.port == 8081);

  // 和 listen 一样接受裸端口。
  write(path, `{"listen":"127.0.0.1:8080","adminListen":8082,"routes":{}}`);
  assert(loadConfig(path).adminListen.port == 8082);
}

@("config rejects an unusable adminListen") unittest {
  auto path = "/tmp/setline-config-adminlisten-bad-test.json";
  scope (exit) remove(path);

  // 同一个地址会抢端口，启动时必然 EADDRINUSE，直接在配置层拦掉。
  write(path, `{"listen":"127.0.0.1:8080","adminListen":"127.0.0.1:8080","routes":{}}`);
  assertThrown!Exception(loadConfig(path));
  write(path, `{"listen":"*:8080","adminListen":"127.0.0.1:8080","routes":{}}`);
  assertThrown!Exception(loadConfig(path));

  // 缺省管理端口同样不能给数据面用，报错要指出冲突来自缺省值。
  write(path, `{"listen":"127.0.0.1:` ~ defaultAdminPort.to!string ~ `","routes":{}}`);
  assertThrown!Exception(loadConfig(path));

  write(path, `{"listen":"127.0.0.1:8080","adminListen":true,"routes":{}}`);
  assertThrown!Exception(loadConfig(path));

  // 显式 false 不再表示「和数据面共用」：管理接口永远有独立监听。
  write(path, `{"listen":"127.0.0.1:8080","adminListen":false,"routes":{}}`);
  assertThrown!Exception(loadConfig(path));

  // listen:false 已从服务拓扑移除：纯渲染由 setline-agent 负责。
  write(path, `{"listen":false,"adminListen":"127.0.0.1:8081",` ~
    `"routes":{}}`);
  assertThrown!Exception(loadConfig(path));
}

@("config reads the websocket idle timeout") unittest {
  auto path = "/tmp/setline-config-wsidle-test.json";
  scope (exit) remove(path);

  // 默认 0：不主动断开隧道，长连接空闲多久由业务和前置代理决定。
  write(path, `{"listen":"127.0.0.1:8080","routes":{}}`);
  assert(loadConfig(path).webSocketIdleTimeoutMillis == 0);

  write(path, `{"listen":"127.0.0.1:8080","webSocketIdleTimeoutMillis":500,"routes":{}}`);
  assert(loadConfig(path).webSocketIdleTimeoutMillis == 500);

  // 0 本身合法（显式关闭），负数不是。
  write(path, `{"listen":"127.0.0.1:8080","webSocketIdleTimeoutMillis":0,"routes":{}}`);
  assert(loadConfig(path).webSocketIdleTimeoutMillis == 0);
  write(path, `{"listen":"127.0.0.1:8080","webSocketIdleTimeoutMillis":-1,"routes":{}}`);
  assertThrown!Exception(loadConfig(path));
}

@("config ignores keys it does not define") unittest {
  auto path = "/tmp/setline-config-unknown-keys-test.json";
  scope (exit) remove(path);

  // 顶层未知键既不报错也不生效；agent 已经从 setline.json 移除并在解析时明确拒绝。
  write(path, `{"listen":"127.0.0.1:8080","adminToken":"secret","peerReaders":["10.0.1.7"],` ~
    `"routes":{}}`);
  auto config = loadConfig(path);
  assert(config.peerReaders == ["10.0.1.7"]);
}
