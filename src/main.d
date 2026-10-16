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
import std.file : readText;
import std.getopt : defaultGetoptPrinter, getopt;
import std.stdio : stderr, stdout;

import core.sys.posix.unistd : geteuid;

import setline.config;
import setline.mapsync : syncMap;
import setline.model : AgentConfig, HostRoutes;
import setline.peer : renderAgentSnippets, writeSnippets;
import setline.server;
import setline.state;
import setline.util :
  defaultConfigPath, rejectsRootUser, requiredFileDescriptorBudget, rootRunRefusalMessage;

/** 解析命令行参数，检查或启动 setline 服务。 */
int main(string[] args) {
  version (linux) {
  } else {
    static assert(false, "setline is Linux-only");
  }

  string configPath = defaultConfigPath;
  bool agentType;
  bool check;
  bool help;
  string syncMapSocket;
  auto helpInfo = getopt(args,
    "file|f", "Path to setline JSON config", &configPath,
    "agent-type", "Print agent.type from the config and exit", &agentType,
    "sync-map", "Sync a HAProxy map file into the running instance via its admin socket",
      &syncMapSocket,
    "check|c", "Check config and exit", &check,
    "help|h", "Show this help", &help);

  if (help) {
    defaultGetoptPrinter("Usage: setline [-f setline.json] [--agent-type] [-c] " ~
      "[--sync-map <socket> <mapfile>]", helpInfo.options);
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
    // 给 setline-apply 的自动分派用：只回显 agent.type（没配 agent 就是空行），
    // 让 shell 侧不必自己解析 JSON。
    if (agentType) {
      stdout.writefln("%s", loadConfig(configPath).agent.type);
      return 0;
    }

    if (check) {
      checkConfig(configPath);
      stdout.writefln("Config %s is valid", configPath);
      return 0;
    }

    // 主服务与渲染 agent 都以非 root 运行：只有 setline-apply 需要 root，而它调用的
    // --agent-type / --sync-map 在上面就返回了。退出码 2 对上 unit 里的
    // RestartPreventExitStatus=2，不会陷入「重启五次后 failed」。
    if (rejectsRootUser(geteuid())) {
      stderr.writefln("%s", rootRunRefusalMessage());
      return 2;
    }

    auto config = loadConfig(configPath);
    // 配了 peers 的机器是「纯渲染机」：不监听，渲染一轮就退出，
    // 周期刷新由 setline-render.timer（systemd）驱动。
    if (config.agent.type.length > 0 && !usesLocalRoutes(config.agent)) {
      return renderAgentOnce(config.agent);
    }

    initialize(config, configPath);
    if (!config.listenDisabled) {
      warnIfFdBudgetInsufficient(config.maxConnections);
    }
    // 单机部署：既当本机代理（也是 basctl 推路由的登记处），又把自己的路由表渲染成片段。
    // 片段在启动时出一版，之后每次管理接口改路由都重渲染，不需要 peers，也不需要轮询。
    if (config.agent.type.length > 0) {
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

    // 纯渲染部署：只把配置文件里的路由渲染成片段，不绑监听，也没有管理接口。
    if (config.listenDisabled) {
      stdout.writefln("setline rendered fragments without a listener (listen:false)");
      return 0;
    }

    serve(config.listen, config.adminListen);
    return 0;
  } catch (Exception e) {
    stderr.writefln("Config %s is invalid: %s", configPath, e.msg);
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

/** 纯渲染机（peers，没有监听）：渲染一轮片段并写入 output 根目录。

    规则模式下会有多个片段文件（例如 haproxy 的 backend 片段加路由 map），
    全部按内容哈希幂等写出，未变化的文件不会被触碰；目录不存在时逐级创建。
    未配置 output 时写到标准输出。重渲染由外层 systemd timer 每隔一段时间再跑一次，
    进程里不做调度。
*/
int renderAgentOnce(AgentConfig agent) {
  writeSnippets(renderAgentSnippets(agent), agent.output);
  return 0;
}
