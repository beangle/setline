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
import setline.model;
import setline.state;

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
  Config config;
  config.listen = ListenAddress("0.0.0.0", 8080);
  config.routes = [Route("/api", [Backend("127.0.0.1", 9001)])];
  initialize(config);

  auto html = statusHtml();
  assert(html.indexOf("setline status") >= 0);
  assert(html.indexOf("0.0.0.0:8080") >= 0);
  assert(html.indexOf("/api") >= 0);
  assert(html.indexOf("9001") >= 0);
}

@("admin renders status json") unittest {
  Config config;
  config.listen = ListenAddress("127.0.0.1", 18080);
  config.connectTimeoutMillis = 1500;
  config.routes = [Route("/api", [Backend("127.0.0.1", 9001), Backend("127.0.0.1", 9002)])];
  initialize(config);

  auto status = statusJson();
  assert(status["listen"]["host"].str == "127.0.0.1");
  assert(jsonNumber(status["listen"]["port"]) == 18080);
  assert(jsonNumber(status["connectTimeoutMillis"]) == 1500);
  assert(jsonNumber(status["routeCount"]) == 1);
  assert(status["routes"].array[0]["prefix"].str == "/api");
}

@("admin escapes status html") unittest {
  assert(escapeHtml(`<tag attr="x">&`) == `&lt;tag attr=&quot;x&quot;&gt;&amp;`);
}

long jsonNumber(JSONValue value) {
  return value.type == JSONType.uinteger ? cast(long) value.uinteger : value.integer;
}
