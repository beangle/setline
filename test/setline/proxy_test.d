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

@("proxy decides client keep alive") unittest {
  auto request = parseHttpHead("GET /api HTTP/1.1\r\nHost: local\r\n\r\n");
  auto response = parseHttpHead("HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\n");
  assert(requestWantsKeepAlive(request));
  assert(clientConnectionReusable(request, response));

  auto closeRequest = parseHttpHead("GET /api HTTP/1.1\r\nConnection: close\r\n\r\n");
  assert(!requestWantsKeepAlive(closeRequest));
  assert(!clientConnectionReusable(closeRequest, response));

  auto closeResponse = parseHttpHead("HTTP/1.1 200 OK\r\nConnection: close\r\nContent-Length: 2\r\n\r\n");
  assert(!clientConnectionReusable(request, closeResponse));

  auto unboundedResponse = parseHttpHead("HTTP/1.1 200 OK\r\n\r\n");
  assert(!clientConnectionReusable(request, unboundedResponse));

  auto http10Request = parseHttpHead("GET /api HTTP/1.0\r\nConnection: keep-alive\r\n\r\n");
  auto http10Response = parseHttpHead("HTTP/1.0 200 OK\r\nConnection: keep-alive\r\nContent-Length: 2\r\n\r\n");
  assert(requestWantsKeepAlive(http10Request));
  assert(clientConnectionReusable(http10Request, http10Response));
}

@("proxy suppresses port connect exception trace") unittest {
  auto e = new PortConnectException(9001, "refused");
  assert(e.info !is null);
  assert(e.info.toString.length == 0);
}
