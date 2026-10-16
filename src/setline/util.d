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

import std.array : appender, split;
import std.conv : to;
import std.string : strip;

enum defaultConfigPath = "setline.json";
enum adminPrefix = "/_setline";
/** 跨机读取路由表的端点；它是数据面 `listen` 上唯一承接的管理路径（见 `server.handleRequest`）。 */
enum peerRoutesPath = adminPrefix ~ "/routes";

/** 在途请求的 fd 预算：client + upstream，另留 64 个监听/日志/健康检查等余量。 */
size_t requiredFileDescriptorBudget(size_t maxConnections) {
  return maxConnections * 2 + 64;
}

/** 主服务与渲染 agent 的启动身份判据：以 root 运行时拒绝启动。

    `setline-apply` 是唯一以 root 运行的组件（`nginx -t`、haproxy reload、代理的 admin
    socket 都要特权），它会以 root 调用 `setline --agent-type` 与 `setline --sync-map`，
    那两个出口不经过这个判据（见 `src/main.d`）。

    只做纯函数判断是为了可测：测试进程改不了自己的 euid。真实 euid 由 `main` 传入
    `core.sys.posix.unistd.geteuid`。
*/
bool rejectsRootUser(uint effectiveUserId) {
  return effectiveUserId == 0;
}

/** 以 root 运行时的拒绝提示：给替代做法，而不是只说「不允许」。 */
string rootRunRefusalMessage() {
  return "refusing to run as root: setline is the network-facing data plane and runs as an " ~
    "unprivileged user (User=setline, Group=beangle). For a port below 1024 add " ~
    "AmbientCapabilities=CAP_NET_BIND_SERVICE to the unit; only setline-apply needs root. " ~
    "See docs/project-constraints.md, Privilege Model.";
}

/** 将 ASCII 大写字母转换为小写，非 ASCII 字符保持不变。 */
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

/** 规范化地址文本：去空白、转小写、去掉 IPv4-mapped IPv6 前缀，方便按文本比较。

    双栈监听上的 IPv4 客户端对端会显示成 `::ffff:10.0.1.7`，去掉这个前缀之后它和配置里
    写的 `10.0.1.7` 就是同一个地址。
*/
string normalizeAddressText(string address) {
  auto value = toLowerAscii(address.strip);
  enum mapped = "::ffff:";
  if (value.length > mapped.length && value[0 .. mapped.length] == mapped &&
      isIpv4Literal(value[mapped.length .. $])) {
    return value[mapped.length .. $];
  }
  return value;
}

/** 地址文本是否为回环地址。 */
bool isLoopbackAddress(string address) {
  auto value = normalizeAddressText(address);
  return value == "127.0.0.1" || value == "::1";
}

/** 地址文本是否为数值地址字面量：点分四段 IPv4，或含两个以上冒号的 IPv6。

    刻意只认字面量：主机名要查 DNS、CIDR 要按位比较，两者都会把「谁可以读路由表」这件事
    从一行地址变成一个需要解释的规则。调用方先 {@link normalizeAddressText} 再判。
*/
bool isAddressLiteral(string address) {
  return isIpv4Literal(address) || isIpv6Literal(address);
}

/** 点分四段 IPv4，每段 0..255。 */
private bool isIpv4Literal(string value) {
  auto parts = value.split(".");
  if (parts.length != 4) return false;
  foreach (part; parts) {
    if (part.length == 0 || part.length > 3) return false;
    foreach (ch; part) {
      if (ch < '0' || ch > '9') return false;
    }
    if (to!ushort(part) > 255) return false;
  }
  return true;
}

/** IPv6 文本（宽松形状检查）：只含十六进制与冒号，且至少两个冒号。 */
private bool isIpv6Literal(string value) {
  if (value.length < 2 || value.length > 45) return false;
  size_t colons;
  foreach (ch; value) {
    if (ch == ':') {
      colons++;
    } else if (!((ch >= '0' && ch <= '9') || (ch >= 'a' && ch <= 'f'))) {
      return false;
    }
  }
  return colons >= 2;
}

/** 远端地址是否落在允许读取的地址列表里（按规范化文本比较）。 */
bool isListedAddress(string remote, const string[] readers) {
  auto value = normalizeAddressText(remote);
  foreach (reader; readers) {
    if (normalizeAddressText(reader) == value) return true;
  }
  return false;
}

/** 转义 HTML 文本节点和属性值中的特殊字符。 */
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
