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
    return Column(children: [
      Text("Mood wallpaper", style: Theme.of(context).textTheme.titleLarge),
      Divider(),
      Expanded(
        child: ListView(children: [
          Padding(padding: EdgeInsets.fromLTRB(8, 4, 8, 4), child: Text("Wallpaper", style: header)),
          for (final g in FLauncherGradients.all)
            RadioListTile<String>(
              dense: true,
              autofocus: g.uuid == mood.uuid,
              value: g.uuid,
              groupValue: mood.uuid,
              title: Text(g.name),
              onChanged: (v) => settings.setMoodGradientUuid(v!),
            ),
          Padding(padding: EdgeInsets.fromLTRB(8, 12, 8, 4), child: Text("Fade", style: header)),
          for (final ms in [1000, 2000, 3000, 5000])
            RadioListTile<int>(
              dense: true,
              value: ms,
              groupValue: settings.moodFadeMs,
              title: Text("${ms ~/ 1000} s"),
              onChanged: (v) => settings.setMoodFadeMs(v!),
            ),
          Padding(padding: EdgeInsets.fromLTRB(8, 12, 8, 4), child: Text("Show it while this is on", style: header)),
          RadioListTile<String?>(
            dense: true,
            value: null,
            groupValue: current,
            title: Text("Never (off)"),
            onChanged: (_) => settings.setMoodEntity(null),
          ),
          if (!ha.connected) Padding(padding: EdgeInsets.all(8), child: Text("Home Assistant not connected")),
          for (final id in candidates)
            RadioListTile<String?>(
              dense: true,
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
