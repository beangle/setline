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
import std.stdio : stdout;

import setline.config;
import setline.constants;
import setline.server;
import setline.state;

version (unittest) {
} else {
void main(string[] args) {
  version (linux) {
  } else {
    static assert(false, "setline is Linux-only");
  }

  string configPath = defaultConfigPath;
  bool help;
  auto helpInfo = getopt(args,
    "config|c", "Path to setline JSON config", &configPath,
    "help|h", "Show this help", &help);

  if (help) {
    defaultGetoptPrinter("Usage: setline --config setline.json", helpInfo.options);
    return;
  }

  auto config = loadConfig(configPath);
  initialize(config);

  stdout.writefln("setline listening on http://%s:%s", config.listen.host, config.listen.port);
  serve(config.listen);
}
}
