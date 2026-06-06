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

module setline.health;

import core.time : msecs;

import vibe.core.core : sleep;
import vibe.core.net : connectTCP;

import setline.model;

struct BackendHealth {
  ushort port;
  bool healthy = true;
  int successCount;
  int failureCount;
}

__gshared private HealthConfig gConfig;
__gshared private BackendHealth[ushort] gHealth;

void initializeHealth(Config config) {
  synchronized {
    gConfig = config.healthCheck;
    gHealth = null;
    foreach (route; config.routes) {
      foreach (backend; route.backends) {
        if ((backend.port in gHealth) is null) {
          gHealth[backend.port] = BackendHealth(backend.port, true);
        }
      }
    }
  }
}

void runHealthChecks() nothrow {
  try {
    startHealthChecks();
  }
  catch (Throwable) {
  }
}

void startHealthChecks() {
  while (true) {
    auto config = healthConfig();
    foreach (port; healthPorts()) {
      updateBackendHealth(port, probeBackend(port, config.timeoutMillis));
    }
    sleep(config.intervalMillis.msecs);
  }
}

HealthConfig healthConfig() {
  synchronized {
    return gConfig;
  }
}

BackendHealth[] healthSnapshot() {
  synchronized {
    BackendHealth[] values;
    foreach (health; gHealth) {
      values ~= health;
    }
    return values;
  }
}

bool isBackendHealthy(Backend backend) {
  synchronized {
    auto health = backend.port in gHealth;
    return health is null || health.healthy;
  }
}

void addBackendHealth(Backend backend) {
  synchronized {
    if ((backend.port in gHealth) is null) {
      gHealth[backend.port] = BackendHealth(backend.port, true);
    }
  }
}

void updateBackendHealth(ushort port, bool ok) {
  synchronized {
    auto health = port in gHealth;
    if (health is null) {
      gHealth[port] = BackendHealth(port, true);
      health = port in gHealth;
    }

    if (ok) {
      health.successCount++;
      health.failureCount = 0;
      if (health.successCount >= gConfig.healthyThreshold) {
        health.healthy = true;
      }
    } else {
      health.failureCount++;
      health.successCount = 0;
      if (health.failureCount >= gConfig.unhealthyThreshold) {
        health.healthy = false;
      }
    }
  }
}

ushort[] healthPorts() {
  synchronized {
    ushort[] ports;
    foreach (port; gHealth.byKey) {
      ports ~= port;
    }
    return ports;
  }
}

bool probeBackend(ushort port, int timeoutMillis) {
  try {
    auto connection = connectTCP("127.0.0.1", port, null, 0, timeoutMillis.msecs);
    scope (exit) connection.close();
    return true;
  }
  catch (Exception) {
    return false;
  }
}
