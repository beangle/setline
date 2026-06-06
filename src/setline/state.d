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

module setline.state;

import std.typecons : Nullable;

import setline.model;
import setline.router;

__gshared private Route[] gRoutes;
__gshared private string gAdminToken;

void initialize(Config config) {
  synchronized {
    gRoutes = config.routes.dup;
    sortRoutes(gRoutes);
    gAdminToken = config.adminToken;
  }
}

string adminToken() {
  synchronized {
    return gAdminToken;
  }
}

Nullable!Route findRoute(string path) {
  synchronized {
    return setline.router.findRoute(gRoutes, path);
  }
}

Nullable!Backend selectBackend(string path) {
  synchronized {
    return setline.router.selectBackend(gRoutes, path);
  }
}

void upsertRoute(Route route) {
  synchronized {
    setline.router.upsertRoute(gRoutes, route);
  }
}

Route[] routesSnapshot() {
  synchronized {
    return gRoutes.dup;
  }
}
