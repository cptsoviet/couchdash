#!/bin/sh
# CouchDash: notification overlay tests over adb (no HA needed; uses the DUMP-protected test receiver).
# Usage: tools/notify-test.sh <tv-ip:port> card|actions|critical|chip|clear|grant
set -e
D=${1:?tv address}; T=${2:-card}
A="adb -s $D shell am broadcast -a app.couchdash.launcher.TEST_NOTIFY -n app.couchdash.launcher/me.efesser.flauncher.HaTestReceiver --es json"
case $T in
  grant)    adb -s $D shell appops set app.couchdash.launcher SYSTEM_ALERT_WINDOW allow ;;
  card)     $A "'{\"title\":\"Washer done\",\"message\":\"Time to move the laundry\",\"data\":{\"duration\":8}}'" ;;
  actions)  $A "'{\"title\":\"Someone at the door\",\"message\":\"Doorbell pressed\",\"data\":{\"tag\":\"door\",\"actions\":[{\"action\":\"TEST_A\",\"title\":\"Unlock\"},{\"action\":\"TEST_B\",\"title\":\"Dismiss\"}]}}'" ;;
  critical) $A "'{\"title\":\"Water leak - kitchen\",\"message\":\"Test alert, press Acknowledge\",\"data\":{\"tag\":\"leak\",\"priority\":\"critical\",\"actions\":[{\"action\":\"ACK\",\"title\":\"Acknowledge\"}]}}'" ;;
  chip)     $A "'{\"title\":\"Pasta\",\"data\":{\"tag\":\"pasta\",\"chip\":true,\"countdown_until\":\"$(date -u -d '+2 min' +%Y-%m-%dT%H:%M:%S+00:00)\"}}'" ;;
  tts)      $A "'{\"title\":\"Test\",\"message\":\"This is a spoken test\",\"data\":{\"tts\":true,\"duration\":6}}'" ;;
  clear)    for t in door leak pasta; do $A "'{\"message\":\"clear_notification\",\"data\":{\"tag\":\"$t\"}}'"; done ;;
esac
