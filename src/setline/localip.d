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

module setline.localip;

import std.conv : to;
import std.socket : AddressFamily, InternetAddress, UdpSocket;
import std.string : indexOf, lastIndexOf, startsWith, strip, toLower;

/**
 * 连接远程地址时使用的本机出口 IP。
 *
 * 用 UDP connect 让内核选路，不真正发包；这样多网卡机器不需要把 IP 写进配置。
 */
string localIpForRemote(string remoteUrl) {
  auto value = remoteUrl.strip;
  auto scheme = value.indexOf("://");
  if (scheme <= 0)
    throw new Exception("remote url must use http:// or https://");
  auto rest = value[scheme + 3 .. $];
  auto slash = rest.indexOf('/');
  auto authority = slash >= 0 ? rest[0 .. slash] : rest;
  auto at = authority.lastIndexOf('@');
  if (at >= 0)
    authority = authority[at + 1 .. $];

  string host;
  ushort port = toLower(value[0 .. scheme]) == "https" ? 443 : 80;
  if (authority.startsWith("[")) {
    auto close = authority.indexOf(']');
    if (close < 0)
      throw new Exception("invalid IPv6 authority in remote url");
    host = authority[1 .. close];
    if (close + 1 < authority.length && authority[close + 1] == ':')
      port = authority[close + 2 .. $].to!ushort;
  } else {
    auto colon = authority.lastIndexOf(':');
    if (colon > 0 && authority[colon + 1 .. $].length > 0
        && authority[colon + 1 .. $].to!ushort > 0) {
      host = authority[0 .. colon];
      port = authority[colon + 1 .. $].to!ushort;
    } else {
      host = authority;
    }
  }
  if (host.length == 0)
    throw new Exception("remote url has no host");

  auto socket = new UdpSocket(AddressFamily.INET);
  scope (exit) socket.close();
  socket.connect(new InternetAddress(host, port));
  return socket.localAddress.toAddrString;
}
