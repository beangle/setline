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
import std.typecons : Nullable, nullable;

import setline.constants;
import setline.model;

enum noRouteIndex = size_t.max;

/** 路由树中的一个路径段节点。

    `children` 以单个 URI path segment 为键，例如 `/api/a` 会形成 `api -> a` 两级。
    `routeIndex` 指向外部 `Route[]` 中的路由下标，节点没有路由时使用 `noRouteIndex`。
*/
struct RouteNode {
  size_t routeIndex = noRouteIndex;
  size_t[string] children;
}

/** 基于 URI 路径段构造的路由索引。

    路由数据仍保存在 `Route[]` 中，树只保存下标。这样管理接口可以继续返回原路由表，
    round-robin 的 `nextBackend` 也只需要更新数组中的 route，不需要在树节点中复制状态。
*/
struct RouteTree {
  RouteNode[] nodes;
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
  tree.nodes ~= RouteNode();
  foreach (i, route; routes) {
    insertRoute(tree, route.prefix, i);
  }
  return tree;
}

/** 查找与 path 匹配的路由。

    返回值使用 `Nullable`，让没有匹配路由和命中空配置这两种情况在类型上保持明确。匹配
    规则仍是最长路径前缀优先，并且按 segment 匹配，`/api` 不会误匹配 `/apiology`。
*/
Nullable!Route findRoute(Route[] routes, RouteTree tree, string path) {
  auto index = findRouteIndex(tree, path);
  if (index == noRouteIndex || index >= routes.length) {
    return Nullable!Route.init;
  }
  return nullable(routes[index]);
}

/** 为 path 选择后端，并推进该路由的轮转下标。

    多后端场景只做最简单的 round-robin，不做健康检查、权重或粘性会话。这个选择符合
    setline 的轻量定位：它负责快速路由和透传，不承担完整负载均衡器职责。
*/
Nullable!Backend selectBackend(ref Route[] routes, RouteTree tree, string path) {
  auto index = findRouteIndex(tree, path);
  if (index == noRouteIndex || index >= routes.length || routes[index].backends.length == 0) {
    return Nullable!Backend.init;
  }

  auto route = routes[index];
  auto backend = route.backends[route.nextBackend % route.backends.length];
  routes[index].nextBackend = (route.nextBackend + 1) % route.backends.length;
  return nullable(backend);
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

void insertRoute(ref RouteTree tree, string prefix, size_t routeIndex) {
  auto nodeIndex = cast(size_t) 0;
  if (prefix == "/") {
    tree.nodes[nodeIndex].routeIndex = routeIndex;
    return;
  }

  foreach (segment; prefix[1 .. $].split("/")) {
    auto existing = segment in tree.nodes[nodeIndex].children;
    if (existing is null) {
      auto nextIndex = tree.nodes.length;
      tree.nodes ~= RouteNode();
      tree.nodes[nodeIndex].children[segment] = nextIndex;
      nodeIndex = nextIndex;
    } else {
      nodeIndex = *existing;
    }
  }
  tree.nodes[nodeIndex].routeIndex = routeIndex;
}

size_t findRouteIndex(RouteTree tree, string path) {
  if (tree.nodes.length == 0) {
    return noRouteIndex;
  }

  auto nodeIndex = cast(size_t) 0;
  auto bestIndex = tree.nodes[nodeIndex].routeIndex;
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
    auto child = segment in tree.nodes[nodeIndex].children;
    if (child is null) {
      break;
    }

    nodeIndex = *child;
    if (tree.nodes[nodeIndex].routeIndex != noRouteIndex) {
      bestIndex = tree.nodes[nodeIndex].routeIndex;
    }
  }
  return bestIndex;
}
