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

module setline.http_test;

import setline.http;

@("http requestPath removes query string") unittest {
  auto target = "/m/edu/learning/src/App.vue?t=1780556259104";
  assert(requestPath(target) == "/m/edu/learning/src/App.vue");
}

@("http detects websocket upgrade request") unittest {
  auto request =
    "GET /m/edu/learning/@vite/client HTTP/1.1\r\n" ~
    "Host: 127.0.0.1:8080\r\n" ~
    "Connection: keep-alive, Upgrade\r\n" ~
    "Upgrade: websocket\r\n\r\n";
  auto head = parseHttpHead(request);
  assert(head.method == "GET");
  assert(head.target == "/m/edu/learning/@vite/client");
  assert(head.httpVersion == "HTTP/1.1");
  assert(head.path == "/m/edu/learning/@vite/client");
  assert(head.host == "127.0.0.1:8080");
  assert(head.connectionKeepAlive);
  assert(head.upgradeWebSocket);
}

@("http parses connection persistence fields") unittest {
  auto closeRequest =
    "GET /api HTTP/1.1\r\n" ~
    "Connection: close\r\n\r\n";
  auto closeHead = parseHttpHead(closeRequest);
  assert(closeHead.httpVersion == "HTTP/1.1");
  assert(closeHead.connectionClose);

  auto keepAliveRequest =
    "GET /api HTTP/1.0\r\n" ~
    "Connection: keep-alive\r\n\r\n";
  auto keepAliveHead = parseHttpHead(keepAliveRequest);
  assert(keepAliveHead.httpVersion == "HTTP/1.0");
  assert(keepAliveHead.connectionKeepAlive);
}

@("http scans header values without body interference") unittest {
  auto request =
    "POST /api HTTP/1.1\r\n" ~
    "Host: LOCAL.EXAMPLE.COM:8080\r\n" ~
    "Connection: keep-alive, Upgrade\r\n" ~
    "Content-Length: 5\r\n\r\n" ~
    "Host: body";
  auto head = parseHttpHead(request);
  assert(head.host == "LOCAL.EXAMPLE.COM:8080");
  assert(!head.upgradeWebSocket);
  assert(head.hasContentLength);
  assert(head.contentLength == 5);
  assert(headerValue(request, "host") == "LOCAL.EXAMPLE.COM:8080");
  assert(headerContains(request, "Connection", "upgrade"));
}

@("http ignores invalid content length") unittest {
  auto request =
    "POST /api HTTP/1.1\r\n" ~
    "Host: local.example.com\r\n" ~
    "Content-Length: abc\r\n\r\n";
  auto head = parseHttpHead(request);
  assert(!head.hasContentLength);
  assert(head.contentLength < 0);
}

@("http handles content length bounds") unittest {
  auto valid =
    "POST /api HTTP/1.1\r\n" ~
    "Content-Length: 00000000000000000005\r\n\r\n";
  assert(parseHttpHead(valid).contentLength == 5);

  auto tooLarge =
    "POST /api HTTP/1.1\r\n" ~
    "Content-Length: 9223372036854775808\r\n\r\n";
  assert(parseHttpHead(tooLarge).contentLength < 0);

  auto negative =
    "POST /api HTTP/1.1\r\n" ~
    "Content-Length: -1\r\n\r\n";
  auto negativeHead = parseHttpHead(negative);
  assert(!negativeHead.hasContentLength);
  assert(negativeHead.contentLength < 0);
}

@("http parses switching protocols response") unittest {
  auto response =
    "HTTP/1.1 101 Switching Protocols\r\n" ~
    "Connection: Upgrade\r\n" ~
    "Upgrade: websocket\r\n\r\n";
  auto head = parseHttpHead(response);
  assert(head.httpVersion == "HTTP/1.1");
  assert(head.statusCode == 101);
}
