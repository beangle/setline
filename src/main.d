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
import core.sys.posix.unistd : geteuid;
import std.getopt : GetOptException, defaultGetoptPrinter, getopt;
import std.stdio : stderr, stdout;

import setline.config : checkConfig, defaultConfigPath, loadConfig;
import setline.server : serve;
import setline.state : initialize;
import setline.util : rejectsRootUser, requiredFileDescriptorBudget, rootRunRefusalMessage;

/** setline 服务入口：只读取 setline.json，监听并按路由代理本机后端。 */
int main(string[] args) {
  version (linux) {
  } else {
    static assert(false, "setline is Linux-only");
  }

  string configPath = defaultConfigPath;
  bool check;
  bool help;

  try {
    auto helpInfo = getopt(args,
      "f", "Path to setline.json", &configPath,
      "check|c", "Check config and exit", &check,
      "help|h", "Show this help", &help);

    if (help) {
      defaultGetoptPrinter("Usage: setline [-f setline.json] [-c]", helpInfo.options);
      return 0;
    }

    if (check) {
      checkConfig(configPath);
      stdout.writefln("Config %s is valid", configPath);
      return 0;
    }

    // setline 是面向网络的数据平面，必须保持非 root；特权留给短命的
    // setline-agent-run / setline-apply。退出码 2 对上 unit 的 RestartPreventExitStatus=2。
    if (rejectsRootUser(geteuid())) {
      stderr.writefln("%s", rootRunRefusalMessage());
      return 2;
    }

    auto config = loadConfig(configPath);
    initialize(config, configPath);
    warnIfFdBudgetInsufficient(config.maxConnections);
    serve(config.listen, config.adminListen);
    return 0;
  } catch (GetOptException e) {
    stderr.writefln("setline: %s; use -h for help", e.msg);
    return 2;
  } catch (Exception e) {
    stderr.writefln("Config %s is invalid: %s", configPath, e.msg);
    return 1;
  }
}

/** 启动时对照 RLIMIT_NOFILE 告警；公式与部署文档、unit 保持一致。 */
private void warnIfFdBudgetInsufficient(size_t maxConnections) {
  auto required = requiredFileDescriptorBudget(maxConnections);
  rlimit limit;
  if (getrlimit(RLIMIT_NOFILE, &limit) == 0 && limit.rlim_cur < required) {
    stderr.writefln(
      "Warning: RLIMIT_NOFILE=%s is below required fd budget %s " ~
      "(2*maxConnections+%s=%s*2+64); raise systemd LimitNOFILE",
      limit.rlim_cur, required, 64, maxConnections);
  }
}
