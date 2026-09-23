#!/bin/zsh
# Séance de bout en bout sur la PAIRE de simulateurs (iPhone + Apple Watch reliés par la vraie WatchConnectivity).
# La montre fabrique cœur/distance/calories (WATCHCOACH_FAKE_HEALTH), joue des appuis scriptés (pause, reprise…),
# l'iPhone tourne avec le coach factice (WATCHCOACH_FAKE_REALTIME). Ni OpenAI, ni HealthKit, ni clé.
# Usage : Tests/Scripts/e2e-session.sh [dossier de sortie] [script montre]
#   script montre par défaut : "pause@60,resume@78" (secondes après le lancement de l'app montre)
set -u
PHONE=DA7A1593-AA47-4E29-B4F4-5DB2EAA6F507   # iPhone 18 Pro Max, jumelé à…
WATCH=D92CC0CE-C1D9-46DD-A332-05D451100C90   # …Apple Watch Series 12 (46 mm)
OUT=${1:-/tmp/jeffrey-e2e}
SCRIPT=${2:-"pause@60,resume@78"}
mkdir -p "$OUT"
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
PAPP=$ROOT/build/dd-sim/Build/Products/Debug-iphonesimulator/WatchCoach.app
WAPP=$ROOT/build/dd-watchsim/Build/Products/Debug-watchsimulator/WatchCoachWatch.app
PBID=dev.promo.watchcoach
WBID=dev.promo.watchcoach.watchkitapp

for u in $PHONE $WATCH; do xcrun simctl boot $u 2>/dev/null; xcrun simctl bootstatus $u -b >/dev/null 2>&1; done
xcrun simctl terminate $PHONE $PBID 2>/dev/null; xcrun simctl terminate $WATCH $WBID 2>/dev/null
xcrun simctl install $PHONE "$PAPP" || exit 1
xcrun simctl install $WATCH "$WAPP" || exit 1
for svc in motion location microphone media-library; do xcrun simctl privacy $PHONE grant $svc $PBID 2>/dev/null; done
xcrun simctl privacy $WATCH grant location $WBID 2>/dev/null

CONT=$(xcrun simctl get_app_container $PHONE $PBID data)
rm -f "$CONT/Documents/sessions.json" "$CONT/Documents/derniere-seance.txt"; rm -rf "$CONT/Documents/journaux"
xcrun simctl launch --terminate-running-process $PHONE $PBID -pref.onboarded YES -pref.setupVersion 2 -pref.userName Test >/dev/null; sleep 3
xcrun simctl terminate $PHONE $PBID

# 1. La montre d'abord (elle doit être « connectée » pour que l'iPhone accepte de démarrer).
SIMCTL_CHILD_WATCHCOACH_FAKE_HEALTH=1 SIMCTL_CHILD_WATCHCOACH_WATCH_SCRIPT="$SCRIPT" \
  xcrun simctl launch $WATCH $WBID >/dev/null
sleep 6
# 2. L'iPhone : coach factice, départ automatique, objectif 2 min, arrêt à 170 s. Pas de montre factice : la vraie WC.
SIMCTL_CHILD_WATCHCOACH_FAKE_REALTIME=1 SIMCTL_CHILD_WATCHCOACH_AUTOSTART=1 SIMCTL_CHILD_WATCHCOACH_GOAL_MIN=2 \
SIMCTL_CHILD_WATCHCOACH_STOP_AFTER=170 SIMCTL_CHILD_WATCHCOACH_NO_HEALTH=1 SIMCTL_CHILD_WATCHCOACH_NO_SPLASH=1 \
  xcrun simctl launch $PHONE $PBID -pref.onboarded YES -pref.setupVersion 2 -pref.userName Test >/dev/null

snap() { xcrun simctl io $PHONE screenshot "$OUT/phone-$1.png" >/dev/null 2>&1; xcrun simctl io $WATCH screenshot "$OUT/watch-$1.png" >/dev/null 2>&1; }
sleep 25; snap 25s
sleep 45; snap 70s      # pendant la pause scriptée (60 → 78 s après le lancement montre)
sleep 60; snap 130s
sleep 60; snap end      # après l'arrêt (170 s) et le débrief

echo "=== JOURNAL iPhone ==="; cat "$CONT/Documents/derniere-seance.txt" 2>/dev/null || echo "(pas de journal)"
echo; echo "=== SESSIONS ==="; python3 -c "
import json,sys
try: d=json.load(open('$CONT/Documents/sessions.json'))
except Exception: print('pas de sessions.json (normal sous 5 min)'); sys.exit()
for s in d: print({k:s.get(k) for k in ('elapsed','distance','averageHeartRate','maxHeartRate','goalLabel','goalReached','zoneCounts')})"
echo "=== CRASHES (10 min) ==="; find ~/Library/Logs/DiagnosticReports -name 'WatchCoach*.ips' -mmin -10 2>/dev/null
xcrun simctl terminate $WATCH $WBID 2>/dev/null; xcrun simctl terminate $PHONE $PBID 2>/dev/null
echo "Captures : $OUT"
