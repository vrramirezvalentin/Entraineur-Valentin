#!/bin/bash
# Lance Entraîneur Valentin dans un simulateur iPhone avec des données de démo et capture les écrans.
set -u
APP="$1"; OUT="$2"
BID="app.foulee.perso.k7r2"
mkdir -p "$OUT/screens"

UDID=$(xcrun simctl list devices available -j | python3 -c '
import json, sys
d = json.load(sys.stdin)["devices"]
devs = [x for rt, l in d.items() if "iOS" in rt for x in l if x["name"].startswith("iPhone")]
pref = [x for x in devs if x["name"].endswith("Pro")] or devs
print(pref[-1]["udid"])')
NAME=$(xcrun simctl list devices | grep "$UDID" | head -1)
echo "Simulateur : $NAME"
echo "$NAME" > "$OUT/simulator.txt"

xcrun simctl boot "$UDID" || true
xcrun simctl bootstatus "$UDID" -b
xcrun simctl status_bar "$UDID" override --time "9:41" --batteryState charged --batteryLevel 100 \
  --cellularMode active --cellularBars 4 --wifiBars 3 --operatorName "" || true
xcrun simctl install "$UDID" "$APP"
xcrun simctl privacy "$UDID" grant location-always "$BID" || xcrun simctl privacy "$UDID" grant location "$BID" || true
xcrun simctl location "$UDID" set 45.8990,6.1290 || true

ARGS=(-demo YES -AppleLanguages "(fr)" -AppleLocale fr_FR)

shot() { xcrun simctl io "$UDID" screenshot --type=png "$OUT/screens/$1.png" >/dev/null 2>&1 && echo "capture $1"; }

launch() {
  xcrun simctl terminate "$UDID" "$BID" >/dev/null 2>&1 || true
  xcrun simctl launch "$UDID" "$BID" "${ARGS[@]}" -screen "$1" >/dev/null
}

# Premier lancement : création des courses de démo
launch history; sleep 15

launch record;  sleep 10; shot 1-pret
launch history; sleep 6;  shot 4-historique
launch detail;  sleep 10; shot 5-detail
launch stats;   sleep 6;  shot 6-stats

# Course en direct : l'iPhone simulé se déplace le long du lac
WAYPOINTS=$(python3 -c '
import math
pts=[]
for k in range(40):
    t=k/39
    lat=45.8990-0.012*t+0.002*math.sin(t*9)
    lon=6.1290+0.010*t+0.003*math.sin(t*5)
    pts.append(f"{lat:.6f},{lon:.6f}")
print(" ".join(pts))')
xcrun simctl location "$UDID" start --speed=3.3 --interval=1 $WAYPOINTS || true
launch running; sleep 80; shot 2-course
xcrun simctl location "$UDID" clear || true
xcrun simctl location "$UDID" set 45.8990,6.1290 || true

# Survol 3D + vidéo
launch flyover
xcrun simctl io "$UDID" recordVideo --codec=h264 --force "$OUT/survol-3d.mp4" >/dev/null 2>&1 &
REC=$!
sleep 4;  shot 7-survol-vue
sleep 10; shot 8-survol-suivi
sleep 10; shot 9-survol-suivi2
sleep 14
kill -INT $REC; wait $REC 2>/dev/null || true
ls -la "$OUT" "$OUT/screens"
