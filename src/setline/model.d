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

/** 一条基于路径前缀的路由规则。

    `prefix` 只参与最长前缀匹配；命中后在本机端口之间做随机选择。后端固定为
    `127.0.0.1:<port>`，因此 Route 不再为 backend 单独建模。
*/
struct Route {
  string prefix;
  ushort[] ports;
}

/** 一个明确 host 下的路由集合。

    host 是运行时路由的第一层命名空间，普通主机名不带端口。`*` 是 fallback 命名空间：
    请求 `Host` 头没有精确命中时，才会尝试 `*` 下的路由。
*/
struct HostRoutes {
  string host;
  Route[] routes;
}

/** 后端健康检查配置。

    健康检查总是开启，只允许调整固定后台循环的间隔和阈值。检查方式为 TCP connect 到
    `127.0.0.1:<port>`，请求路径只读取已有健康状态，不即时探测后端。
*/
struct HealthConfig {
  int intervalMillis = 5000;
  int timeoutMillis = 1000;
  int unhealthyThreshold = 2;
  int healthyThreshold = 1;
}

/** 一台被聚合的远端 setline 实例。

    agent 读取它的 `GET /__setline/routes` 路由表，把 `url` 里的主机和每条路由自带的
    本机端口拼成 `<主机>:<port>`，再和其他实例的同前缀路由合并成一份边缘代理配置。

    - `url` 同时决定读端和数据面：`http://10.0.1.10:8080` 表示去 `10.0.1.10:8080` 读
      路由表，边缘代理回源的目标主机也是 `10.0.1.10`（URL 端口只是管理入口，业务端口
      由每条路由自带）。因此 `url` 必须带主机，`file://` 这类没有主机的来源不能当 peer。
    - `name` 只用于生成可读的服务名；留空时从 `url` 的主机推导。
    - `token` 是该实例的 `X-Setline-Token`；留空时回退到 agent 级 `token`。
*/
struct PeerConfig {
  string name;
  string url;
  string token;
}

/** agent 的同步机制。

    `once` 只跑一轮就退出，适合交给 cron / systemd timer 周期调用；`interval` 按
    `intervalMillis` 常驻重复，避免依赖外部调度器。
*/
struct SyncConfig {
  string mode = "once";
  int intervalMillis = 30000;
}

/** 边缘代理渲染配置。

    `peers` 非空时走「聚合远端 setline 路由表」这条路；`url` 则保留给更早的
    registry bundle 模式，两者取其一即可。
*/
struct AgentConfig {
  string type;
  string url;
  string workDir = "/tmp/setline-agent";
  /** 生成片段的落盘路径；为空时写到标准输出。 */
  string output;
  /** 边缘代理监听串：haproxy 用作 `bind`，nginx 取其端口。 */
  string bind = "*:80";
  /** 被聚合的远端 setline 实例。 */
  PeerConfig[] peers;
  SyncConfig sync;
  /** peers 未单独设置 token 时的默认 `X-Setline-Token`。 */
  string token;
}

/** 完整运行配置。

    配置描述监听地址、管理 token 和路由表。代理行为本身保持固定：按 URL 找路由、连接
    本机后端、透明透传请求和响应，不提供缓存、URL 改写或复杂负载均衡策略。

    `adminToken` 只保护**读**的**非本机**来源（`GET /__setline/routes` 与状态页），因为路由表
    将来要开放给同网段的服务进程（例如同步 haproxy / nginx 的 agent）读取；本机来源免凭据，
    与**写**接口同一条门——写也不认这条凭据，只接受 TCP 对端是本机的请求（改路由等于改流量走向，
    不对外开放）。
*/
struct Config {
  ListenAddress listen;
  /** 非本机读接口的凭据；为空表示开发模式放行（生产绑 `*` 时必须设置）。 */
  string adminToken;
  int connectTimeoutMillis = 3000;
  size_t maxConnections = 65535;
  HealthConfig healthCheck;
  AgentConfig agent;
  HostRoutes[] routes;
}
