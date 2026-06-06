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

module setline.router;

import std.algorithm : sort, startsWith;
import std.array : split;
import std.exception : enforce;
import std.random : uniform;
import std.typecons : Nullable, nullable;

import setline.constants;
import setline.model;

/** 路由树中的一个路径段节点。

    `name` 是不带 `/` 的单个 URI path segment；根节点名字为空。节点自己承载后端列表和
    `children` 以子 segment 为键。这样运行时查找命中节点后可以直接选择 backend，不需要
    再通过下标回查另一个数组，也不需要为每次请求改写路由节点状态。
*/
struct RouteNode {
  string name;
  Backend[] backends;
  RouteNode[string] children;
}

/** 基于 URI 路径段构造的路由索引。

    路由数据直接落在树节点上。`Route[]` 仅保留为管理接口快照和配置视图；请求热路径只走
    树，不再扫描路由数组，也不再通过树节点保存数组下标。
*/
struct RouteTree {
  RouteNode root;
}

/** 校验路由前缀是否符合项目约束。

    路由前缀必须是绝对路径，并且不能占用管理接口命名空间。这样普通代理流量和
    `__setline` 运行时管理 API 在入口处就能稳定分流。
*/
void validateRoute(Route route) {
  enforce(route.prefix.length > 0 && route.prefix[0] == '/', "route prefix must start with /");
  enforce(!route.prefix.startsWith(adminPrefix), "route prefix conflicts with admin API");
}

/** 按前缀长度降序排列路由。

    路由树按 segment 查找最长前缀，不依赖数组扫描；这里仍保持排序，是为了让管理接口快照
    和调试输出更直观。例如 `/m/edu/learning` 应该排在 `/m` 前面，方便人工阅读。
*/
void sortRoutes(ref Route[] routes) {
  sort!((a, b) => a.prefix.length > b.prefix.length)(routes);
}

/** 根据路由表构建路径段树。

    构建发生在配置加载或管理接口更新路由时，不在每次请求的热路径上执行。查找时只需要
    沿着请求路径的 segment 前进，并记录最后一个带路由的节点，即可得到最长前缀匹配结果。
*/
RouteTree buildRouteTree(Route[] routes) {
  RouteTree tree;
  foreach (i, route; routes) {
    insertRoute(tree, route);
  }
  return tree;
}

/** 查找与 path 匹配的路由。

    返回值使用 `Nullable`，让没有匹配路由和命中空配置这两种情况在类型上保持明确。匹配
    规则仍是最长路径前缀优先，并且按 segment 匹配，`/api` 不会误匹配 `/apiology`。
*/
Nullable!Route findRoute(RouteTree tree, string path) {
  return findRoute(path, tree.root, "");
}

/** 为 path 随机选择一个可用后端。

    多后端场景只做随机选择，不维护 round-robin 游标、权重或粘性会话。这样请求热路径只
    读取路由配置和健康状态，不会因为每次选择 backend 而改写路由树节点。
*/
alias BackendPredicate = bool delegate(Backend backend);

Nullable!Backend selectBackend(ref RouteTree tree, string path) {
  return selectBackend(tree, path, null);
}

Nullable!Backend selectBackend(ref RouteTree tree, string path, BackendPredicate available) {
  auto node = &tree.root;
  RouteNode* best = node.backends.length > 0 ? node : null;
  size_t pos;
  while (pos < path.length) {
    while (pos < path.length && path[pos] == '/') {
      ++pos;
    }
    if (pos >= path.length) {
      break;
    }

    auto start = pos;
    while (pos < path.length && path[pos] != '/') {
      ++pos;
    }
    auto child = path[start .. pos] in node.children;
    if (child is null) {
      break;
    }

    node = child;
    if (node.backends.length > 0) {
      best = node;
    }
  }
  if (best is null) {
    return Nullable!Backend.init;
  }

  Backend[] candidates;
  foreach (backend; best.backends) {
    if (available is null || available(backend)) {
      candidates ~= backend;
    }
  }
  return candidates.length == 0 ? Nullable!Backend.init : nullable(candidates[uniform(0, candidates.length)]);
}

/** 新增或替换一条运行时路由。

    管理接口使用该函数更新内存路由表。每次更新后立即重新排序并重建树索引，保证后续
    请求仍按最长前缀规则匹配；函数不负责持久化，当前项目把动态路由视为运行时状态。
*/
void upsertRoute(ref Route[] routes, ref RouteTree tree, Route route) {
  validateRoute(route);
  foreach (i, existing; routes) {
    if (existing.prefix == route.prefix) {
      routes[i] = route;
      sortRoutes(routes);
      tree = buildRouteTree(routes);
      return;
    }
  }
  routes ~= route;
  sortRoutes(routes);
  tree = buildRouteTree(routes);
}

/** 判断路径是否被给定前缀覆盖。

    前缀 `/` 匹配所有路径；其他前缀只匹配自身或其子路径。这样 `/foo` 不会误匹配
    `/foobar`，可以避免相邻应用路径互相抢占资源请求。
*/
bool matchesRoute(string path, string prefix) {
  if (prefix == "/") {
    return true;
  }
  return path == prefix || path.startsWith(prefix ~ "/");
}

void insertRoute(ref RouteTree tree, Route route) {
  auto node = &tree.root;
  if (route.prefix == "/") {
    node.backends = route.backends.dup;
    return;
  }

  foreach (segment; route.prefix[1 .. $].split("/")) {
    auto existing = segment in node.children;
    if (existing is null) {
      node.children[segment] = RouteNode(segment);
      node = segment in node.children;
    } else {
      node = existing;
    }
  }
  node.backends = route.backends.dup;
}

Nullable!Route findRoute(string path, RouteNode node, string prefix) {
  Backend[] bestBackends;
  auto bestPrefix = prefix.length == 0 ? "/" : prefix;
  if (node.backends.length > 0) {
    bestBackends = node.backends.dup;
  }

  size_t pos;
  while (pos < path.length) {
    while (pos < path.length && path[pos] == '/') {
      ++pos;
    }
    if (pos >= path.length) {
      break;
    }

    auto start = pos;
    while (pos < path.length && path[pos] != '/') {
      ++pos;
    }
    auto segment = path[start .. pos];
    auto child = segment in node.children;
    if (child is null) {
      break;
    }

    prefix = prefix == "" || prefix == "/" ? "/" ~ segment : prefix ~ "/" ~ segment;
    node = *child;
    if (node.backends.length > 0) {
      bestPrefix = prefix;
      bestBackends = node.backends.dup;
    }
  }
  return bestBackends.length == 0 ? Nullable!Route.init : nullable(Route(bestPrefix, bestBackends));
}
