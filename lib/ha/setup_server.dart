/*
 * CouchDash: first-run setup from the phone.
 * While the setup screen is open, the TV serves a small page on the LAN; the TV shows its URL as a QR code.
 * The phone enters the HA URL and logs in with HA's normal OAuth flow, with this page as the client:
 *   client_id    = http://<tv-ip>:<port>/
 *   redirect_uri = http://<tv-ip>:<port>/callback   (same host as client_id, so HA accepts it without fetching)
 * HA redirects the phone back here with a code; the TV exchanges it for a refresh token and saves ha.json.
 * Fallback: paste a long-lived token. Every request must carry the random key from the QR code.
 */

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';

import 'ha_auth.dart';
import 'ha_config.dart';

enum SetupStatus { waiting, phoneConnected, done }

class SetupServer extends ChangeNotifier {
  static const defaultPort = 8099;

  final HaConfigStore store;
  final int preferredPort;
  final Future<void> Function()? onSaved;
  final Future<String?> Function() _lanAddress;

  HttpServer? _server;
  String? _host;
  final String key = _randomKey();

  SetupStatus status = SetupStatus.waiting;
  String? savedUrl;

  SetupServer(this.store, {this.preferredPort = defaultPort, this.onSaved, Future<String?> Function()? lanAddress})
      : _lanAddress = lanAddress ?? _defaultLanAddress;

  /// e.g. http://10.0.106.20:8099/
  String? get clientId => _host == null ? null : "http://$_host:${_server!.port}/";

  String? get redirectUri => clientId == null ? null : "${clientId}callback";

  /// What the QR code encodes.
  String? get pageUrl => clientId == null ? null : "$clientId?k=$key";

  /// Returns false when the TV has no LAN address (no network).
  Future<bool> start() async {
    _host = await _lanAddress();
    if (_host == null) return false;
    try {
      _server = await HttpServer.bind(InternetAddress.anyIPv4, preferredPort);
    } on SocketException {
      _server = await HttpServer.bind(InternetAddress.anyIPv4, 0); // port taken: any free one, the QR has it
    }
    _server!.listen((request) => _handle(request).catchError((_) {}));
    notifyListeners();
    return true;
  }

  Future<void> stop() async {
    await _server?.close(force: true);
    _server = null;
  }

  @override
  void dispose() {
    stop();
    super.dispose();
  }

  // ---------- requests ----------

  Future<void> _handle(HttpRequest request) async {
    final path = request.uri.path;
    final form = request.method == "POST"
        ? Uri.splitQueryString(await utf8.decoder.bind(request).join())
        : request.uri.queryParameters;
    // the OAuth redirect carries the key as "state"; everything else as "k"
    if ((path == "/callback" ? form["state"] : form["k"]) != key) {
      return _reply(request, _page("This setup link has expired. Scan the code on the TV again."), status: 403);
    }
    if (status == SetupStatus.waiting) {
      status = SetupStatus.phoneConnected;
      notifyListeners();
    }
    if (status == SetupStatus.done) return _reply(request, _donePage());
    switch ("${request.method} $path") {
      case "GET /":
        return _reply(request, _formPage());
      case "POST /start":
        return _startLogin(request, form);
      case "GET /callback":
        return _callback(request, form);
      case "POST /token":
        return _pasteToken(request, form);
      default:
        return _reply(request, _page("Not found"), status: 404);
    }
  }

  Future<void> _startLogin(HttpRequest request, Map<String, String> form) async {
    final ha = normaliseHaUrl(form["ha"] ?? "");
    final problem = ha == null ? "That doesn't look like a URL." : await _checkReachable(ha);
    if (problem != null) return _reply(request, _formPage(ha: form["ha"], error: problem));
    _pendingUrl = ha;
    final authorize = Uri.parse("$ha/auth/authorize").replace(queryParameters: {
      "response_type": "code",
      "client_id": clientId!,
      "redirect_uri": redirectUri!,
      "state": key,
    });
    request.response
      ..statusCode = HttpStatus.found
      ..headers.set(HttpHeaders.locationHeader, authorize.toString());
    await request.response.close();
  }

  String? _pendingUrl;

  Future<void> _callback(HttpRequest request, Map<String, String> query) async {
    final code = query["code"];
    final ha = _pendingUrl;
    if (code == null || ha == null) {
      return _reply(request, _formPage(error: "Login was cancelled or didn't finish. Try again."));
    }
    try {
      final tokens = await HaAuth.exchangeCode(ha, clientId!, code);
      final refresh = tokens["refresh_token"];
      if (refresh is! String) throw HaAuthException("HA returned no refresh token");
      await _save(ha, clientId: clientId, refreshToken: refresh);
    } catch (e) {
      return _reply(request, _formPage(ha: ha, error: "Couldn't finish the login: $e"));
    }
    return _reply(request, _donePage());
  }

  Future<void> _pasteToken(HttpRequest request, Map<String, String> form) async {
    final ha = normaliseHaUrl(form["ha"] ?? "");
    final token = (form["token"] ?? "").trim();
    String? problem;
    if (ha == null) {
      problem = "That doesn't look like a URL.";
    } else if (token.isEmpty) {
      problem = "Paste a token first.";
    } else {
      problem = await _checkReachable(ha) ?? await _checkToken(ha, token);
    }
    if (problem != null) return _reply(request, _formPage(ha: form["ha"], error: problem, showToken: true));
    await _save(ha!, token: token);
    return _reply(request, _donePage());
  }

  Future<void> _save(String ha, {String? token, String? clientId, String? refreshToken}) async {
    await store.saveCredentials(ha, token: token, clientId: clientId, refreshToken: refreshToken);
    savedUrl = ha;
    status = SetupStatus.done;
    notifyListeners();
    await onSaved?.call();
  }

  // ---------- checks against HA, made from the TV ----------

  /// null if the TV reaches HA at [ha]; /auth/providers answers without a login.
  static Future<String?> _checkReachable(String ha) async {
    final status = await _get("$ha/auth/providers");
    if (status == 200) return null;
    return status == null
        ? "The TV can't reach $ha. Check the address and that the TV's network can reach Home Assistant."
        : "$ha answered, but it doesn't look like Home Assistant (HTTP $status).";
  }

  static Future<String?> _checkToken(String ha, String token) async {
    final status = await _get("$ha/api/", token: token);
    return status == 200 ? null : "Home Assistant didn't accept that token (HTTP $status).";
  }

  static Future<int?> _get(String url, {String? token}) async {
    final client = HttpClient()..connectionTimeout = Duration(seconds: 5);
    try {
      final request = await client.getUrl(Uri.parse(url));
      if (token != null) request.headers.set(HttpHeaders.authorizationHeader, "Bearer $token");
      final response = await request.close().timeout(Duration(seconds: 10));
      await response.drain();
      return response.statusCode;
    } catch (_) {
      return null;
    } finally {
      client.close();
    }
  }

  /// "homeassistant.local" -> "http://homeassistant.local:8123"; keeps explicit schemes and ports.
  static String? normaliseHaUrl(String input) {
    var text = input.trim();
    if (text.isEmpty) return null;
    final hasScheme = text.startsWith(RegExp(r"https?://", caseSensitive: false));
    if (!hasScheme) text = "http://$text";
    final uri = Uri.tryParse(text);
    if (uri == null || uri.host.isEmpty) return null;
    final port = !hasScheme && !uri.hasPort ? 8123 : null;
    return HaConfigStore.normaliseUrl(
        Uri(scheme: uri.scheme.toLowerCase(), host: uri.host, port: port ?? (uri.hasPort ? uri.port : null), path: uri.path)
            .toString());
  }

  // ---------- pages ----------

  Future<void> _reply(HttpRequest request, String html, {int status = 200}) async {
    request.response
      ..statusCode = status
      ..headers.contentType = ContentType.html
      ..headers.set(HttpHeaders.cacheControlHeader, "no-store")
      ..write(html);
    await request.response.close();
  }

  String _formPage({String? ha, String? error, bool showToken = false}) {
    final value = _esc(ha ?? _pendingUrl ?? "");
    return _page('''
${error != null ? '<p class="err">${_esc(error)}</p>' : ''}
<form method="post" action="/start">
  <input type="hidden" name="k" value="$key">
  <label>Home Assistant address</label>
  <input name="ha" value="$value" placeholder="homeassistant.local:8123" autocapitalize="off" autocorrect="off" inputmode="url" required>
  <p class="hint">The address this TV should use. Without http:// we assume http and port 8123.</p>
  <button>Log in with Home Assistant</button>
  <p class="hint">Log in as the user the TV should act as. A separate, non-admin user is best.</p>
</form>
<details${showToken ? ' open' : ''}>
  <summary>Use a long-lived token instead</summary>
  <form method="post" action="/token">
    <input type="hidden" name="k" value="$key">
    <label>Home Assistant address</label>
    <input name="ha" value="$value" placeholder="homeassistant.local:8123" autocapitalize="off" autocorrect="off" inputmode="url" required>
    <label>Long-lived access token</label>
    <textarea name="token" rows="4" autocapitalize="off" autocorrect="off" required></textarea>
    <p class="hint">Profile &rarr; Security &rarr; Long-lived access tokens, in Home Assistant.</p>
    <button>Save token</button>
  </form>
</details>''');
  }

  String _donePage() => _page('<p class="ok">Done. The TV is connected to Home Assistant; you can close this page.</p>');

  static String _page(String body) => '''<!doctype html>
<html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>CouchDash setup</title>
<style>
body{font-family:system-ui,sans-serif;background:#111418;color:#e8eaed;margin:0;padding:24px 16px;max-width:480px;margin:auto}
h1{font-size:1.4em;margin:0 0 20px}label{display:block;margin:16px 0 6px;font-weight:600}
input,textarea{box-sizing:border-box;width:100%;padding:12px;font-size:16px;border-radius:8px;border:1px solid #3c4043;background:#1c2025;color:inherit}
button{margin-top:16px;width:100%;padding:14px;font-size:16px;border:0;border-radius:8px;background:#03a9f4;color:#fff;font-weight:600}
.hint{color:#9aa0a6;font-size:.9em;margin:6px 0 0}.err{background:#5c1f1f;padding:12px;border-radius:8px}
.ok{background:#1f4d2b;padding:12px;border-radius:8px}details{margin-top:32px}summary{color:#9aa0a6}
</style></head><body><h1>CouchDash setup</h1>
$body
</body></html>''';

  static String _esc(String s) =>
      s.replaceAll("&", "&amp;").replaceAll("<", "&lt;").replaceAll(">", "&gt;").replaceAll('"', "&quot;");

  static String _randomKey() {
    const chars = "abcdefghijkmnpqrstuvwxyz23456789";
    final random = Random.secure();
    return List.generate(12, (_) => chars[random.nextInt(chars.length)]).join();
  }

  /// The TV's IPv4 LAN address, preferring ethernet over wifi.
  static Future<String?> _defaultLanAddress() async {
    final interfaces = await NetworkInterface.list(type: InternetAddressType.IPv4);
    interfaces.sort((a, b) => _rank(a.name).compareTo(_rank(b.name)));
    for (final i in interfaces) {
      for (final a in i.addresses) {
        if (!a.isLoopback && !a.isLinkLocal) return a.address;
      }
    }
    return null;
  }

  static int _rank(String name) => name.startsWith("eth") ? 0 : (name.startsWith("wlan") ? 1 : 2);
}
