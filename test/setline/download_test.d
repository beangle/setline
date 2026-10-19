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

module setline.download_test;

import std.algorithm : canFind;
import std.conv : octal;
import std.exception : assertThrown;
import std.file : exists, getAttributes, readText, remove, rmdirRecurse, write;

import setline.download;
import setline.model : PeerConfig;

@("download builds bashub machine endpoints") unittest {
  assert(downloadUrl("http://127.0.0.1:8082/", "openurp.prod", DownloadKind.peers) ==
    "http://127.0.0.1:8082/api/openurp.prod/config/setline-peers");
  assert(downloadUrl("https://hub.example.com", "openurp.prod", DownloadKind.proxy) ==
    "https://hub.example.com/api/openurp.prod/config/proxy");
  assert(downloadUrl("https://hub.example.com", "openurp.prod", DownloadKind.certificate) ==
    "https://hub.example.com/api/openurp.prod/config/certificate");
  assert(downloadUrl("https://hub.example.com", "openurp.prod", DownloadKind.certificateKey) ==
    "https://hub.example.com/api/openurp.prod/config/certificate-key");
  assertThrown!Exception(downloadUrl("127.0.0.1:8082", "openurp.prod", DownloadKind.peers));
  assertThrown!Exception(downloadUrl("http://127.0.0.1:8082", "../bad", DownloadKind.peers));
}

@("download binds the profile into the bearer token") unittest {
  assert(bearerToken("openurp.prod", "secret") == "openurp.prod:secret");
  assert(bearerToken("openurp.prod", "openurp.prod:secret") == "openurp.prod:secret");
  assertThrown!Exception(bearerToken("openurp.prod", "other:secret"));
  assertThrown!Exception(bearerToken("openurp.prod", ""));
}

@("download passes the URL and authorization header to the fetcher") unittest {
  string requestedUrl;
  string[] requestedHeaders;
  auto text = downloadConfig("http://127.0.0.1:8082", "openurp.prod", "secret",
      DownloadKind.proxy, delegate string(string url, string[] headers) {
    requestedUrl = url;
    requestedHeaders = headers;
    return "global\n";
  });

  assert(text == "global\n");
  assert(requestedUrl == "http://127.0.0.1:8082/api/openurp.prod/config/proxy");
  assert(requestedHeaders == ["Authorization: Bearer openurp.prod:secret"]);
}

@("download validates the peers response before returning it") unittest {
  assertThrown!Exception(downloadConfig("http://127.0.0.1:8082", "openurp.prod", "secret",
      DownloadKind.peers, delegate string(string url, string[] headers) {
    return "not json";
  }));
}

@("download parses peers and rejects malformed peer entries") unittest {
  auto text = downloadConfig("http://127.0.0.1:8082", "openurp.prod", "secret",
      DownloadKind.peers, delegate string(string url, string[] headers) {
    return `{"peers":[{"name":"host01","url":"http://10.0.0.11:8080"}]}`;
  });
  assert(text.canFind("host01"));
  auto peers = parseDownloadedPeers(text);
  assert(peers.length == 1);
  assert(peers[0].name == "host01");
  assert(peers[0].url == "http://10.0.0.11:8080");

  assertThrown!Exception(downloadConfig("http://127.0.0.1:8082", "openurp.prod", "secret",
      DownloadKind.peers, delegate string(string url, string[] headers) {
    return `{"agent":{"peers":[]}}`;
  }));
  assertThrown!Exception(downloadConfig("http://127.0.0.1:8082", "openurp.prod", "secret",
      DownloadKind.peers, delegate string(string url, string[] headers) {
    return `{"peers":[{"name":"host01","url":"file:///tmp/routes"}]}`;
  }));
  assertThrown!Exception(downloadConfig("http://127.0.0.1:8082", "openurp.prod", "secret",
      DownloadKind.peers, delegate string(string url, string[] headers) {
    return `{"peers":[{"name":"host01","url":"http://10.0.0.11:8080","port":80}]}`;
  }));
}

@("rewrite agent peers preserves the rest of setline.conf") unittest {
  auto original =
    "[remote]\nurl = https://hub.example.com\nprofile = openurp.prod\ntoken = secret\n" ~
    "\n[agent]\ntype = haproxy\noutput = /var/lib/setline\n" ~
    "peers = old=http://old:8080\n" ~
    "\n[apply]\nquietSeconds = 15\n";
  auto peers = [PeerConfig("host01", "http://10.0.0.11:8080"),
    PeerConfig("cdn01", "http://10.0.0.31:8081")];
  auto updated = rewriteAgentPeers(original, peers);
  assert(updated.canFind("[remote]\nurl = https://hub.example.com\n"));
  assert(updated.canFind("token = secret\n"));
  assert(updated.canFind("type = haproxy\noutput = /var/lib/setline\n"));
  assert(updated.canFind("peers = host01=http://10.0.0.11:8080, cdn01=http://10.0.0.31:8081\n"));
  assert(!updated.canFind("http://old:8080"));
  assert(updated.canFind("[apply]\nquietSeconds = 15\n"));
  assert(rewriteAgentPeers(updated, peers) == updated);

  auto inserted = rewriteAgentPeers(
    "[remote]\nurl = https://hub.example.com\n[agent]\ntype = nginx\n", peers);
  assert(inserted.canFind("type = nginx\npeers = host01=http://10.0.0.11:8080"));

  auto appended = rewriteAgentPeers("[remote]\nurl = https://hub.example.com\n", peers);
  assert(appended.canFind("\n[agent]\npeers = host01=http://10.0.0.11:8080"));

  auto cleared = rewriteAgentPeers(original, []);
  assert(cleared.canFind("peers = \n"));
  assert(!cleared.canFind("http://old:8080"));
}

@("download writes atomically and leaves unchanged files untouched") unittest {
  auto path = "/tmp/setline-download-test/setline.json";
  scope (exit) {
    if (exists(path)) remove(path);
    if (exists(path ~ ".tmp")) remove(path ~ ".tmp");
  }

  assert(writeDownloaded(path, "[agent]\npeers =\n"));
  assert(readText(path) == "[agent]\npeers =\n");
  assert(!writeDownloaded(path, "[agent]\npeers =\n"));
  assert(writeDownloaded(path, "[agent]\npeers = app1=http://10.0.0.11:8080\n"));
  assert(readText(path) == "[agent]\npeers = app1=http://10.0.0.11:8080\n");
}

@("certificate pair writes nginx files and the haproxy bundle") unittest {
  auto dir = "/tmp/setline-certificate-test";
  scope (exit) {
    if (exists(dir)) rmdirRecurse(dir);
  }
  if (exists(dir)) rmdirRecurse(dir);

  auto cert = "-----BEGIN CERTIFICATE-----\nCERT\n-----END CERTIFICATE-----";
  auto key = "-----BEGIN PRIVATE KEY-----\nKEY\n-----END PRIVATE KEY-----";
  assert(writeCertificatePair(dir, cert, key));
  assert(readText(certificatePath(dir, "cert.pem")) == cert ~ "\n");
  assert(readText(certificatePath(dir, "key.pem")) == key ~ "\n");
  assert(readText(certificatePath(dir, "bundle.pem")) == cert ~ "\n" ~ key ~ "\n");
  assert((getAttributes(certificatePath(dir, "cert.pem")) & octal!777) == octal!644);
  assert((getAttributes(certificatePath(dir, "key.pem")) & octal!777) == octal!600);
  assert((getAttributes(certificatePath(dir, "bundle.pem")) & octal!777) == octal!600);
  assert(!writeCertificatePair(dir, cert, key));
  assert(writeCertificatePair(dir, "", ""));
  assert(!exists(certificatePath(dir, "cert.pem")));
  assert(!exists(certificatePath(dir, "key.pem")));
  assert(!exists(certificatePath(dir, "bundle.pem")));
  assert(!writeCertificatePair(dir, "", ""));
}

@("certificate pair rejects half a pair and malformed PEM") unittest {
  auto dir = "/tmp/setline-certificate-invalid-test";
  scope (exit) {
    if (exists(dir)) rmdirRecurse(dir);
  }
  if (exists(dir)) rmdirRecurse(dir);

  assertThrown!Exception(writeCertificatePair(dir,
    "-----BEGIN CERTIFICATE-----\nCERT\n-----END CERTIFICATE-----\n", ""));
  assertThrown!Exception(writeCertificatePair(dir, "not a certificate",
    "-----BEGIN PRIVATE KEY-----\nKEY\n-----END PRIVATE KEY-----\n"));
  assertThrown!Exception(writeCertificatePair(dir,
    "-----BEGIN CERTIFICATE-----\nCERT\n-----END CERTIFICATE-----\n", "not a key"));
}
