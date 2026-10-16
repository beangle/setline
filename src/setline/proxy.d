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

module setline.proxy;

import core.time : Duration, MonoTime, msecs;
import std.conv : to;
import std.string : indexOf;

import vibe.core.core : runTask, sleep;
import vibe.core.net : ReadTimeoutException, TCPConnection, WaitForDataStatus, connectTCP;
import vibe.core.stream : IOMode;
import vibe.core.task : InterruptException, Task;

import setline.http :
  HttpHead, headerContains, isIntermediateResponse, readResponseHead, sendPrepared;
import setline.model;
import setline.state :
  connectTimeoutMillis, notePoolHit, noteUpstreamConnect, noteUpstreamTimeout,
  noteWebSocketBytesToClient, noteWebSocketBytesToUpstream, noteWebSocketClose,
  noteWebSocketIdleTimeout, noteWebSocketOpen, readTimeoutMillis, upstreamIdleTimeoutMillis,
  webSocketIdleTimeoutMillis;

/** 本机上游端口 TCP 连接失败。

    这个异常只表示代理尚未和上游端口建立连接，请求头和请求体都还没有发送给上游。调用方
    可以在同一路由下尝试其他端口，而不会造成非幂等请求被重复提交。
*/
class PortConnectException : Exception {
  this(ushort port, string message) {
    super("connect 127.0.0.1:" ~ port.to!string ~ " failed: " ~ message);
    this.info = EmptyTraceInfo.instance;
  }
}

/** 上游 read timeout 已触发。调用方据此决定能否安全地向 client 发送 504。 */
class UpstreamReadTimeoutException : Exception {
  ushort port;
  bool finalResponseStarted;

  this(ushort port, bool finalResponseStarted) {
    super("upstream 127.0.0.1:" ~ port.to!string ~ " read timed out");
    this.port = port;
    this.finalResponseStarted = finalResponseStarted;
    this.info = EmptyTraceInfo.instance;
  }
}

/** client 在等待上游时关闭；调用方立即回收两端连接。 */
class ClientDisconnectedException : Exception {
  this() {
    super("client disconnected while proxying request");
    this.info = EmptyTraceInfo.instance;
  }
}

/** 最终响应头已经写给 client 之后代理失败。

    响应流已经开了，这时再补发一个错误响应只会把状态行和错误文本混进响应体：前置代理会把
    它们当成响应内容转发给浏览器，声明过 `Content-Length` 时甚至会被判成协议错误。调用方
    看到这个异常只能关掉 client 连接，让「响应被截断」如实暴露出来；`cause` 保留原始异常，
    便于排障。
*/
class ResponseStartedException : Exception {
  ushort port;

  this(ushort port, Throwable cause) {
    super("upstream 127.0.0.1:" ~ port.to!string ~
      " failed after the response head was sent to the client", cause);
    this.port = port;
    this.info = EmptyTraceInfo.instance;
  }
}

private class EmptyTraceInfo : Throwable.TraceInfo {
  override int opApply(scope int delegate(ref const(char[])) dg) const {
    return 0;
  }

  override int opApply(scope int delegate(ref size_t, ref const(char[])) dg) const {
    return 0;
  }

  override string toString() const {
    return null;
  }

  static EmptyTraceInfo instance() @trusted {
    static immutable EmptyTraceInfo value = new EmptyTraceInfo;
    return cast(EmptyTraceInfo) value;
  }
}

/** 一次代理的结果，供 server 层写访问日志。 */
struct ForwardResult {
  /** 本轮代理结束后，这条 client 连接能否继续复用来发下一个请求。 */
  bool keepAlive;
  /** 最终响应状态码；没有读到最终响应（上游提前关闭）时为 0。 */
  int status;
}

/** 将一个普通 HTTP 请求转发到匹配到的后端。

    这个函数是 setline 的核心透明代理路径：请求头按原始字节顺序发送给上游，请求体和
    响应体都采用流式透传。这里不做 URL 改写、不缓存、不压缩、不解释业务内容，目标是
    让浏览器与上游服务之间的 HTTP 语义尽量保持一致。

    响应体的转发策略由响应头决定：有 `Content-Length` 时按长度补齐，chunked 响应按
    chunk 边界转发，没有明确长度时一直转发到上游关闭连接。

    失败语义按「最终响应头是否已经写给 client」分成两类：响应头之前的失败
    （连不上上游、读头超时、client 中途断开）抛常见异常，由调用方决定回哪个状态码；
    响应头之后的失败（响应体被上游截断、读超时、client 断开）抛
    `ResponseStartedException`，调用方只能截断连接，不能再补发合成响应。
*/
ForwardResult forward(TCPConnection client, HttpHead request, ushort port, UpstreamLease lease) {
  bool keepConnection;
  scope (exit) {
    lease.busy = false;
    if (!keepConnection) {
      dropLeaseConnection(lease);
    }
  }
  lease.busy = true;
  ensureLeaseUpstream(lease, port);

  bool finalResponseStarted;
  Task clientWatcher;
  scope (exit) {
    stopTaskIfRunning(clientWatcher);
  }
  try {
    string pending;
    HttpHead response;
    bool haveFinalResponse;

    sendPrepared(lease.connection, request.head);
    if (request.bufferedBody.length > 0) {
      sendPrepared(lease.connection, request.bufferedBody);
    }

    // Expect: 100-continue 必须先读上游的 100 再等 client body，否则两边互相等待。
    if (headerContains(request.head, "Expect", "100-continue")) {
      while (true) {
        response = readResponseHead(lease.connection, pending);
        if (response.head.length == 0) {
          return ForwardResult(false, 0);
        }
        if (isIntermediateResponse(response)) {
          sendPrepared(client, response.head);
          if (response.statusCode == 100) {
            break;
          }
          continue;
        }
        haveFinalResponse = true;
        break;
      }
    }

    if (!haveFinalResponse) {
      if (!relayRequestBody(client, lease.connection, request)) {
        throw new ClientDisconnectedException;
      }

      clientWatcher = runTask(&watchClientDisconnect, client, lease.connection);

      while (true) {
        response = readResponseHead(lease.connection, pending);
        if (response.head.length == 0) {
          return ForwardResult(false, 0);
        }
        if (isIntermediateResponse(response)) {
          sendPrepared(client, response.head);
          continue;
        }
        break;
      }
    }

    finalResponseStarted = true;
    sendPrepared(client, response.head);
    if (response.bufferedBody.length > 0) {
      sendPrepared(client, response.bufferedBody);
    }

    bool bodyComplete = true;
    bool upstreamCanReuse;
    if (request.method != "HEAD" && !responseHasNoBody(response)) {
      if (response.hasContentLength) {
        auto contentLength = cast(size_t) response.contentLength;
        auto bodySize = response.bufferedBody.length;
        bodyComplete = relayBytes(lease.connection, client,
          contentLength > bodySize ? contentLength - bodySize : 0);
      } else if (response.transferChunked) {
        bodyComplete = relayChunked(lease.connection, client, response.bufferedBody);
      } else {
        relayUntilClose(lease.connection, client);
        bodyComplete = false;
      }
    }
    stopTaskIfRunning(clientWatcher);
    clientWatcher = Task.init;

    // `pending` 里还留着字节说明上游在同一段读里给了下一条响应（setline 不支持 pipelining，
    // 这些字节既不属于本轮响应也没法原样交出去），这条连接只能丢弃。
    upstreamCanReuse = bodyComplete && pending.length == 0
      && upstreamConnectionReusable(request, response);
    if (upstreamCanReuse) {
      // 连接留在 lease 上，下一条请求继续用（客户端连接亲和）。
      keepConnection = true;
      lease.lastUsed = MonoTime.currTime;
    }
    return ForwardResult(clientConnectionReusable(request, response), response.statusCode);
  } catch (Exception e) {
    if (upstreamReadTimedOut(e)) {
      noteUpstreamTimeout();
      throw new UpstreamReadTimeoutException(port, finalResponseStarted);
    }
    if (finalResponseStarted) {
      // 响应头已在 client 侧：这时只能截断连接，不能再补发合成响应。
      throw new ResponseStartedException(port, e);
    }
    throw e;
  }
}

/** 上游是否仍能承载同一端口的下一个请求。

    framing 冲突的响应（CL 重复且不一致、CL+TE、非 chunked 的 TE）已经被原样透传，但代理
    不能再假定自己知道这条连接读到哪儿了，所以不复用。
*/
bool upstreamConnectionReusable(HttpHead request, HttpHead response) {
  if (!requestWantsKeepAlive(request) || response.connectionClose || response.invalidFraming
      || !responseBodyDelimited(request, response)) {
    return false;
  }
  if (response.httpVersion == "HTTP/1.1") {
    return true;
  }
  return response.httpVersion == "HTTP/1.0" && response.connectionKeepAlive;
}

/** 判断异常是否来自上游读超时。

    vibe-core 在 `readTimeout` 到期时抛 `vibe.core.net.ReadTimeoutException`（见它的
    `loopWithTimeout`）。直接按类型判断比拿类名字符串稳妥：vibe-core 改名或多包一层时，
    字符串比较会静默失效，超时会被当成普通读错误。
*/
private bool upstreamReadTimedOut(Exception error) {
  return cast(ReadTimeoutException) error !is null;
}

/** 判断本轮代理完成后，proxy 到 setline 的 client 连接是否可继续复用。

    setline 不支持 HTTP pipelining，只支持前置 proxy 在收到完整响应后复用同一 TCP 连接
    顺序发送下一次请求。这里要求请求和响应都允许 keep-alive，并且响应体边界明确。
*/
bool clientConnectionReusable(HttpHead request, HttpHead response) {
  if (response.statusCode == 101 || !requestWantsKeepAlive(request) || response.connectionClose
      || !responseBodyDelimited(request, response)) {
    return false;
  }
  if (response.httpVersion == "HTTP/1.1") {
    return true;
  }
  return response.httpVersion == "HTTP/1.0" && response.connectionKeepAlive;
}

/** 判断 client 请求是否希望复用到 setline 的连接。 */
bool requestWantsKeepAlive(HttpHead request) {
  if (request.connectionClose) {
    return false;
  }
  if (request.httpVersion == "HTTP/1.1") {
    return true;
  }
  return request.httpVersion == "HTTP/1.0" && request.connectionKeepAlive;
}

/** client 完成 request body 后，独立 task 监听其 FIN，立即中断卡住的上游读。

    只负责「客户端消失」这一种情况：`noMoreData` 表示对端已关闭，立刻关掉上游读来唤醒
    正卡在读响应上的主 task。`dataAvailable` 表示客户端又发了字节——setline 不支持
    pipelining，这些字节只能是异常流量，这里不消费也不等待，直接结束监听（后续请求的
    生命周期由本轮代理结束后的正常循环接管）。
*/
private void watchClientDisconnect(TCPConnection client, TCPConnection upstream) nothrow {
  while (upstream.connected) {
    try {
      auto status = client.waitForDataEx(0.msecs);
      if (status == WaitForDataStatus.noMoreData) {
        upstream.close();
        return;
      }
      if (status == WaitForDataStatus.dataAvailable) {
        return;
      }
      sleep(50.msecs);
    } catch (InterruptException) {
      return;
    } catch (Throwable) {
      upstream.close();
      return;
    }
  }
}

private void stopTaskIfRunning(ref Task task) nothrow {
  try {
    if (task) {
      task.interrupt();
    }
  } catch (Throwable) {
  }
}

/** 判断响应体是否有明确边界，避免复用连接时把下一轮消息混入上一轮响应。

    `Content-Length` 和 chunked 都能划出边界；`HEAD` 与 1xx/204/304 按定义没有响应体。
    没有边界的响应只能以连接关闭作为结束信号，因此两端连接都不能再复用。
*/
bool responseBodyDelimited(HttpHead request, HttpHead response) {
  return request.method == "HEAD" || responseHasNoBody(response)
    || response.hasContentLength || response.transferChunked;
}

/** 将 WebSocket 握手转发给后端，并在 101 后切换为双向隧道。

    WebSocket 的 HTTP 阶段只持续到握手结束。浏览器收到 101 后，后续帧已经不再能按
    HTTP header/body 模型处理，因此这里必须把客户端和上游连接都交给 `tunnel`，让两边
    任意方向到达的字节都立即写到另一边。

    如果后端没有返回 101，则该响应被当作普通握手失败响应发回浏览器并关闭上游连接。

    `onTunnelStart` 在 101 已经写回客户端、即将开始字节透传时调用一次。握手仍然是一次
    普通的在途请求，但后面的隧道是长连接，调用方用它把请求计数交出去，否则优雅退出会
    一直等这条隧道自己结束。
*/
int forwardWebSocket(
  TCPConnection client,
  HttpHead request,
  ushort port,
  scope void delegate() nothrow onTunnelStart = null
) {
  auto upstream = connectPort(port);
  upstream.readTimeout = readTimeoutMillis().msecs;
  upstream.tcpNoDelay = true;
  scope (exit) {
    upstream.close();
  }

  bool finalResponseStarted;
  try {
    string pending;
    sendPrepared(upstream, request.head);
    if (request.bufferedBody.length > 0) {
      sendPrepared(upstream, request.bufferedBody);
    }

    HttpHead response;
    while (true) {
      response = readResponseHead(upstream, pending);
      if (response.head.length == 0) {
        throw new Exception("upstream closed websocket handshake");
      }
      if (isIntermediateResponse(response)) {
        sendPrepared(client, response.head);
        continue;
      }
      break;
    }

    finalResponseStarted = true;
    sendPrepared(client, response.head);
    if (response.bufferedBody.length > 0) {
      sendPrepared(client, response.bufferedBody);
    }
    if (response.statusCode != 101) {
      return response.statusCode;
    }
  } catch (Exception e) {
    if (upstreamReadTimedOut(e)) {
      noteUpstreamTimeout();
      throw new UpstreamReadTimeoutException(port, finalResponseStarted);
    }
    throw e;
  }

  upstream.readTimeout = Duration.max;
  if (onTunnelStart) onTunnelStart();
  noteWebSocketOpen();
  scope (exit) {
    noteWebSocketClose();
  }
  try {
    tunnel(client, upstream);
  } catch (Exception e) {
    // 101 已经写回 client：隧道里的异常不能再变成 HTTP 响应。
    throw new ResponseStartedException(port, e);
  }
  return 101;
}

/** 建立到本机上游端口的 TCP 连接。

    连接失败被包装为 `PortConnectException`，让 server 层可以精确地区分“尚未接触
    上游服务，可以换一个端口重试”和“已经开始代理字节，不应该自动重放请求”这两种情况。
*/
TCPConnection connectPort(ushort port) {
  try {
    auto connection = connectTCP("127.0.0.1", port, null, 0, connectTimeoutMillis().msecs);
    noteUpstreamConnect();
    return connection;
  } catch (Exception e) {
    throw new PortConnectException(port, e.msg);
  }
}

/** 空闲池每端口容量：跟随近期并发高水位，在 [4, 32] 之间伸缩。 */
private enum upstreamPoolMinIdlePerPort = 4;
private enum upstreamPoolMaxIdlePerPort = 32;
/** 专属上游连接的空闲巡检间隔（毫秒）。 */
private enum upstreamLeaseCheckMillis = 1_000;
/** 空闲池巡检间隔（毫秒）。独立于 `healthCheck.intervalMillis`：池回收的精度不该由
    后端探测频率决定（健康检查配成 60s 时，池里的连接也只多留一个巡检周期）。 */
private enum upstreamPoolSweepMillis = 1_000;
/** 并发高水位的半衰期（毫秒）：空闲这么久，超出下限的部分折半。 */
private enum upstreamPeakHalfLifeMillis = 30_000;
private enum ioBufferSize = 32 * 1024;

private struct IdleUpstream {
  TCPConnection connection;
  MonoTime lastUsed;
}

/** 一条客户端连接跨请求持有的专属上游连接（客户端连接亲和）。

    前置代理的 `http-reuse` 会把同一条前置连接上的请求顺序转给 setline，所以 setline 也按
    「一条客户端连接一条上游连接」做亲和：只要这条客户端连接还活着、端口没被换掉，同一个
    后端端口上的连续请求就走同一条上游 TCP 连接。

    这样稳态下上游连接数就是客户端连接数，而不是每次并发都新建/关闭——每次关闭都会在
    setline 自己的临时端口上留一个 TIME_WAIT，并发一高就会把临时端口耗尽（见
    docs/deployment.md 的 Ephemeral Ports）。

    对象放在 GC 堆上：客户端 task 和空闲回收 task 都要引用它，放在栈上会让回收 task 拿到
    已经失效的栈指针。
*/
final class UpstreamLease {
  TCPConnection connection;
  ushort port;
  MonoTime lastUsed;
  /** 正在代理一个请求；空闲回收 task 看到它就不动这条连接。 */
  bool busy;
  /** 客户端 task 已经处理完这条连接，回收 task 可以退出。 */
  bool done;

  this() {
    lastUsed = MonoTime.currTime;
  }
}

private __gshared IdleUpstream[][ushort] gUpstreamPools;
/** 每个端口当前借出（挂在某条客户端连接上）的上游连接数。 */
private __gshared size_t[ushort] gUpstreamLeased;
/** 借出数的历史高水位；空闲时衰减，空闲池容量跟着它走。 */
private __gshared size_t[ushort] gUpstreamPeak;

/** 每个端口的空闲池容量：跟随近期并发高水位伸缩。 */
size_t upstreamPoolCapacity(ushort port) {
  auto peak = port in gUpstreamPeak ? gUpstreamPeak[port] : 0;
  return upstreamPoolCapacityForPeak(peak);
}

/** 把并发高水位换算成每端口空闲池容量，clamp 到 [4, 32]。 */
pure nothrow size_t upstreamPoolCapacityForPeak(size_t peak) {
  if (peak < upstreamPoolMinIdlePerPort) return upstreamPoolMinIdlePerPort;
  if (peak > upstreamPoolMaxIdlePerPort) return upstreamPoolMaxIdlePerPort;
  return peak;
}

/** 借出后的并发高水位：只涨不落，取借出数与旧高水位的较大者。 */
pure nothrow size_t raisedUpstreamPeak(size_t peak, size_t leased) {
  return leased > peak ? leased : peak;
}

/** 经过 `elapsedMillis` 之后的并发高水位：超出下限的部分每过半衰期折半，到下限为止。

    按时间而不是按巡检次数衰减，所以巡检节奏（`upstreamPoolSweepMillis`）变了也不会
    改变高水位的回落速度；误差最多一个巡检周期。
*/
pure nothrow size_t decayedUpstreamPeak(size_t peak, long elapsedMillis) {
  if (peak <= upstreamPoolMinIdlePerPort || elapsedMillis <= 0) return peak;
  auto excess = peak - upstreamPoolMinIdlePerPort;
  for (auto halfLives = elapsedMillis / upstreamPeakHalfLifeMillis; halfLives > 0 && excess > 0;
      halfLives--) {
    excess /= 2;
  }
  return upstreamPoolMinIdlePerPort + excess;
}

/** 记录一次上游连接借出，并抬高该端口的并发高水位。 */
package(setline) void noteUpstreamLeaseAcquired(ushort port) nothrow {
  auto current = port in gUpstreamLeased;
  auto leased = (current is null ? 0 : *current) + 1;
  gUpstreamLeased[port] = leased;
  auto peak = port in gUpstreamPeak;
  gUpstreamPeak[port] = raisedUpstreamPeak(peak is null ? 0 : *peak, leased);
}

/** 记录一次上游连接归还（放回空闲池或关闭）。 */
package(setline) void noteUpstreamLeaseReleased(ushort port) nothrow {
  auto current = port in gUpstreamLeased;
  if (current !is null && *current > 0) {
    gUpstreamLeased[port] = *current - 1;
  }
}

/** 当前挂在客户端连接上的上游连接数。 */
size_t leasedUpstreamCount() {
  size_t total;
  foreach (count; gUpstreamLeased) {
    total += count;
  }
  return total;
}

/** 当前空闲池里的上游连接数。 */
size_t idleUpstreamCount() {
  size_t total;
  foreach (pool; gUpstreamPools) {
    total += pool.length;
  }
  return total;
}

/** 关闭空闲池里所有上游连接。

    池里的连接已经没有任何请求在用，但 eventcore 的句柄还活着：进程退出时每个活动句柄都会
    换来一条 “leaking eventcore driver” 告警。退出前统一关掉最干净。

    必须用 `ref` 遍历：`TCPConnection` 的拷贝会各自 addRef 一次，按值取出来再 close 会把
    同一个句柄多减一次引用，第二次会读到已经释放的 userData。
*/
void closeUpstreamPool() nothrow {
  foreach (ref pool; gUpstreamPools) {
    foreach (ref entry; pool) {
      try {
        entry.connection.close();
      } catch (Throwable) {
      }
    }
  }
  gUpstreamPools = null;
}

/** 发送任何字节之前确认这条空闲连接没有 EOF、也没有残留数据。 */
private bool upstreamConnectionUsable(ref TCPConnection connection) nothrow {
  if (!connection.connected) {
    return false;
  }
  try {
    return connection.waitForDataEx(0.msecs) == WaitForDataStatus.timeout;
  } catch (Throwable) {
    return false;
  }
}

/** 从指定端口的空闲池取连接；发送任何字节前先确认没有 EOF 和残留数据。 */
private TCPConnection acquireUpstream(ushort port) {
  if (auto poolPtr = port in gUpstreamPools) {
    auto pool = *poolPtr;
    while (pool.length > 0) {
      auto candidate = pool[$ - 1];
      pool = pool[0 .. $ - 1];
      auto expired = MonoTime.currTime - candidate.lastUsed
        > upstreamIdleTimeoutMillis().msecs;
      if (!expired && upstreamConnectionUsable(candidate.connection)) {
        gUpstreamPools[port] = pool;
        candidate.connection.readTimeout = readTimeoutMillis().msecs;
        candidate.connection.tcpNoDelay = true;
        notePoolHit();
        noteUpstreamLeaseAcquired(port);
        return candidate.connection;
      }
      candidate.connection.close();
    }
    gUpstreamPools.remove(port);
  }

  auto upstream = connectPort(port);
  upstream.readTimeout = readTimeoutMillis().msecs;
  upstream.tcpNoDelay = true;
  noteUpstreamLeaseAcquired(port);
  return upstream;
}

/** 让 lease 在 port 上有一条可用的上游连接：先复用自己的，再试空闲池，最后新建。 */
private void ensureLeaseUpstream(UpstreamLease lease, ushort port) {
  if (lease.connection && lease.port == port
      && upstreamConnectionUsable(lease.connection)) {
    lease.connection.readTimeout = readTimeoutMillis().msecs;
    lease.connection.tcpNoDelay = true;
    notePoolHit();
    return;
  }
  dropLeaseConnection(lease);
  lease.connection = acquireUpstream(port);
  lease.port = port;
}

/** 把一条还健康的上游连接放回空闲池；池满时淘汰最旧连接。 */
private void releaseUpstreamToPool(ref TCPConnection upstream, ushort port) nothrow {
  try {
    upstream.readTimeout = Duration.max;
    IdleUpstream[] pool;
    if (auto poolPtr = port in gUpstreamPools) {
      pool = *poolPtr;
    }
    auto capacity = upstreamPoolCapacity(port);
    while (pool.length >= capacity) {
      auto oldest = pool[0];
      pool = pool[1 .. $];
      oldest.connection.close();
    }
    IdleUpstream entry;
    entry.connection = upstream;
    entry.lastUsed = MonoTime.currTime;
    pool ~= entry;
    gUpstreamPools[port] = pool;
  } catch (Throwable) {
  }
}

/** 关闭 lease 上的上游连接并清空 lease。 */
void dropLeaseConnection(UpstreamLease lease) nothrow {
  if (!lease.connection) {
    lease.port = 0;
    return;
  }
  auto port = lease.port;
  try {
    lease.connection.close();
  } catch (Throwable) {
  }
  lease.connection = TCPConnection.init;
  lease.port = 0;
  noteUpstreamLeaseReleased(port);
}

/** 把 lease 上的连接交回空闲池（lease 只放引用，不关闭连接）。 */
void returnLeaseToPool(UpstreamLease lease) nothrow {
  if (!lease.connection) {
    lease.port = 0;
    return;
  }
  if (!upstreamConnectionUsable(lease.connection)) {
    dropLeaseConnection(lease);
    return;
  }
  auto port = lease.port;
  releaseUpstreamToPool(lease.connection, port);
  lease.connection = TCPConnection.init;
  lease.port = 0;
  noteUpstreamLeaseReleased(port);
}

/** 空闲回收：客户端连接长时间不发新请求时，把专属上游连接交回空闲池。

    客户端连接保持 keep-alive 但一直空闲时，挂着的那条上游连接会白占一个 fd 和一个临时
    端口。超过 `upstreamIdleTimeoutMillis` 没有请求就还回池子，下一条请求再从池子里取。
    巡检间隔固定 1s：这是低频兜底，秒级误差不影响正确性。
*/
private void recycleIdleLease(UpstreamLease lease) nothrow {
  while (true) {
    try {
      sleep(upstreamLeaseCheckMillis.msecs);
    } catch (InterruptException) {
      return;
    } catch (Throwable) {
      return;
    }
    if (lease.done) {
      return;
    }
    if (lease.busy || !lease.connection) {
      continue;
    }
    if (MonoTime.currTime - lease.lastUsed <= upstreamIdleTimeoutMillis().msecs) {
      continue;
    }
    returnLeaseToPool(lease);
  }
}

/** 为一条客户端连接开启专属上游连接的空闲回收，返回它的 task。 */
Task beginLease(UpstreamLease lease) {
  return runTask(&recycleIdleLease, lease);
}

/** 客户端连接结束：停掉回收 task，并把还健康的专属连接交回空闲池。 */
void finishLease(UpstreamLease lease, ref Task idleTask) nothrow {
  lease.done = true;
  stopTaskIfRunning(idleTask);
  returnLeaseToPool(lease);
}

/** 周期回收：按 `elapsed` 衰减并发高水位，并清掉超时或超容量的空闲连接。

    `elapsed` 是距上一次巡检的真实时间，由 `runUpstreamPoolJanitor` 填；测试可以传一个
    虚拟值来检查衰减，不用真的等待。
*/
void sweepUpstreamPool(Duration elapsed) nothrow {
  try {
    ushort[] peakPorts;
    foreach (port; gUpstreamPeak.byKey) {
      peakPorts ~= port;
    }
    foreach (port; peakPorts) {
      auto peak = port in gUpstreamPeak;
      if (peak !is null) {
        gUpstreamPeak[port] = decayedUpstreamPeak(*peak, elapsed.total!"msecs");
      }
    }

    ushort[] ports;
    foreach (port; gUpstreamPools.byKey) {
      ports ~= port;
    }
    foreach (port; ports) {
      auto pool = gUpstreamPools[port];
      auto capacity = upstreamPoolCapacity(port);
      auto now = MonoTime.currTime;
      // 池内按 lastUsed 升序排列：要丢的是「超出容量的最旧几条」加上「已经过期的」，
      // 两者都落在头部，所以这里只需要从头部往尾扫一遍。
      auto start = pool.length > capacity ? pool.length - capacity : 0;
      while (start < pool.length
          && now - pool[start].lastUsed > upstreamIdleTimeoutMillis().msecs) {
        pool[start].connection.close();
        start++;
      }
      if (start == 0) continue;
      IdleUpstream[] kept;
      foreach (ref entry; pool[start .. $]) {
        kept ~= entry;
      }
      if (kept.length == 0) {
        gUpstreamPools.remove(port);
      } else {
        gUpstreamPools[port] = kept;
      }
    }
  } catch (Throwable) {
  }
}

/** 空闲池巡检：独立于健康检查节奏，按真实经过的时间衰减高水位并回收空闲连接。

    每 `upstreamPoolSweepMillis` 醒一次，把实际间隔交给 `sweepUpstreamPool`，所以巡检频率
    变了也不会改变高水位的回落速度。健康检查配成 60s 时，池里的连接最多多留一个巡检周期，
    而不是跟着等 60s。
*/
void runUpstreamPoolJanitor() nothrow {
  auto previous = MonoTime.currTime;
  while (true) {
    try {
      sleep(upstreamPoolSweepMillis.msecs);
    } catch (InterruptException) {
      return;
    } catch (Throwable) {
      return;
    }
    auto now = MonoTime.currTime;
    sweepUpstreamPool(now - previous);
    previous = now;
  }
}

/** 隧道两个方向共享的活动状态。

    两个方向跑在各自的 task 里，但都在同一个事件循环线程上，所以普通字段就够了。放在 GC
    堆上是为了后台方向的 task 不会拿到已经失效的栈指针。
*/
private struct TunnelActivity {
  MonoTime last;
  bool timedOut;
}

/** 在两个 TCP 连接之间建立双向字节转发。

    vibe-core 的 task 用于承载上游到浏览器方向，当前 task 负责浏览器到上游方向。任意一边
    读到 EOF 或出错后都会关闭目标连接，让另一边尽快退出，避免 WebSocket 或长连接残留。

    配置了 `webSocketIdleTimeoutMillis` 时按「两个方向都没有字节」计时：只有一侧在动就不算
    空闲；真正静默到点就断开两端，并记一次 `webSocketIdleTimeouts`。
*/
void tunnel(TCPConnection client, TCPConnection upstream) {
  auto activity = new TunnelActivity(MonoTime.currTime);
  runTask(&relayToClient, upstream, client, activity);

  // 用 scope(exit) 而不是顺序调用：两个方向的读写都可能抛异常，异常路径同样要把两端都关掉
  // ——漏关的句柄要等 GC 才释放，退出时会被 eventcore 记成 leaking driver。
  scope (exit) {
    if (activity.timedOut) {
      noteWebSocketIdleTimeout();
    }
    closeBoth(client, upstream);
  }
  relayDirection(client, upstream, activity, true);
}

/** 从 source 转发到 target，并在异常或 EOF 后关闭 target。

    这是隧道中后台方向的保护壳。它不能把异常抛回调用方，因为该函数运行在独立 task 中；
    出错时关闭目标连接就是通知另一半隧道退出的机制。
*/
private void relayToClient(
  TCPConnection source,
  TCPConnection target,
  TunnelActivity* activity
) nothrow {
  try {
    relayDirection(source, target, activity, false);
  } catch (Throwable) {
  }
  try {
    target.close();
  } catch (Throwable) {
  }
}

/** 单向隧道透传，并顺带做空闲超时和字节计数。

    该函数不理解 HTTP、WebSocket 帧或 chunked 编码，只做字节复制。保持这种低层语义可以
    让 WebSocket、SSE 或其他升级后的协议尽量不受代理层影响。

    `upstreamDirection` 为真表示 client -> upstream。读超时本身只说明「这个方向没等到
    数据」，因此超时后回到循环重算剩余空闲时间：另一个方向刚有字节就不算空闲。这样做的
    代价是每个方向最多每隔 `idleTimeout` 醒一次，不会变成忙等。
*/
private void relayDirection(
  TCPConnection source,
  TCPConnection target,
  TunnelActivity* activity,
  bool upstreamDirection
) {
  ubyte[ioBufferSize] buffer;
  auto idleMillis = webSocketIdleTimeoutMillis();
  while (true) {
    if (idleMillis > 0) {
      auto remaining = idleMillis.msecs - (MonoTime.currTime - activity.last);
      if (remaining <= Duration.zero) {
        activity.timedOut = true;
        closeBoth(source, target);
        return;
      }
      source.readTimeout = remaining;
    }

    size_t received;
    try {
      received = source.read(buffer[], IOMode.once);
    } catch (Exception e) {
      if (idleMillis > 0 && upstreamReadTimedOut(e)) {
        continue;
      }
      return;
    }
    if (received == 0) {
      return;
    }
    activity.last = MonoTime.currTime;
    if (upstreamDirection) {
      noteWebSocketBytesToUpstream(received);
    } else {
      noteWebSocketBytesToClient(received);
    }
    sendPrepared(target, buffer[0 .. received]);
  }
}

/** 关闭隧道两端；对已经关闭的连接是空操作。 */
private void closeBoth(TCPConnection source, TCPConnection target) nothrow {
  try {
    source.close();
  } catch (Throwable) {
  }
  try {
    target.close();
  } catch (Throwable) {
  }
}

/** 按请求头声明把剩余 request body 转发给上游。

    `bufferedBody` 是读请求头时已经多读到的 body 前缀，调用方已经先把它写给上游。
    因此这里仅补齐剩余字节：`Content-Length` 按长度读，chunked 则按 chunk 结束标记读。
    如果请求没有 body 相关头部，则不会继续从浏览器读取，避免阻塞 GET 等普通请求。
*/
bool relayRequestBody(
  TCPConnection source,
  TCPConnection target,
  HttpHead request
) {
  if (request.transferChunked) {
    return relayChunked(source, target, request.bufferedBody);
  } else if (request.hasContentLength) {
    auto contentLength = cast(size_t) request.contentLength;
    return relayBytes(source, target,
      contentLength > request.bufferedBody.length ? contentLength - request.bufferedBody.length : 0);
  }
  return true;
}

/** 按固定字节数转发数据。

    用于 `Content-Length` 明确的请求体或响应体。读取过程中如果连接提前关闭，则直接返回；
    代理不伪造剩余数据，也不尝试修复上游或客户端的半截消息。
*/
bool relayBytes(TCPConnection source, TCPConnection target, size_t bytes) {
  ubyte[ioBufferSize] buffer;
  auto remaining = bytes;
  while (remaining > 0) {
    auto limit = remaining < buffer.length ? remaining : buffer.length;
    auto received = source.read(buffer[0 .. limit], IOMode.once);
    if (received <= 0) {
      return false;
    }
    sendPrepared(target, buffer[0 .. received]);
    remaining -= received;
  }
  return true;
}

/** 一直转发到 source 关闭。

    该路径用于没有 `Content-Length` 且不是 chunked 的响应。HTTP/1.1 中这类响应通常以
    连接关闭作为 body 结束信号，因此代理只能跟随后端关闭连接，不能主动截断。
*/
bool relayUntilClose(TCPConnection source, TCPConnection target) {
  ubyte[ioBufferSize] buffer;
  while (true) {
    auto received = source.read(buffer[], IOMode.once);
    if (received <= 0) {
      return true;
    }
    sendPrepared(target, buffer[0 .. received]);
  }
}

/** 转发 chunked 编码的数据直到读到最后一个 chunk。

    函数需要同时考虑初始响应头读取时已经带回来的 body 前缀，以及之后从连接中继续读到
    的 chunk。每次新读到的数据都会立即写给目标连接，内部只保留 chunk 边界解析状态，
    不累计完整 body。
*/
bool relayChunked(TCPConnection source, TCPConnection target, const(ubyte)[] body) {
  ChunkedBodyTracker tracker;
  if (tracker.feed(body)) return true;

  ubyte[ioBufferSize] buffer;
  while (true) {
    auto received = source.read(buffer[], IOMode.once);
    if (received <= 0) {
      return false;
    }
    sendPrepared(target, buffer[0 .. received]);
    if (tracker.feed(buffer[0 .. received])) {
      return true;
    }
  }
}

/** 判断一段 chunked body 是否已经包含终止 chunk 和可选 trailer。

    该函数只做边界识别，不返回解码后的实体内容。代理不需要理解业务 body，只需要知道
    什么时候可以停止从上游继续读取，避免等待已经完成的资源而拖慢浏览器后续请求。
*/
bool chunkedBodyComplete(string body) {
  ChunkedBodyTracker tracker;
  return tracker.feed(cast(const(ubyte)[]) body);
}

/** 解析 chunk size 行中的十六进制长度。 */
size_t parseChunkSize(string line) {
  size_t size;
  foreach (ch; line) {
    if (ch == ';') break;
    if (ch >= '0' && ch <= '9') {
      size = size * 16 + cast(size_t)(ch - '0');
    } else if (ch >= 'a' && ch <= 'f') {
      size = size * 16 + cast(size_t)(ch - 'a' + 10);
    } else if (ch >= 'A' && ch <= 'F') {
      size = size * 16 + cast(size_t)(ch - 'A' + 10);
    } else {
      throw new Exception("invalid chunk size");
    }
  }
  return size;
}

/** 跟踪 chunked 消息边界。

    代理不需要读取或解析业务 body，只需要知道 chunked 消息何时结束。该状态机只保存当前
    行和剩余 chunk 字节数，避免大 body 通过代理时被累积到内存中。
*/
struct ChunkedBodyTracker {
  private enum State {
    sizeLine,
    sizeLineLf,
    data,
    dataCr,
    dataLf,
    trailerLine,
    trailerLineLf,
    complete
  }

  private State state;
  private string line;
  private size_t remaining;

  bool feed(const(ubyte)[] data) {
    size_t pos;
    while (pos < data.length && state != State.complete) {
      final switch (state) {
        case State.sizeLine:
          readLineByte(cast(char) data[pos], State.sizeLineLf);
          ++pos;
          break;
        case State.sizeLineLf:
          readLineFeed(cast(char) data[pos], &finishSizeLine);
          ++pos;
          break;
        case State.data:
          auto available = data.length - pos;
          auto consumed = remaining < available ? remaining : available;
          remaining -= consumed;
          pos += consumed;
          if (remaining == 0) {
            state = State.dataCr;
          }
          break;
        case State.dataCr:
          enforceByte(cast(char) data[pos], '\r', "chunk data must end with CRLF");
          state = State.dataLf;
          ++pos;
          break;
        case State.dataLf:
          enforceByte(cast(char) data[pos], '\n', "chunk data must end with CRLF");
          state = State.sizeLine;
          ++pos;
          break;
        case State.trailerLine:
          readLineByte(cast(char) data[pos], State.trailerLineLf);
          ++pos;
          break;
        case State.trailerLineLf:
          readLineFeed(cast(char) data[pos], &finishTrailerLine);
          ++pos;
          break;
        case State.complete:
          break;
      }
    }
    return state == State.complete;
  }

  private void readLineByte(char ch, State nextState) {
    if (ch == '\r') {
      state = nextState;
    } else {
      line ~= ch;
    }
  }

  private void readLineFeed(char ch, void delegate() finishLine) {
    enforceByte(ch, '\n', "chunk line must end with CRLF");
    finishLine();
  }

  private void finishSizeLine() {
    auto size = parseChunkSize(line);
    line = "";
    if (size == 0) {
      state = State.trailerLine;
    } else {
      remaining = size;
      state = State.data;
    }
  }

  private void finishTrailerLine() {
    if (line.length == 0) {
      state = State.complete;
    } else {
      line = "";
      state = State.trailerLine;
    }
  }
}

private void enforceByte(char actual, char expected, string message) {
  if (actual != expected) {
    throw new Exception(message);
  }
}

/** 判断响应状态是否按 HTTP 规则没有响应体。

    1xx、204、304 以及 HEAD 请求响应不能按普通 body 继续读取。这里处理的是状态码本身；
    HEAD 请求由调用方结合原始请求方法单独判断。
*/
bool responseHasNoBody(HttpHead response) {
  auto status = response.statusCode;
  return (status >= 100 && status < 200) || status == 204 || status == 304;
}
