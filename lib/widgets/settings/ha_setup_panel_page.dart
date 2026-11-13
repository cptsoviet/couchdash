/*
 * CouchDash: Settings -> Home Assistant setup.
 * Not connected: a QR code for the phone setup page (ha/setup_server.dart); the server only runs while it's shown.
 * Connected: status, notifications on/off (with the overlay-permission prompt), device name, connect again.
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
    if (state == AppLifecycleState.resumed) _checkOverlay();
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
