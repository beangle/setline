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

import setline.config;

@("config keeps large default connection limit") unittest {
  auto path = "/tmp/setline-config-defaults-test.json";
  write(path, `{"listen":"127.0.0.1:8080","routes":{}}`);
  scope (exit) remove(path);

  auto config = loadConfig(path);
  assert(config.connectTimeoutMillis == 3000);
  assert(config.maxConnections == 65535);
}

@("config parses connection protection settings") unittest {
  auto path = "/tmp/setline-config-protection-test.json";
  write(path, `{"connectTimeoutMillis":1500,"maxConnections":128,"routes":{}}`);
  scope (exit) remove(path);

  auto config = loadConfig(path);
  assert(config.connectTimeoutMillis == 1500);
  assert(config.maxConnections == 128);
}

@("config rejects direct response routes") unittest {
  auto path = "/tmp/setline-config-direct-response-test.json";
  write(path, `{"routes":{"/healthz":{"directResponse":{"body":"ok"}}}}`);
  scope (exit) remove(path);

  assertThrown!Exception(loadConfig(path));
}

@("config parses route ports") unittest {
  auto path = "/tmp/setline-config-routes-test.json";
  write(path, `{"routes":{"/api":9001,"/api/edu":[9002,9003]}}`);
  scope (exit) remove(path);

  auto config = loadConfig(path);
  assert(config.routes.length == 2);
  assert(config.routes[0].prefix == "/api/edu");
  assert(config.routes[0].backends[0].port == 9002);
  assert(config.routes[0].backends[1].port == 9003);
  assert(config.routes[1].prefix == "/api");
  assert(config.routes[1].backends[0].port == 9001);
}

@("config rejects backend urls") unittest {
  auto path = "/tmp/setline-config-backend-url-test.json";
  write(path, `{"routes":[{"prefix":"/api","backend":"http://127.0.0.1:9001"}]}`);
  scope (exit) remove(path);

  assertThrown!Exception(loadConfig(path));
}
