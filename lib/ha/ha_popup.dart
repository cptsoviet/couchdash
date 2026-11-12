/*
 * kronie-ha fork: the TV's "more-info" popup for an HA tile.
 * Top: the tile's custom options (button cards stacked after it in the HA dashboard).
 * Below: built-in controls for the entity type (climate / light / fan). Back closes it.
 */

import 'package:flauncher/ha/ha_panel.dart';
import 'package:flauncher/ha/ha_service.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

void showHaPopup(BuildContext context, Map<String, dynamic> card) => showDialog(
      context: context,
      barrierColor: Colors.black54,
      builder: (_) => ChangeNotifierProvider.value(value: context.read<HaService>(), child: _HaPopup(card)),
    );

class _HaPopup extends StatelessWidget {
  final Map<String, dynamic> card;

  _HaPopup(this.card);

  @override
  Widget build(BuildContext context) {
    final ha = context.watch<HaService>();
    final entityId = card["entity"] as String;
    final state = ha.states[entityId];
    final options = List<Map<String, dynamic>>.from(card["_options"] ?? []);
    final domain = entityId.split(".").first;
    final controls = _controls(context, ha, domain, entityId, state);
    final lastScene = _lastActivatedScene(ha, options);
    return Dialog(
      backgroundColor: Color(0xF0161A20),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(22), side: BorderSide(color: Color(0x2EFFFFFF))),
      child: SizedBox(
        width: 380,
        child: Padding(
          padding: EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(card["name"] ?? state?["attributes"]?["friendly_name"] ?? entityId,
                  style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600)),
              SizedBox(height: 2),
              Text(formatState(state), style: TextStyle(fontSize: 14, color: Colors.white60)),
              if (options.isNotEmpty) SizedBox(height: 14),
              for (var i = 0; i < options.length; i++)
                Padding(
                  padding: EdgeInsets.only(bottom: 8),
                  child: _PopupButton(
                    label: options[i]["name"] ?? "Option ${i + 1}",
                    selected: lastScene != null && _sceneOf(options[i]) == lastScene,
                    autofocus: i == 0,
                    onPressed: () {
                      final moreInfo = ha.runAction(
                          Map<String, dynamic>.from(options[i]["tap_action"] ?? {}), options[i]["entity"],
                          fallback: "toggle");
                      if (!moreInfo) Navigator.of(context).pop();
                    },
                  ),
                ),
              if (controls.isNotEmpty) ...[SizedBox(height: 10), ...controls],
              if (options.isEmpty && controls.isEmpty)
                Padding(
                  padding: EdgeInsets.only(top: 14),
                  child: Text("No controls on the TV for this one.", style: TextStyle(color: Colors.white54)),
                ),
            ],
          ),
        ),
      ),
    );
  }

  // the most recently activated scene among the options (scene state = last activation time)
  String? _lastActivatedScene(HaService ha, List<Map<String, dynamic>> options) {
    String? best;
    DateTime? bestTime;
    for (final o in options) {
      final scene = _sceneOf(o);
      final t = DateTime.tryParse("${ha.states[scene]?["state"]}");
      if (scene != null && t != null && (bestTime == null || t.isAfter(bestTime))) {
        best = scene;
        bestTime = t;
      }
    }
    return best;
  }

  String? _sceneOf(Map<String, dynamic> option) {
    final action = option["tap_action"] ?? {};
    final svc = action["perform_action"] ?? action["service"];
    if (svc != "scene.turn_on") return null;
    final target = action["target"]?["entity_id"] ?? action["data"]?["entity_id"];
    return target is List ? (target.isEmpty ? null : "${target.first}") : target as String?;
  }

  List<Widget> _controls(
      BuildContext context, HaService ha, String domain, String entityId, Map<String, dynamic>? state) {
    if (state == null) return [];
    final a = Map<String, dynamic>.from(state["attributes"] ?? {});
    final target = {"entity_id": entityId};
    final on = state["state"] != "off";
    switch (domain) {
      case "climate":
        final step = (a["target_temp_step"] as num?) ?? 1;
        final temp = a["temperature"] as num?;
        final modes = List<String>.from(a["hvac_modes"] ?? []);
        return [
          if (temp != null)
            Row(children: [
              Expanded(
                  child: _PopupButton(
                      label: "−",
                      autofocus: true,
                      onPressed: () => ha.callService("climate", "set_temperature",
                          data: {"temperature": temp - step}, target: target))),
              SizedBox(width: 8),
              SizedBox(
                  width: 90,
                  child: Text("${temp % 1 == 0 ? temp.toInt() : temp}°",
                      textAlign: TextAlign.center, style: TextStyle(fontSize: 26, fontWeight: FontWeight.w600))),
              SizedBox(width: 8),
              Expanded(
                  child: _PopupButton(
                      label: "+",
                      onPressed: () => ha.callService("climate", "set_temperature",
                          data: {"temperature": temp + step}, target: target))),
            ]),
          SizedBox(height: 8),
          Wrap(spacing: 8, runSpacing: 8, children: [
            for (final m in modes)
              _PopupButton(
                  label: m == "heat_cool" ? "Auto" : m[0].toUpperCase() + m.substring(1).replaceAll("_", " "),
                  selected: state["state"] == m,
                  compact: true,
                  onPressed: () => ha.callService("climate", "set_hvac_mode", data: {"hvac_mode": m}, target: target)),
          ]),
        ];
      case "light":
        final pct = a["brightness"] == null ? 0 : (a["brightness"] * 100 / 255).round();
        return [
          Wrap(spacing: 8, runSpacing: 8, children: [
            for (final p in [25, 50, 75, 100])
              _PopupButton(
                  label: "$p%",
                  compact: true,
                  selected: on && (pct - p).abs() < 8,
                  onPressed: () => ha.callService("light", "turn_on", data: {"brightness_pct": p}, target: target)),
            _PopupButton(
                label: "Off",
                compact: true,
                selected: !on,
                onPressed: () => ha.callService("light", "turn_off", target: target)),
          ]),
        ];
      case "fan":
        final count = ((a["speed_count"] as num?) ?? 3).toInt().clamp(1, 10);
        final current = (a["percentage"] as num?) ?? 0;
        return [
          Wrap(spacing: 8, runSpacing: 8, children: [
            for (var i = 1; i <= count; i++)
              _PopupButton(
                  label: "Speed $i",
                  compact: true,
                  selected: on && (current - 100 * i / count).abs() < 100 / count / 2,
                  onPressed: () =>
                      ha.callService("fan", "set_percentage", data: {"percentage": (100 * i / count).round()}, target: target)),
            _PopupButton(
                label: "Off",
                compact: true,
                selected: !on,
                onPressed: () => ha.callService("fan", "turn_off", target: target)),
          ]),
        ];
      default:
        return [];
    }
  }
}

class _PopupButton extends StatefulWidget {
  final String label;
  final VoidCallback onPressed;
  final bool selected;
  final bool autofocus;
  final bool compact;

  _PopupButton(
      {required this.label, required this.onPressed, this.selected = false, this.autofocus = false, this.compact = false});

  @override
  State<_PopupButton> createState() => _PopupButtonState();
}

class _PopupButtonState extends State<_PopupButton> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) => InkWell(
        autofocus: widget.autofocus,
        onFocusChange: (f) => setState(() => _focused = f),
        onTap: widget.onPressed,
        focusColor: Colors.transparent,
        borderRadius: BorderRadius.circular(12),
        child: AnimatedContainer(
          duration: Duration(milliseconds: 120),
          padding: EdgeInsets.symmetric(horizontal: widget.compact ? 16 : 18, vertical: 12),
          decoration: BoxDecoration(
            color: _focused
                ? Colors.white
                : widget.selected
                    ? Color(0x3DFFC85A)
                    : Color(0x14FFFFFF),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Row(mainAxisSize: widget.compact ? MainAxisSize.min : MainAxisSize.max, children: [
            Text(widget.label,
                style: TextStyle(
                    fontSize: 16, fontWeight: FontWeight.w500, color: _focused ? Colors.black : Colors.white)),
            if (widget.selected && !widget.compact) ...[
              Spacer(),
              Icon(Icons.check, size: 18, color: _focused ? Colors.black : Colors.amberAccent),
            ],
          ]),
        ),
      );
}
