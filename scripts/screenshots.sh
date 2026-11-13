#!/bin/bash
# Lance Valentin Entraîneur dans un simulateur iPhone avec des données de démo,
# capture les écrans, fait créer une vidéo par l'appli et teste la récupération d'une course.
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

install_app() {
  xcrun simctl install "$UDID" "$APP"
  xcrun simctl privacy "$UDID" grant location-always "$BID" || xcrun simctl privacy "$UDID" grant location "$BID" || true
  xcrun simctl privacy "$UDID" grant motion "$BID" || true
}
install_app
xcrun simctl location "$UDID" set 45.8990,6.1290 || true

ARGS=(-demo YES -AppleLanguages "(fr)" -AppleLocale fr_FR)

shot() { xcrun simctl io "$UDID" screenshot --type=png "$OUT/screens/$1.png" >/dev/null 2>&1 && echo "capture $1"; }

launch() {
  local screen="$1"; shift
  xcrun simctl terminate "$UDID" "$BID" >/dev/null 2>&1 || true
  xcrun simctl launch "$UDID" "$BID" "${ARGS[@]}" -screen "$screen" "$@" >/dev/null
}

# --- Écrans principaux -------------------------------------------------------
launch history; sleep 15            # premier lancement : création des courses de démo
launch record;  sleep 10; shot 1-pret
launch today;   sleep 6;  shot 0-aujourdhui
launch today -scrollTo semaine; sleep 7; shot 0b-aujourdhui-semaine
launch today -scrollTo jours;   sleep 7; shot 0c-aujourdhui-jours
launch history; sleep 6;  shot 4-historique
launch detail;  sleep 10; shot 5-detail
launch stats;   sleep 6;  shot 6-stats

# --- Survol 3D en direct -----------------------------------------------------
launch flyover
sleep 9;  shot 7-survol-direct
sleep 9;  shot 8-survol-direct2

# --- Vidéo créée par l'appli elle-même ---------------------------------------
DATA=$(xcrun simctl get_app_container "$UDID" "$BID" data)
rm -f "$DATA/Documents/export-done.txt" "$DATA/Documents/export.mp4"
launch export
START=$(date +%s)
sleep 25; shot 9-creation-video
while [ ! -f "$DATA/Documents/export-done.txt" ]; do
  NOW=$(date +%s)
  if [ $((NOW - START)) -gt 1200 ]; then echo "ERREUR délai dépassé" > "$OUT/export-report.txt"; break; fi
  sleep 10
done
if [ -f "$DATA/Documents/export-done.txt" ]; then
  cp "$DATA/Documents/export-done.txt" "$OUT/export-report.txt"
  cp "$DATA/Documents/export.mp4" "$OUT/video-appli.mp4" 2>/dev/null || true
  sleep 3; shot 10-video-prete
fi
echo "Création vidéo : $(cat "$OUT/export-report.txt") (attente $(( $(date +%s) - START )) s)"

# --- Course en direct, puis fermeture brutale et récupération ----------------
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
launch running; sleep 75; shot 2-course
xcrun simctl terminate "$UDID" "$BID" || true      # l'appli est tuée en pleine course
xcrun simctl location "$UDID" clear || true
xcrun simctl location "$UDID" set 45.8990,6.1290 || true
sleep 2
launch history; sleep 7; shot 3-recuperation

# --- Mode sombre --------------------------------------------------------------
xcrun simctl terminate "$UDID" "$BID" >/dev/null 2>&1 || true
xcrun simctl uninstall "$UDID" "$BID" || true
install_app
xcrun simctl ui "$UDID" appearance dark || true
launch history; sleep 15
launch record;  sleep 8;  shot d1-sombre-pret
launch today;   sleep 6;  shot d0-sombre-aujourdhui
launch today -scrollTo semaine; sleep 7; shot d0b-sombre-aujourdhui-semaine
launch detail;  sleep 8;  shot d2-sombre-detail
launch stats;   sleep 5;  shot d3-sombre-stats
launch flyover; sleep 12; shot d4-sombre-survol
xcrun simctl location "$UDID" start --speed=3.3 --interval=1 $WAYPOINTS || true
launch running; sleep 40; shot d5-sombre-course
xcrun simctl location "$UDID" clear || true
xcrun simctl location "$UDID" set 45.8990,6.1290 || true
xcrun simctl ui "$UDID" appearance light || true

# --- Texte agrandi (réglage d'accessibilité courant) -------------------------
xcrun simctl ui "$UDID" content_size extra-extra-large || true
xcrun simctl location "$UDID" start --speed=3.3 --interval=1 $WAYPOINTS || true
launch running; sleep 40; shot g1-gros-texte-course
xcrun simctl location "$UDID" clear || true
launch detail;  sleep 8;  shot g2-gros-texte-detail
launch today;   sleep 6;  shot g0-gros-texte-aujourdhui
launch today -scrollTo semaine; sleep 7; shot g0b-gros-texte-aujourdhui-semaine
launch history; sleep 5;  shot g3-gros-texte-historique
launch stats;   sleep 5;  shot g4-gros-texte-stats
launch flyover; sleep 12; shot g5-gros-texte-survol
xcrun simctl ui "$UDID" content_size large || true

# --- Premier lancement : aucune course ---------------------------------------
xcrun simctl terminate "$UDID" "$BID" >/dev/null 2>&1 || true
xcrun simctl uninstall "$UDID" "$BID" || true
xcrun simctl install "$UDID" "$APP"
FIRST=(-AppleLanguages "(fr)" -AppleLocale fr_FR)
xcrun simctl launch "$UDID" "$BID" "${FIRST[@]}" >/dev/null; sleep 8; shot n1-premier-lancement
xcrun simctl privacy "$UDID" grant location "$BID" || true
xcrun simctl terminate "$UDID" "$BID" >/dev/null 2>&1 || true
xcrun simctl launch "$UDID" "$BID" "${FIRST[@]}" >/dev/null; sleep 6; shot n2-pret-sans-course
xcrun simctl terminate "$UDID" "$BID" >/dev/null 2>&1 || true
xcrun simctl launch "$UDID" "$BID" "${FIRST[@]}" -screen history >/dev/null; sleep 5; shot n3-historique-vide
xcrun simctl terminate "$UDID" "$BID" >/dev/null 2>&1 || true
xcrun simctl launch "$UDID" "$BID" "${FIRST[@]}" -screen stats >/dev/null; sleep 5; shot n4-stats-vides
xcrun simctl privacy "$UDID" revoke location "$BID" || true
xcrun simctl terminate "$UDID" "$BID" >/dev/null 2>&1 || true
xcrun simctl launch "$UDID" "$BID" "${FIRST[@]}" -screen record >/dev/null; sleep 6; shot n5-localisation-refusee

xcrun simctl shutdown "$UDID" || true

# --- Petit iPhone -------------------------------------------------------------
SMALL=$(xcrun simctl list devices available -j | python3 -c '
import json, sys
d = json.load(sys.stdin)["devices"]
devs = [x for rt, l in d.items() if "iOS" in rt for x in l if x["name"].startswith("iPhone")]
for want in ("iPhone SE", "iPhone 16e", "iPhone 17e", "mini"):
    m = [x for x in devs if want in x["name"]]
    if m:
        print(m[-1]["udid"]); break')
if [ -n "$SMALL" ]; then
  UDID="$SMALL"
  echo "Petit iPhone : $(xcrun simctl list devices | grep "$UDID" | head -1)" | tee -a "$OUT/simulator.txt"
  xcrun simctl boot "$UDID" || true
  xcrun simctl bootstatus "$UDID" -b
  xcrun simctl status_bar "$UDID" override --time "9:41" --batteryState charged --batteryLevel 100 || true
  install_app
  xcrun simctl location "$UDID" set 45.8990,6.1290 || true
  launch history; sleep 15
  xcrun simctl location "$UDID" start --speed=3.3 --interval=1 $WAYPOINTS || true
  launch running; sleep 40; shot p1-petit-course
  xcrun simctl location "$UDID" clear || true
  launch detail;  sleep 8;  shot p2-petit-detail
  launch today;   sleep 6;  shot p0-petit-aujourdhui
  launch stats;   sleep 5;  shot p3-petit-stats
  launch flyover; sleep 12; shot p4-petit-survol
  xcrun simctl ui "$UDID" content_size extra-extra-large || true
  launch flyover; sleep 12; shot p5-petit-gros-texte-survol
  launch history; sleep 5;  shot p7-petit-gros-texte-historique
  launch today;   sleep 6;  shot p8-petit-gros-texte-aujourdhui
  xcrun simctl location "$UDID" start --speed=3.3 --interval=1 $WAYPOINTS || true
  launch running; sleep 30; shot p6-petit-gros-texte-course
  xcrun simctl ui "$UDID" content_size large || true
else
  echo "Aucun petit iPhone disponible" | tee -a "$OUT/simulator.txt"
fi

ls -la "$OUT" "$OUT/screens"
