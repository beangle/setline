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
import setline.model : AgentConfig;
import setline.peer : renderAgentConfig, writeSnippet;
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
  bool check;
  bool help;
  auto helpInfo = getopt(args,
    "file|f", "Path to setline JSON config", &configPath,
    "check|c", "Check config and exit", &check,
    "help|h", "Show this help", &help);

  if (help) {
    defaultGetoptPrinter("Usage: setline [-f setline.json] [-c]", helpInfo.options);
    return 0;
  }

  try {
    if (check) {
      checkConfig(configPath);
      stdout.writefln("Config %s is valid", configPath);
      return 0;
    }

    auto config = loadConfig(configPath);
    if (config.agent.type.length > 0) {
      return runAgent(config.agent);
    }

    initialize(config, configPath);

    stdout.writefln("setline listening on http://%s:%s", config.listen.host, config.listen.port);
    serve(config.listen);
    return 0;
  } catch (Exception e) {
    stderr.writefln("Config %s is invalid: %s", configPath, e.msg);
    return 1;
  }
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

/** 执行一轮 agent 同步：渲染片段并写入 output，未配置 output 时写到标准输出。 */
void syncAgentOnce(AgentConfig agent) {
  auto text = renderAgentConfig(agent);
  if (agent.output.length == 0) {
    stdout.write(text);
    return;
  }
  auto changed = writeSnippet(agent.output, text);
  stdout.writefln("setline agent wrote %s (%s)", agent.output, changed ? "updated" : "unchanged");
}
