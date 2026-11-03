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

module setline_agent_main;

import core.sys.posix.unistd : geteuid;
import std.conv : octal;
import std.file : exists, mkdirRecurse, readText, setAttributes;
import std.getopt : GetOptException, defaultGetoptPrinter, getopt;
import std.path : buildPath;
import std.stdio : stderr, stdout;
import std.string : strip;

import setline.control :
  ControlConfig, defaultCertificateDir, defaultControlPath, loadControlConfig, renderApplyShell,
  validateRemoteConfig, writeControlConfigTemplate;
import setline.download : DownloadKind, RemoteManifest, clearRemoteStage, downloadConfig,
  downloadManifest, manifestResourceCertificate, manifestResourceCertificateKey,
  manifestResourceProxy, manifestResourceRoutes, parseDownloadedRoutes, parseRemoteManifest,
  readRemoteManifest,
  installRemoteStage, RemoteInstallTargets, remoteStagePath, remoteStatePath, resourceChanged,
  sha256Hex, stagedCertificateEmptyName, stagedCertificateKeyName,
  stagedCertificateName, stagedManifestName, stagedProxyName,
  writeCertificatePair, writeDownloaded, writeRemoteManifest;
import setline.mapsync : syncMap;
import setline.model : AgentConfig, HostRoutes;
import setline.render : renderAgentSnippets, writeSnippets;
import setline.util : rejectsRootUser, rootRunRefusalMessage;

/** setline-agent 入口：只读取 setline.conf，负责渲染、下载与配置自省。 */
int main(string[] args) {
  version (linux) {
  } else {
    static assert(false, "setline is Linux-only");
  }

  try {
    if (args.length > 1) {
      if (args[1] == "pull")
        return runPull(args[1 .. $]);
      if (args[1] == "render")
        return runRender(args[1 .. $]);
      if (args[1] == "init")
        return runInit(args[1 .. $]);
    }
    return runDefault(args);
  } catch (GetOptException e) {
    stderr.writefln("setline-agent: %s; use -h for help", e.msg);
    return 2;
  }
}

/** 默认动作是一轮渲染；`--agent-*` 与 `--sync-map` 是给脚本调用的短命令。 */
private int runDefault(string[] args) {
  string confPath = defaultControlPath;
  bool agentType;
  bool applyConfig;
  bool check;
  bool help;
  string syncMapSocket;
  auto helpInfo = getopt(args,
    "config", "Path to setline.conf", &confPath,
    "agent-type", "Print [agent] type from setline.conf and exit", &agentType,
    "apply-config", "Print setline-apply settings as shell assignments and exit", &applyConfig,
    "sync-map", "Sync a HAProxy map file into the running instance via its admin socket",
      &syncMapSocket,
    "check|c", "Check config and exit", &check,
    "help|h", "Show this help", &help);

  if (help) {
    defaultGetoptPrinter("Usage: setline-agent [--config setline.conf] " ~
      "[--agent-type] [--apply-config] [-c]\n" ~
      "       setline-agent render [--config setline.conf]\n" ~
      "       setline-agent pull [--check [--stage] | --install] [--config setline.conf]\n" ~
      "       setline-agent init [--config setline.conf]\n" ~
      "       setline-agent --sync-map <socket> <mapfile>", helpInfo.options);
    return 0;
  }

  // 规则模式的 map 热同步：走独立出口码，setline-apply 只在 0 时跳过 reload。
  if (syncMapSocket.length > 0) {
    if (args.length != 2) {
      stderr.writefln("usage: setline-agent --sync-map <socket> <mapfile>");
      return 2;
    }
    try {
      auto change = syncMap(syncMapSocket, args[1], readText(args[1]));
      stdout.writefln("setline-agent hot-synced %s: +%d ~%d -%d", args[1], change.added.length,
        change.updated.length, change.removed.length);
      return 0;
    } catch (Exception e) {
      stderr.writefln("map hot-sync unavailable: %s", e.msg);
      return 4;
    }
  }

  try {
    auto control = commandControl(confPath);

    // 给 setline-apply 的自动分派用：只回显 [agent] type（没配就是空行），
    // 让 shell 侧不必自己解析 INI。
    if (agentType) {
      stdout.writefln("%s", control.agent.type);
      return 0;
    }
    if (applyConfig) {
      stdout.write(renderApplyShell(control));
      return 0;
    }

    if (check) {
      stdout.writefln("Config %s is valid", confPath);
      return 0;
    }

    if (rejectsRootUser(geteuid())) {
      stderr.writefln("%s", rootRunRefusalMessage());
      return 2;
    }
    renderAgentOnce(control.agent);
    return 0;
  } catch (Exception e) {
    stderr.writefln("Config %s is invalid: %s", confPath, e.msg);
    return 1;
  }
}

/** `setline-agent render`：读取 setline.conf 渲染一轮片段，不监听端口。 */
private int runRender(string[] args) {
  string confPath = defaultControlPath;
  bool help;
  auto helpInfo = getopt(args,
    "config", "Path to setline.conf", &confPath,
    "help|h", "Show this help", &help);
  if (help) {
    defaultGetoptPrinter("Usage: setline-agent render [--config setline.conf]",
      helpInfo.options);
    return 0;
  }

  try {
    auto control = commandControl(confPath);
    // 渲染会处理远端 JSON/文件，不能继承 root。
    if (rejectsRootUser(geteuid())) {
      stderr.writefln("%s", rootRunRefusalMessage());
      return 2;
    }
    if (control.agent.type.length == 0) {
      stdout.writefln("setline-agent type is empty, nothing to render");
      return 0;
    }
    renderAgentOnce(control.agent);
    return 0;
  } catch (Exception e) {
    stderr.writefln("Config %s is invalid: %s", confPath, e.msg);
    return 1;
  }
}

/** 读取下载命令使用的 setline.conf；缺失是配置错误。 */
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
  case DownloadKind.routes:
    throw new Exception("setline routes cannot be fetched as a manifest resource");
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
  auto text = downloadConfig(control.remote.url, control.remote.project, control.remote.token, kind, control.remote.ip);
  auto actual = sha256Hex(text);
  if (actual != expected)
    throw new Exception("downloaded " ~ name ~ " hash mismatch: expected " ~ expected ~
        ", got " ~ actual);
  return text;
}

/** 按清单同步远程资源。`changedOnly` 时只下载 SHA-256 与上次成功状态不同的资源。
 *  `stageOnly` 时写入 `remote-stage/`，最终安装由 root 的 `pull --install` 完成。
 *  返回 proxy 主配置或证书是否变化。 */
private bool pullRemote(ControlConfig control, string confPath, bool changedOnly, bool stageOnly,
    ref bool unchanged) {
  if (stageOnly)
    clearRemoteStage(control.agent.output);
  auto etagPath = buildPath(control.agent.output, "remote.etag");
  auto knownEtag = changedOnly && exists(etagPath) ? readText(etagPath).strip : "";
  bool notModified;
  string etag;
  auto manifestText = downloadManifest(control.remote.url, control.remote.project,
      control.remote.token, control.remote.ip, knownEtag, notModified, etag);
  if (notModified) {
    unchanged = true;
    return false;
  }
  auto manifest = parseRemoteManifest(manifestText);
  auto statePath = remoteStatePath(control.agent.output);
  auto previous = changedOnly ? readRemoteManifest(statePath) : RemoteManifest.init;
  // routes 只在 manifest 的 routes 哈希变化时刷新；失败保留上次缓存。
  auto routesChanged = !changedOnly || resourceChanged(previous, manifest, manifestResourceRoutes);
  bool routesOk = true;
  if (routesChanged) {
    try {
      auto routeText = downloadConfig(control.remote.url, control.remote.project,
          control.remote.token, DownloadKind.routes, control.remote.ip);
      parseDownloadedRoutes(routeText);
      writeDownloaded(buildPath(control.agent.output, "routes.json"), routeText);
    } catch (Exception e) {
      routesOk = false;
      stderr.writefln("setline-agent: route refresh failed, keeping cache: %s", e.msg);
    }
  }
  // 路由没刷新成功时不要记下新 ETag，否则下一轮 304 会让旧 routes 永久留在缓存里。
  if (routesOk)
    writeDownloaded(etagPath, etag ~ "\n");

  auto proxyManaged = control.proxyPath.length > 0;
  auto proxyChanged = proxyManaged
      && (!changedOnly || resourceChanged(previous, manifest, manifestResourceProxy));
  auto certificateChanged = !changedOnly
      || resourceChanged(previous, manifest, manifestResourceCertificate);
  auto keyChanged = !changedOnly
      || resourceChanged(previous, manifest, manifestResourceCertificateKey);
  auto pairChanged = certificateChanged || keyChanged;

  if (changedOnly && !proxyChanged && !pairChanged) {
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

  string proxy;
  string cert;
  string key;
  // 先把变化的资源全部取回并验哈希，再触碰磁盘。
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
    stdout.writefln("setline-agent staged remote configuration in %s", stageDir);
    return proxyChanged || pairChanged;
  }

  if (proxyChanged) {
    auto changed = writeDownloaded(control.proxyPath, proxy);
    stdout.writefln("setline-agent downloaded proxy config %s (%s)", control.proxyPath,
      changed ? "updated" : "unchanged");
  }
  if (pairChanged) {
    auto changed = writeCertificatePair(defaultCertificateDir, cert, key);
    stdout.writefln("setline-agent downloaded certificate pair %s (%s)", defaultCertificateDir,
      changed ? "updated" : "unchanged");
  }
  writeRemoteManifest(statePath, manifest);
  return proxyChanged || pairChanged;
}

/** `setline-agent pull`：按 `[remote]` 下载代理主配置和证书。 */
private int runPull(string[] args) {
  string confPath = defaultControlPath;
  bool check;
  bool stage;
  bool install;
  bool help;
  auto helpInfo = getopt(args,
    "config", "Path to setline.conf", &confPath,
    "check", "Only download resources whose manifest hash changed", &check,
    "stage", "Write changed resources to the unprivileged staging directory", &stage,
    "install", "Install a staged download as root", &install,
    "help|h", "Show this help", &help);
  auto usage =
    "Usage: setline-agent pull [--check [--stage] | --install] [--config setline.conf]";
  if (help) {
    defaultGetoptPrinter(usage, helpInfo.options);
    return 0;
  }
  if ((stage && !check) || (install && (check || stage))) {
    stderr.writefln("%s", usage);
    return 2;
  }
  if (stage && geteuid() == 0) {
    stderr.writefln("setline-agent pull --stage must run as the unprivileged setline user");
    return 2;
  }
  if (install && geteuid() != 0) {
    stderr.writefln("setline-agent pull --install must run as root");
    return 2;
  }

  try {
    auto control = commandControl(confPath);
    if (install) {
      auto staged = installRemoteStage(remoteStagePath(control.agent.output),
        RemoteInstallTargets(confPath, control.proxyPath, defaultCertificateDir,
          remoteStatePath(control.agent.output)));
      if (staged)
        stdout.writefln("setline-agent installed staged remote configuration");
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
    bool unchanged;
    auto changed = pullRemote(control, confPath, check, stage, unchanged);
    if (check && unchanged)
      return 12;
    // 10 只给 setline-agent-run：proxy 主配置/证书变化不一定改变片段哈希，
    // 需要它给 setline-apply 加 --force，确保验证并 reload 一次。
    return check && changed ? 10 : 0;
  } catch (Exception e) {
    stderr.writefln("setline-agent pull failed: %s", e.msg);
    return 1;
  }
}

/** `setline-agent init --config <path>`：写入 setline.conf 模板，已有文件保持不动。 */
private int runInit(string[] args) {
  string path = defaultControlPath;
  bool help;
  auto helpInfo = getopt(args,
    "config", "Path to setline.conf", &path,
    "help|h", "Show this help", &help);
  auto usage = "Usage: setline-agent init [--config setline.conf]";
  if (help) {
    defaultGetoptPrinter(usage, helpInfo.options);
    return 0;
  }
  if (args.length > 1) {
    stderr.writefln("%s", usage);
    return 2;
  }
  try {
    auto written = writeControlConfigTemplate(path);
    stdout.writefln("%s %s", written ? "wrote" : "kept", path);
    return 0;
  } catch (Exception e) {
    stderr.writefln("setline-agent init failed: %s", e.msg);
    return 1;
  }
}

/** 渲染一轮片段并写入 output 根目录。 */
private void renderAgentOnce(AgentConfig agent) {
  if (agent.type.length == 0) {
    stdout.writefln("setline-agent type is empty, nothing to render");
    return;
  }
  HostRoutes[] routes;
  auto routePath = buildPath(agent.output, "routes.json");
  if (exists(routePath))
    routes = parseDownloadedRoutes(readText(routePath));
  writeSnippets(renderAgentSnippets(agent, routes), agent.output);
}
