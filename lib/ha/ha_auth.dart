/*
 * CouchDash: Home Assistant credentials.
 * Two kinds, both stored in ha.json next to "url":
 *   long-lived token (legacy / paste fallback):  {"token": "<long-lived token>"}
 *   OAuth from the QR setup flow:               {"client_id": "http://<tv>:<port>/", "refresh_token": "..."}
 * OAuth access tokens live 30 min and are only kept in memory; each consumer (this app and the Kotlin
 * notification service) refreshes on its own. HA refresh tokens are reusable, so nothing is written back.
 */

import 'dart:async';
import 'dart:convert';
import 'dart:io';

class HaAuthException implements Exception {
  final String message;

  /// true when HA says the refresh token is no longer valid (revoked, or unused for 90 days): set up again
  final bool revoked;

  HaAuthException(this.message, {this.revoked = false});

  @override
  String toString() => message;
}

class HaAuth {
  final String url;
  final String? _longLivedToken;
  final String? clientId;
  final String? refreshToken;

  String? _accessToken;
  DateTime _expiresAt = DateTime.fromMillisecondsSinceEpoch(0);
  Future<String>? _refreshing;

  HaAuth.longLived(this.url, String token)
      : _longLivedToken = token,
        clientId = null,
        refreshToken = null;

  HaAuth.oauth(this.url, {required String this.clientId, required String this.refreshToken}) : _longLivedToken = null;

  /// Reads the credential part of ha.json; [url] must already be normalised (no trailing slash).
  factory HaAuth.fromConfig(String url, Map<String, dynamic> config) {
    final refresh = config["refresh_token"];
    final client = config["client_id"];
    if (refresh is String && client is String) return HaAuth.oauth(url, clientId: client, refreshToken: refresh);
    final token = config["token"];
    if (token is String) return HaAuth.longLived(url, token);
    throw HaAuthException("ha.json has neither \"token\" nor \"refresh_token\" + \"client_id\"");
  }

  bool get isOAuth => refreshToken != null;

  /// The last known access token, for synchronous use (image headers). Call [accessToken] first.
  String? get cachedToken => _longLivedToken ?? _accessToken;

  /// A valid access token, refreshed when it expires within 5 minutes.
  Future<String> accessToken() {
    if (_longLivedToken != null) return Future.value(_longLivedToken);
    if (_accessToken != null && DateTime.now().isBefore(_expiresAt.subtract(Duration(minutes: 5)))) {
      return Future.value(_accessToken);
    }
    return _refreshing ??= _refresh().whenComplete(() => _refreshing = null);
  }

  Future<String> _refresh() async {
    final result = await postTokenEndpoint(url, {
      "grant_type": "refresh_token",
      "refresh_token": refreshToken!,
      "client_id": clientId!,
    });
    _accessToken = result["access_token"] as String;
    _expiresAt = DateTime.now().add(Duration(seconds: (result["expires_in"] as num?)?.toInt() ?? 1800));
    return _accessToken!;
  }

  /// Step 2 of the OAuth flow: trade the authorization code from the redirect for tokens.
  /// Returns HA's token response (access_token, refresh_token, expires_in, ...).
  static Future<Map<String, dynamic>> exchangeCode(String url, String clientId, String code) =>
      postTokenEndpoint(url, {"grant_type": "authorization_code", "code": code, "client_id": clientId});

  static Future<Map<String, dynamic>> postTokenEndpoint(String url, Map<String, String> form) async {
    final client = HttpClient()..connectionTimeout = Duration(seconds: 10);
    try {
      final request = await client.postUrl(Uri.parse("$url/auth/token"));
      request.headers.contentType = ContentType("application", "x-www-form-urlencoded", charset: "utf-8");
      request.write(Uri(queryParameters: form).query);
      final response = await request.close().timeout(Duration(seconds: 15));
      final body = await response.transform(utf8.decoder).join();
      if (response.statusCode == 200) return Map<String, dynamic>.from(jsonDecode(body));
      String? code;
      try {
        code = jsonDecode(body)["error"];
      } catch (_) {}
      throw HaAuthException("HA token endpoint: HTTP ${response.statusCode}${code != null ? " ($code)" : ""}",
          revoked: response.statusCode == 400 && code == "invalid_grant");
    } on HaAuthException {
      rethrow;
    } catch (e) {
      throw HaAuthException("HA token endpoint: $e");
    } finally {
      client.close();
    }
  }
}
