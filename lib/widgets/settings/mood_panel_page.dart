/*
 * kronie-ha fork: Settings -> Wallpaper -> Mood wallpaper.
 * Crossfades to a second background while the chosen HA entity is "on".
 */

import 'package:flauncher/gradients.dart';
import 'package:flauncher/ha/ha_service.dart';
import 'package:flauncher/providers/settings_service.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

class MoodPanelPage extends StatelessWidget {
  static const String routeName = "mood_panel";
  static const _triggerDomains = ["binary_sensor", "input_boolean", "switch", "light"];

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<SettingsService>();
    final ha = context.watch<HaService>();
    final candidates = ha.states.keys.where((id) => _triggerDomains.contains(id.split(".").first)).toList()
      ..sort((a, b) => _label(ha, a).toLowerCase().compareTo(_label(ha, b).toLowerCase()));
    final current = settings.moodEntity;
    if (current != null && !candidates.contains(current)) candidates.insert(0, current);
    final mood = FLauncherGradients.byUuid(settings.moodGradientUuid);
    TextStyle? header = Theme.of(context).textTheme.titleSmall?.copyWith(color: Colors.white60);
    final triggerState = current == null ? null : ha.states[current]?["state"];
    final status = current == null
        ? "No trigger chosen: the normal wallpaper always shows."
        : "Trigger: ${_label(ha, current)} is ${triggerState ?? "unknown"}"
            "${triggerState == "on" ? " → showing ${mood.name}" : " → showing the normal wallpaper"}";
    return Column(children: [
      Text("Mood wallpaper", style: Theme.of(context).textTheme.titleLarge),
      Divider(),
      Container(
        width: double.infinity,
        margin: EdgeInsets.only(bottom: 8),
        padding: EdgeInsets.all(10),
        decoration: BoxDecoration(color: Color(0x26000000), borderRadius: BorderRadius.circular(10)),
        child: Text(status, style: TextStyle(fontSize: 13)),
      ),
      Expanded(
        child: ListView(children: [
          Padding(padding: EdgeInsets.fromLTRB(8, 4, 8, 4), child: Text("Wallpaper", style: header)),
          for (final g in FLauncherGradients.all)
            _Choice<String>(
              autofocus: g.uuid == mood.uuid,
              value: g.uuid,
              groupValue: mood.uuid,
              title: Text(g.name),
              onChanged: (v) => settings.setMoodGradientUuid(v!),
            ),
          Padding(padding: EdgeInsets.fromLTRB(8, 12, 8, 4), child: Text("Fade", style: header)),
          for (final ms in [1000, 2000, 3000, 5000])
            _Choice<int>(
              value: ms,
              groupValue: settings.moodFadeMs,
              title: Text("${ms ~/ 1000} s"),
              onChanged: (v) => settings.setMoodFadeMs(v!),
            ),
          Padding(padding: EdgeInsets.fromLTRB(8, 12, 8, 4), child: Text("Show it while this is on", style: header)),
          _Choice<String?>(
            value: null,
            groupValue: current,
            title: Text("Never (off)"),
            onChanged: (_) => settings.setMoodEntity(null),
          ),
          if (!ha.connected) Padding(padding: EdgeInsets.all(8), child: Text("Home Assistant not connected")),
          for (final id in candidates)
            _Choice<String?>(
              value: id,
              groupValue: current,
              title: Text(_label(ha, id)),
              subtitle: Text("$id · ${ha.states[id]?["state"] ?? "?"}"),
              onChanged: (v) => settings.setMoodEntity(v),
            ),
        ]),
      ),
    ]);
  }

  String _label(HaService ha, String id) => "${ha.states[id]?["attributes"]?["friendly_name"] ?? id}";
}

/// Radio row with a clearly visible focus highlight (RadioListTile shows none on this theme).
class _Choice<T> extends StatefulWidget {
  final T value;
  final T groupValue;
  final Widget title;
  final Widget? subtitle;
  final bool autofocus;
  final ValueChanged<T?> onChanged;

  _Choice({
    required this.value,
    required this.groupValue,
    required this.title,
    this.subtitle,
    this.autofocus = false,
    required this.onChanged,
  });

  @override
  State<_Choice<T>> createState() => _ChoiceState<T>();
}

class _ChoiceState<T> extends State<_Choice<T>> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final selected = widget.value == widget.groupValue;
    final fg = _focused ? Colors.black : Colors.white;
    return Padding(
      padding: EdgeInsets.symmetric(vertical: 2),
      child: InkWell(
        autofocus: widget.autofocus,
        focusColor: Colors.transparent,
        borderRadius: BorderRadius.circular(10),
        onFocusChange: (f) {
          setState(() => _focused = f);
          if (f) Scrollable.ensureVisible(context, alignment: 0.5, duration: Duration(milliseconds: 120));
        },
        onTap: () => widget.onChanged(widget.value),
        child: AnimatedContainer(
          duration: Duration(milliseconds: 100),
          padding: EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          decoration: BoxDecoration(
            color: _focused ? Colors.white : Colors.transparent,
            borderRadius: BorderRadius.circular(10),
          ),
          child: Row(children: [
            Icon(selected ? Icons.radio_button_checked : Icons.radio_button_unchecked,
                size: 20, color: _focused ? Colors.black : (selected ? Colors.cyanAccent : Colors.white70)),
            SizedBox(width: 12),
            Expanded(
              child: DefaultTextStyle.merge(
                style: TextStyle(color: fg),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  DefaultTextStyle.merge(style: TextStyle(fontSize: 15), child: widget.title),
                  if (widget.subtitle != null)
                    DefaultTextStyle.merge(
                        style: TextStyle(fontSize: 11, color: _focused ? Colors.black54 : Colors.white54),
                        child: widget.subtitle!),
                ]),
              ),
            ),
          ]),
        ),
      ),
    );
  }
}
