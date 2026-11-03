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
import std.file : exists, getAttributes, mkdirRecurse, readText, remove, rmdirRecurse, setAttributes, write;

import setline.download;

@("download builds bashub machine endpoints") unittest {
  assert(downloadUrl("http://127.0.0.1:8082/", "openurp.prod", DownloadKind.manifest) ==
    "http://127.0.0.1:8082/api/bashub/config/openurp.prod/setline-manifest");
  assert(downloadUrl("https://hub.example.com", "openurp.prod", DownloadKind.proxy) ==
    "https://hub.example.com/api/bashub/config/openurp.prod/proxy");
  assert(downloadUrl("https://hub.example.com", "openurp.prod", DownloadKind.certificate) ==
    "https://hub.example.com/api/bashub/config/openurp.prod/certificate");
  assert(downloadUrl("https://hub.example.com", "openurp.prod", DownloadKind.certificateKey) ==
    "https://hub.example.com/api/bashub/config/openurp.prod/certificate-key");
  assertThrown!Exception(downloadUrl("127.0.0.1:8082", "openurp.prod", DownloadKind.proxy));
  assertThrown!Exception(downloadUrl("http://127.0.0.1:8082", "../bad", DownloadKind.proxy));
}

@("manifest parsing, state persistence and per-resource comparison") unittest {
  auto text = "{\"version\":1,\"resources\":{" ~
    "\"proxy\":\"" ~ sha256Hex("proxy\n") ~ "\"," ~
    "\"certificate\":\"" ~ sha256Hex("") ~ "\"," ~
    "\"certificate-key\":\"" ~ sha256Hex("") ~ "\"}}";
  auto manifest = parseRemoteManifest(text);
  assert(manifest.schemaVersion == 1);

  auto path = "/tmp/setline-remote-manifest-test/remote.manifest.json";
  auto corrupt = "/tmp/setline-remote-manifest-test/corrupt.json";
  scope (exit) {
    if (exists(path)) remove(path);
    if (exists(corrupt)) remove(corrupt);
  }
  assert(remoteStatePath("/var/lib/setline") == "/var/lib/setline/remote.manifest.json");
  assert(remoteStagePath("/var/lib/setline") == "/var/lib/setline/remote-stage");
  assert(writeRemoteManifest(path, manifest));
  auto loaded = readRemoteManifest(path);
  assert(!resourceChanged(loaded, manifest, manifestResourceProxy));
  write(corrupt, "not json");
  assert(readRemoteManifest(corrupt).resources.length == 0);

  auto changed = manifest;
  changed.resources[manifestResourceProxy] = sha256Hex("proxy-v2\n");
  assert(resourceChanged(loaded, changed, manifestResourceProxy));

  assertThrown!Exception(parseRemoteManifest(
    "{\"version\":1,\"resources\":{\"proxy\":\"bad\"}}"));
  assertThrown!Exception(parseRemoteManifest(
    "{\"version\":2,\"resources\":{}}"));
  assertThrown!Exception(parseRemoteManifest(
    "{\"version\":1,\"resources\":{\"proxy\":\"" ~ sha256Hex("p") ~ "\"," ~
    "\"proxy\":\"" ~ sha256Hex("x") ~ "\"," ~
    "\"certificate\":\"" ~ sha256Hex("") ~ "\"," ~
    "\"certificate-key\":\"" ~ sha256Hex("") ~ "\"," ~
    "\"unknown\":\"" ~ sha256Hex("u") ~ "\"}}"));
  assertThrown!Exception(downloadConfig("http://127.0.0.1:8082", "openurp.prod", "secret",
      DownloadKind.manifest, "", delegate string(string url, string[] headers) {
    return "not json";
  }));
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
      DownloadKind.proxy, "", delegate string(string url, string[] headers) {
    requestedUrl = url;
    requestedHeaders = headers;
    return "global\n";
  });

  assert(text == "global\n");
  assert(requestedUrl == "http://127.0.0.1:8082/api/bashub/config/openurp.prod/proxy");
  assert(requestedHeaders == ["Authorization: Bearer openurp.prod:secret"]);
}

@("download writes atomically and leaves unchanged files untouched") unittest {
  auto path = "/tmp/setline-download-test/setline.json";
  scope (exit) {
    if (exists(path)) remove(path);
    if (exists(path ~ ".tmp")) remove(path ~ ".tmp");
  }

  assert(writeDownloaded(path, "[agent]\ntype =\n"));
  assert(readText(path) == "[agent]\ntype =\n");
  setAttributes(path, octal!640);
  assert(!writeDownloaded(path, "[agent]\ntype =\n"));
  assert(writeDownloaded(path, "[agent]\ntype = app1=http://10.0.0.11:8080\n"));
  assert(readText(path) == "[agent]\ntype = app1=http://10.0.0.11:8080\n");
  assert((getAttributes(path) & octal!777) == octal!640);
}

@("remote staging is cleared without touching installed files") unittest {
  auto root = "/tmp/setline-remote-stage-test";
  auto stage = remoteStagePath(root);
  auto installed = root ~ "/remote.manifest.json";
  scope (exit) {
    if (exists(root)) rmdirRecurse(root);
  }
  if (exists(root)) rmdirRecurse(root);
  mkdirRecurse(stage);
  write(stage ~ "/" ~ stagedManifestName, "{}");
  write(installed, "installed");
  clearRemoteStage(root);
  assert(!exists(stage));
  assert(exists(installed));
}

@("staged remote install verifies hashes and removes cleared certificates") unittest {
  auto root = "/tmp/setline-remote-install-test";
  auto stage = remoteStagePath(root);
  auto targetConf = root ~ "/conf/setline.conf";
  auto targetProxy = root ~ "/conf/haproxy.cfg";
  auto certificateDir = root ~ "/certs";
  auto targetState = root ~ "/remote.manifest.json";
  scope (exit) {
    if (exists(root)) rmdirRecurse(root);
  }
  if (exists(root)) rmdirRecurse(root);

  auto proxyText = "global\n";
  auto manifest = RemoteManifest(1,
    [manifestResourceProxy: sha256Hex(proxyText),
     manifestResourceCertificate: sha256Hex(""),
     manifestResourceCertificateKey: sha256Hex("")]);
  mkdirRecurse(stage);
  write(stage ~ "/" ~ stagedProxyName, proxyText);
  write(stage ~ "/" ~ stagedCertificateEmptyName, "");
  writeRemoteManifest(stage ~ "/" ~ stagedManifestName, manifest);
  mkdirRecurse(certificateDir);
  foreach (name; ["cert.pem", "key.pem", "bundle.pem"])
    write(certificateDir ~ "/" ~ name, "old");

  assert(installRemoteStage(stage,
    RemoteInstallTargets(targetConf, targetProxy, certificateDir, targetState)));
  assert(readText(targetProxy) == proxyText);
  assert(readText(targetState).length > 0);
  foreach (name; ["cert.pem", "key.pem", "bundle.pem"])
    assert(!exists(certificateDir ~ "/" ~ name));
  assert(!exists(stage));
}

@("staged remote install rejects tampered content before replacing targets") unittest {
  auto root = "/tmp/setline-remote-install-invalid-test";
  auto stage = remoteStagePath(root);
  auto targetConf = root ~ "/conf/setline.conf";
  auto targetProxy = root ~ "/conf/haproxy.cfg";
  auto certificateDir = root ~ "/certs";
  auto targetState = root ~ "/remote.manifest.json";
  scope (exit) {
    if (exists(root)) rmdirRecurse(root);
  }
  if (exists(root)) rmdirRecurse(root);

  auto proxyText = "global\n";
  auto manifest = RemoteManifest(1,
    [manifestResourceProxy: sha256Hex(proxyText),
     manifestResourceCertificate: sha256Hex(""),
     manifestResourceCertificateKey: sha256Hex("")]);
  mkdirRecurse(stage);
  write(stage ~ "/" ~ stagedProxyName, "tampered\n");
  writeRemoteManifest(stage ~ "/" ~ stagedManifestName, manifest);
  mkdirRecurse(root ~ "/conf");
  write(targetConf, "old conf");
  write(targetProxy, "old proxy");

  assertThrown!Exception(installRemoteStage(stage,
    RemoteInstallTargets(targetConf, targetProxy, certificateDir, targetState)));
  assert(readText(targetConf) == "old conf");
  assert(readText(targetProxy) == "old proxy");
  assert(!exists(targetState));
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
