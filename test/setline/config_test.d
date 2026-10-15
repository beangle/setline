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

@("config parses agent settings") unittest {
  auto path = "/tmp/setline-config-agent-test.json";
  write(path,
    `{"agent":{"type":"nginx","output":"/var/lib/setline",` ~
    `"peers":[{"url":"http://10.0.1.10:8080"}]},"routes":{}}`);
  scope (exit) remove(path);

  auto config = loadConfig(path);
  assert(config.agent.type == "nginx");
  assert(config.agent.output == "/var/lib/setline");
  assert(config.agent.peers.length == 1);
  assert(usesLocalRoutes(config.agent) == false);
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
}

@("config normalizes route hosts") unittest {
  assert(normalizeRouteHost("LOCAL1.EXAMPLE.COM") == "local1.example.com");
  assert(normalizeRouteHost("*") == "*");
  assert(normalizeRequestHost("LOCAL1.EXAMPLE.COM:8080") == "local1.example.com");
  assert(normalizeRequestHost("") == "*");
  assertThrown!Exception(normalizeRouteHost("local1.example.com:8080"));
}

@("config parses agent peers") unittest {
  auto path = "/tmp/setline-config-agent-peers-test.json";
  write(path,
    `{"agent":{"type":"haproxy","output":"/etc/haproxy",` ~
    `"peers":[{"name":"app1","url":"http://10.0.1.10:8080"},` ~
    `{"url":"http://10.0.1.11:8080"}]},"routes":{}}`);
  scope (exit) remove(path);

  auto config = loadConfig(path);
  assert(config.agent.type == "haproxy");
  assert(config.agent.output == "/etc/haproxy");
  assert(config.agent.peers.length == 2);
  assert(config.agent.peers[0].name == "app1");
  assert(config.agent.peers[0].url == "http://10.0.1.10:8080");
  assert(config.agent.peers[1].url == "http://10.0.1.11:8080");
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

  // 没有监听就没有读方，名单是死配置。
  write(path, `{"listen":false,"peerReaders":["10.0.1.7"],` ~
    `"agent":{"type":"haproxy","output":"/tmp/setline"},"routes":{}}`);
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
    `"output":"/var/lib/setline"},"routes":{}}`);
  scope (exit) remove(path);

  auto config = loadConfig(path);
  assert(config.agent.type == "haproxy");
  assert(config.agent.output == "/var/lib/setline");
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
  write(path, `{"agent":{"output":"/tmp/setline"},"routes":{}}`);
  assertThrown!Exception(loadConfig(path));
}

@("config requires an absolute agent output root") unittest {
  auto path = "/tmp/setline-config-agent-relative-output-test.json";
  scope (exit) remove(path);

  // output 是片段根目录（内部再拼 <type>/），相对路径会随 CWD 漂移，直接拦掉。
  write(path, `{"listen":"127.0.0.1:8080","agent":{"type":"haproxy","output":"setline"},"routes":{}}`);
  assertThrown!Exception(loadConfig(path));

  // 空字符串等同于没配：单机模式仍然要求一个根目录。
  write(path, `{"listen":"127.0.0.1:8080","agent":{"type":"haproxy","output":""},"routes":{}}`);
  assertThrown!Exception(loadConfig(path));
}

@("config rejects misspelled agent type") unittest {
  auto path = "/tmp/setline-config-agent-badtype-test.json";
  write(path, `{"agent":{"type":"nginux","peers":[{"url":"http://10.0.1.10:8080"}]},"routes":{}}`);
  scope (exit) remove(path);
  assertThrown!Exception(loadConfig(path));
}

@("config accepts listen false for a render-only deployment") unittest {
  auto path = "/tmp/setline-config-listen-false-test.json";
  write(path, `{"listen":false,"agent":{"type":"haproxy",` ~
    `"output":"/var/lib/setline"},"routes":{"app.example.com":{"/":9001}}}`);
  scope (exit) remove(path);

  auto config = loadConfig(path);
  assert(config.listenDisabled);
  assert(config.routes.length == 1);
}

@("config requires an agent when listen is false") unittest {
  auto path = "/tmp/setline-config-listen-false-bad-test.json";
  scope (exit) remove(path);

  // 不监听又没有 agent：进程既没有监听入口，也没有片段要渲染，什么都不会做。
  write(path, `{"listen":false,"routes":{"app.example.com":{"/":9001}}}`);
  assertThrown!Exception(loadConfig(path));

  // `true` 不是合法值：能监听就必须写地址。
  write(path, `{"listen":true,"agent":{"type":"haproxy","output":"/tmp/setline"}}`);
  assertThrown!Exception(loadConfig(path));
}

@("config reads the access log switch") unittest {
  auto path = "/tmp/setline-config-accesslog-test.json";
  write(path, `{"listen":"127.0.0.1:8080","accessLog":true,"routes":{}}`);
  scope (exit) remove(path);
  assert(loadConfig(path).accessLog);

  // 默认关闭，且非布尔值必须报错。
  write(path, `{"listen":"127.0.0.1:8080","routes":{}}`);
  assert(!loadConfig(path).accessLog);
  write(path, `{"listen":"127.0.0.1:8080","accessLog":"yes","routes":{}}`);
  assertThrown!Exception(loadConfig(path));
}

@("config always gives the admin API its own listener") unittest {
  auto path = "/tmp/setline-config-adminlisten-test.json";
  scope (exit) remove(path);

  // 不写 adminListen 就用默认值：绑回环的 10080（写只在这个口上），数据面照旧只绑它自己
  // 的地址。
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
  write(path, `{"listen":"127.0.0.1:10080","routes":{}}`);
  assertThrown!Exception(loadConfig(path));

  write(path, `{"listen":"127.0.0.1:8080","adminListen":true,"routes":{}}`);
  assertThrown!Exception(loadConfig(path));

  // 显式 false 不再表示「和数据面共用」：管理接口永远有独立监听。
  write(path, `{"listen":"127.0.0.1:8080","adminListen":false,"routes":{}}`);
  assertThrown!Exception(loadConfig(path));

  // listen:false 是渲染完就退出，没有进程来服务这个管理监听。
  write(path, `{"listen":false,"adminListen":"127.0.0.1:8081",` ~
    `"agent":{"type":"haproxy","output":"/tmp/setline"},"routes":{}}`);
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

  // 没有发布过，所以不为「曾经打算加」的键留兼容分支：配置里多出来的键既不报错也不生效，
  // 与其它未知键一个待遇（这条钉住的是行为，不是某个具体键）。
  write(path, `{"listen":"127.0.0.1:8080","adminToken":"secret","peerReaders":["10.0.1.7"],` ~
    `"agent":{"type":"nginx","output":"/var/lib/setline","bind":"*:8080",` ~
    `"sync":{"mode":"interval"},"token":"shared"},` ~
    `"peers":[{"url":"http://10.0.1.10:8080"}],"routes":{}}`);
  auto config = loadConfig(path);
  assert(config.agent.type == "nginx");
  assert(config.peerReaders == ["10.0.1.7"]);
}
