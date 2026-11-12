# FLauncher HA

An Android TV launcher with a live **Home Assistant** panel above the app list. It is a fork of
[FLauncher](https://gitlab.com/flauncher/flauncher) (GPL-3.0, © Étienne Fesser), restyled after AT4K: dark
backgrounds, a clock pill top-right, and the first app row in a rounded dock.

The HA panel is **driven by an HA dashboard**: you design it in HA's normal dashboard editor and the TV picks up
changes live, with no rebuild. The upstream README is kept as [README.upstream.md](README.upstream.md).

## What it does

- **Top bar** (left of the clock): outdoor weather and AQI, then `Indoors:` temperature, humidity and AQI.
- **Status pills**: e.g. `Front Door: Locked`, with an icon, coloured green when secure and amber when not.
- **Tile row**: lights, fans, climate, locks, switches, scripts, buttons, camera snapshots.
  - **OK** runs the card's `tap_action`.
  - **Holding OK (~0.5 s)** runs its `hold_action`.
  - A tile's default action is HA's `more-info`, which opens a popup with built-in controls:
    - climate: target −/+, modes, on/off
    - light: brightness
    - fan: speed
  - **Custom popup menus**: Button cards stacked after a tile.
  - HA **card visibility** conditions are honoured: time, state, and/or.
- **Wallpaper from HA**: an `input_select` chooses the background. It crossfades when it changes, so HA automations can match the room lights.
- **Removed from upstream**: Firebase analytics, crash reporting and remote config, and Unsplash.

Requirements: Android TV 5.0+ (tested on NVIDIA Shield, Android 11), Home Assistant 2024.x or newer reachable from
the TV over HTTP(S).

---

## 1. Build the APK

Prerequisites: Flutter (stable, Dart 3), Android SDK (platform-tools, a current build-tools/platform), JDK 17.

```sh
git clone <this repo> flauncher-ha && cd flauncher-ha
flutter pub get
flutter build apk --release --target-platform android-arm64     # most TV boxes; use android-arm for 32-bit devices
# -> build/app/outputs/flutter-apk/app-release.apk
```

**Signing:** `android/app/build.gradle.kts` signs release builds with `~/.claude/keys/tv-launcher/signing.keystore`
if it exists. Otherwise it uses your local debug key. Point it at your own keystore if you like.
Always sign updates with the same key: Android refuses to update an app signed with a different key, so you
would have to uninstall (and lose its settings) first.

**Low-memory build hosts:** `android/gradle.properties` caps Gradle at 1.5 GB heap, with the daemon off. Raise it on
a bigger machine for faster builds.

## 2. Install on the TV

1. On the TV, enable **Developer options** (Settings → Device Preferences → About → click *Build* 7 times), then
   turn on **Network debugging** / **USB debugging**.
2. From the build machine:
   ```sh
   adb connect <tv-ip>:5555        # accept the "Allow debugging?" prompt on the TV (tick "always allow")
   adb install -r build/app/outputs/flutter-apk/app-release.apk
   ```
3. The app appears as **FLauncher HA** in the TV's app list. Open it once.

## 3. Link it to Home Assistant

### 3a. HA user and token
1. In HA, create a **non-admin** user for the TV (Settings → People → Users → Add user), e.g. "TV Launcher".
   Allowing local login only is fine.
2. Log in as that user (or ask an admin), go to Profile → Security → **Long-lived access tokens**, and create a token.

### 3b. Config file on the TV
Create `ha.json`:
```json
{ "url": "http://<ha-host>:8123", "token": "<long-lived token>", "dashboard": "tv-launcher" }
```
Push it into the app's own storage. No storage permission is needed for this path:
```sh
adb shell mkdir -p /sdcard/Android/data/net.kronie.flauncher/files
adb push ha.json /sdcard/Android/data/net.kronie.flauncher/files/ha.json
adb shell am force-stop net.kronie.flauncher     # re-reads the file on next start
```
Without the file there is simply no HA panel. Check that the TV can reach HA, including firewalls between VLANs:
`adb shell 'printf "GET /api/ HTTP/1.0\r\n\r\n" | toybox nc <ha-host> 8123 | head -1'` should print `HTTP/1.0 401`.

### 3c. The dashboard
Create a dashboard in HA (Settings → Dashboards → Add, e.g. "TV Launcher" with URL `tv-launcher`, hidden from the
sidebar, **not** admin-only). The launcher reads the **first view**: its `cards`, and/or all `sections` of a
sections view. Stacks and grids are flattened.

| Card | Shown on the TV as |
|---|---|
| `glance` titled **Outdoors** | top bar: `weather.*` (condition, icon, temp) and any AQI sensor as a coloured badge |
| `glance` titled **Indoors** | top bar after `Indoors:`: sensors in order (temp, humidity, AQI) |
| `glance` with any other / no title | status pills (`Name: **State**`, icon, green/amber) |
| `tile` | a tile. `tap_action` → OK, `hold_action` → hold OK. Default `more-info` = TV popup |
| `button` cards **after a tile in the same vertical-stack** | that tile's popup menu (name + `tap_action`); the last-activated scene is ticked |
| stand-alone `button` | its own tile |
| `picture-entity` with a `camera.*` | snapshot tile, refreshed every 10 s |
| `heading`, anything else | ignored |

- **Supported actions:** `toggle`, `perform-action` (or legacy `call-service`), `more-info`, `none`.
- **Visibility:** `visibility` conditions `time` (after/before/weekdays, may wrap midnight), `state` (state/state_not), `and`/`or` are evaluated on the TV and re-checked every minute.
- **Icons:** common `mdi:` icons are mapped; others fall back to an icon per entity type.

Minimal example:
```yaml
views:
  - title: Launcher
    cards:
      - type: glance
        title: Outdoors
        entities: [weather.home]
      - type: glance
        entities:
          - entity: lock.front_door
            name: Front Door
      - type: vertical-stack
        cards:
          - type: tile
            entity: light.living_room
            tap_action: {action: toggle}
            hold_action: {action: more-info}
          - type: button
            name: Movie
            tap_action:
              action: perform-action
              perform_action: scene.turn_on
              target: {entity_id: scene.movie}
      - type: tile
        entity: climate.living_room        # OK opens temperature controls
```

### 3d. Optional: wallpaper chosen by HA
Create `input_select.tv_launcher_wallpaper`. Its options must be launcher wallpaper names: *True Black (OLED), Backglow,
Purple Glow, AT4K Dark, Great Whale, …* (see `lib/gradients.dart`). Set it from automations. On the TV, Settings → Wallpaper
→ **Wallpaper from Home Assistant** lets HA choose (on by default) and sets the fade time. An unknown value falls back
to the wallpaper picked on the TV.

## 4. Make it the home screen

The test builds can be opened from any launcher. To make FLauncher HA the home app:
```sh
adb shell cmd package set-home-activity net.kronie.flauncher/me.efesser.flauncher.MainActivity
```
On Google TV / Android TV with the stock launcher you may also need to disable it:
`adb shell pm disable-user --user 0 com.google.android.tvlauncher`. That is reversible with `pm enable`.
If a button-remapping app such as "Home Button" or "Button Mapper" owns the Home key, set its Home action to FLauncher HA.

To go back: `cmd package set-home-activity <other.launcher/.Activity>` (and re-enable the stock launcher).

## Development notes
- **HA code:** `lib/ha/`, with `ha_service.dart` (WebSocket client, config, actions, visibility), `ha_panel.dart` (top bar, pills, tiles) and `ha_popup.dart` (popup).
- **Changes vs upstream:** see `git log`. Firebase/Unsplash were removed, the theme was ported to current Flutter (Material 2 look kept), and the layered gradients are in `gradients.dart`.
- **Package id:** `net.kronie.flauncher` (label "FLauncher HA"), so it can sit next to upstream FLauncher.

License: GPL-3.0, same as upstream.
