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

module main;

import core.sys.posix.sys.resource : RLIMIT_NOFILE, getrlimit, rlimit;
import std.file : exists, readText;
import std.getopt : defaultGetoptPrinter, getopt;
import std.stdio : stderr, stdout;

import core.sys.posix.unistd : geteuid;

import setline.config;
import setline.control :
  ControlConfig, defaultCertificateDir, defaultControlPath, loadControlConfig, renderApplyShell,
  validateRemoteConfig, writeControlConfigTemplate;
import setline.download : DownloadKind, downloadConfig, parseDownloadedPeers, rewriteAgentPeers,
  writeCertificatePair, writeDownloaded;
import setline.mapsync : syncMap;
import setline.model : AgentConfig, HostRoutes;
import setline.peer : renderAgentSnippets, writeSnippets;
import setline.server;
import setline.state;
import setline.util : rejectsRootUser, requiredFileDescriptorBudget, rootRunRefusalMessage;

/** 解析命令行参数，检查或启动 setline 服务。 */
int main(string[] args) {
  version (linux) {
  } else {
    static assert(false, "setline is Linux-only");
  }

  if (args.length > 1) {
    if (args[1] == "pull")
      return runPull(args[1 .. $]);
    if (args[1] == "render")
      return runRender(args[1 .. $]);
    if (args[1] == "init")
      return runInit(args[1 .. $]);
  }

  string confPath = defaultControlPath;
  string configPath;
  bool agentType;
  bool agentPeers;
  bool applyConfig;
  bool check;
  bool help;
  string syncMapSocket;
  auto helpInfo = getopt(args,
    "conf", "Path to setline.conf", &confPath,
    "file|f", "Path to topology JSON (overrides [topology] file)", &configPath,
    "agent-type", "Print [agent] type from setline.conf and exit", &agentType,
    "agent-peers", "Print [agent] peer count from setline.conf and exit", &agentPeers,
    "apply-config", "Print setline-apply settings as shell assignments and exit", &applyConfig,
    "sync-map", "Sync a HAProxy map file into the running instance via its admin socket",
      &syncMapSocket,
    "check|c", "Check config and exit", &check,
    "help|h", "Show this help", &help);

  if (help) {
    defaultGetoptPrinter("Usage: setline [--conf setline.conf] [-f setline.json] " ~
      "[--agent-type] [--agent-peers] [--apply-config] [-c] " ~
      "[--sync-map <socket> <mapfile>]\n" ~
      "       setline pull [--conf setline.conf]\n" ~
      "       setline render [--conf setline.conf] [-f setline.json]\n" ~
      "       setline init [path]", helpInfo.options);
    return 0;
  }

  // 规则模式的 map 热同步：走独立出口码，setline-apply 只在 0 时跳过 reload，其余一律回退。
  if (syncMapSocket.length > 0) {
    if (args.length != 2) {
      stderr.writefln("usage: setline --sync-map <socket> <mapfile>");
      return 2;
    }
    try {
      auto change = syncMap(syncMapSocket, args[1], readText(args[1]));
      stdout.writefln("setline hot-synced %s: +%d ~%d -%d", args[1], change.added.length,
        change.updated.length, change.removed.length);
      return 0;
    } catch (Exception e) {
      stderr.writefln("map hot-sync unavailable: %s", e.msg);
      return 4;
    }
  }

  try {
    if (confPath != defaultControlPath && !exists(confPath))
      throw new Exception("control config not found: " ~ confPath);
    auto control = loadControlConfig(confPath);
    if (configPath.length == 0)
      configPath = control.topologyPath;

    // 给 setline-apply 的自动分派用：只回显 [agent] type（没配就是空行），
    // 让 shell 侧不必自己解析 INI。
    if (agentType) {
      stdout.writefln("%s", control.agent.type);
      return 0;
    }
    if (agentPeers) {
      stdout.writefln("%s", control.agent.peers.length);
      return 0;
    }
    if (applyConfig) {
      stdout.write(renderApplyShell(control));
      return 0;
    }

    if (check) {
      checkConfig(configPath, control);
      stdout.writefln("Config %s is valid", configPath);
      return 0;
    }

    // 主服务与渲染 agent 都以非 root 运行：只有短命的
    // setline-agent/setline-apply 需要 root，而它们调用的
    // --agent-type / --agent-peers / --sync-map 在上面就返回了。退出码 2 对上 unit 里的
    // RestartPreventExitStatus=2，不会陷入「重启五次后 failed」。
    if (rejectsRootUser(geteuid())) {
      stderr.writefln("%s", rootRunRefusalMessage());
      return 2;
    }

    auto config = loadConfig(configPath, control);

    // listen:false 没有代理进程可启动，保留「渲染一轮后退出」的用法。
    // peers 仍由 agent 的 render 入口处理；这里只服务显式无监听的部署。
    if (config.listenDisabled) {
      renderAgentOnce(config.agent, config.routes);
      stdout.writefln("setline rendered fragments without a listener (listen:false)");
      return 0;
    }

    initialize(config, configPath);
    warnIfFdBudgetInsufficient(config.maxConnections);
    // 单机部署：setline.service 既当本机代理（也是 basctl 推路由的登记处），
    // 又对本机路由变化即时渲染。配置了 peers 时片段由 setline-agent 聚合远端路由后
    // 渲染，service 只负责监听/代理，避免两个数据源互相覆盖。
    if (config.agent.type.length > 0 && usesLocalRoutes(config.agent)) {
      auto agent = config.agent;
      void renderLocal(HostRoutes[] routes) {
        try {
          renderLocalAgent(agent, routes);
        } catch (Exception e) {
          stderr.writefln("setline agent render failed: %s", e.msg);
        }
      }
      setRoutesChangedHook(&renderLocal);
      renderLocal(routesSnapshot());
    }

    serve(config.listen, config.adminListen);
    return 0;
  } catch (Exception e) {
    stderr.writefln("Config %s is invalid: %s", configPath, e.msg);
    return 1;
  }
}

/** `setline render`：由 setline-agent 调用的一轮渲染，不监听端口。

    数据源由 `[agent] peers` 决定：有 peers 时聚合远端路由表，否则渲染本机拓扑。
    这个入口保持非 root：它解析 peer 的 HTTP/JSON，不能继承 setline-agent 的特权。
*/
private int runRender(string[] args) {
  string confPath = defaultControlPath;
  string configPath;
  bool help;
  auto helpInfo = getopt(args,
    "conf", "Path to setline.conf", &confPath,
    "file|f", "Path to topology JSON (overrides [topology] file)", &configPath,
    "help|h", "Show this help", &help);
  if (help) {
    defaultGetoptPrinter("Usage: setline render [--conf setline.conf] [-f setline.json]",
      helpInfo.options);
    return 0;
  }

  try {
    if (confPath != defaultControlPath && !exists(confPath))
      throw new Exception("control config not found: " ~ confPath);
    auto control = loadControlConfig(confPath);
    if (configPath.length == 0)
      configPath = control.topologyPath;
    if (rejectsRootUser(geteuid())) {
      stderr.writefln("%s", rootRunRefusalMessage());
      return 2;
    }
    auto config = loadConfig(configPath, control);
    if (config.agent.type.length == 0) {
      stdout.writefln("setline agent type is empty, nothing to render");
      return 0;
    }
    renderAgentOnce(config.agent, config.routes);
    return 0;
  } catch (Exception e) {
    stderr.writefln("Config %s is invalid: %s", configPath, e.msg);
    return 1;
  }
}

/** 读取下载命令使用的 setline.conf；缺失是配置错误，不再退回命令行参数。 */
private ControlConfig commandControl(string confPath) {
  if (!exists(confPath))
    throw new Exception("control config not found: " ~ confPath);
  return loadControlConfig(confPath);
}

/** `setline pull`：按 `[remote]` 下载 peers、代理主配置和证书。 */
private int runPull(string[] args) {
  string confPath = defaultControlPath;
  bool help;
  auto helpInfo = getopt(args,
    "conf", "Path to setline.conf", &confPath,
    "help|h", "Show this help", &help);
  auto usage = "Usage: setline pull [--conf setline.conf]";
  if (help) {
    defaultGetoptPrinter(usage, helpInfo.options);
    return 0;
  }

  try {
    auto control = commandControl(confPath);
    validateRemoteConfig(control.remote, confPath);
    auto peersText = downloadConfig(control.remote.url, control.remote.profile, control.remote.token,
      DownloadKind.peers);
    auto peers = parseDownloadedPeers(peersText);
    string proxy;
    if (control.proxyPath.length > 0) {
      proxy = downloadConfig(control.remote.url, control.remote.profile, control.remote.token,
        DownloadKind.proxy);
    }
    auto cert = downloadConfig(control.remote.url, control.remote.profile, control.remote.token,
      DownloadKind.certificate);
    auto key = downloadConfig(control.remote.url, control.remote.profile, control.remote.token,
      DownloadKind.certificateKey);

    // 四份内容都拿到且证书对通过校验后才触碰磁盘，网络或 PEM 错误不会留下半套更新。
    auto updatedControl = rewriteAgentPeers(readText(confPath), peers);
    auto certChanged = writeCertificatePair(defaultCertificateDir, cert, key);
    if (control.proxyPath.length > 0) {
      auto proxyChanged = writeDownloaded(control.proxyPath, proxy);
      stdout.writefln("setline downloaded proxy config %s (%s)", control.proxyPath,
        proxyChanged ? "updated" : "unchanged");
    }
    stdout.writefln("setline downloaded certificate pair %s (%s)", defaultCertificateDir,
      certChanged ? "updated" : "unchanged");
    auto changed = writeDownloaded(confPath, updatedControl);
    stdout.writefln("setline updated peers in %s (%s)", confPath,
      changed ? "updated" : "unchanged");
    return 0;
  } catch (Exception e) {
    stderr.writefln("setline pull failed: %s", e.msg);
    return 1;
  }
}

/** `setline init [path]`：写入 setline.conf 模板，已有文件保持不动。 */
private int runInit(string[] args) {
  bool help;
  auto helpInfo = getopt(args, "help|h", "Show this help", &help);
  auto usage = "Usage: setline init [setline.conf]";
  if (help) {
    defaultGetoptPrinter(usage, helpInfo.options);
    return 0;
  }
  auto path = args.length > 1 ? args[1] : defaultControlPath;
  try {
    auto written = writeControlConfigTemplate(path);
    stdout.writefln("%s %s", written ? "wrote" : "kept", path);
    return 0;
  } catch (Exception e) {
    stderr.writefln("setline init failed: %s", e.msg);
    return 1;
  }
}

/** 启动时对照 RLIMIT_NOFILE 告警；公式与部署文档、unit 保持一致。 */
void warnIfFdBudgetInsufficient(size_t maxConnections) {
  auto required = requiredFileDescriptorBudget(maxConnections);
  rlimit limit;
  if (getrlimit(RLIMIT_NOFILE, &limit) == 0 && limit.rlim_cur < required) {
    stderr.writefln(
      "Warning: RLIMIT_NOFILE=%s is below required fd budget %s " ~
      "(2*maxConnections+%s=%s*2+64); raise systemd LimitNOFILE",
      limit.rlim_cur, required, 64, maxConnections);
  }
}

/** 单机部署：把本机路由表渲染成边缘代理片段（agent.output 由配置校验保证非空）。 */
private void renderLocalAgent(AgentConfig agent, HostRoutes[] routes) {
  writeSnippets(renderAgentSnippets(agent, routes), agent.output);
}

/** 渲染一轮片段并写入 output 根目录。

    规则模式下会有多个片段文件（例如 haproxy 的 backend 片段加路由 map），
    全部按内容哈希幂等写出，未变化的文件不会被触碰；目录不存在时逐级创建。
    peers 非空时数据来自远端 setline，否则使用传入的本机拓扑。重渲染由外层
    systemd timer 每隔一段时间再跑一次，进程里不做调度。
*/
int renderAgentOnce(AgentConfig agent, HostRoutes[] localRoutes) {
  writeSnippets(renderAgentSnippets(agent, localRoutes), agent.output);
  return 0;
}
