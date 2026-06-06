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
  assert(isWebSocketUpgrade(request));
}

@("http detects switching protocols response") unittest {
  auto response =
    "HTTP/1.1 101 Switching Protocols\r\n" ~
    "Connection: Upgrade\r\n" ~
    "Upgrade: websocket\r\n\r\n";
  assert(isSwitchingProtocols(response));
}
