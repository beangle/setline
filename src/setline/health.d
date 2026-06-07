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

/** 本机端口的健康检查运行时状态。 */
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

/** 以 nothrow 入口运行健康检查循环，供 vibe-core task 调用。 */
void runHealthChecks() nothrow {
  try {
    startHealthChecks();
  }
  catch (Throwable) {
  }
}

/** 按配置间隔循环探测所有已配置端口。 */
void startHealthChecks() {
  while (!healthChecksStopped()) {
    auto config = healthConfig();
    foreach (port; healthPorts()) {
      updatePortHealth(port, probePort(port, config.timeoutMillis));
    }
    sleep(config.intervalMillis.msecs);
  }
}

/** 请求后台健康检查循环停止。 */
void stopHealthChecks() nothrow {
  atomicStore(gStopping, true);
}

/** 返回健康检查循环是否已收到停止信号。 */
bool healthChecksStopped() nothrow {
  return atomicLoad(gStopping);
}

/** 返回当前健康检查配置。 */
HealthConfig healthConfig() {
  return gConfig;
}

/** 判断端口当前是否可用于路由选择。 */
bool isPortHealthy(ushort port) {
  auto health = port in gHealth;
  return health is null || health.healthy;
}

/** 按新的路由集合刷新健康表，并保留仍被引用端口的状态。 */
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

/** 写入一次端口探测结果并更新连续成功/失败计数。 */
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

/** 返回当前需要健康检查的端口列表快照。 */
ushort[] healthPorts() {
  ushort[] ports;
  foreach (port; gHealth.byKey) {
    ports ~= port;
  }
  return ports;
}

/** 尝试建立到本机端口的 TCP 连接以判断端口是否在线。 */
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
