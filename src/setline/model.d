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

module setline.model;

struct ListenAddress {
  string host = "127.0.0.1";
  ushort port = 8080;
}

struct DirectResponse {
  int status = 200;
  string contentType = "text/plain; charset=utf-8";
  string body;
  string[string] headers;
}

struct Backend {
  string host;
  ushort port;
}

struct Route {
  string prefix;
  DirectResponse response;
  string wireResponse;
  Backend[] backends;
  size_t nextBackend;
}

struct Config {
  ListenAddress listen;
  string adminToken;
  Route[] routes;
}
