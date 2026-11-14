import 'package:flauncher/ha/ha_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test("dashboard button cards become native shortcuts", () {
    expect(
        HaService.shortcutFromCard({
          "type": "button",
          "name": "Netflix",
          "entity": "light.living_room_tv_area",
          "tap_action": {"action": "toggle"},
        }, states: {
          "light.living_room_tv_area": {
            "attributes": {"friendly_name": "Living room lights"}
          }
        }),
        {
          "type": "service",
          "domain": "homeassistant",
          "service": "toggle",
          "data": {"entity_id": "light.living_room_tv_area"},
          "name": "Toggle Living room lights",
        });

    expect(
        HaService.shortcutFromCard({
          "type": "button",
          "name": "Menu hold",
          "tap_action": {
            "action": "perform-action",
            "perform_action": "script.turn_on",
            "target": {"entity_id": "script.goodnight"},
          },
        }),
        {
          "type": "service",
          "domain": "script",
          "service": "turn_on",
          "data": {"entity_id": "script.goodnight"},
          "name": "script.goodnight",
        });

    expect(
        HaService.shortcutFromCard({
          "type": "button",
          "name": "Netflix hold",
          "tap_action": {"action": "assist", "pipeline_id": "01abc"},
        }),
        {"type": "ask", "pipeline_id": "01abc", "name": "Ask Home Assistant"});

    // a button card without tap_action toggles its entity, like in HA
    expect(HaService.shortcutFromCard({"type": "button", "name": "Netflix", "entity": "switch.fan"})?["service"], "toggle");
    expect(HaService.shortcutFromCard({"type": "button", "name": "Menu hold", "tap_action": {"action": "none"}}), isNull);
    expect(HaService.shortcutFromCard({"type": "button", "name": "Menu hold", "tap_action": {"action": "more-info"}}),
        isNull);
  });

  test("trigger names", () {
    expect(HaService.remoteTriggers["netflix"], "netflix_short");
    expect(HaService.remoteTriggers["netflix hold"], "netflix_long");
    expect(HaService.remoteTriggers["menu hold"], "menu_long");
    expect(HaService.remoteTriggers["menu double"], "menu_double");
  });
}
