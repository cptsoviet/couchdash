/*
 * FLauncher
 * Copyright (C) 2021  Étienne Fesser
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program.  If not, see <https://www.gnu.org/licenses/>.
 */

import 'dart:async';

import 'package:flutter/services.dart';

class FLauncherChannel {
  static const _methodChannel = MethodChannel('me.efesser.flauncher/method');
  static const _eventChannel = EventChannel('me.efesser.flauncher/event');

  Future<List<dynamic>> getApplications() async => (await _methodChannel.invokeListMethod('getApplications'))!;

  Future<bool> applicationExists(String packageName) async =>
      await _methodChannel.invokeMethod('applicationExists', packageName);

  Future<void> launchApp(String packageName) async => await _methodChannel.invokeMethod('launchApp', packageName);

  Future<void> openSettings() async => await _methodChannel.invokeMethod('openSettings');

  Future<void> openAppInfo(String packageName) async => await _methodChannel.invokeMethod('openAppInfo', packageName);

  Future<void> uninstallApp(String packageName) async => await _methodChannel.invokeMethod('uninstallApp', packageName);

  /// CouchDash: the notification service re-reads ha.json (after the setup flow saved new credentials)
  Future<void> restartHaNotify() async => await _methodChannel.invokeMethod('restartHaNotify');

  /// CouchDash: the overlay permission HA notifications need ("Display over other apps")
  Future<bool> canDrawOverlays() async => await _methodChannel.invokeMethod('canDrawOverlays');

  /// false when this TV has no such settings screen
  Future<bool> openOverlaySettings() async => await _methodChannel.invokeMethod('openOverlaySettings');

  /// CouchDash: the accessibility service that sees remote buttons in every app (HaButtonService):
  /// "on", "off", or "stuck" (switched on but not running until it's turned off and on, e.g. after an app update)
  Future<String> buttonServiceState() async => await _methodChannel.invokeMethod('buttonServiceState');

  /// false when this TV has no accessibility settings screen
  Future<bool> openAccessibilitySettings() async => await _methodChannel.invokeMethod('openAccessibilitySettings');

  /// runs the remote shortcut stored in ha.json under [key] (native side, same code as the accessibility service)
  Future<void> runShortcut(String key, String button, String press) async =>
      await _methodChannel.invokeMethod('runShortcut', {"key": key, "button": button, "press": press});

  Future<bool> isDefaultLauncher() async => await _methodChannel.invokeMethod('isDefaultLauncher');

  Future<bool> checkForGetContentAvailability() async =>
      await _methodChannel.invokeMethod("checkForGetContentAvailability");

  Future<void> startAmbientMode() async => await _methodChannel.invokeMethod("startAmbientMode");

  void addAppsChangedListener(void Function(Map<dynamic, dynamic>) listener) =>
      _eventChannel.receiveBroadcastStream().listen((event) => listener(event));
}
