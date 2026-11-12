/*
 * kronie-ha fork: Settings -> Wallpaper -> Wallpaper from Home Assistant.
 * HA picks the wallpaper through input_select.tv_launcher_wallpaper (option = wallpaper name), usually from
 * an automation; the launcher crossfades when it changes. Unknown/missing value -> the local wallpaper.
 */

import 'package:flauncher/gradients.dart';
import 'package:flauncher/ha/ha_service.dart';
import 'package:flauncher/providers/settings_service.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

class MoodPanelPage extends StatelessWidget {
  static const String routeName = "mood_panel";

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<SettingsService>();
    final ha = context.watch<HaService>();
    final value = ha.states[SettingsService.haWallpaperEntity]?["state"] as String?;
    final known = FLauncherGradients.byName(value) != null;
    final status = !settings.haWallpaperEnabled
        ? "Off: the wallpaper set on the TV is always used."
        : !ha.connected
            ? "Home Assistant not connected: using the TV's own wallpaper."
            : value == null
                ? "${SettingsService.haWallpaperEntity} not found in Home Assistant: using the TV's own wallpaper."
                : known
                    ? "Home Assistant says: $value"
                    : "Home Assistant says \"$value\", which isn't a wallpaper name here: using the TV's own wallpaper.";
    final header = Theme.of(context).textTheme.titleSmall?.copyWith(color: Colors.white60);
    return Column(children: [
      Text("HA wallpaper", style: Theme.of(context).textTheme.titleLarge),
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
          _Choice<bool>(
            autofocus: true,
            value: true,
            groupValue: settings.haWallpaperEnabled,
            title: Text("Let Home Assistant choose"),
            onChanged: (_) => settings.setHaWallpaperEnabled(true),
          ),
          _Choice<bool>(
            value: false,
            groupValue: settings.haWallpaperEnabled,
            title: Text("Always use the TV's wallpaper"),
            onChanged: (_) => settings.setHaWallpaperEnabled(false),
          ),
          Padding(padding: EdgeInsets.fromLTRB(8, 12, 8, 4), child: Text("Fade", style: header)),
          for (final ms in [1000, 2000, 3000, 5000])
            _Choice<int>(
              value: ms,
              groupValue: settings.moodFadeMs,
              title: Text("${ms ~/ 1000} s"),
              onChanged: (v) => settings.setMoodFadeMs(v!),
            ),
          Padding(
            padding: EdgeInsets.fromLTRB(8, 16, 8, 8),
            child: Text(
              "Set in HA: ${SettingsService.haWallpaperEntity}, options = wallpaper names "
              "(e.g. Backglow, True Black (OLED)). Change it from automations, your phone or voice.",
              style: TextStyle(fontSize: 11, color: Colors.white54),
            ),
          ),
        ]),
      ),
    ]);
  }
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
