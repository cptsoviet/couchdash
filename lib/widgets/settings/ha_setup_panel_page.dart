/*
 * CouchDash: Settings -> Home Assistant setup.
 * Not connected: a QR code for the phone setup page (ha/setup_server.dart); the server only runs while it's shown.
 * Connected: status, notifications on/off (with the overlay-permission prompt), device name, remote shortcuts (with
 * the accessibility-service prompt), connect again.
 */

import 'package:flauncher/flauncher_channel.dart';
import 'package:flauncher/ha/ha_service.dart';
import 'package:flauncher/ha/ha_config.dart';
import 'package:flauncher/ha/setup_server.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:qr_flutter/qr_flutter.dart';

class HaSetupPanelPage extends StatefulWidget {
  static const String routeName = "ha_setup_panel";

  @override
  State<HaSetupPanelPage> createState() => _HaSetupPanelPageState();
}

class _HaSetupPanelPageState extends State<HaSetupPanelPage> {
  late bool _setup = !context.read<HaService>().configured;

  @override
  Widget build(BuildContext context) => _setup
      ? _SetupView(onDone: () => setState(() => _setup = false))
      : _HaSettingsView(onConnectAgain: () => setState(() => _setup = true));
}

class _SetupView extends StatefulWidget {
  final VoidCallback onDone;

  const _SetupView({required this.onDone});

  @override
  State<_SetupView> createState() => _SetupViewState();
}

class _SetupViewState extends State<_SetupView> {
  late final SetupServer _server;
  bool? _started;

  @override
  void initState() {
    super.initState();
    final ha = context.read<HaService>();
    _server = SetupServer(ha.configStore, onSaved: () async {
      await ha.reload();
      await FLauncherChannel().restartHaNotify().catchError((_) {});
    });
    _server.start().then((ok) {
      if (mounted) setState(() => _started = ok);
    }, onError: (_) {
      if (mounted) setState(() => _started = false);
    });
  }

  @override
  void dispose() {
    _server.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ha = context.watch<HaService>();
    final small = Theme.of(context).textTheme.bodySmall?.copyWith(color: Colors.white70);
    return ListenableBuilder(
      listenable: _server,
      builder: (context, _) {
        final Widget body;
        if (_started == null) {
          body = Center(child: CircularProgressIndicator());
        } else if (_started == false) {
          body = Text("This TV has no network address. Connect it to your network first.");
        } else if (_server.status == SetupStatus.done) {
          body = Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text("Connected to ${_server.savedUrl}", style: Theme.of(context).textTheme.bodyMedium),
            SizedBox(height: 8),
            Text(ha.connected ? "Home Assistant is online." : (ha.error ?? "Connecting..."), style: small),
            SizedBox(height: 16),
            TextButton(autofocus: true, onPressed: widget.onDone, child: Text("Done")),
          ]);
        } else {
          body = Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text("Scan with your phone", style: Theme.of(context).textTheme.bodyMedium),
            SizedBox(height: 12),
            Center(
              child: Container(
                color: Colors.white,
                padding: EdgeInsets.all(8),
                child: QrImageView(data: _server.pageUrl!, size: 180, padding: EdgeInsets.zero),
              ),
            ),
            SizedBox(height: 12),
            Text("or open ${_server.pageUrl}", style: small),
            SizedBox(height: 12),
            Text(
              _server.status == SetupStatus.phoneConnected
                  ? "Phone connected: finish on the phone."
                  : "The phone must be on the same network as this TV.",
              style: small,
            ),
            if (ha.configured) ...[
              SizedBox(height: 12),
              Text("Currently connected to ${ha.url}; finishing setup replaces that login.", style: small),
            ],
            // something focusable, so the remote's back button has a home on this page
            TextButton(
                autofocus: true,
                onPressed: ha.configured ? widget.onDone : () => Navigator.of(context).pop(),
                child: Text("Cancel")),
          ]);
        }
        return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text("Home Assistant", style: Theme.of(context).textTheme.titleLarge),
          Divider(),
          Expanded(child: SingleChildScrollView(child: body)),
        ]);
      },
    );
  }
}

class _HaSettingsView extends StatefulWidget {
  final VoidCallback onConnectAgain;

  const _HaSettingsView({required this.onConnectAgain});

  @override
  State<_HaSettingsView> createState() => _HaSettingsViewState();
}

class _HaSettingsViewState extends State<_HaSettingsView> with WidgetsBindingObserver {
  static const defaultDeviceName = "Living Room TV";
  final _channel = FLauncherChannel();
  late final HaConfigStore _store = context.read<HaService>().configStore;

  bool _notifications = false;
  String _deviceName = defaultDeviceName;
  bool? _canOverlay;
  bool _noOverlayScreen = false;
  bool _noAccessibilityScreen = false;
  bool _micAllowed = true; // checked on load and on return from Android's permission prompt

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _load();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  // back from Android's "Display over other apps" screen
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _checkOverlay();
      _checkMic();
    }
  }

  Future<void> _load() async {
    final config = await _store.read() ?? {};
    if (!mounted) return;
    setState(() {
      _notifications = config["notifications"] == true;
      final name = config["device_name"];
      _deviceName = name is String && name.trim().isNotEmpty ? name : defaultDeviceName;
    });
    await _checkOverlay();
    await _checkMic();
  }

  Future<void> _checkOverlay() async {
    final can = await _channel.canDrawOverlays().catchError((_) => false);
    if (mounted) setState(() => _canOverlay = can);
  }

  Future<void> _apply(Map<String, dynamic> changes) async {
    await _store.update(changes);
    await _channel.restartHaNotify().catchError((_) {});
  }

  Future<void> _setNotifications(bool on) async {
    setState(() => _notifications = on);
    await _apply({"notifications": on});
    if (on && _canOverlay == false) await _openOverlaySettings();
  }

  Future<void> _openOverlaySettings() async {
    final opened = await _channel.openOverlaySettings().catchError((_) => false);
    if (mounted) setState(() => _noOverlayScreen = !opened);
  }

  Future<void> _editDeviceName() async {
    final controller = TextEditingController(text: _deviceName);
    final name = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text("Device name"),
        content: TextField(
          controller: controller,
          autofocus: true,
          textInputAction: TextInputAction.done,
          onSubmitted: (value) => Navigator.of(context).pop(value),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(), child: Text("Cancel")),
          TextButton(onPressed: () => Navigator.of(context).pop(controller.text), child: Text("Save")),
        ],
      ),
    );
    final trimmed = name?.trim();
    if (trimmed == null || trimmed.isEmpty || trimmed == _deviceName) return;
    setState(() => _deviceName = trimmed);
    await _apply({"device_name": trimmed});
  }

  static String _shortcutLabel(Map<String, dynamic>? shortcut) => switch (shortcut?["type"]) {
        "script" || "scene" => "${shortcut!["name"] ?? shortcut["entity_id"]}",
        "service" => "${shortcut!["name"] ?? "${shortcut["domain"]}.${shortcut["service"]}"}",
        "event" => "Send event to Home Assistant",
        "ask" => "Ask Home Assistant (voice)",
        _ => "Nothing",
      };

  // [key]: "menu_long" / "menu_double"; [press]: what the couchdash_button event reports
  Future<void> _pickShortcut(String key, String title, String press) async {
    final ha = context.read<HaService>();
    // scripts and scenes this HA user can see, by name
    final runnable = ha.states.values
        .where((s) => "${s["entity_id"]}".startsWith("script.") || "${s["entity_id"]}".startsWith("scene."))
        .map((s) => (id: "${s["entity_id"]}", name: "${s["attributes"]?["friendly_name"] ?? s["entity_id"]}"))
        .toList()
      ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    final current = key == "menu_double" ? ha.menuDoubleShortcut : ha.menuLongShortcut;
    // dialogContext: the popup's own navigator (the settings panel has a nested one; popping that closed the page)
    Widget option(BuildContext dialogContext, String label, Map<String, dynamic>? value, {String? subtitle}) {
      final selected = value?["type"] == current?["type"] && value?["entity_id"] == current?["entity_id"];
      return SimpleDialogOption(
        onPressed: () => Navigator.of(dialogContext).pop({"value": value}),
        child: Row(children: [
          Icon(selected ? Icons.radio_button_checked : Icons.radio_button_unchecked, size: 18),
          SizedBox(width: 10),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(label),
              if (subtitle != null) Text(subtitle, style: TextStyle(fontSize: 12, color: Colors.white60)),
            ]),
          ),
        ]),
      );
    }

    final picked = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (context) => SimpleDialog(
        title: Text(title),
        children: [
          option(context, "Nothing", null),
          option(context, "Ask Home Assistant (voice)", {"type": "ask"},
              subtitle: "speak a question or command; your Assist agent answers"),
          option(context, "Send event to Home Assistant", {"type": "event"},
              subtitle: "couchdash_button (button: menu, press: $press) for your automations"),
          for (final r in runnable)
            option(context, r.name, {"type": r.id.split(".").first, "entity_id": r.id, "name": r.name}, subtitle: r.id),
        ],
      ),
    );
    if (picked == null) return; // dialog dismissed
    final config = await _store.read() ?? {};
    final shortcuts = Map<String, dynamic>.from(config["shortcuts"] as Map? ?? {});
    if (picked["value"] == null) {
      shortcuts.remove(key);
    } else {
      shortcuts[key] = picked["value"];
    }
    await _store.update({"shortcuts": shortcuts.isEmpty ? null : shortcuts});
    ha.readShortcuts(await _store.read() ?? {});
    if (picked["value"]?["type"] == "ask") await _checkMic();
  }

  Future<void> _checkMic() async {
    final allowed = await _channel.micAllowed().catchError((_) => false);
    if (mounted) setState(() => _micAllowed = allowed);
  }

  Widget _shortcutRow(String label, Map<String, dynamic>? shortcut, VoidCallback onPressed, IconData icon) =>
      TextButton(
        onPressed: onPressed,
        child: Row(children: [
          Icon(icon),
          Container(width: 8),
          Expanded(child: Text("$label: ${_shortcutLabel(shortcut)}", style: Theme.of(context).textTheme.bodyMedium)),
        ]),
      );

  Future<void> _openAccessibilitySettings() async {
    final opened = await _channel.openAccessibilitySettings().catchError((_) => false);
    if (mounted) setState(() => _noAccessibilityScreen = !opened);
  }

  @override
  Widget build(BuildContext context) {
    final ha = context.watch<HaService>();
    final small = Theme.of(context).textTheme.bodySmall?.copyWith(color: Colors.white70);
    final status = ha.connected ? "Connected to ${ha.url}" : (ha.error ?? "Connecting to ${ha.url}...");
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text("Home Assistant", style: Theme.of(context).textTheme.titleLarge),
      Divider(),
      Expanded(
        child: SingleChildScrollView(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Container(
              width: double.infinity,
              padding: EdgeInsets.all(10),
              decoration: BoxDecoration(color: Color(0x26000000), borderRadius: BorderRadius.circular(10)),
              child: Text(status, style: TextStyle(fontSize: 13)),
            ),
            SwitchListTile(
              autofocus: true,
              value: _notifications,
              onChanged: _setNotifications,
              title: Text("Notifications", style: Theme.of(context).textTheme.bodyMedium),
              subtitle: Text("Show Home Assistant notifications over any app", style: small),
              dense: true,
            ),
            if (_notifications && _canOverlay == false) ...[
              Padding(
                padding: EdgeInsets.symmetric(horizontal: 16),
                child: Text(
                  _noOverlayScreen
                      ? "Notifications need permission to appear over other apps. This TV has no shortcut to it: "
                          "open Settings > Apps > Special app access > Display over other apps, and allow CouchDash."
                      : "Notifications need permission to appear over other apps: allow CouchDash in the list.",
                  style: small?.copyWith(color: Colors.amberAccent),
                ),
              ),
              if (!_noOverlayScreen) TextButton(onPressed: _openOverlaySettings, child: Text("Open settings")),
            ],
            TextButton(
              onPressed: _editDeviceName,
              child: Row(children: [
                Icon(Icons.tv_outlined),
                Container(width: 8),
                Expanded(child: Text("Device name: $_deviceName", style: Theme.of(context).textTheme.bodyMedium)),
              ]),
            ),
            Padding(
              padding: EdgeInsets.symmetric(horizontal: 16),
              child: Text("The name this TV has in Home Assistant (notify.mobile_app_...).", style: small),
            ),
            Divider(),
            Padding(
              padding: EdgeInsets.symmetric(horizontal: 16, vertical: 4),
              child: Text("Remote shortcuts",
                  style: Theme.of(context).textTheme.titleSmall?.copyWith(color: Colors.white60)),
            ),
            if (ha.remoteButtons != null) ...[
              // assigned in the dashboard ("Remote buttons" cards): shown here, changed in HA
              Padding(
                padding: EdgeInsets.symmetric(horizontal: 16),
                child: Text("Set in Home Assistant: \"Remote buttons\" cards in the TV dashboard.", style: small),
              ),
              for (final e in const {
                "netflix_short": "Netflix",
                "netflix_long": "Hold Netflix",
                "menu_long": "Hold Menu",
                "menu_double": "Press Menu twice",
              }.entries)
                if (ha.remoteButtons![e.key] != null)
                  Padding(
                    padding: EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                    child: Text("${e.value}: ${_shortcutLabel(Map<String, dynamic>.from(ha.remoteButtons![e.key]))}",
                        style: Theme.of(context).textTheme.bodyMedium),
                  ),
            ] else ...[
              _shortcutRow(
                  "Hold Menu", ha.menuLongShortcut, () => _pickShortcut("menu_long", "Hold Menu", "long"), Icons.menu),
              _shortcutRow("Press Menu twice", ha.menuDoubleShortcut,
                  () => _pickShortcut("menu_double", "Press Menu twice", "double"), Icons.keyboard_double_arrow_right),
            ],
            if (!_micAllowed &&
                [...?ha.remoteButtons?.values, ha.menuLongShortcut, ha.menuDoubleShortcut]
                    .any((s) => s is Map && s["type"] == "ask")) ...[
              Padding(
                padding: EdgeInsets.symmetric(horizontal: 16),
                child:
                    Text("Ask Home Assistant needs the microphone.", style: small?.copyWith(color: Colors.amberAccent)),
              ),
              TextButton(onPressed: () => _channel.requestMic().catchError((_) {}), child: Text("Allow microphone")),
            ],
            if (((ha.remoteButtons?.isNotEmpty ?? false) ||
                    ha.menuLongShortcut != null ||
                    ha.menuDoubleShortcut != null) &&
                !ha.buttonServiceEnabled) ...[
              Padding(
                padding: EdgeInsets.symmetric(horizontal: 16),
                child: Text(
                  ha.buttonServiceStuck
                      // Android 11 parks the service after the app was updated or force-stopped
                      ? "Android stopped CouchDash remote buttons (it does after an update). Turn it off and on again: "
                          "Settings > Device Preferences > Accessibility > CouchDash remote buttons."
                      : _noAccessibilityScreen
                          ? "Allow CouchDash to see remote buttons, so this works in every app (now only on this screen): "
                              "Settings > Device Preferences > Accessibility > CouchDash remote buttons."
                          : "Allow CouchDash to see remote buttons, so this works in every app (now only on this screen).",
                  style: small?.copyWith(color: Colors.amberAccent),
                ),
              ),
              _noAccessibilityScreen
                  // no direct link on this TV (e.g. the Shield): open Android settings at the top, the text has the path
                  ? TextButton(
                      onPressed: () => _channel.openSettings().catchError((_) {}), child: Text("Open Android settings"))
                  : TextButton(onPressed: _openAccessibilitySettings, child: Text("Open settings")),
            ],
            Divider(),
            TextButton(
              onPressed: widget.onConnectAgain,
              child: Row(children: [
                Icon(Icons.qr_code),
                Container(width: 8),
                Text("Connect again", style: Theme.of(context).textTheme.bodyMedium),
              ]),
            ),
          ]),
        ),
      ),
    ]);
  }
}
