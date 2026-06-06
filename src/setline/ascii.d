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

module setline.ascii;

import std.array : appender;

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
