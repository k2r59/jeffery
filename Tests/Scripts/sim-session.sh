#!/bin/zsh
# Séance simulée de bout en bout sur le simulateur iPhone : montre et coach factices (Debug).
# Usage : Tests/Scripts/sim-session.sh [UDID simulateur] [dossier de sortie]
set -u
UDID=${1:-82F7DC19-55D7-42DE-B19A-450A9A6C34C4}
OUT=${2:-/tmp/jeffrey-sim}
mkdir -p "$OUT"
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
APP=$ROOT/build/dd-sim/Build/Products/Debug-iphonesimulator/WatchCoach.app
BID=dev.promo.watchcoach
xcrun simctl boot $UDID 2>/dev/null; xcrun simctl bootstatus $UDID -b >/dev/null 2>&1
xcrun simctl terminate $UDID $BID 2>/dev/null
xcrun simctl install $UDID "$APP" || exit 1
for svc in motion location microphone media-library; do xcrun simctl privacy $UDID grant $svc $BID; done
CONT=$(xcrun simctl get_app_container $UDID $BID data)
rm -f "$CONT/Documents/sessions.json" "$CONT/Documents/derniere-seance.txt"
xcrun simctl launch --terminate-running-process $UDID $BID -pref.onboarded YES -pref.setupVersion 2 -pref.userName Test >/dev/null
sleep 3
xcrun simctl terminate $UDID $BID
SIMCTL_CHILD_WATCHCOACH_FAKE_WATCH=1 SIMCTL_CHILD_WATCHCOACH_FAKE_REALTIME=1 SIMCTL_CHILD_WATCHCOACH_AUTOSTART=1 \
SIMCTL_CHILD_WATCHCOACH_GOAL_MIN=2 SIMCTL_CHILD_WATCHCOACH_NO_SPLASH=1 SIMCTL_CHILD_WATCHCOACH_STOP_AFTER=170 SIMCTL_CHILD_WATCHCOACH_NO_HEALTH=1 \
xcrun simctl launch $UDID $BID -pref.onboarded YES -pref.setupVersion 2 -pref.userName Test
sleep 30; xcrun simctl io $UDID screenshot "$OUT/live-30s.png" >/dev/null 2>&1
sleep 60; xcrun simctl io $UDID screenshot "$OUT/live-90s.png" >/dev/null 2>&1
sleep 60; xcrun simctl io $UDID screenshot "$OUT/live-150s.png" >/dev/null 2>&1
sleep 55; xcrun simctl io $UDID screenshot "$OUT/end.png" >/dev/null 2>&1
echo "=== JOURNAL ==="; cat "$CONT/Documents/derniere-seance.txt" 2>/dev/null || echo "(pas de journal)"
echo; echo "=== SESSIONS ==="; python3 -c "
import json,sys
try: d=json.load(open('$CONT/Documents/sessions.json'))
except Exception as e: print('pas de sessions.json', e); sys.exit()
for s in d: print({k:s.get(k) for k in ('elapsed','distance','averageHeartRate','maxHeartRate','goalLabel','goalReached','zoneCounts','analysis')})"
echo "=== CRASHES (10 min) ==="; find ~/Library/Logs/DiagnosticReports -name 'WatchCoach-*.ips' -mmin -10 2>/dev/null
