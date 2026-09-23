#!/bin/zsh
# Deux séances à la suite sur la paire de simulateurs : la seconde doit repartir de zéro (chrono, distance, calories).
# Usage : Tests/Scripts/two-sessions.sh [dossier de sortie]
set -u
PHONE=DA7A1593-AA47-4E29-B4F4-5DB2EAA6F507
WATCH=D92CC0CE-C1D9-46DD-A332-05D451100C90
OUT=${1:-/tmp/jeffrey-two}
mkdir -p "$OUT"
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
PBID=dev.promo.watchcoach
WBID=dev.promo.watchcoach.watchkitapp

for u in $PHONE $WATCH; do xcrun simctl boot $u 2>/dev/null; xcrun simctl bootstatus $u -b >/dev/null 2>&1; done
xcrun simctl terminate $PHONE $PBID 2>/dev/null; xcrun simctl terminate $WATCH $WBID 2>/dev/null
xcrun simctl install $PHONE "$ROOT/build/dd-sim/Build/Products/Debug-iphonesimulator/WatchCoach.app" || exit 1
xcrun simctl install $WATCH "$ROOT/build/dd-watchsim/Build/Products/Debug-watchsimulator/WatchCoachWatch.app" || exit 1
for svc in motion location microphone media-library; do xcrun simctl privacy $PHONE grant $svc $PBID 2>/dev/null; done
CONT=$(xcrun simctl get_app_container $PHONE $PBID data)
rm -rf "$CONT/Documents/journaux"; rm -f "$CONT/Documents/derniere-seance.txt"

SIMCTL_CHILD_WATCHCOACH_FAKE_HEALTH=1 xcrun simctl launch $WATCH $WBID >/dev/null; sleep 6

run_session() {   # $1 = durée avant arrêt (s), $2 = suffixe des captures
  SIMCTL_CHILD_WATCHCOACH_FAKE_REALTIME=1 SIMCTL_CHILD_WATCHCOACH_AUTOSTART=1 SIMCTL_CHILD_WATCHCOACH_GOAL_MIN=2 \
  SIMCTL_CHILD_WATCHCOACH_STOP_AFTER=$1 SIMCTL_CHILD_WATCHCOACH_NO_HEALTH=1 SIMCTL_CHILD_WATCHCOACH_NO_SPLASH=1 \
    xcrun simctl launch --terminate-running-process $PHONE $PBID -pref.onboarded YES -pref.setupVersion 2 -pref.userName Test >/dev/null
  sleep $(( $1 + 12 ))
  xcrun simctl io $PHONE screenshot "$OUT/phone-$2.png" >/dev/null 2>&1
  xcrun simctl io $WATCH screenshot "$OUT/watch-$2.png" >/dev/null 2>&1
}

run_session 45 s1-fin
sleep 3
# Deuxième séance lancée juste après, sans redémarrer la montre : tout doit repartir à zéro.
SIMCTL_CHILD_WATCHCOACH_FAKE_REALTIME=1 SIMCTL_CHILD_WATCHCOACH_AUTOSTART=1 SIMCTL_CHILD_WATCHCOACH_GOAL_MIN=2 \
SIMCTL_CHILD_WATCHCOACH_STOP_AFTER=60 SIMCTL_CHILD_WATCHCOACH_NO_HEALTH=1 SIMCTL_CHILD_WATCHCOACH_NO_SPLASH=1 \
  xcrun simctl launch --terminate-running-process $PHONE $PBID -pref.onboarded YES -pref.setupVersion 2 -pref.userName Test >/dev/null
sleep 20; xcrun simctl io $PHONE screenshot "$OUT/phone-s2-20s.png" >/dev/null 2>&1
xcrun simctl io $WATCH screenshot "$OUT/watch-s2-20s.png" >/dev/null 2>&1
sleep 55; xcrun simctl io $PHONE screenshot "$OUT/phone-s2-fin.png" >/dev/null 2>&1

echo "=== JOURNAUX ==="
for f in "$CONT/Documents/journaux/"*.txt; do echo "--- $(basename $f)"; head -4 "$f"; echo; done
xcrun simctl terminate $WATCH $WBID 2>/dev/null; xcrun simctl terminate $PHONE $PBID 2>/dev/null
echo "Captures : $OUT (regarder phone-s2-20s.png : chrono ~20 s, distance quasi nulle)"
