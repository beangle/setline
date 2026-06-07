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

module setline.util;

import std.array : appender;

enum defaultConfigPath = "setline.json";
enum adminPrefix = "/__setline";

string toLowerAscii(string value) {
  auto outp = appender!string();
  foreach (ch; value) {
    if (ch >= 'A' && ch <= 'Z') {
      outp.put(cast(char)(ch + 32));
    } else {
      outp.put(ch);
    }
  }
  return outp.data;
}

string escapeHtml(string value) {
  auto outp = appender!string();
  foreach (ch; value) {
    switch (ch) {
      case '&':
        outp.put("&amp;");
        break;
      case '<':
        outp.put("&lt;");
        break;
      case '>':
        outp.put("&gt;");
        break;
      case '"':
        outp.put("&quot;");
        break;
      case '\'':
        outp.put("&#39;");
        break;
      default:
        outp.put(ch);
        break;
    }
  }
  return outp.data;
}
