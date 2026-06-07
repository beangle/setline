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
import std.exception : enforce;
import std.random : uniform;
import std.typecons : Nullable, nullable;

import setline.model;
import setline.util : adminPrefix;

/** 路由树中的一个路径段节点。

    `name` 是不带 `/` 的单个 URI path segment；根节点名字为空。节点自己承载端口列表和
    `children` 以子 segment 为键。这样运行时查找命中节点后可以直接选择端口，不需要
    再通过下标回查另一个数组，也不需要为每次请求改写路由节点状态。
*/
struct RouteNode {
  string name;
  string prefix;
  ushort[] ports;
  RouteNode[string] children;
}

/** 基于 URI 路径段构造的路由索引。

    路由数据直接落在树节点上。`Route[]` 仅保留为管理接口快照和配置视图；请求热路径只走
    树，不再扫描路由数组，也不再通过树节点保存数组下标。
*/
struct RouteTree {
  RouteNode root;
}

struct RouteMatch {
  string prefix;
  ushort[] ports;
}

/** 按 URI path segment 迭代字符串切片。

    该 range 跳过连续的 `/`，每次 `front` 返回原 path 上的一个 segment 切片，不创建
    segment 数组。路由构建和请求匹配都使用它，避免各自手写路径扫描逻辑。
*/
struct PathSegments {
  string path;
  size_t pos;
  string current;
  bool done;

  this(string path) {
    this.path = path;
    popFront();
  }

  @property bool empty() const {
    return done;
  }

  @property string front() const {
    return current;
  }

  void popFront() {
    while (pos < path.length && path[pos] == '/') {
      ++pos;
    }
    if (pos >= path.length) {
      current = "";
      done = true;
      return;
    }

    auto start = pos;
    while (pos < path.length && path[pos] != '/') {
      ++pos;
    }
    current = path[start .. pos];
    done = false;
  }
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
  auto matched = matchRoute(tree, path);
  return matched.ports.length == 0 ? Nullable!Route.init : nullable(Route(matched.prefix, matched.ports));
}

/** 为 path 随机选择一个可用端口。

    查找过程按 URI segment 从根节点向下走，并持续记录最后一个带端口列表的节点。这样
    `/api/a/users` 会优先命中 `/api/a`，如果中途没有对应 child，就使用此前记录的最长
    前缀节点。

    多端口场景只做随机选择，不维护 round-robin 游标、权重或粘性会话。`available` 用于
    调用方传入健康状态、请求内重试排除列表等过滤条件；过滤本身只读外部状态，不改写
    路由树。

    Returns:
      选中的本机后端端口；`0` 表示没有匹配路由，或匹配路由下没有满足 `available`
      条件的端口。配置层已经禁止端口 `0`，所以这里可以用它作为哨兵值，避免为一个整数
      返回值再套 `Nullable`。
*/
alias PortPredicate = bool delegate(ushort port);

ushort selectPort(ref RouteTree tree, string path) {
  return selectPort(tree, path, null);
}

ushort selectPort(ref RouteTree tree, string path, PortPredicate available) {
  auto matched = matchRoute(tree, path);
  if (matched.ports.length == 0) {
    return 0;
  }

  ushort[] candidates;
  foreach (port; matched.ports) {
    // available 为空表示不做健康或重试过滤，直接在路由端口中随机选择。
    if (available is null || available(port)) {
      candidates ~= port;
    }
  }
  return candidates.length == 0 ? 0 : candidates[uniform(0, candidates.length)];
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

void insertRoute(ref RouteTree tree, Route route) {
  auto node = &tree.root;
  if (route.prefix == "/") {
    node.ports = route.ports.dup;
    return;
  }

  foreach (segment; PathSegments(route.prefix)) {
    auto existing = segment in node.children;
    if (existing is null) {
      RouteNode child;
      child.name = segment;
      child.prefix = node.prefix.length == 0 || node.prefix == "/" ? "/" ~ segment : node.prefix ~ "/" ~ segment;
      node.children[segment] = child;
      node = segment in node.children;
    } else {
      node = existing;
    }
  }
  node.ports = route.ports.dup;
}

/** 返回 path 的最长前缀匹配结果。

    这是路由树唯一的请求路径扫描逻辑。调用方如果只关心路由是否存在，用返回的 `ports`
    是否为空判断；如果还需要展示命中的前缀，可以使用返回的 `prefix`。
*/
RouteMatch matchRoute(RouteTree tree, string path) {
  auto node = &tree.root;
  RouteMatch best;
  if (node.ports.length > 0) {
    best = RouteMatch("/", node.ports.dup);
  }

  foreach (segment; PathSegments(path)) {
    auto child = segment in node.children;
    if (child is null) {
      break;
    }

    node = child;
    if (node.ports.length > 0) {
      best = RouteMatch(node.prefix, node.ports.dup);
    }
  }
  return best;
}
