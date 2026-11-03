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

import std.algorithm : canFind, sort, startsWith;
import std.array : appender;
import std.exception : enforce;
import std.file : exists, getAttributes, mkdirRecurse, readText, remove, rename, rmdirRecurse, setAttributes, write;
import std.functional : toDelegate;
import std.json : JSONType, JSONValue, parseJSON;
import std.path : buildPath, dirName;
import std.string : indexOf, splitLines, strip, stripRight, toStringz;
import std.conv : octal, to;
import std.digest : LetterCase, toHexString;
import std.digest.sha : sha256Of;

import core.sys.posix.sys.stat : stat, stat_t;
import core.sys.posix.unistd : chown, getegid, geteuid;

import setline.control : defaultFragmentRoot;
import setline.config : normalizeRouteHost, normalizeRoutePrefix, parsePort;
import setline.edge : fetchText, fetchTextStatus;
import setline.model : HostRoutes, Route;
import setline.util : toLowerAscii;

/** bashub 为 setline 提供的两份机器配置。 */
enum DownloadKind {
  manifest,
  routes,
  proxy,
  certificate,
  certificateKey,
}

enum manifestResourceProxy = "proxy";
enum manifestResourceRoutes = "routes";
enum manifestResourceCertificate = "certificate";
enum manifestResourceCertificateKey = "certificate-key";

/// agent 以非特权用户写入、由 root 原子安装的暂存目录和固定文件名。
enum remoteStageName = "remote-stage";
enum stagedControlName = "setline.conf";
enum stagedProxyName = "proxy.cfg";
enum stagedCertificateName = "certificate.pem";
enum stagedCertificateKeyName = "certificate-key.pem";
enum stagedCertificateEmptyName = "certificate.empty";
enum stagedManifestName = "remote.manifest.json";

/// bashub 返回的远程资源清单：资源名 → 响应 Body 的 SHA-256。
struct RemoteManifest {
  int schemaVersion = 1;
  string[string] resources;
}

/** 由 bashub 根地址、Project 名和配置类型组成下载 URL。

    `remoteUrl` 与 basctl 的 `[remote] url` 同义，例如 `http://127.0.0.1:8082`；
    机器配置固定走 `/api/{project}/config/...`，这里统一补 `/api`，配置文件里不要重复写。
*/
string downloadUrl(string remoteUrl, string project, DownloadKind kind) {
  auto base = remoteUrl.strip.stripRight("/");
  enforce(base.length > 0, "[remote] url must not be empty");
  enforce(base.startsWith("http://") || base.startsWith("https://"),
    "[remote] url must start with http:// or https://");
  enforce(base.indexOf('?') < 0 && base.indexOf('#') < 0,
    "[remote] url must not contain a query string or fragment");
  auto name = project.strip;
  enforce(name.length > 0, "[remote] project must not be empty");
  enforce(name.indexOf('/') < 0 && name.indexOf(':') < 0 && name.indexOf('?') < 0
      && name.indexOf('#') < 0,
    "[remote] project must not contain '/', ':', '?' or '#'");
  string endpoint;
  final switch (kind) {
  case DownloadKind.manifest:
    endpoint = "config/setline-manifest";
    break;
  case DownloadKind.routes:
    endpoint = "config/routes";
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
  return base ~ "/api/bashub/config/" ~ name ~ "/" ~ endpoint["config/".length .. $];
}

/** 构造 bashub 机器下载使用的 Bearer 值。

    bashub 接受 Project key 本身，也接受 `<project>:<key>`；这里优先发送后者，
    让服务端能同时校验 URL 里的 Project 与凭证是否绑定。用户显式给出带 Profile 的
    token 时原样使用，但必须与 `[remote] project` 一致。
*/
string bearerToken(string project, string token) {
  auto name = project.strip;
  auto value = token.strip;
  enforce(name.length > 0, "[remote] project must not be empty");
  enforce(value.length > 0, "[remote] token must not be empty");
  enforce(value.indexOf('\r') < 0 && value.indexOf('\n') < 0,
    "[remote] token must not contain a line break");
  auto colon = value.indexOf(':');
  if (colon < 0)
    return name ~ ":" ~ value;
  enforce(value[0 .. colon] == name,
    "[remote] token project does not match [remote] project: " ~ value[0 .. colon]);
  return value;
}

/** 下载一份配置。

    默认通过 curl 拉取；`fetcher` 只供单测注入，避免依赖网络。下载资源时先校验
    响应结构，防止把错误页或半截响应当成有效配置写出。
*/
string downloadConfig(string remoteUrl, string project, string token, DownloadKind kind,
    string ip = "", string delegate(string url, string[] headers) fetcher = null) {
  auto url = downloadUrl(remoteUrl, project, kind);
  if (kind == DownloadKind.routes && ip.length > 0)
    url ~= "?ip=" ~ ip;
  auto headers = ["Authorization: Bearer " ~ bearerToken(project, token)];
  if (ip.length > 0)
    headers ~= "ip: " ~ ip;
  auto get = fetcher is null ? toDelegate(&fetchText) : fetcher;
  auto text = get(url, headers);
  if (kind == DownloadKind.proxy)
    enforce(text.strip.length > 0, "downloaded config is empty: " ~ url);
  if (kind == DownloadKind.manifest)
    parseRemoteManifest(text);
  return text;
}

/** 条件 GET manifest；304 时返回空串并置 notModified。 */
string downloadManifest(string remoteUrl, string project, string token, string ip,
    string ifNoneMatch, out bool notModified, out string etag) {
  auto url = downloadUrl(remoteUrl, project, DownloadKind.manifest);
  auto headers = ["Authorization: Bearer " ~ bearerToken(project, token)];
  if (ip.length > 0)
    headers ~= "ip: " ~ ip;
  if (ifNoneMatch.length > 0)
    headers ~= "If-None-Match: " ~ ifNoneMatch;
  auto response = fetchTextStatus(url, headers);
  if (response.status == 304) {
    notModified = true;
    etag = ifNoneMatch;
    return "";
  }
  enforce(response.status == 200, "manifest download failed: HTTP " ~ response.status.to!string);
  notModified = false;
  etag = "\"" ~ sha256Hex(response.body) ~ "\"";
  return response.body;
}

/** 解析 bashub 的 routes 响应：`{"host":"...","routes":[{"prefix":"/x","port":8080}]}`。 */
HostRoutes[] parseDownloadedRoutes(string text) {
  auto root = parseJSON(text);
  enforce(root.type == JSONType.object, "downloaded routes must be an object");
  enforce("host" in root.object && root["host"].type == JSONType.string,
    "downloaded routes must contain host");
  enforce("routes" in root.object && root["routes"].type == JSONType.array,
    "downloaded routes must contain routes");
  HostRoutes group;
  group.host = normalizeRouteHost(root["host"].str);
  Route[] routes;
  foreach (item; root["routes"].array) {
    enforce(item.type == JSONType.object, "downloaded route must be an object");
    enforce("prefix" in item.object && item["prefix"].type == JSONType.string,
      "downloaded route must contain prefix");
    enforce("port" in item.object && item["port"].type == JSONType.integer,
      "downloaded route must contain port");
    Route route;
    route.prefix = normalizeRoutePrefix(item["prefix"].str);
    route.ports = [parsePort(item["port"].integer, "route port")];
    routes ~= route;
  }
  group.routes = routes;
  return [group];
}

/** 解析并校验远程清单。四个资源必须齐全，未知资源忽略，便于将来加字段。 */
RemoteManifest parseRemoteManifest(string text) {
  enforce(text.strip.length > 0, "downloaded setline manifest is empty");
  auto root = parseJSON(text);
  enforce(root.type == JSONType.object, "downloaded setline manifest must be a JSON object");
  enforce("version" in root.object, "downloaded setline manifest must contain version");
  enforce(root["version"].type == JSONType.integer,
    "downloaded setline manifest version must be an integer");
  auto schemaVersion = root["version"].integer.to!int;
  enforce(schemaVersion == 1, "unsupported setline manifest version: " ~ schemaVersion.to!string);
  enforce("resources" in root.object, "downloaded setline manifest must contain resources");
  auto res = root["resources"];
  enforce(res.type == JSONType.object, "downloaded setline manifest resources must be an object");

  RemoteManifest manifest;
  manifest.schemaVersion = schemaVersion;
  foreach (name, value; res.object) {
    enforce(name == manifestResourceProxy || name == manifestResourceCertificate
        || name == manifestResourceCertificateKey,
      "downloaded setline manifest has unknown resource: " ~ name);
    enforce(value.type == JSONType.string,
      "downloaded setline manifest resource must be a string: " ~ name);
    auto hash = toLowerAscii(value.str.strip);
    enforce(isSha256(hash),
      "downloaded setline manifest resource is not a SHA-256: " ~ name);
    manifest.resources[name] = hash;
  }
  foreach (name; [manifestResourceProxy, manifestResourceCertificate,
      manifestResourceCertificateKey]) {
    enforce(name in manifest.resources, "downloaded setline manifest is missing " ~ name);
  }
  return manifest;
}

/// 资源对应的响应 Body SHA-256（小写十六进制）。
string sha256Hex(string text) {
  return toHexString!(LetterCase.lower)(sha256Of(text)).idup;
}

/// 远程同步状态固定放在片段根目录；不另加配置项。
string remoteStatePath(string outputRoot) {
  auto root = outputRoot.length > 0 ? outputRoot : defaultFragmentRoot;
  return buildPath(root, "remote.manifest.json");
}

/// 远程同步的暂存目录。agent 用户在这里落盘，root 校验后安装到最终位置。
string remoteStagePath(string outputRoot) {
  auto root = outputRoot.length > 0 ? outputRoot : defaultFragmentRoot;
  return buildPath(root, remoteStageName);
}

/// 清掉上一轮未安装或失败的暂存内容。
void clearRemoteStage(string outputRoot) {
  auto path = remoteStagePath(outputRoot);
  if (exists(path))
    rmdirRecurse(path);
}

/// 读取上次成功应用的远程清单；文件不存在或损坏都当作首次同步。
RemoteManifest readRemoteManifest(string path) {
  if (!exists(path))
    return RemoteManifest.init;
  try {
    return parseRemoteManifest(readText(path));
  } catch (Exception) {
    return RemoteManifest.init;
  }
}

/// 以稳定顺序写回清单状态。
bool writeRemoteManifest(string path, const RemoteManifest manifest) {
  auto out_ = appender!string;
  out_.put("{\n  \"version\": ");
  out_.put(manifest.schemaVersion.to!string);
  out_.put(",\n  \"resources\": {\n");
  auto names = manifest.resources.keys;
  names.sort;
  foreach (i, name; names) {
    out_.put("    \"");
    out_.put(name);
    out_.put("\": \"");
    out_.put(manifest.resources[name]);
    out_.put(i + 1 < names.length ? "\",\n" : "\"\n");
  }
  out_.put("  }\n}\n");
  return writeDownloaded(path, out_.data);
}

/// root 安装 staging 时使用的最终路径。
struct RemoteInstallTargets {
  string controlPath;
  string proxyPath;
  string certificateDir;
  string statePath;
}

/** 安装 `setline-agent pull --check --stage` 写出的文件。

    网络响应已经由非特权进程下载并写入 staging；这里只读本地 staging，按清单再次
    校验哈希后安装。缺少清单表示本轮无变化，清理残留 staging 后返回 false。
*/
bool installRemoteStage(string stageDir, RemoteInstallTargets targets) {
  auto manifestPath = buildPath(stageDir, stagedManifestName);
  if (!exists(manifestPath)) {
    if (exists(stageDir))
      rmdirRecurse(stageDir);
    return false;
  }

  auto manifest = parseRemoteManifest(readText(manifestPath));
  auto stagedProxyPath = buildPath(stageDir, stagedProxyName);
  auto stagedCertPath = buildPath(stageDir, stagedCertificateName);
  auto stagedKeyPath = buildPath(stageDir, stagedCertificateKeyName);
  auto stagedEmptyPath = buildPath(stageDir, stagedCertificateEmptyName);

  auto proxyChanged = exists(stagedProxyPath);
  string proxy;
  if (proxyChanged) {
    verifyStagedHash(stagedProxyPath, manifest, manifestResourceProxy);
    proxy = readText(stagedProxyPath);
  }

  auto certificateChanged = exists(stagedCertPath) || exists(stagedKeyPath)
      || exists(stagedEmptyPath);
  enforce(exists(stagedCertPath) == exists(stagedKeyPath),
    "staged certificate and certificate-key must be installed together");
  auto certificateEmpty = manifest.resources.get(manifestResourceCertificate, "") == sha256Hex("")
      && manifest.resources.get(manifestResourceCertificateKey, "") == sha256Hex("");
  if (certificateChanged && certificateEmpty) {
    enforce(!exists(stagedCertPath) && !exists(stagedKeyPath),
      "empty certificate resource must not have staged PEM files");
  } else if (certificateChanged) {
    verifyStagedHash(stagedCertPath, manifest, manifestResourceCertificate);
    verifyStagedHash(stagedKeyPath, manifest, manifestResourceCertificateKey);
  }

  if (proxyChanged)
    writeDownloaded(targets.proxyPath, proxy);
  if (certificateChanged)
    writeCertificatePair(targets.certificateDir,
      certificateEmpty ? "" : readText(stagedCertPath),
      certificateEmpty ? "" : readText(stagedKeyPath));
  writeRemoteManifest(targets.statePath, manifest);
  rmdirRecurse(stageDir);
  return true;
}

private void verifyStagedHash(string path, const RemoteManifest manifest, string resource) {
  auto expected = manifest.resources.get(resource, "");
  auto actual = sha256Hex(readText(path));
  enforce(actual == expected,
    "staged " ~ resource ~ " hash mismatch: expected " ~ expected ~ ", got " ~ actual);
}

/// 某一资源相对上次清单是否变化。缺失状态会让所有资源都视为变化。
bool resourceChanged(const RemoteManifest previous, const RemoteManifest current, string name) {
  auto before = previous.resources.get(name, "");
  auto after = current.resources.get(name, "");
  return before != after;
}

private bool isSha256(string text) {
  if (text.length != 64)
    return false;
  foreach (ch; text) {
    if (!((ch >= '0' && ch <= '9') || (ch >= 'a' && ch <= 'f')))
      return false;
  }
  return true;
}

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
  inheritMetadata(path, tmpPath);
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
  inheritOwner(path, tmpPath);
  setAttributes(tmpPath, mode);
  rename(tmpPath, path);
  return true;
}

/** rename 会带上临时文件的属主/权限，替换前把已有目标文件的元数据继承过来。

    `setline.conf` 安装前是 `root:beangle 0640`；如果直接 rename root 的临时文件，
    会变成 `root:root 0664`，既可能泄露 token，也会让 setline 用户读不到配置。
*/
private void inheritMetadata(string target, string replacement) {
  inheritOwner(target, replacement);
  stat_t info;
  if (stat(target.toStringz, &info) == 0)
    setAttributes(replacement, cast(uint)(info.st_mode & octal!7777));
}

/// 非 root 进程只在 root 安装阶段替换系统文件；普通用户写自己的文件不需要 chown。
private void inheritOwner(string target, string replacement) {
  if (geteuid() != 0)
    return;
  stat_t info;
  if (stat(target.toStringz, &info) != 0)
    return;
  if (info.st_uid == geteuid() && info.st_gid == getegid())
    return;
  enforce(chown(replacement.toStringz, info.st_uid, info.st_gid) == 0,
    "cannot preserve owner for " ~ replacement);
}
