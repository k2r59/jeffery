#!/bin/zsh
# Séance de bout en bout sur la PAIRE de simulateurs (iPhone + Apple Watch reliés par la vraie WatchConnectivity).
# La montre fabrique cœur/distance/calories (WATCHCOACH_FAKE_HEALTH), l'iPhone tourne avec le coach factice
# (WATCHCOACH_FAKE_REALTIME) et des phrases scriptées. Ni OpenAI, ni HealthKit, ni clé. Le journal est vérifié
# par check-journal.py : code de sortie 1 si une règle échoue.
# Usage : Tests/Scripts/e2e-session.sh [dossier de sortie]
# Variables : WATCH_FIRST=1 (app montre ouverte avant le départ) ou 0 (fermée : l'iPhone doit la lancer),
#             WATCH_SCRIPT="pause@60,resume@78" (appuis montre, seulement si WATCH_FIRST=1),
#             FAKE_USER="38:Oui, c'est bien ça.|100:Tu peux terminer la séance ?|107:Oui, vas-y." (phrases dites,
#               s après la connexion : confirme l'exercice proposé, puis demande la fin et la confirme),
#             STOP_AFTER=170 (arrêt de secours, s).
set -u
PHONE=DA7A1593-AA47-4E29-B4F4-5DB2EAA6F507   # iPhone 18 Pro Max, jumelé à…
WATCH=D92CC0CE-C1D9-46DD-A332-05D451100C90   # …Apple Watch Series 12 (46 mm)
OUT=${1:-/tmp/jeffrey-e2e}
WATCH_FIRST=${WATCH_FIRST:-1}
WATCH_SCRIPT=${WATCH_SCRIPT:-"pause@60,resume@78"}
FAKE_USER=${FAKE_USER:-"38:Oui, c'est bien ça.|100:Tu peux terminer la séance ?|107:Oui, vas-y."}
STOP_AFTER=${STOP_AFTER:-170}
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
# Données de santé fabriquées, même quand c'est l'iPhone qui lance l'app montre (variable vue par tout le simulateur).
xcrun simctl spawn $WATCH launchctl setenv WATCHCOACH_FAKE_HEALTH 1

CONT=$(xcrun simctl get_app_container $PHONE $PBID data)
rm -f "$CONT/Documents/sessions.json" "$CONT/Documents/derniere-seance.txt"; rm -rf "$CONT/Documents/journaux"
xcrun simctl launch --terminate-running-process $PHONE $PBID -pref.onboarded YES -pref.setupVersion 2 -pref.userName Test >/dev/null; sleep 3
xcrun simctl terminate $PHONE $PBID

if [[ $WATCH_FIRST == 1 ]]; then
  SIMCTL_CHILD_WATCHCOACH_FAKE_HEALTH=1 SIMCTL_CHILD_WATCHCOACH_WATCH_SCRIPT="$WATCH_SCRIPT" \
    xcrun simctl launch $WATCH $WBID >/dev/null
  sleep 6
fi
# L'iPhone : coach factice, départ automatique dès « Montre connectée », objectif 2 min.
SIMCTL_CHILD_WATCHCOACH_FAKE_REALTIME=1 SIMCTL_CHILD_WATCHCOACH_AUTOSTART=1 SIMCTL_CHILD_WATCHCOACH_GOAL_MIN=2 \
SIMCTL_CHILD_WATCHCOACH_STOP_AFTER=$STOP_AFTER SIMCTL_CHILD_WATCHCOACH_NO_HEALTH=1 SIMCTL_CHILD_WATCHCOACH_NO_SPLASH=1 \
SIMCTL_CHILD_WATCHCOACH_FAKE_USER="$FAKE_USER" \
  xcrun simctl launch $PHONE $PBID -pref.onboarded YES -pref.setupVersion 2 -pref.userName Test >/dev/null

snap() { xcrun simctl io $PHONE screenshot "$OUT/phone-$1.png" >/dev/null 2>&1; xcrun simctl io $WATCH screenshot "$OUT/watch-$1.png" >/dev/null 2>&1; }
sleep 30; snap 30s
sleep $(( STOP_AFTER - 10 )); snap fin

cp "$CONT/Documents/derniere-seance.txt" "$OUT/journal.txt" 2>/dev/null || echo "(pas de journal)" > "$OUT/journal.txt"
echo "=== JOURNAL iPhone ==="; cat "$OUT/journal.txt"
echo "=== CRASHES (10 min) ==="; find ~/Library/Logs/DiagnosticReports -name 'WatchCoach*.ips' -mmin -10 2>/dev/null
xcrun simctl terminate $WATCH $WBID 2>/dev/null; xcrun simctl terminate $PHONE $PBID 2>/dev/null
xcrun simctl spawn $WATCH launchctl unsetenv WATCHCOACH_FAKE_HEALTH
echo "=== VÉRIFICATION ==="
"$ROOT/Tests/Scripts/check-journal.py" "$OUT/journal.txt"
