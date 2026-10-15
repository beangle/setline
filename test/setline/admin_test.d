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

module setline.admin_test;

import std.conv : to;
import std.json : JSONType, JSONValue;
import std.string : indexOf;

import setline.admin;
import setline.config : normalizeRoutePrefix;
import setline.health;
import setline.model;
import setline.state;
import setline.test_lock;
import setline.util : escapeHtml;

@("admin parses the request host down to a name") unittest {
  assert(hostNameOf("127.0.0.1:8080") == "127.0.0.1");
  assert(hostNameOf("LOCALHOST") == "localhost");
  assert(hostNameOf("[::1]:8080") == "::1");
  assert(hostNameOf("::1") == "::1");
  assert(hostNameOf("app.example.com") == "app.example.com");
  assert(hostNameOf("") == "");
  assert(hostNameOf("[::1") == "");

  assert(isLoopbackHostName("127.0.0.1:8080"));
  assert(isLoopbackHostName("localhost"));
  assert(isLoopbackHostName("[::1]"));
  assert(!isLoopbackHostName("app.example.com"));
  assert(!isLoopbackHostName("127.0.0.1.evil.test"));
  assert(!isLoopbackHostName(""));
}

@("admin only treats loopback peers with a loopback host as local") unittest {
  // 本机 + 回环 Host：本机来源
  assert(isLoopbackRequestHost("GET /_setline/routes HTTP/1.1\r\nHost: 127.0.0.1:8080\r\n\r\n"));
  assert(isLoopbackRequestHost("GET /_setline/routes HTTP/1.1\r\nHost: localhost\r\n\r\n"));

  // 经本机代理转发的远端请求带着公开主机名：不算本机（借用 micdn getOrigin 的口径先看
  // X-Forwarded-Host，再看 Host）。
  assert(!isLoopbackRequestHost("GET /_setline/routes HTTP/1.1\r\nHost: app.example.com\r\n\r\n"));
  assert(!isLoopbackRequestHost("GET /_setline/routes HTTP/1.1\r\nHost: 127.0.0.1\r\n" ~
    "X-Forwarded-Host: app.example.com\r\n\r\n"));
  // 没有 Host 的请求（HTTP/1.0 或刻意省略）也不算本机。
  assert(!isLoopbackRequestHost("GET /_setline/routes HTTP/1.1\r\n\r\n"));
}

@("admin renders status html") unittest {
  withStateTestLock({
    Config config;
    config.listen = ListenAddress("0.0.0.0", 8080);
    config.adminListen = ListenAddress("127.0.0.1", 8081);
    config.routes = [HostRoutes("local.example.com", [Route("/api", [9001])])];
    initialize(config);

    auto html = statusHtml();
    assert(html.indexOf("setline status") >= 0);
    assert(html.indexOf("0.0.0.0:8080") >= 0);
    assert(html.indexOf("local.example.com") >= 0);
    assert(html.indexOf("/api") >= 0);
    assert(html.indexOf("9001") >= 0);
    assert(html.indexOf("online") >= 0);
    assert(html.indexOf("dot") >= 0);
    // 管理面独立监听时状态页要列出它的地址，否则排障时看不出管理入口在哪。
    assert(html.indexOf("admin listen") >= 0);
    assert(html.indexOf("127.0.0.1:8081") >= 0);
  });
}

@("admin renders status json") unittest {
  withStateTestLock({
    Config config;
    config.listen = ListenAddress("127.0.0.1", 8080);
    config.adminListen = ListenAddress("127.0.0.1", 9081);
    config.connectTimeoutMillis = 1500;
    config.routes = [
      HostRoutes("local.example.com", [
        Route("/api", [9001, 9002])
      ])
    ];
    initialize(config);

    auto status = statusJson();
    assert(status["listen"]["host"].str == "127.0.0.1");
    assert(jsonNumber(status["listen"]["port"]) == 8080);
    assert(jsonNumber(status["connectTimeoutMillis"]) > 0);
    assert(jsonNumber(status["routeHostCount"]) == 1);
    assert(jsonNumber(status["routeCount"]) == 1);
    assert(jsonNumber(status["healthCheck"]["intervalMillis"]) == 5000);
    assert(status["routes"].type == JSONType.object);
    assert(status["routes"]["local.example.com"].type == JSONType.array);
    assert(status["routes"]["local.example.com"][0]["ports"][0]["healthy"].boolean);
    // status.json 面向机器读取，不暴露管理口地址；入口只在状态页 HTML 和启动日志里。
    assert(!("adminListen" in status.object));
  });
}

@("admin escapes status html") unittest {
  // 单引号也要转义：属性值一旦用单引号包起来，`'` 就能闭合属性注入新的属性。
  assert(escapeHtml(`<tag attr="x" data-y='z'>&`) ==
    `&lt;tag attr=&quot;x&quot; data-y=&#39;z&#39;&gt;&amp;`);
}

@("admin detects localhost addresses") unittest {
  assert(isLocalhostAddress("127.0.0.1"));
  assert(isLocalhostAddress("::1"));
  assert(isLocalhostAddress("::ffff:127.0.0.1"));
  assert(!isLocalhostAddress("192.168.1.10"));
}

@("admin allows localhost route updates without token") unittest {
  assert(isLocalRouteUpdateAllowed(true));
  assert(!isLocalRouteUpdateAllowed(false));
}

@("admin gates reads by source first, token only for non-local callers") unittest {
  auto request = "GET /_setline/routes HTTP/1.1\r\n\r\n";

  // 本机来源：不管有没有 token、配置了什么 token，一律放行（读写同一条门）
  assert(isReadAllowed(true, request));
  assert(isReadAllowed(true, "GET /_setline/routes HTTP/1.1\r\nX-Setline-Token: wrong\r\n\r\n"));

  // 非本机来源：token 为空按开发模式放行
  assert(isReadAllowed(false, request));
}

@("admin requires the read token only for non-local callers when it is set") unittest {
  withStateTestLock({
    Config config;
    config.adminToken = "secret";
    initialize(config);
    try {
      auto request = "GET /_setline/routes HTTP/1.1\r\n\r\n";
      // 非本机且没带凭据：拒绝；带对了才放行
      assert(!isReadAllowed(false, request));
      assert(isReadAllowed(false, "GET /_setline/routes HTTP/1.1\r\nX-Setline-Token: secret\r\n\r\n"));
      assert(!isReadAllowed(false, "GET /_setline/routes HTTP/1.1\r\nX-Setline-Token: wrong\r\n\r\n"));

      // 本机来源不受 token 影响：basctl 因此不需要在 server.xml 里存任何凭据
      assert(isReadAllowed(true, request));

      // 状态页和路由表同一条规则、同一种凭据：没有 Basic Auth 这一路。
      auto status = "GET /_setline/status HTTP/1.1\r\nHost: setline.internal\r\n\r\n";
      assert(!isReadAllowed(false, status));
      assert(isReadAllowed(false, status[0 .. $ - 2] ~ "X-Setline-Token: secret\r\n\r\n"));
      assert(isReadAllowed(true, "GET /_setline/status HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n"));
    } finally {
      Config empty;
      initialize(empty);
    }
  });
}

@("admin extracts query value") unittest {
  assert(queryValue("/_setline/routes?prefix=/api", "prefix") == "/api");
  assert(normalizeRoutePrefix(queryValue("/_setline/routes?prefix=/api/", "prefix")) == "/api");
  assert(queryValue("/_setline/routes?x=1&prefix=/m/edu", "prefix") == "/m/edu");
  // 没有 `=` 的参数按空值处理；名字对不上就跳过，继续往后找。
  assert(queryValue("/_setline/routes?prefix", "prefix") == "");
  assert(queryValue("/_setline/routes?other&prefix=/api", "prefix") == "/api");
  assert(queryValue("/_setline/routes", "prefix") == "");
  assert(routeHostFromTarget("/_setline/routes?host=LOCAL.EXAMPLE.COM") == "local.example.com");
}

@("admin updates route set") unittest {
  withStateTestLock({
    Config config;
    config.routes = [
      HostRoutes("local.example.com", [
        Route("/api", [9001]),
        Route("/m", [9002])
      ])
    ];
    initialize(config);
    updatePortHealth(9001, false);
    updatePortHealth(9001, false);

    upsertRoute("local.example.com",
      Route("/api", [9001, 9003]));
    assert(routesSnapshot().length == 1);
    assert(routesSnapshot()[0].routes.length == 2);
    assert(!isPortHealthy(9001));
    assert(isPortHealthy(9003));

    assert(deleteRoute("local.example.com", "/m"));
    assert(!deleteRoute("local.example.com", "/missing"));
    assert(routesSnapshot()[0].routes.length == 1);

    clearRoutes("local.example.com");
    assert(routesSnapshot().length == 0);

    replaceRoutes("local.example.com", [Route("/new", [9010])]);
    assert(routesSnapshot().length == 1);
    assert(routesSnapshot()[0].routes[0].prefix == "/new");
    assert(isPortHealthy(9010));
  });
}

long jsonNumber(JSONValue value) {
  return value.type == JSONType.uinteger ? cast(long) value.uinteger : value.integer;
}
