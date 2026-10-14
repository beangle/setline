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

module setline.mapsync;

import std.array : join;
import std.conv : to;
import std.exception : enforce;
import std.socket : AddressFamily, Socket, SocketShutdown, SocketType, UnixAddress;
import std.string : lineSplitter, split, startsWith, strip;

/** 一条 map 键值对，对应 haproxy map 文件里的一行 `<key> <value>`。 */
struct MapEntry {
  string key;
  string value;
}

/** 一轮同步要下发的三类变更。 */
struct MapChange {
  MapEntry[] added;
  MapEntry[] updated;
  MapEntry[] removed;
}

/** 解析 setline 生成的 `.map`：跳过注释与空行，第一个空白前是 key，其余是 value。 */
MapEntry[] parseMapFile(string text) {
  MapEntry[] entries;
  foreach (line; text.lineSplitter) {
    auto stripped = line.strip;
    if (stripped.length == 0 || stripped.startsWith("#")) continue;
    auto parts = stripped.split;
    enforce(parts.length >= 2, "invalid map line: " ~ stripped);
    entries ~= MapEntry(parts[0], parts[1 .. $].join(" "));
  }
  return entries;
}

/** 解析 haproxy `show map <file>` 的输出：每行是 `<ref> <key> <value>`。

    出错时 haproxy 回一行纯文本（例如 `Unknown map identifier. Please use #<id> or
    <file>.`），没有引用指针前缀。这里直接抛异常，让调用方回退到 reload。
*/
MapEntry[] parseShowMap(string text) {
  MapEntry[] entries;
  foreach (line; text.lineSplitter) {
    auto stripped = line.strip;
    if (stripped.length == 0) continue;
    if (!stripped.startsWith("0x")) throw new Exception(stripped);
    auto parts = stripped.split;
    enforce(parts.length >= 3, "unexpected show map line: " ~ stripped);
    entries ~= MapEntry(parts[1], parts[2 .. $].join(" "));
  }
  return entries;
}

/** 计算「当前 → 期望」的差量：新增、改值、删除。

    同名 key 在现有 map 里出现多条时一律算改值（走重建），而不是和第一条比完就当没变。
*/
MapChange diffMap(MapEntry[] current, MapEntry[] desired) {
  MapChange change;
  foreach (want; desired) {
    auto values = valuesOf(current, want.key);
    if (values.length == 0) {
      change.added ~= want;
    } else if (values.length > 1 || values[0] != want.value) {
      change.updated ~= want;
    }
  }
  foreach (have; current) {
    if (hasKey(desired, have.key) || hasKey(change.removed, have.key)) continue;
    change.removed ~= MapEntry(have.key, "");
  }
  return change;
}

/** 把一份 map 同步到运行中的 haproxy；任何一步不成立都抛异常，调用方据此回退 reload。

    顺序是「先增改、后删」：`del map` 会让命中的路由立刻回落到 default_backend，所以删除
    必须排在最后。同名 key 已有重复条目时（`add map` 对已存在的 key 是追加而不是覆盖）
    先 `del` 清干净再 `add`——重复条目下 haproxy 采用先插入的那个值，留着会让结果不可预期。
*/
MapChange syncMap(string socketPath, string mapPath, string mapText) {
  enforce(socketPath.length > 0, "admin socket path must not be empty");
  enforce(mapPath.length > 0, "map path must not be empty");
  auto current = parseShowMap(sendRuntimeCommand(socketPath, "show map " ~ mapPath));
  auto desired = parseMapFile(mapText);
  auto change = diffMap(current, desired);
  foreach (entry; change.added) {
    runMapCommand(socketPath, "add map " ~ mapPath ~ " " ~ entry.key ~ " " ~ entry.value);
  }
  foreach (entry; change.updated) {
    if (valuesOf(current, entry.key).length > 1) {
      runMapCommand(socketPath, "del map " ~ mapPath ~ " " ~ entry.key);
      runMapCommand(socketPath, "add map " ~ mapPath ~ " " ~ entry.key ~ " " ~ entry.value);
    } else {
      runMapCommand(socketPath, "set map " ~ mapPath ~ " " ~ entry.key ~ " " ~ entry.value);
    }
  }
  foreach (entry; change.removed) {
    runMapCommand(socketPath, "del map " ~ mapPath ~ " " ~ entry.key);
  }
  verifyMap(socketPath, mapPath, desired);
  return change;
}

/** 回读确认：条目总数对得上，每个期望的 key 恰好一条且值与期望一致。 */
void verifyMap(string socketPath, string mapPath, MapEntry[] desired) {
  auto actual = parseShowMap(sendRuntimeCommand(socketPath, "show map " ~ mapPath));
  enforce(actual.length == desired.length, "map holds " ~ actual.length.to!string ~
    " entries, expected " ~ desired.length.to!string);
  foreach (want; desired) {
    auto values = valuesOf(actual, want.key);
    enforce(values.length == 1, "map key " ~ want.key ~ " has " ~
      values.length.to!string ~ " entries");
    enforce(values[0] == want.value, "map key " ~ want.key ~ " maps to " ~ values[0] ~
      ", expected " ~ want.value);
  }
}

/** 发一条会改动 map 的命令；haproxy 成功时回空行，失败时回一行原因。 */
void runMapCommand(string socketPath, string command) {
  auto reply = sendRuntimeCommand(socketPath, command).strip;
  enforce(reply.length == 0, "haproxy rejected '" ~ command ~ "': " ~ reply);
}

/** 通过 unix socket 发一条 haproxy runtime 命令并读回全部输出。

    命令发完立刻半关闭写端：haproxy 会把响应写完再关闭连接，因此拿到 EOF 就知道响应结束，
    不必靠读超时判断（2.0.33、2.2.9、3.0.25 实测行为一致）。
*/
string sendRuntimeCommand(string socketPath, string command) {
  auto socket = new Socket(AddressFamily.UNIX, SocketType.STREAM);
  scope (exit) socket.close();
  socket.connect(new UnixAddress(socketPath));
  socket.send(command ~ "\n");
  socket.shutdown(SocketShutdown.SEND);
  char[8192] buffer;
  string output;
  while (true) {
    auto received = socket.receive(buffer);
    if (received <= 0) break;
    output ~= buffer[0 .. received];
  }
  return output;
}

/** 取某个 key 在条目集合里的全部值，顺序与来源一致。 */
private string[] valuesOf(MapEntry[] entries, string key) {
  string[] values;
  foreach (entry; entries) {
    if (entry.key == key) values ~= entry.value;
  }
  return values;
}

/** 条目集合里是否存在该 key。 */
private bool hasKey(MapEntry[] entries, string key) {
  foreach (entry; entries) {
    if (entry.key == key) return true;
  }
  return false;
}
