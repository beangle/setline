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

module setline.control;

import std.algorithm : startsWith;
import std.array : Appender, appender, split;
import std.conv : to;
import std.exception : enforce;
import std.file : exists, mkdirRecurse, readText, write;
import std.json : JSONValue, parseJSON;
import std.path : dirName;
import std.string : indexOf, splitLines, strip;

import setline.config : parseHostRoutes;
import setline.util : toLowerAscii;
import setline.model : AgentConfig;

/** 本机控制面配置的缺省位置。 */
enum defaultControlPath = "/etc/setline/setline.conf";

/** 本机片段根目录。 */
enum defaultFragmentRoot = "/var/lib/setline";

/** setline-agent pull 下载证书的固定目录；bashub 生成的 nginx/haproxy 配置也引用这里。 */
enum defaultCertificateDir = "/etc/setline/certs";

/** setline-agent pull 下载代理主配置的缺省落点。 */
enum defaultHaproxyConfig = "/etc/haproxy/haproxy.cfg";
enum defaultNginxConfig = "/etc/nginx/nginx.conf";

/** bashub 的远程连接信息，和 basctl 的 `[remote]` 保持同一形状。 */
struct RemoteConfig {
  string url;
  string project;
  /** 本机内网 IP，用于向 bashub 查询该机器的 routes；空时由 bashub 按单实例选择。 */
  string ip;
  string token;

  bool complete() const {
    return url.length > 0 && project.length > 0 && token.length > 0;
  }
}

/** setline-apply 的 reload 参数。 */
struct ApplyControl {
  string type;
  string configs;
  string fragmentDir;
  string service;
  string runtimeDir = "/run";
  string owner = "setline:beangle";
}

/** `setline.conf` 的完整内容。 */
struct ControlConfig {
  RemoteConfig remote;
  string proxyPath;
  AgentConfig agent;
  ApplyControl apply;
}

/** 读取控制面配置；文件不存在时返回空配置，由调用方决定是否报错。 */
ControlConfig loadControlConfig(string path) {
  if (!exists(path))
    return ControlConfig.init;
  return parseControlConfig(readText(path));
}

/** 检查模式要求文件必须存在。 */
ControlConfig checkControlConfig(string path) {
  enforce(exists(path), "control config not found: " ~ path);
  return parseControlConfig(readText(path));
}

/** 解析 INI 文本。空行与整行 `#` / `;` 注释会被忽略。 */
ControlConfig parseControlConfig(string text) {
  ControlConfig result;
  string section;
  foreach (raw; text.splitLines()) {
    auto line = strip(raw);
    if (line.length == 0 || line[0] == '#' || line[0] == ';')
      continue;
    if (line[0] == '[') {
      auto close = line.indexOf(']');
      enforce(close > 0, "invalid section header: " ~ line);
      section = toLowerAscii(strip(line[1 .. close]));
      continue;
    }
    auto equals = line.indexOf('=');
    enforce(equals > 0, "invalid line (expected key = value): " ~ line);
    enforce(section.length > 0, "key outside any section: " ~ line);
    auto key = toLowerAscii(strip(line[0 .. equals]));
    auto value = unquote(line[equals + 1 .. $]);
    if (section == "remote") {
      if (key == "url") result.remote.url = value;
      else if (key == "project") result.remote.project = value;
      else if (key == "ip") result.remote.ip = value.strip;
      else if (key == "token") result.remote.token = value;
    } else if (section == "proxy") {
      if (key == "file") result.proxyPath = value;
    } else if (section == "agent") {
      if (key == "type") result.agent.type = toLowerAscii(value);
      else if (key == "output") result.agent.output = value;
    } else if (section == "apply") {
      if (key == "type") result.apply.type = toLowerAscii(value);
      else if (key == "configs") result.apply.configs = value;
      else if (key == "fragmentdir") result.apply.fragmentDir = value;
      else if (key == "service") result.apply.service = value;
      else if (key == "runtimedir") result.apply.runtimeDir = value;
      else if (key == "owner") result.apply.owner = value;
    }
  }
  applyDefaults(result);
  validateControlConfig(result);
  return result;
}



/** 补齐可推导的默认值，让部署方只需要写真正不同的字段。 */
private void applyDefaults(ref ControlConfig config) {
  if (config.agent.output.length == 0 && config.agent.type.length > 0)
    config.agent.output = defaultFragmentRoot;
  if (config.apply.type.length == 0)
    config.apply.type = config.agent.type;
  if (config.proxyPath.length == 0) {
    if (config.apply.type == "haproxy")
      config.proxyPath = defaultHaproxyConfig;
    else if (config.apply.type == "nginx")
      config.proxyPath = defaultNginxConfig;
  }
  auto fragmentRoot = config.agent.output.length > 0
    ? config.agent.output : defaultFragmentRoot;
  if (config.apply.type == "haproxy") {
    if (config.apply.configs.length == 0)
      config.apply.configs = defaultHaproxyConfig ~ " /etc/haproxy/conf.d " ~
        fragmentRoot ~ "/haproxy";
    if (config.apply.fragmentDir.length == 0)
      config.apply.fragmentDir = fragmentRoot ~ "/haproxy";
    if (config.apply.service.length == 0)
      config.apply.service = "haproxy";
  } else if (config.apply.type == "nginx") {
    if (config.apply.configs.length == 0)
      config.apply.configs = defaultNginxConfig;
    if (config.apply.fragmentDir.length == 0)
      config.apply.fragmentDir = fragmentRoot ~ "/nginx";
    if (config.apply.service.length == 0)
      config.apply.service = "nginx";
  }
}

/** 校验字段形态。单独的 `setline` 启动不要求 `[remote]` 完整。 */
void validateControlConfig(const ControlConfig config) {
  if (config.remote.url.length > 0) {
    enforce(config.remote.url.startsWith("http://") || config.remote.url.startsWith("https://"),
      "remote.url must start with http:// or https://");
  }
  if (config.remote.project.length > 0)
    enforce(validProjectName(config.remote.project),
      "remote.project must be org.name and must not contain path separators");
  if (config.remote.ip.length > 0) {
    foreach (ch; config.remote.ip)
      enforce(ch > ' ' && ch != '/' && ch != ':', "remote.ip must be a plain IP address: " ~ config.remote.ip);
  }
  if (config.remote.token.length > 0)
    enforce(config.remote.token.indexOf('\n') < 0 && config.remote.token.indexOf('\r') < 0,
      "remote.token must not contain a line break");
  validateAgentType(config.agent.type, "agent.type");
  validateAgentType(config.apply.type, "apply.type");
  if (config.agent.output.length > 0)
    enforceAbsolute(config.agent.output, "agent.output");
  if (config.proxyPath.length > 0)
    enforceAbsolute(config.proxyPath, "proxy.file");
  if (config.apply.fragmentDir.length > 0)
    enforceAbsolute(config.apply.fragmentDir, "apply.fragmentDir");
  if (config.apply.runtimeDir.length > 0)
    enforceAbsolute(config.apply.runtimeDir, "apply.runtimeDir");
  foreach (path; config.apply.configs.split) {
    if (path.length > 0)
      enforceAbsolute(path, "apply.configs");
  }
}

/** 下载前要求 `[remote]` 三项齐全。 */
void validateRemoteConfig(const RemoteConfig remote, string path) {
  enforce(remote.url.length > 0, "No remote.url in " ~ path);
  enforce(remote.project.length > 0, "No remote.project in " ~ path);
  enforce(remote.token.length > 0, "No remote.token in " ~ path);
}

/** 把 `[apply]` 输出成可由 setline-apply `eval` 的 shell 赋值。 */
string renderApplyShell(const ControlConfig config) {
  auto out_ = appender!string();
  appendShellVar(out_, "SETLINE_APPLY_TYPE", config.apply.type);
  appendShellVar(out_, "SETLINE_APPLY_CONFIGS", config.apply.configs);
  appendShellVar(out_, "SETLINE_APPLY_FRAGMENT_DIR", config.apply.fragmentDir);
  appendShellVar(out_, "SETLINE_APPLY_SERVICE", config.apply.service);
  auto outputRoot = config.agent.output.length > 0 ? config.agent.output : defaultFragmentRoot;
  appendShellVar(out_, "SETLINE_APPLY_STATE_DIR", outputRoot ~ "/apply");
  appendShellVar(out_, "SETLINE_APPLY_RUNTIME_DIR", config.apply.runtimeDir);
  appendShellVar(out_, "SETLINE_APPLY_FRAGMENT_OWNER", config.apply.owner);
  return out_.data;
}

/** `setline-agent init` 写入的模板；不覆盖已有文件。 */
enum controlConfigTemplate =
  "# setline-agent control plane. setline.json belongs to the setline service.\n" ~
  "[remote]\n" ~
  "# Used by explicit `setline-agent pull` or one-shot `setline-agent-run`.\n" ~
  "url = http://127.0.0.1:8082\n" ~
  "project = org.name\n" ~
  "# local IP used to select this machine's routes (optional).\n" ~
  "#ip = 192.168.1.10\n" ~
  "token = change-me\n" ~
  "\n" ~
  "[proxy]\n" ~
  "# Optional. Defaults from [agent] type:\n" ~
  "#   haproxy -> /etc/haproxy/haproxy.cfg\n" ~
  "#   nginx   -> /etc/nginx/nginx.conf\n" ~
  "#file = /etc/haproxy/haproxy.cfg\n" ~
  "\n" ~
  "[agent]\n" ~
  "type = haproxy\n" ~
  "output = /var/lib/setline\n" ~
  "\n";

/** 写入模板；目标已存在时保留原文件并返回 false。 */
bool writeControlConfigTemplate(string path) {
  if (exists(path))
    return false;
  auto parent = dirName(path);
  if (parent.length > 0 && parent != "." && !exists(parent))
    mkdirRecurse(parent);
  write(path, controlConfigTemplate);
  return true;
}

private void validateAgentType(string type, string field) {
  if (type.length == 0)
    return;
  enforce(type == "haproxy" || type == "nginx", field ~ " must be haproxy or nginx");
}

private void enforceAbsolute(string path, string field) {
  enforce(path.length > 0 && path[0] == '/', field ~ " must be an absolute path: " ~ path);
}

private bool validProjectName(string profile) {
  auto dot = profile.indexOf('.');
  if (dot <= 0 || dot >= profile.length - 1)
    return false;
  foreach (ch; profile) {
    if (ch == '/' || ch == '\\' || ch == ' ' || ch == '\t')
      return false;
  }
  return true;
}

private string unquote(string value) {
  auto result = strip(value);
  if (result.length >= 2
      && ((result[0] == '"' && result[$ - 1] == '"')
        || (result[0] == '\'' && result[$ - 1] == '\'')))
    return result[1 .. $ - 1];
  return result;
}

private void appendShellVar(ref Appender!string out_, string name, string value) {
  out_.put(name);
  out_.put("='");
  foreach (ch; value) {
    if (ch == '\'')
      out_.put("'\\''");
    else
      out_.put(ch);
  }
  out_.put("'\n");
}
