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

import std.getopt : defaultGetoptPrinter, getopt;
import std.stdio : stderr, stdout;

import setline.config;
import setline.server;
import setline.state;
import setline.util : defaultConfigPath;

version (unittest) {
} else {
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
    initialize(config, configPath);

    stdout.writefln("setline listening on http://%s:%s", config.listen.host, config.listen.port);
    serve(config.listen);
    return 0;
  } catch (Exception e) {
    stderr.writefln("Config %s is invalid: %s", configPath, e.msg);
    return 1;
  }
}
}
