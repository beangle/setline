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
BackendService service(string host, string contentPath, BackendInstance[] instances) {
  BackendService result;
  result.host = host;
  result.contentPath = contentPath;
  result.instances = instances;
  return result;
}

@("edge renders haproxy backends with TCP checks only") unittest {
  auto services = [
    service("local.example.com", "/m/edu/learning", [at("10.0.1.10", 18001)]),
    service("*", "/a", [at("10.0.1.30", 18003)]),
  ];

  auto backends = renderHaproxyBackends(services);
  // 标识 = host 分组名 + 路径前缀，`*` 分组写作 default。
  assert(backends.canFind("backend b_local_example_com_m_edu_learning"));
  assert(backends.canFind("server local_example_com_m_edu_learning_0 10.0.1.10:18001 check"));
  assert(backends.canFind("backend b_default_a"));
  assert(backends.canFind("server default_a_0 10.0.1.30:18003 check"));
  // 片段只发 TCP `check`，绝不发 httpchk：HTTP 检查会把应用返回 404/401 的根路径判成 DOWN。
  assert(!backends.canFind("option httpchk"));
  assert(!backends.canFind("del-header"));
}

@("edge renders haproxy routing map usable from 2.0") unittest {
  auto services = [
    service("app.example.com", "/api/edu", [at("10.0.1.10", 18001)]),
    service("*", "/", [at("10.0.1.20", 18002)]),
  ];

  auto map = renderHaproxyMap(services);
  // 键里的 host 必须小写（与 setline 的 normalizeRequestHost 口径一致）；map 的键由
  // 上游路由表解析时归一化，这里直接给规范形式。
  assert(map.canFind("app.example.com~/api/edu b_app_example_com_api_edu"));
  // 根路径不单独占一段：`*` + `/` 的标识就是 default。
  assert(map.canFind("/ b_default"));
  // map 是纯路由数据，主配置里的 map_beg 接线说明只留在文档中。
  assert(!map.canFind("#"), map);
  // set-var-fmt 是 2.6 才有的动作，规则模式只用 2.0 起就有的 set-var + concat，
  // 且绝不生成会跟着请求到应用的内部头。
  assert(!map.canFind("set-var-fmt"));
  assert(!map.canFind("set-header"));
  assert(!map.canFind("X-Setline-Route"));
}

@("edge renders nginx upstreams and locations separately") unittest {
  auto services = [
    service("*", "/api/permission", [at("10.0.2.10", 19001)]),
  ];

  // 规则模式把 upstream 与 location 拆成两份：前者只能出现在 http{}，后者只能出现在 server{}。
  auto upstreams = renderNginxUpstreams(services);
  assert(upstreams.canFind("upstream default_api_permission"));
  assert(upstreams.canFind("server 10.0.2.10:19001;"));
  assert(!upstreams.canFind("listen "));
  assert(!upstreams.canFind("location "));

  auto locations = renderNginxLocations(services, "*");
  assert(locations.canFind("location /api/permission"));
  assert(locations.canFind("proxy_pass http://default_api_permission;"));
  assert(!locations.canFind("listen "));
}
