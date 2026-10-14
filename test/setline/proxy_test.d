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

import core.time : Duration, msecs;
import std.algorithm : canFind;

import setline.http : parseHttpHead;
import setline.proxy;
import setline.test_lock;

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
  assert(!upstreamConnectionReusable(closeRequest, response));

  auto closeResponse = parseHttpHead("HTTP/1.1 200 OK\r\nConnection: close\r\nContent-Length: 2\r\n\r\n");
  assert(!clientConnectionReusable(request, closeResponse));
  assert(!upstreamConnectionReusable(request, closeResponse));

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

@("proxy flags failures that happen after the response head was sent") unittest {
  // 响应头已经交给 client 之后失败，调用方只能截断连接：再补一个合成响应会把状态行和
  // 错误文本混进响应体。原始异常留在 `next` 上，排障时能看到真正的原因。
  auto cause = new Exception("upstream closed in the middle of the response body");
  auto e = new ResponseStartedException(9002, cause);
  assert(e.port == 9002);
  assert(e.next is cause);
  assert(e.msg.canFind("9002"));
  assert(e.info !is null);
  assert(e.info.toString.length == 0);
}

@("proxy will not reuse an upstream connection with conflicting framing") unittest {
  auto request = parseHttpHead("GET /api HTTP/1.1\r\nHost: local\r\n\r\n");
  auto valid = parseHttpHead("HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\n");
  assert(upstreamConnectionReusable(request, valid));

  // CL + TE 并存：代理按 chunked 读，但流位置不再是它能担保的东西，不能留给下一条请求。
  auto conflicting = parseHttpHead(
    "HTTP/1.1 200 OK\r\nContent-Length: 2\r\nTransfer-Encoding: chunked\r\n\r\n");
  assert(conflicting.invalidFraming);
  assert(conflicting.transferChunked);
  assert(!upstreamConnectionReusable(request, conflicting));
}

@("proxy sizes the idle upstream pool from recent concurrency") unittest {
  // silly 并发跑 unittest，而空闲池的借出数和并发高水位是进程级状态：本测试和下面
  // 「raises and decays」共用一把锁，否则会读到对方 noteUpstreamLeaseAcquired 之后、
  // 归还之前的中间态，借出数断言随机误报。
  withStateTestLock({
    // 没有并发历史时用下限：低并发部署不该攒下一堆空闲上游连接。
    assert(upstreamPoolCapacity(65001) == 4);
    assert(leasedUpstreamCount() == 0);
    assert(idleUpstreamCount() == 0);
    // 空池回收是空操作（周期巡检会先跑一遍这里）。
    sweepUpstreamPool(Duration.zero);
    assert(upstreamPoolCapacity(65001) == 4);
  });
}

@("proxy raises and decays the upstream concurrency high-water mark") unittest {
  withStateTestLock({
    // 借出只抬不降；容量换算把高水位 clamp 到 [4, 32]。
    assert(raisedUpstreamPeak(0, 3) == 3);
    assert(raisedUpstreamPeak(5, 2) == 5);
    assert(raisedUpstreamPeak(5, 6) == 6);
    assert(upstreamPoolCapacityForPeak(0) == 4);
    assert(upstreamPoolCapacityForPeak(4) == 4);
    assert(upstreamPoolCapacityForPeak(9) == 9);
    assert(upstreamPoolCapacityForPeak(32) == 32);
    assert(upstreamPoolCapacityForPeak(4096) == 32);

    // 衰减按真实经过时间算：每过半衰期折半，到下限停住；时间为 0 时不动。
    enum halfLife = 30_000;
    assert(decayedUpstreamPeak(32, 0) == 32);
    assert(decayedUpstreamPeak(4, halfLife * 10) == 4);
    assert(decayedUpstreamPeak(8, halfLife) == 6);
    assert(decayedUpstreamPeak(32, halfLife) == 18);
    assert(decayedUpstreamPeak(32, halfLife * 2) == 11);
    assert(decayedUpstreamPeak(32, halfLife * 10) == 4);
    size_t peak = 32;
    size_t rounds;
    while (peak > 4) {
      auto next = decayedUpstreamPeak(peak, halfLife);
      assert(next < peak);
      peak = next;
      rounds++;
      assert(rounds < 64, "decay should reach the floor quickly");
    }
    assert(peak == 4);

    // 全局路径：借出抬高水位、容量跟着走；归还只降借出数，高水位留在原地。
    enum port = 65009;
    assert(upstreamPoolCapacity(port) == 4);
    foreach (_; 0 .. 9) {
      noteUpstreamLeaseAcquired(port);
    }
    assert(leasedUpstreamCount() == 9);
    assert(upstreamPoolCapacity(port) == 9);
    foreach (_; 0 .. 9) {
      noteUpstreamLeaseReleased(port);
    }
    assert(leasedUpstreamCount() == 0);
    assert(upstreamPoolCapacity(port) == 9);

    // 巡检把实际经过的时间交给衰减：0 不动，一个半衰期后 9 → 6，逐轮回到下限。
    sweepUpstreamPool(Duration.zero);
    assert(upstreamPoolCapacity(port) == 9);
    sweepUpstreamPool(halfLife.msecs);
    assert(upstreamPoolCapacity(port) == 6);
    while (upstreamPoolCapacity(port) > 4) {
      sweepUpstreamPool(halfLife.msecs);
    }
    assert(upstreamPoolCapacity(port) == 4);
  });
}
