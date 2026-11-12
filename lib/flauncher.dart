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

import 'dart:typed_data';
import 'dart:ui';

import 'package:flauncher/custom_traversal_policy.dart';
import 'package:flauncher/database.dart';
import 'package:flauncher/providers/settings_service.dart';
import 'package:flauncher/ha/ha_service.dart';
import 'package:flauncher/ha/ha_panel.dart';
import 'package:flauncher/gradients.dart';
import 'package:flauncher/providers/apps_service.dart';
import 'package:flauncher/providers/wallpaper_service.dart';
import 'package:flauncher/widgets/apps_grid.dart';
import 'package:flauncher/widgets/category_row.dart';
import 'package:flauncher/widgets/settings/settings_panel.dart';
import 'package:flauncher/widgets/time_widget.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

class FLauncher extends StatelessWidget {
  @override
  Widget build(BuildContext context) => FocusTraversalGroup(
        policy: RowByRowTraversalPolicy(),
        child: Stack(
          children: [
            Builder(builder: _background),
            Scaffold(
              backgroundColor: Colors.transparent,
              appBar: _appBar(context),
              body: Padding(
                padding: EdgeInsets.fromLTRB(40, 8, 40, 0),
                child: Consumer<AppsService>(
                  builder: (context, appsService, _) => appsService.initialized
                      ? SingleChildScrollView(
                          child: Column(children: [HaPanel(), _categories(appsService.categoriesWithApps)]))
                      : _emptyState(context),
                ),
              ),
            ),
          ],
        ),
      );

  // kronie-ha fork: AT4K-style layout - no category titles, first category sits in a rounded "dock"
  Widget _categories(List<CategoryWithApps> categoriesWithApps) => Column(
        children: [
          for (var i = 0; i < categoriesWithApps.length; i++)
            i == 0 ? _dock(_category(categoriesWithApps[i])) : _category(categoriesWithApps[i]),
        ],
      );

  Widget _dock(Widget child) => Container(
        margin: EdgeInsets.symmetric(vertical: 8),
        padding: EdgeInsets.symmetric(vertical: 4),
        decoration: BoxDecoration(
          color: Color(0x14FFFFFF),
          borderRadius: BorderRadius.circular(24),
          border: Border.all(color: Color(0x14FFFFFF)),
        ),
        child: child,
      );

  Widget _category(CategoryWithApps categoryWithApps) {
    switch (categoryWithApps.category.type) {
      case CategoryType.row:
        return Padding(
          padding: EdgeInsets.symmetric(vertical: 8),
          child: CategoryRow(
              key: Key(categoryWithApps.category.id.toString()),
              category: categoryWithApps.category,
              applications: categoryWithApps.applications,
              showTitle: false),
        );
      case CategoryType.grid:
        return Padding(
          padding: EdgeInsets.symmetric(vertical: 8),
          child: AppsGrid(
              key: Key(categoryWithApps.category.id.toString()),
              category: categoryWithApps.category,
              applications: categoryWithApps.applications,
              showTitle: false),
        );
    }
  }

  // AT4K-style status pill, top right: clock + settings
  PreferredSizeWidget _appBar(BuildContext context) => PreferredSize(
        preferredSize: Size.fromHeight(80),
        child: SafeArea(
          child: Align(
            alignment: Alignment.topRight,
            child: Container(
              margin: EdgeInsets.only(top: 20, right: 40),
              padding: EdgeInsets.symmetric(horizontal: 20, vertical: 6),
              decoration: BoxDecoration(color: Color(0x66000000), borderRadius: BorderRadius.circular(28)),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TimeWidget(),
                  SizedBox(width: 20),
                  IconButton(
                    padding: EdgeInsets.all(4),
                    constraints: BoxConstraints(),
                    splashRadius: 20,
                    icon: Icon(Icons.settings),
                    onPressed: () => showDialog(context: context, builder: (_) => SettingsPanel()),
                  ),
                ],
              ),
            ),
          ),
        ),
      );

  // kronie-ha fork: normal wallpaper, or the mood wallpaper while its HA entity is "on"; crossfades between them
  Widget _background(BuildContext context) {
    final wallpaper = context.watch<WallpaperService>();
    final settings = context.watch<SettingsService>();
    final moodEntity = settings.moodEntity;
    final moodState = context.select<HaService, String?>((ha) => moodEntity == null ? null : ha.states[moodEntity]?["state"]);
    final Widget child;
    if (moodState == "on") {
      final mood = FLauncherGradients.byUuid(settings.moodGradientUuid);
      child = KeyedSubtree(key: ValueKey("mood-${mood.uuid}"), child: mood.background());
    } else {
      final bytes = wallpaper.wallpaperBytes;
      child = KeyedSubtree(
        key: ValueKey(bytes != null ? "image-${identityHashCode(bytes)}" : "gradient-${wallpaper.gradient.uuid}"),
        child: _wallpaper(context, bytes, wallpaper.gradient),
      );
    }
    return AnimatedSwitcher(
      duration: Duration(milliseconds: settings.moodFadeMs),
      layoutBuilder: (current, previous) =>
          Stack(fit: StackFit.expand, children: [...previous, if (current != null) current]),
      child: child,
    );
  }

  Widget _wallpaper(BuildContext context, Uint8List? wallpaperImage, FLauncherGradient gradient) => wallpaperImage != null
      ? Image.memory(
          wallpaperImage,
          key: Key("background"),
          fit: BoxFit.cover,
          height: window.physicalSize.height,
          width: window.physicalSize.width,
        )
      : gradient.background(key: Key("background"));

  Widget _emptyState(BuildContext context) => Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            CircularProgressIndicator(),
            SizedBox(height: 16),
            Text("Loading...", style: Theme.of(context).textTheme.titleLarge),
          ],
        ),
      );
}
