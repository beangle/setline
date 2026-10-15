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

import setline.edge;

/** 构造一个后端实例，省掉测试里的结构体字面量。 */
BackendInstance at(string host, ushort port) {
  return BackendInstance(host, port);
}

/** 构造一个后端服务；services 列表顺序就是渲染顺序。 */
BackendService service(string name, string host, string contentPath, BackendInstance[] instances) {
  BackendService result;
  result.name = name;
  result.host = host;
  result.contentPath = contentPath;
  result.instances = instances;
  return result;
}

@("edge renders haproxy backends with TCP checks only") unittest {
  auto services = [
    service("edu-learning", "local.example.com", "/m/edu/learning", [at("10.0.1.10", 18001)]),
    service("app", "*", "/a", [at("10.0.1.30", 18003)]),
  ];

  auto backends = renderHaproxyBackends(services);
  assert(backends.canFind("backend be_edu_learning"));
  assert(backends.canFind("server edu_learning_0 10.0.1.10:18001 check"));
  assert(backends.canFind("backend be_app"));
  assert(backends.canFind("server app_0 10.0.1.30:18003 check"));
  // 片段只发 TCP `check`，绝不发 httpchk：HTTP 检查会把应用返回 404/401 的根路径判成 DOWN。
  assert(!backends.canFind("option httpchk"));
  assert(!backends.canFind("del-header"));
}

@("edge renders haproxy routing map usable from 2.0") unittest {
  auto services = [
    service("app", "app.example.com", "/api/edu", [at("10.0.1.10", 18001)]),
    service("fallback", "*", "/", [at("10.0.1.20", 18002)]),
  ];

  auto map = renderHaproxyMap(services, "/var/lib/setline/haproxy/setline.map");
  // 键里的 host 必须小写（与 setline 的 normalizeRequestHost 口径一致）；map 的键由
  // 上游路由表解析时归一化，这里直接给规范形式。
  // 免改请求头：键拼在事务变量里，请求原样透传给后端。
  assert(map.canFind("#   http-request set-var(txn.setline_path) path"));
  assert(map.canFind("#   http-request set-var(txn.setline_route) " ~
    "req.hdr(host),lower,field(1,:),concat(~,txn.setline_path)"));
  assert(map.canFind("use_backend %[var(txn.setline_route),map_beg(" ~
    "/var/lib/setline/haproxy/setline.map)] if { var(txn.setline_route),map_beg(" ~
    "/var/lib/setline/haproxy/setline.map) -m found }"));
  assert(map.canFind("app.example.com~/api/edu be_app"));
  assert(map.canFind("/ be_fallback"));
  // set-var-fmt 是 2.6 才有的动作，规则模式只用 2.0 起就有的 set-var + concat，
  // 且绝不生成会跟着请求到应用的内部头。
  assert(!map.canFind("set-var-fmt"));
  assert(!map.canFind("set-header"));
  assert(!map.canFind("X-Setline-Route"));
}

@("edge renders nginx upstreams and locations separately") unittest {
  auto services = [
    service("permission-service", "*", "/api/permission", [at("10.0.2.10", 19001)]),
  ];

  // 规则模式把 upstream 与 location 拆成两份：前者只能出现在 http{}，后者只能出现在 server{}。
  auto upstreams = renderNginxUpstreams(services);
  assert(upstreams.canFind("upstream permission_service"));
  assert(upstreams.canFind("server 10.0.2.10:19001;"));
  assert(!upstreams.canFind("listen "));
  assert(!upstreams.canFind("location "));

  auto locations = renderNginxLocations(services, "*");
  assert(locations.canFind("location /api/permission"));
  assert(locations.canFind("proxy_pass http://permission_service;"));
  assert(!locations.canFind("listen "));
}
