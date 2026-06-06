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

module setline.state_test;

import setline.model;
import setline.state;

@("state enforces max active connections") unittest {
  Config config;
  config.maxConnections = 1;
  initialize(config);

  assert(maxConnections() == 1);
  assert(activeConnections() == 0);
  assert(tryAcquireConnection());
  assert(activeConnections() == 1);
  assert(!tryAcquireConnection());

  releaseConnection();
  assert(activeConnections() == 0);
  assert(tryAcquireConnection());
  releaseConnection();
}
