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

import std.base64 : Base64;
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

@("admin validates status basic auth") unittest {
  auto encoded = Base64.encode(cast(ubyte[]) "setline:secret").to!string;
  auto request = "GET /__setline/status HTTP/1.1\r\nAuthorization: Basic " ~ encoded ~ "\r\n\r\n";
  assert(isBasicAuthorized(request, "secret"));

  auto wrong = Base64.encode(cast(ubyte[]) "setline:wrong").to!string;
  assert(!isBasicAuthorized(
    "GET /__setline/status HTTP/1.1\r\nAuthorization: Basic " ~ wrong ~ "\r\n\r\n",
    "secret"));
  assert(!isBasicAuthorized("GET /__setline/status HTTP/1.1\r\n\r\n", "secret"));
  assert(isBasicAuthorized("GET /__setline/status HTTP/1.1\r\n\r\n", ""));
}

@("admin renders status html") unittest {
  withStateTestLock({
    Config config;
    config.listen = ListenAddress("0.0.0.0", 8080);
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
  });
}

@("admin renders status json") unittest {
  withStateTestLock({
    Config config;
    config.listen = ListenAddress("127.0.0.1", 18080);
    config.connectTimeoutMillis = 1500;
    config.routes = [
      HostRoutes("local.example.com", [
        Route("/api", [9001, 9002])
      ])
    ];
    initialize(config);

    auto status = statusJson();
    assert(status["listen"]["host"].str == "127.0.0.1");
    assert(jsonNumber(status["listen"]["port"]) == 18080);
    assert(jsonNumber(status["connectTimeoutMillis"]) > 0);
    assert(jsonNumber(status["routeHostCount"]) == 1);
    assert(jsonNumber(status["routeCount"]) == 1);
    assert(jsonNumber(status["healthCheck"]["intervalMillis"]) == 5000);
    assert(status["routes"].type == JSONType.object);
    assert(status["routes"]["local.example.com"].type == JSONType.array);
    assert(status["routes"]["local.example.com"][0]["ports"][0]["healthy"].boolean);
  });
}

@("admin escapes status html") unittest {
  assert(escapeHtml(`<tag attr="x">&`) == `&lt;tag attr=&quot;x&quot;&gt;&amp;`);
}

@("admin detects localhost addresses") unittest {
  assert(isLocalhostAddress("127.0.0.1"));
  assert(isLocalhostAddress("::1"));
  assert(isLocalhostAddress("::ffff:127.0.0.1"));
  assert(!isLocalhostAddress("192.168.1.10"));
}

@("admin allows localhost route updates without token") unittest {
  assert(isLocalhostAddress("127.0.0.1"));
}

@("admin extracts query value") unittest {
  assert(queryValue("/__setline/routes?prefix=/api", "prefix") == "/api");
  assert(normalizeRoutePrefix(queryValue("/__setline/routes?prefix=/api/", "prefix")) == "/api");
  assert(queryValue("/__setline/routes?x=1&prefix=/m/edu", "prefix") == "/m/edu");
  assert(queryValue("/__setline/routes", "prefix") == "");
  assert(routeHostFromTarget("/__setline/routes?host=LOCAL.EXAMPLE.COM") == "local.example.com");
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
