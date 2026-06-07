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
