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

module setline.config;

import std.algorithm : startsWith;
import std.array : split;
import std.conv : to;
import std.exception : enforce;
import std.file : exists, readText;
import std.json;
import std.stdio : stderr;
import std.string : indexOf;

import setline.http : buildHttpResponse, statusReason;
import setline.model;
import setline.router : sortRoutes, validateRoute;

Config loadConfig(string path) {
  Config config;

  if (!exists(path)) {
    stderr.writefln("Config %s not found, using empty route table", path);
    return config;
  }

  auto root = parseJSON(readText(path));
  if ("listen" in root.object) {
    config.listen = parseListen(root["listen"].str);
  }
  if ("adminToken" in root.object) {
    config.adminToken = root["adminToken"].str;
  }
  if ("routes" in root.object) {
    foreach (item; root["routes"].array) {
      config.routes ~= parseRoute(item);
    }
  }
  sortRoutes(config.routes);
  return config;
}

ListenAddress parseListen(string value) {
  auto parts = value.split(":");
  enforce(parts.length == 2, "listen must be host:port");
  enforce(isLocalHost(parts[0]), "listen host must be local");
  return ListenAddress(parts[0], parts[1].to!ushort);
}

Route parseRoute(JSONValue value) {
  auto obj = value.object;
  enforce("prefix" in obj, "route.prefix is required");
  enforce(!("stripPrefix" in obj), "stripPrefix is not supported");
  auto hasDirectResponse = ("directResponse" in obj) !is null;
  auto hasBackend = ("backend" in obj) !is null;
  auto hasBackends = ("backends" in obj) !is null;
  enforce(hasDirectResponse || hasBackend || hasBackends,
    "route.directResponse, route.backend, or route.backends is required");
  enforce(cast(int) hasDirectResponse + cast(int) hasBackend + cast(int) hasBackends == 1,
    "route must define exactly one of directResponse, backend, or backends");

  Route route;
  route.prefix = obj["prefix"].str;
  if (hasDirectResponse) {
    route.response = parseDirectResponse(obj["directResponse"]);
    route.wireResponse = buildHttpResponse(
      route.response.status.to!string ~ " " ~ statusReason(route.response.status),
      route.response.contentType,
      route.response.body,
      route.response.headers);
  } else if (hasBackend)  {
    route.backends = [parseBackend(obj["backend"].str)];
  } else {
    foreach (backendValue; obj["backends"].array) {
      route.backends ~= parseBackend(backendValue.str);
    }
    enforce(route.backends.length > 0, "route.backends must not be empty");
  }
  validateRoute(route);
  return route;
}

DirectResponse parseDirectResponse(JSONValue value) {
  auto obj = value.object;

  DirectResponse response;
  response.status = ("status" in obj) ? cast(int) obj["status"].integer : 200;
  response.contentType = ("contentType" in obj) ? obj["contentType"].str : response.contentType;
  response.body = ("body" in obj) ? obj["body"].str : "";

  if ("headers" in obj) {
    foreach (name, headerValueJson; obj["headers"].object) {
      response.headers[name] = headerValueJson.str;
    }
  }

  enforce(response.status >= 100 && response.status <= 599, "directResponse.status must be 100..599");
  return response;
}

Backend parseBackend(string raw) {
  enforce(raw.startsWith("http://"), "only http:// backends are supported");
  auto authority = raw["http://".length .. $];
  auto slashIndex = authority.indexOf("/");
  if (slashIndex >= 0) {
    authority = authority[0 .. slashIndex];
  }

  auto parts = authority.split(":");
  enforce(parts.length == 2, "backend must be http://host:port");
  enforce(isLocalHost(parts[0]), "backend host must be local");
  return Backend(parts[0], parts[1].to!ushort);
}

bool isLocalHost(string host) {
  return host == "127.0.0.1" || host == "localhost";
}
