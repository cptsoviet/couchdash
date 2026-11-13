/*
 * CouchDash: Settings -> Home Assistant setup.
 * Shows a QR code for the phone setup page (ha/setup_server.dart); the server only runs while this page is open.
 */

import 'package:flauncher/flauncher_channel.dart';
import 'package:flauncher/ha/ha_service.dart';
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
            TextButton(autofocus: true, onPressed: () => Navigator.of(context).pop(), child: Text("Done")),
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
            TextButton(autofocus: true, onPressed: () => Navigator.of(context).pop(), child: Text("Cancel")),
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
