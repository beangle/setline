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

module setline.state_test;

import std.file : remove, write;

import setline.config;
import setline.health;
import setline.model;
import setline.state;
import setline.test_lock;
import setline.util : requiredFileDescriptorBudget;

@("util calculates fd budget as two sockets per connection plus overhead") unittest {
  assert(requiredFileDescriptorBudget(1) == 66);
  assert(requiredFileDescriptorBudget(65535) == 131134);
}

@("state enforces max active connections") unittest {
  withStateTestLock({
    Config config;
    config.maxConnections = 1;
    initialize(config);

    assert(maxConnections() == 1);
    assert(activeConnections() == 0);
    assert(tryAcquireConnection());
    assert(activeConnections() == 1);
    assert(!tryAcquireConnection());

    releaseConnection();
    assert(activeConnections() == 0);
    assert(tryAcquireConnection());
    releaseConnection();
  });
}

@("state persists runtime route changes") unittest {
  withStateTestLock({
    auto path = "/tmp/setline-state-persist-routes-test.json";
    write(path, `{"listen":"127.0.0.1:8080","routes":{"local.example.com":{"/old":9000}}}`);
    scope (exit) remove(path);

    Config config;
    config.routes = [HostRoutes("local.example.com", [Route("/old", [9000])])];
    initialize(config, path);

    replaceRoutes("local.example.com", [Route("/new", [9001])]);

    auto saved = loadConfig(path);
    assert(saved.routes.length == 1);
    assert(saved.routes[0].host == "local.example.com");
    assert(saved.routes[0].routes[0].prefix == "/new");
    assert(saved.routes[0].routes[0].ports[0] == 9001);
  });
}

@("state selects routes by host") unittest {
  withStateTestLock({
    Config config;
    config.routes = [
      HostRoutes("local1.example.com", [Route("/api", [9080])]),
      HostRoutes("local2.example.com", [Route("/api", [9081])]),
      HostRoutes("*", [
        Route("/api", [9090]),
        Route("/m", [9091])
      ])
    ];
    initialize(config);

    assert(selectPort("local1.example.com", "/api/users") == 9080);
    assert(selectPort("local1.example.com", "/m/edu") == 9091);
    assert(selectPort("local2.example.com", "/api/users") == 9081);
    assert(selectPort("missing.example.com", "/api/users") == 9090);

    // 客户端连接亲和复用上游连接前会用这个函数复核一次：端口还在路由里且健康才复用。
    assert(isRoutedPort("local1.example.com", "/api/users", 9080));
    assert(isRoutedPort("missing.example.com", "/api/users", 9090));
    assert(!isRoutedPort("local1.example.com", "/api/users", 9081));
    assert(!isRoutedPort("local1.example.com", "/api/users", 9999));

    updatePortHealth(9080, false);
    updatePortHealth(9080, false);
    assert(selectPort("local1.example.com", "/api/users") == 0);
    assert(!isRoutedPort("local1.example.com", "/api/users", 9080));

    auto snapshot = routesSnapshot();
    snapshot[0].routes[0].ports[0] = 1;
    assert(selectPort("missing.example.com", "/api/users") == 9090);
  });
}

@("state notifies route changes to the hook") unittest {
  withStateTestLock({
    Config config;
    config.routes = [HostRoutes("local.example.com", [Route("/old", [9000])])];
    initialize(config);

    HostRoutes[] last;
    setRoutesChangedHook((HostRoutes[] routes) { last = routes; });
    scope (exit) setRoutesChangedHook(null);

    // 回调拿到的是写入后的新表，而不是旧状态。
    replaceRoutes("local.example.com", [Route("/new", [9001])]);
    assert(last.length == 1);
    assert(last[0].routes.length == 1);
    assert(last[0].routes[0].prefix == "/new");
    assert(last[0].routes[0].ports == [9001]);

    // 取消订阅后不再触发。
    last = [];
    setRoutesChangedHook(null);
    replaceRoutes("local.example.com", [Route("/again", [9002])]);
    assert(last.length == 0);
  });
}

@("state counts pool hits, connects, timeouts and per-port requests") unittest {
  withStateTestLock({
    Config config;
    initialize(config);

    notePoolHit();
    notePoolHit();
    noteUpstreamConnect();
    noteUpstreamTimeout();
    noteRequestPort(9001);
    noteRequestPort(9001);
    noteRequestPort(9002);

    assert(poolHitCount() == 2);
    assert(upstreamConnectCount() == 1);
    assert(upstreamTimeoutCount() == 1);
    auto ports = portRequestCounts();
    assert(ports[9001] == 2);
    assert(ports[9002] == 1);

    // 重新初始化（相当于重启）要把累计计数清零。
    initialize(config);
    assert(poolHitCount() == 0);
    assert(upstreamConnectCount() == 0);
    assert(portRequestCounts().length == 0);
  });
}

@("state counts websocket tunnels, bytes and idle timeouts") unittest {
  withStateTestLock({
    Config config;
    config.webSocketIdleTimeoutMillis = 750;
    initialize(config);

    assert(webSocketIdleTimeoutMillis() == 750);
    assert(activeWebSockets() == 0);

    noteWebSocketOpen();
    noteWebSocketOpen();
    assert(webSocketTunnelCount() == 2);
    assert(activeWebSockets() == 2);

    noteWebSocketBytesToUpstream(11);
    noteWebSocketBytesToUpstream(4);
    noteWebSocketBytesToClient(7);
    assert(webSocketBytesToUpstream() == 15);
    assert(webSocketBytesToClient() == 7);
    assert(webSocketIdleTimeoutCount() == 0);

    // 隧道关闭要把活跃数降回去，否则优雅退出和状态页都会一直以为还有隧道。
    noteWebSocketClose();
    noteWebSocketIdleTimeout();
    noteWebSocketClose();
    assert(activeWebSockets() == 0);
    assert(webSocketIdleTimeoutCount() == 1);
    assert(webSocketTunnelCount() == 2);

    // 重启清零，但空闲超时配置默认是 0（不断开）。
    initialize(Config.init);
    assert(webSocketTunnelCount() == 0);
    assert(webSocketIdleTimeoutCount() == 0);
    assert(webSocketBytesToClient() == 0);
    assert(webSocketIdleTimeoutMillis() == 0);
  });
}

@("health counts a port going unhealthy once per transition") unittest {
  withStateTestLock({
    Config config;
    config.healthCheck.unhealthyThreshold = 2;
    config.routes = [HostRoutes("*", [Route("/", [9001])])];
    initializeHealth(config);

    updatePortHealth(9001, false);
    assert(unhealthyTransitionCount() == 0);
    updatePortHealth(9001, false);
    assert(unhealthyTransitionCount() == 1);
    // 已经离线，继续失败不再重复计数。
    updatePortHealth(9001, false);
    assert(unhealthyTransitionCount() == 1);
  });
}
