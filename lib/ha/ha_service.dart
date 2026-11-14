/*
 * kronie-ha fork: Home Assistant connection for the launcher's tile row.
 * Config is a JSON file pushed over adb to the app's external files dir:
 *   /sdcard/Android/data/app.couchdash.launcher/files/ha.json
 *   {"url": "http://<ha>:8123", "token": "<long-lived token>", "dashboard": "tv-launcher"}
 * or, after the QR setup flow, "client_id" + "refresh_token" instead of "token" (see ha_auth.dart).
 * The layout comes from that HA dashboard's first view, so tiles are changed in HA, not here.
 */

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flauncher/flauncher_channel.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:web_socket_channel/io.dart';

import 'ha_auth.dart';
import 'ha_config.dart';

class HaService extends ChangeNotifier with WidgetsBindingObserver {
  String? url;
  HaAuth? _auth;
  final HaConfigStore configStore;
  String dashboard = "tv-launcher";

  bool connected = false;
  String? error;
  List<Map<String, dynamic>> cards = [];
  final Map<String, Map<String, dynamic>> states = {};

  IOWebSocketChannel? _channel;
  int _nextId = 1;
  final Map<int, Completer<dynamic>> _pending = {};
  Timer? _retryTimer;
  Timer? _minuteTimer;
  int _backoffSeconds = 2;

  // remote shortcuts (ha.json "shortcuts"); the native accessibility service handles them in every app when it is on,
  // else long-press Menu is caught here while the launcher is in front
  final _launcherChannel = FLauncherChannel();
  Map<String, dynamic>? menuLongShortcut;
  bool buttonServiceEnabled = false;
  bool buttonServiceStuck = false; // switched on, but Android won't run it until it's turned off and on
  Duration? _menuDownAt;
  bool _menuFired = false;

  HaService({HaConfigStore? configStore}) : configStore = configStore ?? HaConfigStore() {
    WidgetsBinding.instance.addObserver(this);
    HardwareKeyboard.instance.addHandler(_onKey);
    // re-evaluate time-based card visibility every minute
    _minuteTimer = Timer.periodic(Duration(minutes: 1), (_) {
      if (cards.any((c) => c["visibility"] != null)) notifyListeners();
      // keep the OAuth access token fresh for camera image headers (no-op for long-lived tokens)
      if (connected) _auth?.accessToken().catchError((_) => "");
    });
    _start();
  }

  // back on the home screen: refresh the dashboard (belt and braces next to lovelace_updated)
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) refreshButtonService();
    if (state != AppLifecycleState.resumed || !configured) return;
    if (connected) {
      _loadDashboard().catchError((_) {});
    } else {
      _connect();
    }
  }

  bool get configured => url != null;

  Map<String, String> get authHeaders => {"Authorization": "Bearer ${_auth?.cachedToken}"};

  String cameraUrl(String entityId) => "$url/api/camera_proxy/$entityId?t=${DateTime.now().millisecondsSinceEpoch}";

  Future<void> _start() async {
    try {
      final config = await configStore.read();
      if (config == null) return; // not set up: the launcher simply shows no HA row
      readShortcuts(config);
      url = HaConfigStore.normaliseUrl(config["url"] as String);
      _auth = HaAuth.fromConfig(url!, config);
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
      // ignore the old socket's close after reload() replaced it; once per socket (ready and the stream both report)
      var reported = false;
      void lost() {
        if (reported || !identical(channel, _channel)) return;
        reported = true;
        _onLost();
      }

      channel.stream.listen(_onMessage, onDone: lost, onError: (_) => lost());
      // a failed connect (e.g. no network yet right after boot) is reported here, not on the stream: retry right away
      channel.ready.catchError((_) => lost());
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
        try {
          _send({"type": "auth", "access_token": await _auth!.accessToken()});
        } on HaAuthException catch (e) {
          error = e.revoked ? "HA login expired: set up Home Assistant again" : "HA: $e";
          notifyListeners();
          _channel?.sink.close(); // retried with backoff; a revoked login keeps failing until set up again
        }
        break;
      case "auth_invalid":
        error = "HA rejected the login";
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

  // Flattens stacks/grids so any HA layout works. Button cards that follow a tile inside the same
  // stack become that tile's popup options (stored under "_options"); loose button cards are ignored.
  void _collect(dynamic list, List<Map<String, dynamic>> into) {
    Map<String, dynamic>? lastTile;
    for (final card in (list as List?) ?? []) {
      final map = Map<String, dynamic>.from(card);
      if (map["cards"] is List) {
        _collect(map["cards"], into);
        lastTile = null;
      } else if (map["type"] == "button" && lastTile != null) {
        (lastTile["_options"] as List).add(map);
      } else {
        if (map["type"] == "tile") {
          map["_options"] = <Map<String, dynamic>>[];
          lastTile = map;
        }
        into.add(map);
      }
    }
  }

  /// HA card `visibility` conditions: time (after/before/weekdays, wraps midnight), state (state/state_not),
  /// and/or. Other condition types (screen, user, numeric_state...) count as met.
  bool isVisible(Map<String, dynamic> card) => _conditionsMet(card["visibility"]);

  bool _conditionsMet(dynamic conditions) {
    for (final c in (conditions as List?) ?? []) {
      if (!_conditionMet(Map<String, dynamic>.from(c))) return false;
    }
    return true;
  }

  bool _conditionMet(Map<String, dynamic> c) {
    switch (c["condition"]) {
      case "and":
        return _conditionsMet(c["conditions"]);
      case "or":
        return ((c["conditions"] as List?) ?? []).any((x) => _conditionMet(Map<String, dynamic>.from(x)));
      case "time":
        final now = DateTime.now();
        const days = ["mon", "tue", "wed", "thu", "fri", "sat", "sun"];
        final weekdays = c["weekdays"];
        if (weekdays is List && !weekdays.contains(days[now.weekday - 1])) return false;
        int? mins(dynamic t) {
          final p = "${t ?? ""}".split(":");
          if (p.length < 2) return null;
          return int.parse(p[0]) * 60 + int.parse(p[1]);
        }
        final n = now.hour * 60 + now.minute;
        final after = mins(c["after"]), before = mins(c["before"]);
        if (after != null && before != null && after > before) return n >= after || n < before; // wraps midnight
        return (after == null || n >= after) && (before == null || n < before);
      case "state":
        final s = states["${c["entity"]}"]?["state"];
        bool matches(dynamic v) => v is List ? v.map((e) => "$e").contains(s) : "$v" == s;
        if (c.containsKey("state") && !matches(c["state"])) return false;
        if (c.containsKey("state_not") && matches(c["state_not"])) return false;
        return true;
      default:
        return true;
    }
  }

  Future<void> callService(String domain, String service, {Map<String, dynamic>? data, dynamic target}) => _call({
        "type": "call_service",
        "domain": domain,
        "service": service,
        if (data != null && data.isNotEmpty) "service_data": data,
        if (target != null) "target": target,
      }).catchError((_) {});

  /// Runs an HA card action (tap_action / hold_action). Returns true if it was "more-info",
  /// which the caller shows as the launcher's own popup.
  bool runAction(Map<String, dynamic>? action, String? entityId, {required String fallback}) {
    final kind = action?["action"] ?? fallback;
    switch (kind) {
      case "toggle":
        if (entityId != null) toggle(entityId);
        return false;
      case "perform-action":
      case "call-service":
        final svc = (action?["perform_action"] ?? action?["service"]) as String?;
        if (svc == null || !svc.contains(".")) return false;
        final parts = svc.split(".");
        callService(parts[0], parts[1],
            data: Map<String, dynamic>.from(action?["data"] ?? action?["service_data"] ?? {}),
            target: action?["target"]);
        return false;
      case "more-info":
        return true;
      default:
        return false;
    }
  }

  Future<void> toggle(String entityId) => _call({
        "type": "call_service",
        "domain": "homeassistant",
        "service": "toggle",
        "target": {"entity_id": entityId},
      }).catchError((_) {});

  /// Picks up the "shortcuts" part of ha.json (after Settings changed it, or on start).
  void readShortcuts(Map<String, dynamic> config) {
    final menuLong = (config["shortcuts"] as Map?)?["menu_long"];
    menuLongShortcut = menuLong is Map ? Map<String, dynamic>.from(menuLong) : null;
    refreshButtonService();
    notifyListeners();
  }

  Future<void> refreshButtonService() async {
    final state = await _launcherChannel.buttonServiceState().catchError((_) => "off");
    if ((state == "on") != buttonServiceEnabled || (state == "stuck") != buttonServiceStuck) {
      buttonServiceEnabled = state == "on";
      buttonServiceStuck = state == "stuck";
      notifyListeners();
    }
  }

  // long-press Menu (≡) on the launcher itself; a short press passes through untouched
  bool _onKey(KeyEvent event) {
    if (event.logicalKey != LogicalKeyboardKey.contextMenu || buttonServiceEnabled || menuLongShortcut == null) {
      return false;
    }
    if (event is KeyDownEvent) {
      _menuDownAt = event.timeStamp;
      _menuFired = false;
      return false;
    }
    if (event is KeyRepeatEvent) {
      if (_menuFired) return true;
      if (_menuDownAt != null && event.timeStamp - _menuDownAt! >= Duration(milliseconds: 500)) {
        _menuFired = true;
        _launcherChannel.runShortcut("menu_long", "menu", "long").catchError((_) {});
        return true;
      }
      return false;
    }
    final fired = _menuFired; // KeyUpEvent
    _menuFired = false;
    _menuDownAt = null;
    return fired;
  }

  /// Re-reads ha.json and reconnects (after the setup flow saved new credentials).
  Future<void> reload() async {
    _retryTimer?.cancel();
    final old = _channel;
    _channel = null;
    old?.sink.close();
    connected = false;
    error = null;
    _backoffSeconds = 2;
    _auth = null;
    url = null;
    cards = [];
    states.clear();
    notifyListeners();
    await _start();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    HardwareKeyboard.instance.removeHandler(_onKey);
    _minuteTimer?.cancel();
    _retryTimer?.cancel();
    _channel?.sink.close();
    super.dispose();
  }
}
