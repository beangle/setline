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

module setline.proxy_test;

import setline.http : parseHttpHead;
import setline.proxy;

@("proxy detects complete chunked body") unittest {
  assert(chunkedBodyComplete("4\r\nWiki\r\n5\r\npedia\r\n0\r\n\r\n"));
  assert(chunkedBodyComplete("4;name=value\r\nWiki\r\n0\r\nExpires: now\r\n\r\n"));
  assert(!chunkedBodyComplete("4\r\nWiki\r\n5\r\nped"));
}

@("proxy tracks chunked body across fragments") unittest {
  ChunkedBodyTracker tracker;
  assert(!tracker.feed(cast(const(ubyte)[]) "4\r\nWi"));
  assert(!tracker.feed(cast(const(ubyte)[]) "ki\r"));
  assert(!tracker.feed(cast(const(ubyte)[]) "\n0\r\nExpires: now\r\n"));
  assert(tracker.feed(cast(const(ubyte)[]) "\r\n"));
}

@("proxy detects responses without body") unittest {
  assert(responseHasNoBody(parseHttpHead("HTTP/1.1 304 Not Modified\r\n\r\n")));
  assert(responseHasNoBody(parseHttpHead("HTTP/1.1 204 No Content\r\n\r\n")));
  assert(!responseHasNoBody(parseHttpHead("HTTP/1.1 200 OK\r\n\r\n")));
}

@("proxy detects existing proxy headers") unittest {
  assert(parseHttpHead("GET / HTTP/1.1\r\nForwarded: for=127.0.0.1\r\n\r\n").hasProxyHeaders);
  assert(parseHttpHead("GET / HTTP/1.1\r\nX-Forwarded-For: 127.0.0.1\r\n\r\n").hasProxyHeaders);
  assert(!parseHttpHead("GET / HTTP/1.1\r\nHost: localhost\r\n\r\n").hasProxyHeaders);
}

@("proxy suppresses port connect exception trace") unittest {
  auto e = new PortConnectException(9001, "refused");
  assert(e.info !is null);
  assert(e.info.toString.length == 0);
}
