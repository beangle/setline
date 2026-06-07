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

import core.atomic : atomicLoad, atomicStore;
import core.time : msecs;

import vibe.core.core : sleep;
import vibe.core.net : connectTCP;

import setline.model;

struct PortHealth {
  ushort port;
  bool healthy = true;
  int successCount;
  int failureCount;
}

__gshared private HealthConfig gConfig;
__gshared private PortHealth[ushort] gHealth;
shared private bool gStopping;

/** 初始化端口健康状态。

    健康检查在后台 task 中低频更新，代理请求只读取当前端口状态。这里不使用互斥锁，避免
    每次路由选择都因为健康状态查询进入同步区。
*/
void initializeHealth(Config config) {
  gConfig = config.healthCheck;
  gHealth = null;
  foreach (group; config.routes) {
    foreach (route; group.routes) {
      foreach (port; route.ports) {
        if ((port in gHealth) is null) {
          gHealth[port] = PortHealth(port, true);
        }
      }
    }
  }
  atomicStore(gStopping, false);
}

void runHealthChecks() nothrow {
  try {
    startHealthChecks();
  }
  catch (Throwable) {
  }
}

void startHealthChecks() {
  while (!healthChecksStopped()) {
    auto config = healthConfig();
    foreach (port; healthPorts()) {
      updatePortHealth(port, probePort(port, config.timeoutMillis));
    }
    sleep(config.intervalMillis.msecs);
  }
}

void stopHealthChecks() nothrow {
  atomicStore(gStopping, true);
}

bool healthChecksStopped() nothrow {
  return atomicLoad(gStopping);
}

HealthConfig healthConfig() {
  return gConfig;
}

bool isPortHealthy(ushort port) {
  auto health = port in gHealth;
  return health is null || health.healthy;
}

void syncPortHealth(HostRoutes[] groups) {
  PortHealth[ushort] next;
  foreach (group; groups) {
    foreach (route; group.routes) {
      foreach (port; route.ports) {
        auto existing = port in gHealth;
        next[port] = existing is null ? PortHealth(port, true) : *existing;
      }
    }
  }
  gHealth = next;
}

void updatePortHealth(ushort port, bool ok) {
  auto health = port in gHealth;
  if (health is null) {
    gHealth[port] = PortHealth(port, true);
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

ushort[] healthPorts() {
  ushort[] ports;
  foreach (port; gHealth.byKey) {
    ports ~= port;
  }
  return ports;
}

bool probePort(ushort port, int timeoutMillis) {
  try {
    auto connection = connectTCP("127.0.0.1", port, null, 0, timeoutMillis.msecs);
    scope (exit) connection.close();
    return true;
  }
  catch (Exception) {
    return false;
  }
}
