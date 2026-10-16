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

/** 管理接口的默认端口：`adminListen` 不写时用它。

    取数据面缺省端口 `8080` 的邻居，取号时要避开浏览器的「受限端口」清单：状态页是给人
    用浏览器打开的，命中的端口浏览器连请求都不发（Firefox 报
    `This address is restricted`）。这份清单比 IANA 的知名端口表短得多，也不认「像不像
    8080 的兄弟端口」——`10080`（Amanda 备份）就在里面，看着人畜无害却用不了。

    `8081` 本身是个热门号（Nexus、Tomcat 之类都爱用），撞了就把 `adminListen` 挪开。
*/
enum defaultAdminPort = 8081;

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

    agent 读取它的 `GET /_setline/routes` 路由表，把 `url` 里的主机和每条路由自带的
    本机端口拼成 `<主机>:<port>`，再和其他实例的同前缀路由合并成一份边缘代理配置。

    - `url` 同时决定读端和数据面：`http://10.0.1.10:8080` 表示去 `10.0.1.10:8080` 读
      路由表，边缘代理回源的目标主机也是 `10.0.1.10`（URL 端口只是管理入口，业务端口
      由每条路由自带）。因此 `url` 必须带主机，`file://` 这类没有主机的来源不能当 peer。
    - `name` 只用于生成可读的服务名；留空时从 `url` 的主机推导。
    - 凭据不在这里：所有 peer 共用 agent 级 `token`（见 `AgentConfig.token`），
      整套集群按同一个共享 token 发放，避免每加一台机器就同步一份凭据。
*/
struct PeerConfig {
  string name;
  string url;
}

/** 边缘代理渲染配置。

    数据来源两种：`peers` 聚合远端 setline 的路由表；不配 `peers` 时渲染本进程的路由表，
    也就是 haproxy/nginx 与 setline、basctl 同机的单机部署，此时必须有 `output`。

    `peers` 形态下 setline 每次只渲染一轮就退出，周期性刷新交给 systemd
    timer（包里的 `setline-render.timer`），进程里不带自己的调度循环——节奏统一由 systemd 管，
    `systemctl status`/`journalctl` 里看得见，也不用再维护一个配置项。

    曾经还有一种 `agent.remote`（下载 registry manifest / bundle 再渲染 `backends.json`）
    与配套的 `agent.workDir`：集中打包发布听起来好用，实际与 `peers` 提供的「从运行中的
    实例现拉路由表」是两套冗余来源，维护成本翻倍，已一并取消（数据来源的收敛见
    docs/project-constraints.md 的 External Proxy Integration Decision）。

    片段固定只出规则和后端定义，**从不写监听段**：`bind` / `listen` 归代理主配置，
    setline 不去碰别人持有的监听（曾经有个 `agent.bind` 开关，已取消，见
    docs/configuration.md 的 agent 一节）。
*/
struct AgentConfig {
  string type;
  /** 生成片段的落盘**根目录**；为空时写到标准输出。

      目录名与文件名都由 setline 决定（见 `layoutSnippets`）：按 `type` 落到
      `<output>/haproxy/` 或 `<output>/nginx/`，文件名固定为 `setline.cfg`
      （haproxy）/ `setline.conf`（nginx），规则模式再派生 `.map` 或按 host 分文件。
      运维只负责给一个可写目录，不开放文件粒度配置。
  */
  string output;
  /** 被聚合的远端 setline 实例。 */
  PeerConfig[] peers;
}

/** 完整运行配置。

    配置描述监听地址、可读来源和路由表。代理行为本身保持固定：按 URL 找路由、连接
    本机后端、透明透传请求和响应，不提供缓存、URL 改写或复杂负载均衡策略。

    setline 不持有任何凭据：管理接口的准入完全由**来源地址**决定（见 {@link peerReaders}），
    与写接口同一条判据。
*/
struct Config {
  ListenAddress listen;
  /** `"listen": false` 时不绑定任何监听：纯渲染部署，路由只来自配置文件。 */
  bool listenDisabled;
  /** 管理接口的独立监听，缺省 `127.0.0.1:8081`（见 {@link defaultAdminPort}）。

      两个监听按方法分工：

      - **写**（`PUT` / `DELETE /_setline/routes*`）只在管理口上，缺省绑回环，于是「只有
        本机能改路由」是 TCP 层事实，不依赖请求头判定（那是纵深防御，可被代理改写 `Host`
        绕过）。跨机改路由不是需求，真要做也只能先把管理口显式放开。
      - **读**（`GET` 路由表、状态页、`status.json`）同时挂在数据面 `listen` 和管理口上，
        准入只看来源：本机来源，或地址写在 {@link peerReaders} 里的读方。外界只需要知道
        业务端口就能读，不必知道管理口在哪。

      要把管理口的读放开给同网段的采集机，就显式绑定（例如 `*:8081`）并把那台机器写进
      {@link peerReaders}；缺省绑回环是因为读已经能从 `listen` 走，管理口不需要暴露在网络上。
  */
  ListenAddress adminListen = ListenAddress("127.0.0.1", defaultAdminPort);
  /** 允许跨机读取路由表与状态页的来源地址（读写都只看地址，没有凭据）。

      本机来源本来就免凭据（见 `isLocalAdminRequest`），这里写的是**远端读方**的地址，
      典型场景就是边缘机上那个 `setline -f`：它按 `agent.peers[].url` 读各实例的
      `GET /_setline/routes`，而 `peers[].url` 只是地址，不带任何凭据。

      写数值地址（`10.0.1.7`、`fe80::1`），不支持主机名和 CIDR；列出回环地址会报错——
      本机来源本来就放行，写上去是个空操作，容易让人以为它还有别的含义。
  */
  string[] peerReaders;
  int connectTimeoutMillis = 3000;
  /** 单次上游读取的不活动超时；超时后回收连接并在最终响应未开始时返回 504。 */
  int readTimeoutMillis = 15000;
  size_t maxConnections = 65535;
  /** 同端口启动多个进程时启用 SO_REUSEPORT；默认关闭，避免误共享管理入口。 */
  bool reusePort;
  /** 空闲上游连接保留多久（毫秒）。

      客户端连接亲和会让一条 keep-alive 的客户端连接一直握着它的上游连接；超过这个时间
      没有新请求就把连接交回空闲池，空闲池里的连接也用同一个时限过期回收。
  */
  int upstreamIdleTimeoutMillis = 30000;
  /** WebSocket 隧道两个方向都静默多久后断开（毫秒）。

      `0`（默认）表示不主动超时：WebSocket 是长连接，空闲多久由业务决定，常规位置是
      前置代理的 `timeout tunnel`。设成正数时它只是资源回收的兜底，一侧有流量就不算空闲。
  */
  int webSocketIdleTimeoutMillis = 0;
  HealthConfig healthCheck;
  AgentConfig agent;
  HostRoutes[] routes;
}
