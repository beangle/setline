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

import core.thread : Thread;
import core.time : msecs;
import std.getopt : defaultGetoptPrinter, getopt;
import std.stdio : stderr, stdout;

import setline.config;
import setline.model : AgentConfig, HostRoutes;
import setline.peer : renderAgentSnippets, writeSnippets;
import setline.server;
import setline.state;
import setline.util : defaultConfigPath;

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
  auto helpInfo = getopt(args,
    "file|f", "Path to setline JSON config", &configPath,
    "agent-type", "Print agent.type from the config and exit", &agentType,
    "check|c", "Check config and exit", &check,
    "help|h", "Show this help", &help);

  if (help) {
    defaultGetoptPrinter("Usage: setline [-f setline.json] [--agent-type] [-c]", helpInfo.options);
    return 0;
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

    auto config = loadConfig(configPath);
    // 配了 peers/remote 的机器是「纯渲染机」：不监听，按 sync 拉对端路由表。
    if (config.agent.type.length > 0 && !usesLocalRoutes(config.agent)) {
      return runAgent(config.agent);
    }

    initialize(config, configPath);
    // 单机部署：既当本机代理（也是 basctl 推路由的登记处），又把自己的路由表渲染成片段。
    // 片段在启动时出一版，之后每次管理接口改路由都重渲染，不需要 peers，也不需要轮询。
    if (config.agent.type.length > 0) {
      auto agent = config.agent;
      void renderLocal(HostRoutes[] routes) {
        try {
          renderLocalAgent(agent, routes);
        } catch (Exception e) {
          stderr.writefln("setline agent sync failed: %s", e.msg);
        }
      }
      setRoutesChangedHook(&renderLocal);
      renderLocal(routesSnapshot());
    }

    stdout.writefln("setline listening on http://%s:%s", config.listen.host, config.listen.port);
    serve(config.listen);
    return 0;
  } catch (Exception e) {
    stderr.writefln("Config %s is invalid: %s", configPath, e.msg);
    return 1;
  }
}

/** 单机部署：把本机路由表渲染成边缘代理片段（agent.output 由配置校验保证非空）。 */
private void renderLocalAgent(AgentConfig agent, HostRoutes[] routes) {
  writeSnippets(renderAgentSnippets(agent, routes), agent.output);
}

/** 运行 agent 模式：渲染片段并按 `agent.sync` 决定跑一轮还是常驻重复。 */
int runAgent(AgentConfig agent) {
  if (agent.sync.mode == "interval" && agent.output.length > 0) {
    while (true) {
      try {
        syncAgentOnce(agent);
      } catch (Exception e) {
        stderr.writefln("setline agent sync failed: %s", e.msg);
      }
      Thread.sleep(agent.sync.intervalMillis.msecs);
    }
  }
  syncAgentOnce(agent);
  return 0;
}

/** 执行一轮 agent 同步：渲染片段并写入 output，未配置 output 时写到标准输出。

    规则模式下会有多个片段文件（例如 haproxy 的 backend 片段加路由 map），
    全部按内容哈希幂等写出，未变化的文件不会被触碰。
*/
void syncAgentOnce(AgentConfig agent) {
  writeSnippets(renderAgentSnippets(agent), agent.output);
}
