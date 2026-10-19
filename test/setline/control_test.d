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

module setline.control_test;

import std.exception : assertThrown;
import std.file : exists, readText, remove;

import setline.control;

@("control parses remote, topology, agent and apply") unittest {
  auto config = parseControlConfig(
    "# full local control plane\n" ~
    "[remote]\n" ~
    "url = https://hub.example.com/base\n" ~
    "profile = \"openurp.prod\"\n" ~
    "token = secret\n" ~
    "\n" ~
    "[topology]\n" ~
    "file = /srv/setline/topology.json\n" ~
    "\n" ~
    "[proxy]\n" ~
    "file = /etc/haproxy/haproxy.cfg\n" ~
    "\n" ~
    "[agent]\n" ~
    "type = HAPROXY\n" ~
    "output = /srv/setline/fragments\n" ~
    "peers = app1=http://10.0.1.10:8080, app2=http://10.0.1.11:8080\n" ~
    "\n" ~
    "[apply]\n" ~
    "configs = /etc/haproxy/haproxy.cfg /etc/haproxy/conf.d /srv/setline/fragments\n" ~
    "fragmentDir = /srv/setline/fragments/haproxy\n" ~
    "service = haproxy.service\n" ~
    "quietSeconds = 3\n" ~
    "runtimeDir = /run/setline\n" ~
    "owner = setline:beangle\n");

  assert(config.remote.url == "https://hub.example.com/base");
  assert(config.remote.profile == "openurp.prod");
  assert(config.remote.token == "secret");
  assert(config.topologyPath == "/srv/setline/topology.json");
  assert(config.proxyPath == "/etc/haproxy/haproxy.cfg");
  assert(config.agent.type == "haproxy");
  assert(config.agent.output == "/srv/setline/fragments");
  assert(config.agent.peers.length == 2);
  assert(config.agent.peers[0].name == "app1");
  assert(config.agent.peers[0].url == "http://10.0.1.10:8080");
  assert(config.agent.peers[1].name == "app2");
  assert(config.apply.type == "haproxy");
  assert(config.apply.configs ==
    "/etc/haproxy/haproxy.cfg /etc/haproxy/conf.d /srv/setline/fragments");
  assert(config.apply.fragmentDir == "/srv/setline/fragments/haproxy");
  assert(config.apply.service == "haproxy.service");
  assert(config.apply.quietSeconds == 3);
  assert(config.apply.runtimeDir == "/run/setline");
  assert(config.apply.owner == "setline:beangle");
}

@("control parses and renders agent peers") unittest {
  auto config = parseControlConfig("[agent]\npeers = app1=http://10.0.1.10:8080,app2=http://10.0.1.11:8080\n");
  assert(config.agent.peers.length == 2);
  assert(renderAgentPeers(config.agent.peers) ==
    "app1=http://10.0.1.10:8080, app2=http://10.0.1.11:8080");

  auto empty = parseControlConfig("[agent]\npeers =\n");
  assert(empty.agent.peers.length == 0);
  assert(renderAgentPeers(empty.agent.peers).length == 0);
}

@("control derives proxy defaults from the agent type") unittest {
  auto haproxy = parseControlConfig("[agent]\ntype = haproxy\n");
  assert(haproxy.proxyPath == "/etc/haproxy/haproxy.cfg");
  assert(haproxy.agent.output == "/var/lib/setline");
  assert(haproxy.apply.type == "haproxy");
  assert(haproxy.apply.fragmentDir == "/var/lib/setline/haproxy");
  assert(haproxy.apply.service == "haproxy");

  auto nginx = parseControlConfig("[agent]\ntype = nginx\n");
  assert(nginx.proxyPath == "/etc/nginx/nginx.conf");
  assert(nginx.apply.type == "nginx");
  assert(nginx.apply.configs == "/etc/nginx/nginx.conf");
  assert(nginx.apply.fragmentDir == "/var/lib/setline/nginx");
  assert(nginx.apply.service == "nginx");

  auto custom = parseControlConfig(
    "[agent]\ntype = haproxy\noutput = /srv/setline/fragments\n");
  assert(custom.apply.configs == "/etc/haproxy/haproxy.cfg /etc/haproxy/conf.d " ~
    "/srv/setline/fragments/haproxy");
  assert(custom.apply.fragmentDir == "/srv/setline/fragments/haproxy");

  auto customNginx = parseControlConfig(
    "[agent]\ntype = nginx\noutput = /srv/setline/fragments\n");
  assert(customNginx.apply.fragmentDir == "/srv/setline/fragments/nginx");

  auto applyOnly = parseControlConfig("[apply]\ntype = nginx\n");
  assert(applyOnly.proxyPath == "/etc/nginx/nginx.conf");

  auto explicitPath = parseControlConfig(
    "[agent]\ntype = nginx\n[proxy]\nfile = /srv/nginx/nginx.conf\n");
  assert(explicitPath.proxyPath == "/srv/nginx/nginx.conf");

  auto noType = parseControlConfig("[topology]\nfile = /srv/topology.json\n");
  assert(noType.proxyPath.length == 0);
}

@("control renders apply settings as shell assignments") unittest {
  ControlConfig config;
  config.apply.type = "haproxy";
  config.apply.configs = "/etc/haproxy/haproxy.cfg /etc/haproxy/conf.d";
  config.apply.fragmentDir = "/var/lib/setline/haproxy";
  config.apply.service = "haproxy";
  config.apply.quietSeconds = 15;
  config.apply.runtimeDir = "/run";
  config.apply.owner = "setline:be'angle";

  auto shell = renderApplyShell(config);
  assert(shell ==
    "SETLINE_APPLY_TYPE='haproxy'\n" ~
    "SETLINE_APPLY_CONFIGS='/etc/haproxy/haproxy.cfg /etc/haproxy/conf.d'\n" ~
    "SETLINE_APPLY_FRAGMENT_DIR='/var/lib/setline/haproxy'\n" ~
    "SETLINE_APPLY_SERVICE='haproxy'\n" ~
    "SETLINE_APPLY_QUIET_SECONDS='15'\n" ~
    "SETLINE_APPLY_STATE_DIR='/var/lib/setline/apply'\n" ~
    "SETLINE_APPLY_RUNTIME_DIR='/run'\n" ~
    "SETLINE_APPLY_FRAGMENT_OWNER='setline:be'\\''angle'\n");
}

@("control rejects malformed or unsafe values") unittest {
  assertThrown!Exception(parseControlConfig("[agent]\ntype = apache\n"));
  assertThrown!Exception(parseControlConfig("[agent]\noutput = relative/path\n"));
  assertThrown!Exception(parseControlConfig("[topology]\nfile = relative.json\n"));
  assertThrown!Exception(parseControlConfig("[apply]\nquietSeconds = -1\n"));
  assertThrown!Exception(parseControlConfig("[apply]\nconfigs = /etc/haproxy bad\n"));
  assertThrown!Exception(parseControlConfig("[remote]\nurl = hub.example.com\n"));
  assertThrown!Exception(parseControlConfig("[remote]\nprofile = ../bad\n"));
  assertThrown!Exception(parseControlConfig("[agent\n"));
  assertThrown!Exception(parseControlConfig("type = haproxy\n"));
  assertThrown!Exception(parseControlConfig("[agent]\npeers = app1\n"));
  assertThrown!Exception(parseControlConfig("[agent]\npeers = app1=file:///tmp/routes\n"));
  assertThrown!Exception(parseControlConfig(
    "[agent]\npeers = app1=http://10.0.1.10:8080, http://10.0.1.11:8080\n"));
}

@("control requires a complete remote block before downloads") unittest {
  assertThrown!Exception(validateRemoteConfig(RemoteConfig.init, "setline.conf"));
  assertThrown!Exception(validateRemoteConfig(RemoteConfig("https://hub", "", "secret"),
    "setline.conf"));
  assertThrown!Exception(validateRemoteConfig(RemoteConfig("https://hub", "openurp.prod", ""),
    "setline.conf"));
  validateRemoteConfig(RemoteConfig("https://hub", "openurp.prod", "secret"), "setline.conf");
}

@("control init writes once and never replaces an existing file") unittest {
  auto path = "/tmp/setline-control-init-test.conf";
  scope (exit) {
    if (exists(path)) remove(path);
  }
  if (exists(path)) remove(path);

  assert(writeControlConfigTemplate(path));
  auto first = readText(path);
  assert(first == controlConfigTemplate);
  assert(!writeControlConfigTemplate(path));
  assert(readText(path) == first);
}
