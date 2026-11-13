import 'dart:convert';
import 'dart:io';

import 'package:flauncher/ha/ha_auth.dart';
import 'package:flauncher/ha/ha_config.dart';
import 'package:flauncher/ha/setup_server.dart';
import 'package:flutter_test/flutter_test.dart';

/// Minimal stand-in for HA's auth endpoints.
class FakeHa {
  late HttpServer server;
  final List<Map<String, String>> tokenRequests = [];
  int issued = 0;
  bool revoked = false;

  String get url => "http://127.0.0.1:${server.port}";

  Future<void> start() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((r) async {
      final form = r.method == "POST" ? Uri.splitQueryString(await utf8.decoder.bind(r).join()) : <String, String>{};
      Object? body;
      var status = 200;
      switch (r.uri.path) {
        case "/auth/providers":
          body = [{"name": "Home Assistant Local", "type": "homeassistant", "id": null}];
        case "/api/":
          status = r.headers.value("authorization") == "Bearer good-llat" ? 200 : 401;
          body = {"message": status == 200 ? "API running." : "401: Unauthorized"};
        case "/auth/token":
          tokenRequests.add(form);
          if (form["grant_type"] == "authorization_code" && form["code"] == "the-code") {
            body = {"access_token": "access-${++issued}", "refresh_token": "the-refresh", "expires_in": 1800, "token_type": "Bearer"};
          } else if (form["grant_type"] == "refresh_token" && form["refresh_token"] == "the-refresh" && !revoked) {
            body = {"access_token": "access-${++issued}", "expires_in": 1800, "token_type": "Bearer"};
          } else {
            status = 400;
            body = {"error": "invalid_grant"};
          }
        default:
          status = 404;
      }
      r.response.statusCode = status;
      if (body != null) r.response.write(jsonEncode(body));
      await r.response.close();
    });
  }
}

void main() {
  late FakeHa ha;
  late Directory dir;
  late HaConfigStore store;
  late SetupServer setup;
  late HttpClient phone;
  var saved = 0;

  setUp(() async {
    ha = FakeHa();
    await ha.start();
    dir = await Directory.systemTemp.createTemp("couchdash");
    store = HaConfigStore(dir: () async => dir);
    saved = 0;
    setup = SetupServer(store, preferredPort: 0, lanAddress: () async => "127.0.0.1", onSaved: () async => saved++);
    expect(await setup.start(), isTrue);
    phone = HttpClient();
  });

  tearDown(() async {
    phone.close(force: true);
    await setup.stop();
    await ha.server.close(force: true);
    await dir.delete(recursive: true);
  });

  Future<HttpClientResponse> get(String url) async {
    final request = await phone.getUrl(Uri.parse(url));
    request.followRedirects = false;
    return request.close();
  }

  Future<HttpClientResponse> post(String path, Map<String, String> form) async {
    final request = await phone.postUrl(Uri.parse("${setup.clientId!.replaceAll(RegExp(r'/$'), '')}$path"));
    request.followRedirects = false;
    request.headers.contentType = ContentType("application", "x-www-form-urlencoded");
    request.write(Uri(queryParameters: form).query);
    return request.close();
  }

  test("OAuth flow: page, redirect to HA, callback saves a refresh token, refresh works", () async {
    // existing settings survive a new login
    await File("${dir.path}/ha.json").writeAsString(jsonEncode({"url": "http://old", "token": "old", "dashboard": "tv", "notifications": true}));

    final page = await get(setup.pageUrl!);
    expect(page.statusCode, 200);
    expect(await utf8.decoder.bind(page).join(), contains('name="k" value="${setup.key}"'));
    expect(setup.status, SetupStatus.phoneConnected);

    final start = await post("/start", {"k": setup.key, "ha": "${ha.url}/"});
    await start.drain();
    expect(start.statusCode, HttpStatus.found);
    final authorize = Uri.parse(start.headers.value("location")!);
    expect(authorize.path, "/auth/authorize");
    expect(authorize.queryParameters["client_id"], setup.clientId);
    expect(authorize.queryParameters["redirect_uri"], "${setup.clientId}callback");
    expect(authorize.queryParameters["state"], setup.key);

    // HA redirects the phone back with a code
    final done = await get("${authorize.queryParameters["redirect_uri"]}?code=the-code&state=${setup.key}");
    expect(await utf8.decoder.bind(done).join(), contains("Done"));
    expect(setup.status, SetupStatus.done);
    expect(saved, 1);
    expect(ha.tokenRequests.single["client_id"], setup.clientId);

    final config = (await store.read())!;
    expect(config["url"], ha.url);
    expect(config["refresh_token"], "the-refresh");
    expect(config["client_id"], setup.clientId);
    expect(config.containsKey("token"), isFalse);
    expect(config["dashboard"], "tv");
    expect(config["notifications"], true);

    final auth = HaAuth.fromConfig(config["url"], config);
    expect(auth.isOAuth, isTrue);
    expect(await auth.accessToken(), "access-2");
    expect(await auth.accessToken(), "access-2", reason: "cached until close to expiry");
    expect(auth.cachedToken, "access-2");
  });

  test("a revoked refresh token is reported as revoked", () async {
    ha.revoked = true;
    final auth = HaAuth.oauth(ha.url, clientId: "http://x/", refreshToken: "the-refresh");
    expect(auth.accessToken(), throwsA(isA<HaAuthException>().having((e) => e.revoked, "revoked", isTrue)));
  });

  test("long-lived token fallback is checked against HA before saving", () async {
    final bad = await post("/token", {"k": setup.key, "ha": ha.url, "token": "nope"});
    expect(await utf8.decoder.bind(bad).join(), contains("didn't accept"));
    expect(await store.read(), isNull);

    final good = await post("/token", {"k": setup.key, "ha": ha.url, "token": "good-llat"});
    expect(await utf8.decoder.bind(good).join(), contains("Done"));
    final config = (await store.read())!;
    expect(config["token"], "good-llat");
    expect(HaAuth.fromConfig(config["url"], config).isOAuth, isFalse);
  });

  test("unreachable HA is reported, nothing is saved", () async {
    final response = await post("/start", {"k": setup.key, "ha": "127.0.0.1:1"});
    expect(response.statusCode, 200);
    expect(await utf8.decoder.bind(response).join(), contains("can't reach"));
    expect(await store.read(), isNull);
  });

  test("requests without the key are refused", () async {
    final noKey = await get(setup.clientId!);
    await noKey.drain();
    expect(noKey.statusCode, 403);
    final forged = await get("${setup.clientId}callback?code=the-code&state=wrong");
    await forged.drain();
    expect(forged.statusCode, 403);
    expect(setup.status, SetupStatus.waiting);
    expect(ha.tokenRequests, isEmpty);
  });

  test("URL normalisation", () {
    expect(SetupServer.normaliseHaUrl("homeassistant.local"), "http://homeassistant.local:8123");
    expect(SetupServer.normaliseHaUrl("10.0.0.5:8123/"), "http://10.0.0.5:8123");
    expect(SetupServer.normaliseHaUrl("https://ha.example.com"), "https://ha.example.com");
    expect(SetupServer.normaliseHaUrl("HTTP://ha:9000"), "http://ha:9000");
    expect(SetupServer.normaliseHaUrl("  "), isNull);
  });
}
