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

module setline.test_lock;

import core.sync.mutex : Mutex;

__gshared private Mutex stateMutex;

shared static this() {
  stateMutex = new Mutex();
}

/** 串行化会修改全局 runtime state 的测试。

    silly 默认并发执行 unittest。`setline.state` 是进程级运行状态，所以相关测试必须共用
    一把锁，避免一个测试的 `initialize()` 覆盖另一个测试正在断言的状态。
*/
void withStateTestLock(scope void delegate() test) {
  synchronized (stateMutex) {
    test();
  }
}
