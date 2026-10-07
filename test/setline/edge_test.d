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

module setline.edge_test;

import std.algorithm : canFind;
import std.exception : assertThrown;
import std.file : exists, mkdirRecurse, rmdirRecurse, write;
import std.path : buildPath;
import std.process : execute;

import setline.edge;
import setline.model;

@("edge parses backends json") unittest {
  auto services = parseBackends(`{
    "services": [{
      "name": "edu-learning",
      "host": "LOCAL.EXAMPLE.COM",
      "content_path": "/m/edu/learning/",
      "health_path": "/health",
      "instances": [
        {"ip": "10.0.1.10", "port": 18001},
        {"host": "10.0.1.11", "port": 18002}
      ]
    }]
  }`);

  assert(services.length == 1);
  assert(services[0].name == "edu-learning");
  assert(services[0].host == "local.example.com");
  assert(services[0].contentPath == "/m/edu/learning");
  assert(services[0].healthPath == "/health");
  assert(services[0].instances.length == 2);
  assert(services[0].instances[0].host == "10.0.1.10");
  assert(services[0].instances[1].port == 18002);
}

@("edge renders haproxy config") unittest {
  auto services = parseBackends(`{
    "services": [{
      "name": "edu-learning",
      "contentPath": "/m/edu/learning",
      "healthPath": "/health",
      "instances": [{"host": "10.0.1.10", "port": 18001}]
    }]
  }`);

  auto rendered = renderHaproxy(services);
  assert(rendered.canFind("frontend http_in"));
  assert(rendered.canFind("  mode http\n"));
  assert(rendered.canFind("acl path_edu_learning path_beg /m/edu/learning"));
  assert(rendered.canFind("backend be_edu_learning"));
  assert(rendered.canFind("option httpchk GET /health"));
  assert(rendered.canFind("server edu_learning_0 10.0.1.10:18001 check"));
}

@("edge renders nginx config") unittest {
  auto services = parseBackends(`{
    "services": [{
      "name": "permission-service",
      "contentPath": "/api/permission",
      "instances": [{"host": "10.0.2.10", "port": 19001}]
    }]
  }`);

  auto rendered = renderNginx(services);
  assert(rendered.canFind("upstream permission_service"));
  assert(rendered.canFind("server 10.0.2.10:19001;"));
  assert(rendered.canFind("location /api/permission"));
  assert(rendered.canFind("proxy_pass http://permission_service;"));
}

@("edge rejects empty backends") unittest {
  assertThrown!Exception(parseBackends(`{"services":[]}`));
}

@("edge loads backends from manifest bundle") unittest {
  auto root = "/tmp/setline-edge-bundle-test";
  if (exists(root)) rmdirRecurse(root);
  scope (exit) if (exists(root)) rmdirRecurse(root);

  auto sourceDir = buildPath(root, "source");
  mkdirRecurse(sourceDir);
  write(buildPath(sourceDir, "backends.json"), `{"services":[{"name":"edu","contentPath":"/api/edu",` ~
    `"instances":[{"host":"10.0.3.10","port":18003}]}]}`);

  auto bundlePath = buildPath(root, "bundle.tar.gz");
  auto tarResult = execute(["tar", "-czf", bundlePath, "-C", sourceDir, "."]);
  assert(tarResult.status == 0);
  auto manifestPath = buildPath(root, "latest.json");
  write(manifestPath, `{"version":"2026.06.08.001","bundleUrl":"bundle.tar.gz","sha256":"` ~
    fileSha256(bundlePath) ~ `"}`);

  auto config = AgentConfig("haproxy", "file://" ~ manifestPath, buildPath(root, "work"));
  auto text = loadBackendsJson(config);
  auto services = parseBackends(text);
  assert(services.length == 1);
  assert(services[0].instances[0].port == 18003);
}
