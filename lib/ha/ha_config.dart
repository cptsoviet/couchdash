/*
 * CouchDash: ha.json in the app's external files dir (/sdcard/Android/data/app.couchdash.launcher/files/).
 * Read by this app and by the Kotlin notification service; written only by the setup flow (or by hand over adb).
 */

import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

class HaConfigStore {
  final Future<Directory?> Function() _dir;

  HaConfigStore({Future<Directory?> Function()? dir}) : _dir = dir ?? getExternalStorageDirectory;

  Future<File> get _file async => File("${(await _dir())!.path}/ha.json");

  static String normaliseUrl(String url) => url.trim().replaceAll(RegExp(r"/+$"), "");

  /// null when the launcher hasn't been set up
  Future<Map<String, dynamic>?> read() async {
    final file = await _file;
    if (!await file.exists()) return null;
    return Map<String, dynamic>.from(jsonDecode(await file.readAsString()));
  }

  /// Merges [changes] into ha.json (a null value removes the key).
  Future<void> update(Map<String, dynamic> changes) async {
    final config = await read() ?? {};
    changes.forEach((key, value) => value == null ? config.remove(key) : config[key] = value);
    await _write(config);
  }

  /// Stores new credentials. Keeps the other settings (dashboard, notifications, device_name, ...) and drops
  /// the credential keys of the other kind, so there is never a stale long-lived token next to an OAuth one.
  Future<void> saveCredentials(String url, {String? token, String? clientId, String? refreshToken}) async {
    assert((token != null) != (refreshToken != null && clientId != null));
    final config = await read() ?? {};
    config
      ..remove("token")
      ..remove("client_id")
      ..remove("refresh_token");
    config["url"] = normaliseUrl(url);
    if (token != null) {
      config["token"] = token;
    } else {
      config["client_id"] = clientId;
      config["refresh_token"] = refreshToken;
    }
    await _write(config);
  }

  Future<void> _write(Map<String, dynamic> config) async {
    final file = await _file;
    final tmp = File("${file.path}.tmp");
    await tmp.writeAsString(JsonEncoder.withIndent("  ").convert(config), flush: true);
    await tmp.rename(file.path);
  }
}
