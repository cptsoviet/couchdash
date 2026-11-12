/*
 * kronie-ha fork: the HA row above the apps. Renders the dashboard's cards:
 *   glance        -> read-only status pills
 *   tile          -> focusable tile; OK = tap_action, OK held ~0.5 s = hold_action (HA semantics,
 *                    default more-info = the launcher popup). Button cards stacked after a tile = popup options.
 *   picture-entity (camera) -> snapshot tile, refreshed every 10 s
 * Anything else is ignored, so the dashboard can also hold cards meant for other screens.
 */

import 'dart:async';

import 'package:flauncher/ha/ha_popup.dart';
import 'package:flauncher/ha/ha_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

const _tileWidth = 168.0;
const _tileHeight = 96.0;

class HaPanel extends StatelessWidget {
  @override
  Widget build(BuildContext context) => Consumer<HaService>(builder: (context, ha, _) {
        if (!ha.configured) return SizedBox();
        final pills = <Map<String, dynamic>>[];
        final tiles = <Map<String, dynamic>>[];
        for (final card in ha.cards) {
          switch (card["type"]) {
            case "glance":
              if (_isHeaderCard(card)) break; // "Outdoors"/"Indoors" glance cards feed the top bar instead
              for (final e in (card["entities"] as List?) ?? []) {
                final entry = e is String ? {"entity": e} : Map<String, dynamic>.from(e);
                // weather goes next to the clock (HaWeatherInline), not into the pill row
                if (!"${entry["entity"]}".startsWith("weather.")) pills.add(entry);
              }
              break;
            case "tile":
            case "button": // stand-alone button card (one stacked after a tile is a popup option instead)
              tiles.add(card);
              break;
            case "picture-entity":
              if ((card["entity"] as String?)?.startsWith("camera.") ?? false) tiles.add(card);
              break;
          }
        }
        return Padding(
          padding: EdgeInsets.only(bottom: 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (pills.isNotEmpty || !ha.connected)
                Padding(
                  padding: EdgeInsets.only(left: 8, bottom: 8),
                  child: Wrap(spacing: 10, runSpacing: 8, children: [
                    if (!ha.connected) _Pill(text: ha.error ?? "Home Assistant offline", icon: Icons.cloud_off, iconColor: Colors.redAccent),
                    for (final p in pills) _EntityPill(p),
                  ]),
                ),
              if (tiles.isNotEmpty)
                SizedBox(
                  height: _tileHeight + 24,
                  child: ListView(
                    scrollDirection: Axis.horizontal,
                    clipBehavior: Clip.none,
                    padding: EdgeInsets.symmetric(horizontal: 8, vertical: 12),
                    children: [
                      for (final t in tiles)
                        Padding(
                          padding: EdgeInsets.only(right: 16),
                          child: t["type"] == "tile"
                              ? _HaTile(t)
                              : t["type"] == "button"
                                  ? _ButtonTile(t)
                                  : _CameraTile(t),
                        ),
                    ],
                  ),
                ),
            ],
          ),
        );
      });
}

String _name(Map<String, dynamic> card, Map<String, dynamic>? state) =>
    card["name"] ?? state?["attributes"]?["friendly_name"] ?? card["entity"] ?? "?";

String _cap(String s) => s.isEmpty ? s : s[0].toUpperCase() + s.substring(1).replaceAll("_", " ");

String _num(dynamic v) {
  final d = double.tryParse("$v");
  if (d == null) return "$v";
  return d == d.roundToDouble() || d.abs() >= 10 ? d.round().toString() : d.toStringAsFixed(1);
}

// "%" and temperatures attach directly; F/C get a degree sign; anything else is spaced
String _unit(String unit) {
  if (unit == "%" || unit.startsWith("°")) return unit;
  if (unit == "F" || unit == "C") return "°$unit";
  return " $unit";
}

bool _isHeaderCard(Map<String, dynamic> card) {
  final t = "${card["title"] ?? ""}".trim().toLowerCase();
  return card["type"] == "glance" && (t == "outdoors" || t == "indoors");
}

String formatState(Map<String, dynamic>? state) {
  if (state == null) return "Unknown";
  final s = "${state["state"]}";
  final a = Map<String, dynamic>.from(state["attributes"] ?? {});
  final domain = "${state["entity_id"]}".split(".").first;
  if (s == "unavailable" || s == "unknown") return _cap(s);
  switch (domain) {
    case "light":
      if (s == "on" && a["brightness"] != null) return "On · ${(a["brightness"] * 100 / 255).round()}%";
      return _cap(s);
    case "fan":
      if (s == "on" && a["percentage"] != null) return "On · ${a["percentage"]}%";
      return _cap(s);
    case "climate":
      if (s == "off") return "Off";
      final cur = a["current_temperature"], target = a["temperature"];
      if (cur != null && target != null) return "${_num(cur)}° → ${_num(target)}°";
      return _cap(s);
    case "binary_sensor":
      const openish = {"door", "window", "opening", "garage_door"};
      if (openish.contains(a["device_class"])) return s == "on" ? "Open" : "Closed";
      return s == "on" ? "On" : "Off";
    case "sensor":
      final unit = a["unit_of_measurement"];
      return unit == null ? _cap(s) : "${_num(s)}${_unit(unit.toString())}";
    default:
      return _cap(s);
  }
}

bool _isActive(Map<String, dynamic>? state) {
  final s = state?["state"];
  return s == "on" || s == "open" || s == "unlocked" || s == "heat" || s == "cool" || s == "heat_cool";
}

IconData _icon(String entityId, Map<String, dynamic>? state) {
  final domain = entityId.split(".").first;
  switch (domain) {
    case "light":
      return Icons.lightbulb_outline;
    case "fan":
      return Icons.air;
    case "climate":
      return Icons.ac_unit;
    case "lock":
      return state?["state"] == "unlocked" ? Icons.lock_open : Icons.lock_outline;
    case "switch":
      return Icons.power_settings_new;
    case "camera":
      return Icons.videocam_outlined;
    case "binary_sensor":
      return Icons.sensor_door_outlined;
    case "sensor":
      return Icons.thermostat;
    default:
      return Icons.circle_outlined;
  }
}

// HA weather conditions -> label + icon (pill shows e.g. "Clear ☾ 81°F")
const _weather = <String, (String, IconData)>{
  "clear-night": ("Clear", Icons.nightlight_round),
  "sunny": ("Clear", Icons.wb_sunny_outlined),
  "partlycloudy": ("Partly cloudy", Icons.wb_cloudy_outlined),
  "cloudy": ("Cloudy", Icons.cloud),
  "fog": ("Fog", Icons.blur_on),
  "rainy": ("Rain", Icons.water_drop_outlined),
  "pouring": ("Heavy rain", Icons.water_drop),
  "lightning": ("Thunder", Icons.flash_on),
  "lightning-rainy": ("Storms", Icons.thunderstorm_outlined),
  "snowy": ("Snow", Icons.ac_unit),
  "snowy-rainy": ("Sleet", Icons.ac_unit),
  "hail": ("Hail", Icons.grain),
  "windy": ("Windy", Icons.air),
  "windy-variant": ("Windy", Icons.air),
  "exceptional": ("Weather alert", Icons.warning_amber),
};

class _Pill extends StatelessWidget {
  final String text;
  final String? value; // shown bold after "text: "
  final IconData? icon;
  final Color? iconColor;

  _Pill({required this.text, this.value, this.icon, this.iconColor});

  @override
  Widget build(BuildContext context) => Container(
        padding: EdgeInsets.symmetric(horizontal: 14, vertical: 6),
        decoration: BoxDecoration(
          color: Color(0x14FFFFFF),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: Color(0x1FFFFFFF)),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          if (icon != null) ...[Icon(icon, size: 15, color: iconColor ?? Colors.white70), SizedBox(width: 6)],
          Text.rich(
            TextSpan(children: [
              TextSpan(text: value == null ? text : "$text: "),
              if (value != null) TextSpan(text: value, style: TextStyle(fontWeight: FontWeight.w700)),
            ]),
            style: TextStyle(fontSize: 13, color: Colors.white.withValues(alpha: 0.92)),
          ),
        ]),
      );
}

class _EntityPill extends StatelessWidget {
  final Map<String, dynamic> entry;

  _EntityPill(this.entry);

  @override
  Widget build(BuildContext context) {
    final entityId = "${entry["entity"]}";
    final state = context.select<HaService, Map<String, dynamic>?>((ha) => ha.states[entityId]);
    final s = state?["state"];
    final deviceClass = state?["attributes"]?["device_class"];
    final domain = entityId.split(".").first;
    // secure/closed/"All good" = green, unlocked/open/"N issues" = amber
    final text = "$s".toLowerCase();
    final summary = domain == "sensor" && (text == "all good" || text.contains("issue"));
    final good = s == "locked" || (domain == "binary_sensor" && s == "off") || (summary && text == "all good");
    final bad = s == "unlocked" || s == "jammed" || (domain == "binary_sensor" && s == "on") || (summary && !good);
    final IconData icon = summary
        ? (good ? Icons.check_circle_outline : Icons.warning_amber_rounded)
        : switch (domain) {
      "lock" => s == "unlocked" ? Icons.lock_open : Icons.lock_outline,
      "binary_sensor" => switch (deviceClass) {
          "window" => Icons.window_outlined,
          "garage_door" => Icons.garage_outlined,
          "door" || "opening" => s == "on" ? Icons.door_front_door_outlined : Icons.door_front_door,
          _ => Icons.sensors,
        },
      _ => _icon(entityId, state),
          };
    return _Pill(
      text: _name(entry, state),
      value: formatState(state),
      icon: icon,
      iconColor: good
          ? Colors.greenAccent
          : bad
              ? Colors.orangeAccent
              : null,
    );
  }
}

/// Shared focus/scale frame for HA tiles, styled like the app cards.
class _TileFrame extends StatefulWidget {
  final Widget Function(bool focused) builder;
  final VoidCallback? onSelect;
  final VoidCallback? onHold;
  final bool active;

  _TileFrame({required this.builder, this.onSelect, this.onHold, this.active = false});

  @override
  State<_TileFrame> createState() => _TileFrameState();
}

class _TileFrameState extends State<_TileFrame> {
  static const _holdTime = Duration(milliseconds: 500);
  bool _focused = false;
  bool _pressed = false;
  Timer? _holdTimer;

  bool _isSelectKey(KeyEvent e) =>
      e.logicalKey == LogicalKeyboardKey.select ||
      e.logicalKey == LogicalKeyboardKey.enter ||
      e.logicalKey == LogicalKeyboardKey.gameButtonA;

  // OK down starts a timer: released before 0.5 s = tap, still held = hold (fires once, release ignored)
  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (!_isSelectKey(event)) return KeyEventResult.ignored;
    if (event is KeyDownEvent) {
      setState(() => _pressed = true);
      _holdTimer?.cancel();
      _holdTimer = Timer(_holdTime, () {
        _holdTimer = null;
        setState(() => _pressed = false);
        widget.onHold?.call();
      });
    } else if (event is KeyUpEvent) {
      if (_holdTimer != null) {
        _holdTimer!.cancel();
        _holdTimer = null;
        widget.onSelect?.call();
      }
      setState(() => _pressed = false);
    }
    return KeyEventResult.handled;
  }

  @override
  void dispose() {
    _holdTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Focus(
        onFocusChange: (f) {
          setState(() => _focused = f);
          if (f) Scrollable.ensureVisible(context, alignment: 0.5, duration: Duration(milliseconds: 150));
        },
        onKeyEvent: _onKey,
        child: AnimatedScale(
          // shrinks while OK is held, so you can feel the long press register
          scale: _pressed ? 0.96 : (_focused ? 1.08 : 1.0),
          duration: _pressed ? _holdTime : Duration(milliseconds: 150),
          child: AnimatedContainer(
            duration: Duration(milliseconds: 150),
            width: _tileWidth,
            height: _tileHeight,
            clipBehavior: Clip.antiAlias,
            decoration: BoxDecoration(
              color: _focused
                  ? Color(0x33FFFFFF)
                  : widget.active
                      ? Color(0x2EFFC85A)
                      : Color(0x14FFFFFF),
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: _focused ? Colors.white : Color(0x1FFFFFFF), width: _focused ? 2 : 1),
              boxShadow: _focused ? [BoxShadow(color: Colors.black54, blurRadius: 16, offset: Offset(0, 6))] : [],
            ),
            child: widget.builder(_focused),
          ),
        ),
      );
}

class _HaTile extends StatelessWidget {
  final Map<String, dynamic> card;

  _HaTile(this.card);

  @override
  Widget build(BuildContext context) {
    final entityId = card["entity"] as String;
    final state = context.select<HaService, Map<String, dynamic>?>((ha) => ha.states[entityId]);
    void run(String key) {
      final ha = context.read<HaService>();
      final action = card[key] == null ? null : Map<String, dynamic>.from(card[key]);
      if (ha.runAction(action, entityId, fallback: "more-info")) showHaPopup(context, card);
    }

    return _TileFrame(
      active: _isActive(state),
      onSelect: () => run("tap_action"),
      onHold: () => run("hold_action"),
      builder: (_) => Padding(
        padding: EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Icon(_icon(entityId, state), size: 22),
            Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(_name(card, state),
                  maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 12, color: Colors.white70)),
              Text(formatState(state),
                  maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
            ]),
          ],
        ),
      ),
    );
  }
}

class _CameraTile extends StatefulWidget {
  final Map<String, dynamic> card;

  _CameraTile(this.card);

  @override
  State<_CameraTile> createState() => _CameraTileState();
}

class _CameraTileState extends State<_CameraTile> {
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(Duration(seconds: 10), (_) => setState(() {}));
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ha = context.read<HaService>();
    final entityId = widget.card["entity"] as String;
    return _TileFrame(
      builder: (_) => Stack(fit: StackFit.expand, children: [
        Image.network(ha.cameraUrl(entityId),
            headers: ha.authHeaders,
            fit: BoxFit.cover,
            gaplessPlayback: true,
            errorBuilder: (_, __, ___) => Center(child: Icon(Icons.videocam_off_outlined, color: Colors.white38))),
        Positioned(
          left: 10,
          bottom: 8,
          child: Text(_name(widget.card, ha.states[entityId]),
              style: TextStyle(fontSize: 12, shadows: [Shadow(color: Colors.black, blurRadius: 6)])),
        ),
      ]),
    );
  }
}

/// Stand-alone HA button card: name plus an action, e.g. "All off". OK = tap_action, hold = hold_action.
class _ButtonTile extends StatelessWidget {
  final Map<String, dynamic> card;

  _ButtonTile(this.card);

  @override
  Widget build(BuildContext context) {
    final entityId = card["entity"] as String?;
    final state = context.select<HaService, Map<String, dynamic>?>((ha) => entityId == null ? null : ha.states[entityId]);
    final svc = "${card["tap_action"]?["perform_action"] ?? card["tap_action"]?["service"] ?? ""}";
    void run(String key, String fallback) {
      final action = card[key] == null ? null : Map<String, dynamic>.from(card[key]);
      context.read<HaService>().runAction(action, entityId, fallback: fallback);
    }

    return _TileFrame(
      active: _isActive(state),
      onSelect: () => run("tap_action", entityId != null ? "toggle" : "none"),
      onHold: () => run("hold_action", "none"),
      builder: (_) => Padding(
        padding: EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Icon(
                entityId != null
                    ? _icon(entityId, state)
                    : svc.endsWith("turn_off")
                        ? Icons.power_settings_new
                        : svc.startsWith("scene.")
                            ? Icons.palette_outlined
                            : Icons.touch_app_outlined,
                size: 22),
            Text(card["name"] ?? state?["attributes"]?["friendly_name"] ?? "Button",
                maxLines: 2, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
          ],
        ),
      ),
    );
  }
}

/// Top bar left of the clock: [weather] {AQI} | Indoors: 81°F 35% {AQI} |
/// Driven by the dashboard's glance cards titled "Outdoors" and "Indoors" (entity order is kept).
/// Without an "Outdoors" card it falls back to the first weather.* entity in any glance card.
class HaHeader extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final ha = context.watch<HaService>();
    List<String> entitiesOf(String title) {
      for (final c in ha.cards) {
        if (c["type"] == "glance" && "${c["title"] ?? ""}".trim().toLowerCase() == title) {
          return [for (final e in (c["entities"] as List?) ?? []) "${e is String ? e : e["entity"]}"];
        }
      }
      return [];
    }

    var outdoors = entitiesOf("outdoors");
    if (outdoors.isEmpty) {
      for (final c in ha.cards.where((c) => c["type"] == "glance")) {
        for (final e in (c["entities"] as List?) ?? []) {
          final id = "${e is String ? e : e["entity"]}";
          if (id.startsWith("weather.") && outdoors.isEmpty) outdoors = [id];
        }
      }
    }
    final indoors = entitiesOf("indoors");
    final style = Theme.of(context).textTheme.titleLarge!.copyWith(fontWeight: FontWeight.w400);

    List<Widget> segment(List<String> ids) => [
          for (final id in ids)
            // hidden while unknown/unavailable (e.g. the Winix purifier is off)
            if (ha.states[id] != null && !{"unknown", "unavailable"}.contains(ha.states[id]!["state"])) ...[
              _headerItem(ha.states[id]!, style),
              SizedBox(width: 10)
            ],
        ];

    final out = segment(outdoors);
    final ins = segment(indoors);
    Widget divider() => Padding(
        padding: EdgeInsets.only(left: 6, right: 16), child: Container(width: 1, height: 22, color: Colors.white24));
    return Row(mainAxisSize: MainAxisSize.min, children: [
      ...out,
      if (out.isNotEmpty) divider(),
      if (ins.isNotEmpty) ...[Text("Indoors:", style: style.copyWith(color: Colors.white70)), SizedBox(width: 10), ...ins],
      if (ins.isNotEmpty) divider(),
    ]);
  }

  Widget _headerItem(Map<String, dynamic> state, TextStyle style) {
    final id = "${state["entity_id"]}";
    final a = Map<String, dynamic>.from(state["attributes"] ?? {});
    final s = "${state["state"]}";
    if (id.startsWith("weather.")) {
      final w = _weather[s] ?? (_cap(s), Icons.cloud_outlined);
      final t = a["temperature"];
      return Row(mainAxisSize: MainAxisSize.min, children: [
        Text(w.$1, style: style.copyWith(color: Colors.white70)),
        SizedBox(width: 8),
        Icon(w.$2, size: 22),
        if (t != null) ...[
          SizedBox(width: 8),
          Text("${(t as num).round()}${_unit("${a["temperature_unit"] ?? "°F"}")}", style: style),
        ],
      ]);
    }
    final isAqi = a["device_class"] == "aqi" ||
        id.contains("aqi") ||
        id.contains("air_quality") ||
        "${a["friendly_name"] ?? ""}".toLowerCase().contains("air quality");
    if (isAqi) return _AqiBadge(s);
    return Text(formatState(state), style: style);
  }
}

/// AQI badge: numbers coloured by US EPA band, or text levels (good/fair/poor...).
class _AqiBadge extends StatelessWidget {
  final String value;

  _AqiBadge(this.value);

  @override
  Widget build(BuildContext context) {
    final n = double.tryParse(value);
    final Color color;
    final String label;
    if (n != null) {
      label = "AQI ${n.round()}";
      color = n <= 50
          ? Color(0xFF3DDC84)
          : n <= 100
              ? Color(0xFFFFD54F)
              : n <= 150
                  ? Color(0xFFFF9800)
                  : n <= 200
                      ? Color(0xFFF44336)
                      : n <= 300
                          ? Color(0xFF9C27B0)
                          : Color(0xFF7E0023);
    } else {
      final v = value.toLowerCase();
      label = "AQI ${_cap(v)}";
      color = v.contains("good") || v == "excellent"
          ? Color(0xFF3DDC84)
          : v.contains("fair") || v.contains("moderate")
              ? Color(0xFFFFD54F)
              : v.contains("poor") || v.contains("bad") || v.contains("unhealthy")
                  ? Color(0xFFF44336)
                  : Colors.white54;
    }
    return Container(
      padding: EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.18),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: color.withValues(alpha: 0.7)),
      ),
      child: Text(label, style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: color)),
    );
  }
}
