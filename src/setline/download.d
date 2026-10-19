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

module setline.download;

import std.algorithm : canFind, startsWith;
import std.array : appender;
import std.exception : enforce;
import std.file : exists, getAttributes, mkdirRecurse, readText, remove, rename, setAttributes, write;
import std.functional : toDelegate;
import std.json : JSONType, JSONValue, parseJSON;
import std.path : buildPath, dirName;
import std.string : indexOf, splitLines, strip, stripRight;
import std.conv : octal;

import setline.control : renderAgentPeers;
import setline.edge : fetchText;
import setline.model : PeerConfig;
import setline.peer : peerAddress;
import setline.util : toLowerAscii;

/** bashub 为 setline 提供的两份机器配置。 */
enum DownloadKind {
  peers,
  proxy,
  certificate,
  certificateKey,
}

/** 由 bashub 根地址、Profile 名和配置类型组成下载 URL。

    `remoteUrl` 与 basctl 的 `[remote] url` 同义，例如 `http://127.0.0.1:8082`；
    机器配置固定走 `/api/{profile}/config/...`，这里统一补 `/api`，配置文件里不要重复写。
*/
string downloadUrl(string remoteUrl, string profile, DownloadKind kind) {
  auto base = remoteUrl.strip.stripRight("/");
  enforce(base.length > 0, "[remote] url must not be empty");
  enforce(base.startsWith("http://") || base.startsWith("https://"),
    "[remote] url must start with http:// or https://");
  enforce(base.indexOf('?') < 0 && base.indexOf('#') < 0,
    "[remote] url must not contain a query string or fragment");
  auto name = profile.strip;
  enforce(name.length > 0, "[remote] profile must not be empty");
  enforce(name.indexOf('/') < 0 && name.indexOf(':') < 0 && name.indexOf('?') < 0
      && name.indexOf('#') < 0,
    "[remote] profile must not contain '/', ':', '?' or '#'");
  string endpoint;
  final switch (kind) {
  case DownloadKind.peers:
    endpoint = "config/setline-peers";
    break;
  case DownloadKind.proxy:
    endpoint = "config/proxy";
    break;
  case DownloadKind.certificate:
    endpoint = "config/certificate";
    break;
  case DownloadKind.certificateKey:
    endpoint = "config/certificate-key";
    break;
  }
  return base ~ "/api/" ~ name ~ "/" ~ endpoint;
}

/** 构造 bashub 机器下载使用的 Bearer 值。

    bashub 接受 Profile key 本身，也接受 `<profile>:<key>`；这里优先发送后者，
    让服务端能同时校验 URL 里的 Profile 与凭证是否绑定。用户显式给出带 Profile 的
    token 时原样使用，但必须与 `[remote] profile` 一致。
*/
string bearerToken(string profile, string token) {
  auto name = profile.strip;
  auto value = token.strip;
  enforce(name.length > 0, "[remote] profile must not be empty");
  enforce(value.length > 0, "[remote] token must not be empty");
  enforce(value.indexOf('\r') < 0 && value.indexOf('\n') < 0,
    "[remote] token must not contain a line break");
  auto colon = value.indexOf(':');
  if (colon < 0)
    return name ~ ":" ~ value;
  enforce(value[0 .. colon] == name,
    "[remote] token profile does not match [remote] profile: " ~ value[0 .. colon]);
  return value;
}

/** 下载一份配置。

    默认通过 curl 拉取；`fetcher` 只供单测注入，避免依赖网络。下载 peers 时先校验
    响应结构，防止把错误页或半截响应当成有效配置写出。
*/
string downloadConfig(string remoteUrl, string profile, string token, DownloadKind kind,
    string delegate(string url, string[] headers) fetcher = null) {
  auto url = downloadUrl(remoteUrl, profile, kind);
  auto headers = ["Authorization: Bearer " ~ bearerToken(profile, token)];
  auto get = fetcher is null ? toDelegate(&fetchText) : fetcher;
  auto text = get(url, headers);
  if (kind == DownloadKind.proxy)
    enforce(text.strip.length > 0, "downloaded config is empty: " ~ url);
  if (kind == DownloadKind.peers)
    parseDownloadedPeers(text);
  return text;
}

/** 解析 bashub 的 peers 响应：`{"peers":[{"name":"host01","url":"http://..."}]}`。 */
PeerConfig[] parseDownloadedPeers(string text) {
  enforce(text.strip.length > 0, "downloaded peers config is empty");
  auto root = parseJSON(text);
  enforce(root.type == JSONType.object, "downloaded peers config must be a JSON object");
  enforce("peers" in root.object, "downloaded peers config must contain peers");
  auto value = root["peers"];
  enforce(value.type == JSONType.array, "downloaded peers must be an array");

  PeerConfig[] peers;
  bool[string] urls;
  foreach (item; value.array) {
    enforce(item.type == JSONType.object, "downloaded peer must be an object");
    foreach (key, _; item.object)
      enforce(key == "name" || key == "url", "downloaded peer has unknown field: " ~ key);
    enforce("name" in item.object && item["name"].type == JSONType.string,
      "downloaded peer.name is required");
    enforce("url" in item.object && item["url"].type == JSONType.string,
      "downloaded peer.url is required");
    PeerConfig peer;
    peer.name = item["name"].str.strip;
    peer.url = item["url"].str.strip;
    enforce(peer.name.length > 0, "downloaded peer.name must not be empty");
    enforce(peer.name.indexOf(',') < 0 && peer.name.indexOf(' ') < 0
        && peer.name.indexOf('\t') < 0,
      "downloaded peer.name must not contain a comma or whitespace: " ~ peer.name);
    enforce(peer.url.startsWith("http://") || peer.url.startsWith("https://"),
      "downloaded peer.url must start with http:// or https://: " ~ peer.url);
    enforce(peer.url.indexOf(',') < 0 && peer.url.indexOf(' ') < 0
        && peer.url.indexOf('\t') < 0 && peer.url.indexOf('?') < 0
        && peer.url.indexOf('#') < 0,
      "downloaded peer.url must be a base URL without whitespace, comma, query or fragment: " ~
      peer.url);
    peerAddress(peer);
    enforce(peer.url !in urls, "downloaded peers contains a duplicate url: " ~ peer.url);
    urls[peer.url] = true;
    peers ~= peer;
  }
  return peers;
}

/** 证书目录下的固定文件名。 */
string certificatePath(string dir, string name) {
  return buildPath(dir, name);
}

/** 写入证书对；两端都为空表示 Profile 未配置 HTTPS 证书，清掉旧文件。 */
bool writeCertificatePair(string dir, string certText, string keyText) {
  enforce(dir.length > 0 && dir[0] == '/', "certificate directory must be an absolute path");
  auto cert = normalizePem(certText);
  auto key = normalizePem(keyText);
  if (cert.length == 0 && key.length == 0) {
    bool removed;
    foreach (name; ["cert.pem", "key.pem", "bundle.pem"]) {
      auto path = certificatePath(dir, name);
      if (exists(path)) {
        remove(path);
        removed = true;
      }
    }
    return removed;
  }
  enforce(cert.length > 0, "downloaded certificate is empty but private key is present");
  enforce(key.length > 0, "downloaded private key is empty but certificate is present");
  enforce(cert.canFind("-----BEGIN CERTIFICATE-----"),
    "downloaded certificate is not a PEM certificate");
  enforce(key.canFind("PRIVATE KEY-----"),
    "downloaded private key is not a PEM private key");

  if (!exists(dir))
    mkdirRecurse(dir);
  auto certPath = certificatePath(dir, "cert.pem");
  auto keyPath = certificatePath(dir, "key.pem");
  auto bundlePath = certificatePath(dir, "bundle.pem");
  auto bundle = cert ~ key;
  auto changed = writeDownloadedMode(certPath, cert, octal!644);
  changed = writeDownloadedMode(keyPath, key, octal!600) || changed;
  changed = writeDownloadedMode(bundlePath, bundle, octal!600) || changed;
  return changed;
}

private string normalizePem(string text) {
  auto result = text.strip;
  if (result.length == 0)
    return "";
  result ~= "\n";
  return result;
}

/** 把下载到的 peers 写回 `setline.conf` 的 `[agent] peers`，其余配置原样保留。 */
string rewriteAgentPeers(string text, const PeerConfig[] peers) {
  auto value = renderAgentPeers(peers);
  auto lines = text.splitLines();

  bool hasAgentSection;
  bool hasPeersLine;
  string section;
  foreach (raw; lines) {
    auto line = strip(raw);
    if (line.length == 0 || line[0] == '#' || line[0] == ';')
      continue;
    if (line[0] == '[') {
      auto close = line.indexOf(']');
      if (close > 0) {
        section = toLowerAscii(strip(line[1 .. close]));
        if (section == "agent")
          hasAgentSection = true;
      }
      continue;
    }
    if (section != "agent")
      continue;
    auto equals = line.indexOf('=');
    if (equals > 0 && toLowerAscii(strip(line[0 .. equals])) == "peers")
      hasPeersLine = true;
  }

  auto out_ = appender!string();
  section = "";
  bool inAgent;
  bool replaced;
  bool inserted;
  foreach (raw; lines) {
    auto line = strip(raw);
    if (line.length > 0 && line[0] == '[' && line.indexOf(']') > 0) {
      if (inAgent && !hasPeersLine && !inserted) {
        out_.put("peers = ");
        out_.put(value);
        out_.put('\n');
        inserted = true;
      }
      auto close = line.indexOf(']');
      section = toLowerAscii(strip(line[1 .. close]));
      inAgent = section == "agent";
      out_.put(raw);
      out_.put('\n');
      continue;
    }
    if (inAgent) {
      auto equals = line.indexOf('=');
      if (equals > 0 && toLowerAscii(strip(line[0 .. equals])) == "peers") {
        if (!replaced) {
          out_.put("peers = ");
          out_.put(value);
          out_.put('\n');
          replaced = true;
        }
        continue;
      }
    }
    out_.put(raw);
    out_.put('\n');
  }
  if (inAgent && !hasPeersLine && !inserted) {
    out_.put("peers = ");
    out_.put(value);
    out_.put('\n');
  }
  if (!hasAgentSection) {
    if (out_.data.length > 0) {
      if (out_.data[$ - 1] != '\n')
        out_.put('\n');
      if (out_.data.length < 2 || out_.data[$ - 2] != '\n')
        out_.put('\n');
    }
    out_.put("[agent]\npeers = ");
    out_.put(value);
    out_.put('\n');
  }
  return out_.data;
}

/** 原子写出下载结果；内容未变化时不触碰原文件，返回是否发生写入。 */
bool writeDownloaded(string path, string text) {
  enforce(path.length > 0, "output path must not be empty");
  if (exists(path) && readText(path) == text)
    return false;
  auto parent = dirName(path);
  if (parent.length > 0 && !exists(parent))
    mkdirRecurse(parent);
  auto tmpPath = path ~ ".tmp";
  write(tmpPath, text);
  rename(tmpPath, path);
  return true;
}

/** 同 `writeDownloaded`，但临时文件在 rename 前就设好权限，私钥不会短暂按 umask 暴露。 */
private bool writeDownloadedMode(string path, string text, uint mode) {
  enforce(path.length > 0, "output path must not be empty");
  if (exists(path) && readText(path) == text) {
    if ((getAttributes(path) & octal!777) != mode)
      setAttributes(path, mode);
    return false;
  }
  auto parent = dirName(path);
  if (parent.length > 0 && !exists(parent))
    mkdirRecurse(parent);
  auto tmpPath = path ~ ".tmp";
  write(tmpPath, text);
  setAttributes(tmpPath, mode);
  rename(tmpPath, path);
  return true;
}
