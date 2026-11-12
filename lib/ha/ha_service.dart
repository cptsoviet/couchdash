/*
 * kronie-ha fork: Home Assistant connection for the launcher's tile row.
 * Config is a JSON file pushed over adb to the app's external files dir:
 *   /sdcard/Android/data/net.kronie.flauncher/files/ha.json
 *   {"url": "http://<ha>:8123", "token": "<long-lived token>", "dashboard": "tv-launcher"}
 * The layout comes from that HA dashboard's first view, so tiles are changed in HA, not here.
 */

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:web_socket_channel/io.dart';

class HaService extends ChangeNotifier {
  String? url;
  String? _token;
  String dashboard = "tv-launcher";

  bool connected = false;
  String? error;
  List<Map<String, dynamic>> cards = [];
  final Map<String, Map<String, dynamic>> states = {};

  IOWebSocketChannel? _channel;
  int _nextId = 1;
  final Map<int, Completer<dynamic>> _pending = {};
  Timer? _retryTimer;
  int _backoffSeconds = 2;

  HaService() {
    _start();
  }

  bool get configured => url != null;

  Map<String, String> get authHeaders => {"Authorization": "Bearer $_token"};

  String cameraUrl(String entityId) => "$url/api/camera_proxy/$entityId?t=${DateTime.now().millisecondsSinceEpoch}";

  Future<void> _start() async {
    try {
      final dir = await getExternalStorageDirectory();
      final file = File("${dir!.path}/ha.json");
      if (!await file.exists()) return; // not set up: the launcher simply shows no HA row
      final config = jsonDecode(await file.readAsString());
      url = (config["url"] as String).replaceAll(RegExp(r"/+$"), "");
      _token = config["token"];
      dashboard = config["dashboard"] ?? dashboard;
    } catch (e) {
      error = "HA config: $e";
      notifyListeners();
      return;
    }
    _connect();
  }

  void _connect() {
    _retryTimer?.cancel();
    try {
      final base = Uri.parse(url!);
      final ws = base.replace(scheme: base.scheme == "https" ? "wss" : "ws", path: "/api/websocket");
      final channel = IOWebSocketChannel.connect(ws, pingInterval: Duration(seconds: 30));
      _channel = channel;
      channel.stream.listen(_onMessage, onDone: _onLost, onError: (_) => _onLost());
    } catch (e) {
      _onLost();
    }
  }

  void _onLost() {
    connected = false;
    for (final c in _pending.values) {
      if (!c.isCompleted) c.completeError("connection lost");
    }
    _pending.clear();
    notifyListeners();
    _retryTimer?.cancel();
    _retryTimer = Timer(Duration(seconds: _backoffSeconds), _connect);
    _backoffSeconds = (_backoffSeconds * 2).clamp(2, 60);
  }

  void _send(Map<String, dynamic> message) => _channel?.sink.add(jsonEncode(message));

  Future<dynamic> _call(Map<String, dynamic> message) {
    final id = _nextId++;
    final completer = Completer<dynamic>();
    _pending[id] = completer;
    _send({...message, "id": id});
    return completer.future;
  }

  Future<void> _onMessage(dynamic data) async {
    final message = jsonDecode(data as String);
    switch (message["type"]) {
      case "auth_required":
        _send({"type": "auth", "access_token": _token});
        break;
      case "auth_invalid":
        error = "HA rejected the token";
        notifyListeners();
        _channel?.sink.close();
        break;
      case "auth_ok":
        _backoffSeconds = 2;
        error = null;
        connected = true;
        await _load();
        break;
      case "result":
        final completer = _pending.remove(message["id"]);
        if (completer != null) {
          if (message["success"] == true) {
            completer.complete(message["result"]);
          } else {
            completer.completeError(message["error"]?.toString() ?? "error");
          }
        }
        break;
      case "event":
        final event = message["event"];
        if (event["event_type"] == "state_changed") {
          final eventData = event["data"];
          final newState = eventData["new_state"];
          if (newState != null) {
            states[eventData["entity_id"]] = Map<String, dynamic>.from(newState);
          } else {
            states.remove(eventData["entity_id"]);
          }
          notifyListeners();
        } else if (event["event_type"] == "lovelace_updated") {
          _loadDashboard().catchError((_) {});
        }
        break;
    }
  }

  Future<void> _load() async {
    try {
      await _loadDashboard();
      final all = await _call({"type": "get_states"}) as List;
      states.clear();
      for (final s in all) {
        states[s["entity_id"]] = Map<String, dynamic>.from(s);
      }
      await _call({"type": "subscribe_events", "event_type": "state_changed"});
    } catch (e) {
      error = "HA: $e";
    }
    // dashboard edits show up live; allowed for non-admin users on current HA, but not essential
    _call({"type": "subscribe_events", "event_type": "lovelace_updated"}).catchError((_) {});
    notifyListeners();
  }

  Future<void> _loadDashboard() async {
    final config = await _call({"type": "lovelace/config", "url_path": dashboard});
    final views = (config["views"] as List?) ?? [];
    final found = <Map<String, dynamic>>[];
    if (views.isNotEmpty) {
      final view = views.first;
      _collect(view["cards"], found);
      for (final section in (view["sections"] as List?) ?? []) {
        _collect(section["cards"], found);
      }
    }
    cards = found;
    notifyListeners();
  }

  // flattens stacks/grids so any HA layout works; only the leaf cards matter here
  void _collect(dynamic list, List<Map<String, dynamic>> into) {
    for (final card in (list as List?) ?? []) {
      final map = Map<String, dynamic>.from(card);
      if (map["cards"] is List) {
        _collect(map["cards"], into);
      } else {
        into.add(map);
      }
    }
  }

  Future<void> toggle(String entityId) => _call({
        "type": "call_service",
        "domain": "homeassistant",
        "service": "toggle",
        "target": {"entity_id": entityId},
      }).catchError((_) {});

  @override
  void dispose() {
    _retryTimer?.cancel();
    _channel?.sink.close();
    super.dispose();
  }
}
