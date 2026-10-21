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
import std.conv : octal;
import std.file : exists, mkdirRecurse, readText, setAttributes;
import std.getopt : defaultGetoptPrinter, getopt;
import std.path : buildPath;
import std.stdio : stderr, stdout;

import core.sys.posix.unistd : geteuid;

import setline.config;
import setline.control :
  ControlConfig, defaultCertificateDir, defaultControlPath, loadControlConfig, renderApplyShell,
  validateRemoteConfig, writeControlConfigTemplate;
import setline.download : DownloadKind, RemoteManifest, clearRemoteStage, downloadConfig,
  manifestResourceCertificate, manifestResourceCertificateKey, manifestResourcePeers,
  manifestResourceProxy, parseDownloadedPeers, parseRemoteManifest, readRemoteManifest,
  installRemoteStage, RemoteInstallTargets, remoteStagePath, remoteStatePath, resourceChanged,
  rewriteAgentPeers, sha256Hex, stagedCertificateEmptyName, stagedCertificateKeyName,
  stagedCertificateName, stagedControlName, stagedManifestName, stagedPeersName, stagedProxyName,
  writeCertificatePair, writeDownloaded, writeRemoteManifest;
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
      "       setline pull [--check [--stage] | --install] [--conf setline.conf]\n" ~
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

/** 下载一份资源并核对清单里的 SHA-256；空 Body 的哈希不产生网络请求。 */
private string fetchVerified(const ControlConfig control, const RemoteManifest manifest,
    DownloadKind kind) {
  string name;
  final switch (kind) {
  case DownloadKind.manifest:
    throw new Exception("setline manifest cannot be fetched as a resource");
  case DownloadKind.peers:
    name = manifestResourcePeers;
    break;
  case DownloadKind.proxy:
    name = manifestResourceProxy;
    break;
  case DownloadKind.certificate:
    name = manifestResourceCertificate;
    break;
  case DownloadKind.certificateKey:
    name = manifestResourceCertificateKey;
    break;
  }
  auto expected = manifest.resources.get(name, "");
  if (expected == sha256Hex(""))
    return "";
  auto text = downloadConfig(control.remote.url, control.remote.profile, control.remote.token, kind);
  auto actual = sha256Hex(text);
  if (actual != expected)
    throw new Exception("downloaded " ~ name ~ " hash mismatch: expected " ~ expected ~
        ", got " ~ actual);
  return text;
}

/** 按清单同步远程资源。`changedOnly` 时只下载 SHA-256 与上次成功状态不同的资源。
 *  `stageOnly` 时写入 `remote-stage/`，最终安装由 root 的 `pull --install` 完成。
 *  返回 proxy 主配置或证书是否变化；peers 变化会由正常 render/apply 发现。 */
private bool pullRemote(ControlConfig control, string confPath, bool changedOnly, bool stageOnly) {
  if (stageOnly)
    clearRemoteStage(control.agent.output);
  auto manifest = parseRemoteManifest(downloadConfig(control.remote.url, control.remote.profile,
      control.remote.token, DownloadKind.manifest));
  auto statePath = remoteStatePath(control.agent.output);
  auto previous = changedOnly ? readRemoteManifest(statePath) : RemoteManifest.init;

  auto peersChanged = !changedOnly
      || resourceChanged(previous, manifest, manifestResourcePeers);
  auto proxyManaged = control.proxyPath.length > 0;
  auto proxyChanged = proxyManaged
      && (!changedOnly || resourceChanged(previous, manifest, manifestResourceProxy));
  auto certificateChanged = !changedOnly
      || resourceChanged(previous, manifest, manifestResourceCertificate);
  auto keyChanged = !changedOnly
      || resourceChanged(previous, manifest, manifestResourceCertificateKey);
  auto pairChanged = certificateChanged || keyChanged;

  if (changedOnly && !peersChanged && !proxyChanged && !pairChanged) {
    if (previous.schemaVersion != manifest.schemaVersion)
      writeRemoteManifest(statePath, manifest);
    return false;
  }

  auto certificateExpected = manifest.resources.get(manifestResourceCertificate, "");
  auto keyExpected = manifest.resources.get(manifestResourceCertificateKey, "");
  auto certificateEmpty = certificateExpected == sha256Hex("");
  auto keyEmpty = keyExpected == sha256Hex("");
  if (certificateEmpty != keyEmpty)
    throw new Exception("setline manifest certificate and certificate-key must be both present or both empty");

  string peersText;
  string proxy;
  string cert;
  string key;
  // 先把变化的资源全部取回并验哈希，再触碰磁盘。
  if (peersChanged)
    peersText = fetchVerified(control, manifest, DownloadKind.peers);
  if (proxyChanged) {
    proxy = fetchVerified(control, manifest, DownloadKind.proxy);
    if (proxy.length == 0)
      throw new Exception("downloaded proxy config is empty");
  }
  if (pairChanged) {
    if (!certificateEmpty) {
      cert = fetchVerified(control, manifest, DownloadKind.certificate);
      key = fetchVerified(control, manifest, DownloadKind.certificateKey);
    }
  }

  if (stageOnly) {
    auto stageDir = remoteStagePath(control.agent.output);
    mkdirRecurse(stageDir);
    setAttributes(stageDir, octal!700);
    if (peersChanged) {
      writeDownloaded(buildPath(stageDir, stagedPeersName), peersText);
      auto peers = parseDownloadedPeers(peersText);
      auto updatedControl = rewriteAgentPeers(readText(confPath), peers);
      writeDownloaded(buildPath(stageDir, stagedControlName), updatedControl);
    }
    if (proxyChanged)
      writeDownloaded(buildPath(stageDir, stagedProxyName), proxy);
    if (pairChanged) {
      if (certificateEmpty) {
        writeDownloaded(buildPath(stageDir, stagedCertificateEmptyName), "");
      } else {
        writeDownloaded(buildPath(stageDir, stagedCertificateName), cert);
        writeDownloaded(buildPath(stageDir, stagedCertificateKeyName), key);
      }
    }
    writeRemoteManifest(buildPath(stageDir, stagedManifestName), manifest);
    stdout.writefln("setline staged remote configuration in %s", stageDir);
    return proxyChanged || pairChanged;
  }

  if (peersChanged) {
    auto peers = parseDownloadedPeers(peersText);
    auto updatedControl = rewriteAgentPeers(readText(confPath), peers);
    auto changed = writeDownloaded(confPath, updatedControl);
    stdout.writefln("setline updated peers in %s (%s)", confPath,
      changed ? "updated" : "unchanged");
  }
  if (proxyChanged) {
    auto changed = writeDownloaded(control.proxyPath, proxy);
    stdout.writefln("setline downloaded proxy config %s (%s)", control.proxyPath,
      changed ? "updated" : "unchanged");
  }
  if (pairChanged) {
    auto changed = writeCertificatePair(defaultCertificateDir, cert, key);
    stdout.writefln("setline downloaded certificate pair %s (%s)", defaultCertificateDir,
      changed ? "updated" : "unchanged");
  }
  writeRemoteManifest(statePath, manifest);
  return proxyChanged || pairChanged;
}

/** `setline pull`：按 `[remote]` 下载 peers、代理主配置和证书。 */
private int runPull(string[] args) {
  string confPath = defaultControlPath;
  bool check;
  bool stage;
  bool install;
  bool help;
  auto helpInfo = getopt(args,
    "conf", "Path to setline.conf", &confPath,
    "check", "Only download resources whose manifest hash changed", &check,
    "stage", "Write changed resources to the unprivileged staging directory", &stage,
    "install", "Install a staged download as root", &install,
    "help|h", "Show this help", &help);
  auto usage = "Usage: setline pull [--check [--stage] | --install] [--conf setline.conf]";
  if (help) {
    defaultGetoptPrinter(usage, helpInfo.options);
    return 0;
  }
  if ((stage && !check) || (install && (check || stage))) {
    stderr.writefln("%s", usage);
    return 2;
  }
  if (stage && geteuid() == 0) {
    stderr.writefln("setline pull --stage must run as the unprivileged setline user");
    return 2;
  }
  if (install && geteuid() != 0) {
    stderr.writefln("setline pull --install must run as root");
    return 2;
  }

  try {
    auto control = commandControl(confPath);
    if (install) {
      auto staged = installRemoteStage(remoteStagePath(control.agent.output),
        RemoteInstallTargets(confPath, control.proxyPath, defaultCertificateDir,
          remoteStatePath(control.agent.output)));
      if (staged)
        stdout.writefln("setline installed staged remote configuration");
      return 0;
    }
    // --check 只由显式命令调用；没有完整 remote 配置时安静跳过，
    // 不把「本地单机部署」变成一条错误日志。
    if (check && !control.remote.complete()) {
      if (stage)
        clearRemoteStage(control.agent.output);
      return 0;
    }
    validateRemoteConfig(control.remote, confPath);
    auto changed = pullRemote(control, confPath, check, stage);
    // 10 只给 setline-agent：proxy 主配置/证书变化不一定改变片段哈希，
    // 需要它给 setline-apply 加 --force，确保验证并 reload 一次。
    return check && changed ? 10 : 0;
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
