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

module setline.model;

/** setline 监听的本地地址。

    项目定位是让用户显式访问代理服务地址，再由 setline 按 URL 路径转发到本机后端应用。
    因此配置解析层会限制监听和后端都在本地地址范围内，避免这个轻量代理被误用成开放
    转发代理。
*/
struct ListenAddress {
  string host = "127.0.0.1";
  ushort port = 8080;
}

/** 配置文件中定义的直接响应。

    直接响应用于少量健康检查、占位或本地固定内容。启动解析配置时会提前编译成
    `wireResponse`，运行期命中后直接写回浏览器，不再重复拼接 HTTP 响应头。
*/
struct DirectResponse {
  int status = 200;
  string contentType = "text/plain; charset=utf-8";
  string body;
  string[string] headers;
}

/** 一个可连接的本机 HTTP 后端。

    当前只支持 `http://host:port`，不在这里保存 path，也不支持上游 HTTPS。URL 路径由
    浏览器原样发来并原样传给后端，setline 不做 stripPrefix、rewrite 或 path join。
*/
struct Backend {
  string host;
  ushort port;
}

/** 一条基于路径前缀的路由规则。

    `prefix` 只参与最长前缀匹配；命中后要么返回预构造的 `wireResponse`，要么在 `backends`
    之间做简单轮转。`nextBackend` 是运行期状态，不来自配置文件。
*/
struct Route {
  string prefix;
  DirectResponse response;
  string wireResponse;
  Backend[] backends;
  size_t nextBackend;
}

/** 完整运行配置。

    配置只描述监听地址、管理 token 和路由表。代理行为本身保持固定：按 URL 找路由、连接
    本机后端、透明透传请求和响应，不提供缓存、URL 改写或复杂负载均衡策略。
*/
struct Config {
  ListenAddress listen;
  string adminToken;
  int connectTimeoutMillis = 3000;
  size_t maxConnections = 65535;
  Route[] routes;
}
