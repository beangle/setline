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

    updatePortHealth(9080, false);
    updatePortHealth(9080, false);
    assert(selectPort("local1.example.com", "/api/users") == 0);

    auto snapshot = routesSnapshot();
    snapshot[0].routes[0].ports[0] = 1;
    assert(selectPort("missing.example.com", "/api/users") == 9090);
  });
}
