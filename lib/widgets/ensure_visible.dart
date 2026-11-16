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

import 'package:flutter/material.dart';

/// CouchDash: scrolls the page only as far as needed to show [context]'s widget whole, and not at all when it
/// already is (instead of pulling it to a fixed spot). The home screen uses this, so the top of the HA area stays
/// in view on launch while the first app is focused. Revert: pass `alignment` again (rows used 0.1, the grid 0.5,
/// HA tiles Scrollable.ensureVisible with 0.5).
void ensureVisibleMinimally(BuildContext context,
    {Duration duration = const Duration(milliseconds: 150), double margin = 24}) {
  final box = context.findRenderObject();
  // the page's own scroller: the outermost vertical scrollable (app grids inside it don't scroll themselves)
  ScrollableState? page;
  for (var s = Scrollable.maybeOf(context); s != null; s = Scrollable.maybeOf(s.context)) {
    if (s.axisDirection == AxisDirection.down || s.axisDirection == AxisDirection.up) page = s;
  }
  final viewport = page?.context.findRenderObject();
  if (box is! RenderBox || viewport is! RenderBox || !box.hasSize || !viewport.hasSize) return;
  // keep [margin] between the item and the screen edge, also room for the enlarged focused card
  final top = box.localToGlobal(Offset.zero, ancestor: viewport).dy - margin;
  final bottom = top + box.size.height + 2 * margin;
  final position = page!.position;
  final double delta = bottom > viewport.size.height
      ? bottom - viewport.size.height
      : top < 0
          ? top
          : 0;
  // fits on screen with the page at the very top: show the top, so the HA pills (never focusable themselves)
  // come back into view when moving up onto the tiles or the first app row
  if (position.pixels + bottom <= viewport.size.height) {
    if (position.pixels > position.minScrollExtent) {
      position.animateTo(position.minScrollExtent, duration: duration, curve: Curves.easeInOut);
    }
    return;
  }
  if (delta == 0) return; // fully visible already: don't move the page
  final target = (position.pixels + delta).clamp(position.minScrollExtent, position.maxScrollExtent);
  position.animateTo(target, duration: duration, curve: Curves.easeInOut);
}

class EnsureVisible extends StatelessWidget {
  final Widget child;
  final double alignment;
  final bool minimal; // CouchDash: scroll only as far as needed (ensureVisibleMinimally) instead of to [alignment]

  EnsureVisible({Key? key, required this.child, this.alignment = 0.0, this.minimal = false}) : super(key: key);

  @override
  Widget build(BuildContext context) => Focus(
        canRequestFocus: false,
        onFocusChange: (focused) {
          if (focused && minimal) {
            ensureVisibleMinimally(context, duration: Duration(milliseconds: 100));
          } else if (focused) {
            Scrollable.ensureVisible(
              context,
              alignment: alignment,
              duration: Duration(milliseconds: 100),
              curve: Curves.easeInOut,
            );
          }
        },
        child: child,
      );
}
