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

module setline.edge;

import std.algorithm : canFind;
import std.array : appender;
import std.ascii : isAlphaNum;
import std.conv : to;
import std.digest : toHexString;
import std.digest.sha : sha256Of;
import std.exception : enforce;
import std.file : copy, exists, mkdirRecurse, read, readText, rename, rmdirRecurse;
import std.json;
import std.path : baseName, buildPath, dirName;
import std.process : execute;
import std.string : lastIndexOf, replace, startsWith, toLower;

import setline.config : normalizeRouteHost, normalizeRoutePrefix, parsePort;
import setline.model : AgentConfig;

/** 一个可被边缘代理访问的后端实例。 */
struct BackendInstance {
  string host;
  ushort port;
}

/** 一组共享路由规则的服务后端。 */
struct BackendService {
  string name;
  string host = "*";
  string contentPath;
  string healthPath = "/";
  BackendInstance[] instances;
}

/** 远端代理配置清单。 */
struct AgentManifest {
  string versionId;
  string bundleUrl;
  string sha256;
}

/** 获取 agent bundle 并返回其中的 backends.json 文本。 */
string loadBackendsJson(AgentConfig config) {
  enforce(config.url.length > 0, "agent.remote must not be empty");
  auto manifest = parseAgentManifest(fetchText(config.url));
  auto releaseDir = installBundle(config.url, manifest, config.workDir);
  return readText(buildPath(releaseDir, "backends.json"));
}

/** 从 URL 或本地文件读取文本，可选附加 HTTP 请求头（例如 `X-Setline-Token`）。 */
string fetchText(string url, string[] headers = []) {
  enforce(url.length > 0, "url must not be empty");
  if (url.startsWith("file://")) {
    return readText(url["file://".length .. $]);
  }
  if (!url.canFind("://")) {
    return readText(url);
  }

  string[] args = ["curl", "-fsSL"];
  foreach (header; headers) {
    args ~= "-H";
    args ~= header;
  }
  args ~= url;
  auto result = execute(args);
  enforce(result.status == 0, "curl failed for " ~ url ~ ": " ~ result.output);
  return result.output;
}

/** 解析 agent manifest。 */
AgentManifest parseAgentManifest(string text) {
  auto root = parseJSON(text);
  enforce(root.type == JSONType.object, "agent manifest must be object");
  AgentManifest manifest;
  manifest.versionId = requiredString(root, "version");
  manifest.bundleUrl = requiredString(root, "bundleUrl");
  manifest.sha256 = optionalString(root, "sha256", "");
  enforce(manifest.versionId.length > 0, "agent manifest version must not be empty");
  enforce(manifest.bundleUrl.length > 0, "agent manifest bundleUrl must not be empty");
  return manifest;
}

/** 下载并解包 agent bundle。 */
string installBundle(string manifestUrl, AgentManifest manifest, string workDir) {
  auto releaseDir = buildPath(workDir, "releases", safePathName(manifest.versionId));
  if (exists(buildPath(releaseDir, "backends.json"))) {
    return releaseDir;
  }

  mkdirRecurse(buildPath(workDir, "downloads"));
  mkdirRecurse(buildPath(workDir, "releases"));
  auto bundleUrl = resolveUrl(manifestUrl, manifest.bundleUrl);
  auto bundlePath = buildPath(workDir, "downloads", safePathName(manifest.versionId) ~ ".tar.gz");
  downloadFile(bundleUrl, bundlePath);
  if (manifest.sha256.length > 0) {
    enforce(fileSha256(bundlePath) == manifest.sha256.toLower, "agent bundle sha256 mismatch");
  }

  auto tmpDir = releaseDir ~ ".tmp";
  if (exists(tmpDir)) rmdirRecurse(tmpDir);
  mkdirRecurse(tmpDir);
  auto result = execute(["tar", "-xzf", bundlePath, "-C", tmpDir]);
  enforce(result.status == 0, "tar failed for " ~ bundlePath ~ ": " ~ result.output);
  enforce(exists(buildPath(tmpDir, "backends.json")), "agent bundle must contain backends.json");
  if (exists(releaseDir)) rmdirRecurse(releaseDir);
  rename(tmpDir, releaseDir);
  return releaseDir;
}

/** 下载 URL 到文件。 */
void downloadFile(string url, string path) {
  if (url.startsWith("file://")) {
    copy(url["file://".length .. $], path);
    return;
  }
  if (!url.canFind("://")) {
    copy(url, path);
    return;
  }

  auto result = execute(["curl", "-fsSL", "-o", path, url]);
  enforce(result.status == 0, "curl failed for " ~ url ~ ": " ~ result.output);
}

/** 计算文件 SHA-256。 */
string fileSha256(string path) {
  return toHexString(sha256Of(cast(ubyte[]) read(path))).toLower;
}

/** 解析 manifest 中的相对 bundle URL。 */
string resolveUrl(string manifestUrl, string bundleUrl) {
  if (bundleUrl.canFind("://") || bundleUrl.startsWith("/")) return bundleUrl;
  auto slash = manifestUrl.lastIndexOf("/");
  if (slash >= 0) return manifestUrl[0 .. slash + 1] ~ bundleUrl;
  return buildPath(dirName(manifestUrl), bundleUrl);
}

/** 解析 backends.json。 */
BackendService[] parseBackends(string text) {
  auto root = parseJSON(text);
  JSONValue[] items;
  if (root.type == JSONType.array) {
    items = root.array;
  } else {
    enforce(root.type == JSONType.object, "backends root must be object or array");
    if ("services" in root.object) {
      items = root["services"].array;
    } else {
      enforce("backends" in root.object, "backends root must contain services or backends");
      items = root["backends"].array;
    }
  }

  BackendService[] services;
  foreach (item; items) {
    services ~= parseBackendService(item);
  }
  enforce(services.length > 0, "backends list must not be empty");
  return services;
}

/** 按类型渲染边缘代理配置片段。 */
string renderProxyConfig(BackendService[] services, string kind, string bind = "*:80") {
  if (kind == "haproxy") return renderHaproxy(services, bind);
  if (kind == "nginx") return renderNginx(services, bind);
  throw new Exception("render kind must be haproxy or nginx");
}

/** 生成 HAProxy 配置片段。

    HAProxy 没有 `include` 指令，片段只包含 `frontend` / `backend` 段，`global` 和
    `defaults` 仍由主配置持有；部署时把片段拼接进主配置（或由主配置的生成流程合并），
    不改动主配置里的其他自定义内容。
*/
string renderHaproxy(BackendService[] services, string bind = "*:80") {
  auto outp = appender!string();
  outp.put("# Generated by setline. Do not edit by hand.\n");
  outp.put("# Fragment: concatenate into the HAProxy master config;\n");
  outp.put("# HAProxy has no include directive. The master owns global/defaults.\n");
  outp.put("frontend http_in\n");
  // 显式声明 http：片段可能被单独 -f 加载，一旦主配置没有 defaults，
  // 依赖 mode 的 http 指令（path_beg、hdr 等）会被静默忽略并退回 tcp 模式。
  outp.put("  mode http\n");
  outp.put("  bind ");
  outp.put(bind);
  outp.put("\n");
  foreach (service; services) {
    auto id = proxyId(service.name);
    outp.put("  acl path_");
    outp.put(id);
    outp.put(" path_beg ");
    outp.put(service.contentPath);
    outp.put("\n");
    if (service.host != "*") {
      outp.put("  acl host_");
      outp.put(id);
      outp.put(" hdr(host) -i ");
      outp.put(service.host);
      outp.put("\n");
      outp.put("  use_backend be_");
      outp.put(id);
      outp.put(" if host_");
      outp.put(id);
      outp.put(" path_");
      outp.put(id);
      outp.put("\n");
    } else {
      outp.put("  use_backend be_");
      outp.put(id);
      outp.put(" if path_");
      outp.put(id);
      outp.put("\n");
    }
  }

  foreach (service; services) {
    auto id = proxyId(service.name);
    outp.put("\nbackend be_");
    outp.put(id);
    outp.put("\n");
    outp.put("  mode http\n");
    if (service.healthPath.length > 0) {
      outp.put("  option httpchk GET ");
      outp.put(service.healthPath);
      outp.put("\n");
    }
    foreach (i, instance; service.instances) {
      outp.put("  server ");
      outp.put(id);
      outp.put("_");
      outp.put(i.to!string);
      outp.put(" ");
      outp.put(instance.host);
      outp.put(":");
      outp.put(instance.port.to!string);
      outp.put(" check\n");
    }
  }
  return outp.data;
}

/** 生成 Nginx 配置片段。

    片段是 `upstream` 加 `server` 段，主配置在 `http {}` 里 `include` 它即可，
    既不改动主配置，也保留主配置里的其他 `server` / 自定义内容。
*/
string renderNginx(BackendService[] services, string bind = "*:80") {
  auto outp = appender!string();
  outp.put("# Generated by setline. Do not edit by hand.\n");
  outp.put("# Include this file inside the nginx http {} block.\n");
  foreach (service; services) {
    auto id = proxyId(service.name);
    outp.put("upstream ");
    outp.put(id);
    outp.put(" {\n");
    foreach (instance; service.instances) {
      outp.put("  server ");
      outp.put(instance.host);
      outp.put(":");
      outp.put(instance.port.to!string);
      outp.put(";\n");
    }
    outp.put("}\n\n");
  }

  string[] hosts;
  foreach (service; services) {
    if (!hosts.canFind(service.host)) {
      hosts ~= service.host;
    }
  }

  foreach (host; hosts) {
    outp.put("server {\n");
    outp.put("  listen ");
    outp.put(nginxListenPort(bind));
    outp.put(";\n");
    outp.put("  server_name ");
    outp.put(host == "*" ? "_" : host);
    outp.put(";\n");
    foreach (service; services) {
      if (service.host != host) continue;
      outp.put("  location ");
      outp.put(service.contentPath);
      outp.put(" {\n");
      outp.put("    proxy_set_header Host $host;\n");
      outp.put("    proxy_set_header X-Real-IP $remote_addr;\n");
      outp.put("    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;\n");
      outp.put("    proxy_pass http://");
      outp.put(proxyId(service.name));
      outp.put(";\n");
      outp.put("  }\n");
    }
    outp.put("}\n\n");
  }
  return outp.data;
}

/** 解析单个服务后端。 */
BackendService parseBackendService(JSONValue value) {
  enforce(value.type == JSONType.object, "backend service must be object");
  BackendService service;
  service.name = requiredString(value, "name");
  service.host = optionalString(value, "host", "*");
  service.host = service.host == "*" ? "*" : normalizeRouteHost(service.host);
  auto contentPath = optionalString(value, "contentPath", optionalString(value, "content_path", ""));
  enforce(contentPath.length > 0, "backend service contentPath is required");
  service.contentPath = normalizeRoutePrefix(contentPath);
  service.healthPath = normalizeRoutePrefix(optionalString(value, "healthPath",
    optionalString(value, "health_path", "/")));
  service.instances = parseBackendInstances(value);
  enforce(service.name.length > 0, "backend service name must not be empty");
  enforce(service.instances.length > 0, "backend service instances must not be empty");
  return service;
}

/** 解析服务实例列表。 */
BackendInstance[] parseBackendInstances(JSONValue service) {
  enforce("instances" in service.object, "backend service instances are required");
  enforce(service["instances"].type == JSONType.array, "backend service instances must be array");
  BackendInstance[] instances;
  foreach (item; service["instances"].array) {
    enforce(item.type == JSONType.object, "backend instance must be object");
    BackendInstance instance;
    instance.host = optionalString(item, "host", optionalString(item, "ip", ""));
    enforce(instance.host.length > 0, "backend instance host is required");
    enforce("port" in item.object, "backend instance port is required");
    enforce(item["port"].type == JSONType.integer, "backend instance port must be integer");
    instance.port = parsePort(item["port"].integer, "backend instance port");
    instances ~= instance;
  }
  return instances;
}

/** 返回必填字符串字段。 */
string requiredString(JSONValue value, string key) {
  enforce(key in value.object, key ~ " is required");
  enforce(value[key].type == JSONType.string, key ~ " must be string");
  return value[key].str;
}

/** 返回可选字符串字段。 */
string optionalString(JSONValue value, string key, string fallback) {
  if (!(key in value.object)) return fallback;
  enforce(value[key].type == JSONType.string, key ~ " must be string");
  return value[key].str;
}

/** 从 bind 串中取出 nginx `listen` 需要的端口部分（`*:80` -> `80`）。 */
string nginxListenPort(string bind) {
  auto colon = bind.lastIndexOf(":");
  return colon < 0 ? bind : bind[colon + 1 .. $];
}

/** 将服务名转换为代理配置中的安全标识。 */
string proxyId(string value) {
  auto outp = appender!string();
  foreach (ch; value) {
    if (ch.isAlphaNum) {
      outp.put(ch);
    } else {
      outp.put("_");
    }
  }
  auto id = outp.data.replace("__", "_");
  enforce(id.length > 0, "proxy id must not be empty");
  return id;
}

/** 将版本号转换为安全目录名。 */
string safePathName(string value) {
  auto outp = appender!string();
  foreach (ch; value) {
    if (ch.isAlphaNum || ch == '.' || ch == '-' || ch == '_') {
      outp.put(ch);
    } else {
      outp.put("_");
    }
  }
  auto safe = outp.data;
  enforce(safe.length > 0 && safe != "." && safe != ".." && safe.baseName == safe, "invalid path name");
  return safe;
}
