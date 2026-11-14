import 'dart:convert';
import 'dart:io';

import 'package:flauncher/ha/ha_config.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory dir;
  late HaConfigStore store;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp("couchdash");
    store = HaConfigStore(dir: () async => dir);
    await File("${dir.path}/ha.json").writeAsString(jsonEncode({"url": "http://ha:8123", "refresh_token": "r", "client_id": "c"}));
  });

  tearDown(() => dir.delete(recursive: true));

  test("shortcuts are stored next to the credentials and can be removed again", () async {
    await store.update({
      "shortcuts": {
        "menu_long": {"type": "script", "entity_id": "script.goodnight", "name": "Goodnight"}
      }
    });
    var config = (await store.read())!;
    expect(config["shortcuts"]["menu_long"]["entity_id"], "script.goodnight");
    expect(config["refresh_token"], "r", reason: "update() merges, credentials stay");

    await store.update({
      "shortcuts": {
        "menu_long": {"type": "event"}
      }
    });
    config = (await store.read())!;
    expect(config["shortcuts"], {
      "menu_long": {"type": "event"}
    });

    await store.update({"shortcuts": null});
    config = (await store.read())!;
    expect(config.containsKey("shortcuts"), isFalse);
    expect(config["url"], "http://ha:8123");
  });

  test("new credentials keep the shortcuts", () async {
    await store.update({
      "shortcuts": {
        "menu_long": {"type": "scene", "entity_id": "scene.movie"}
      }
    });
    await store.saveCredentials("http://ha2:8123/", token: "llat");
    final config = (await store.read())!;
    expect(config["shortcuts"]["menu_long"]["entity_id"], "scene.movie");
    expect(config["token"], "llat");
    expect(config.containsKey("refresh_token"), isFalse);
    expect(config["url"], "http://ha2:8123");
  });
}
