#!/bin/zsh
# Tous les scénarios de bout en bout sur la paire de simulateurs, vérifiés par check-journal.py.
# Usage : Tests/Scripts/scenarios.sh [--build]   (--build : recompile l'app iPhone et l'app montre pour simulateur)
set -u
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
OUT=/tmp/jeffrey-scenarios
PHONE=DA7A1593-AA47-4E29-B4F4-5DB2EAA6F507
WATCH=D92CC0CE-C1D9-46DD-A332-05D451100C90

if [[ ${1:-} == --build ]]; then
  cd "$ROOT"
  xcodebuild -project WatchCoach.xcodeproj -scheme WatchCoach -destination "id=$PHONE" -derivedDataPath build/dd-sim build -quiet || exit 1
  xcodebuild -project WatchCoach.xcodeproj -scheme WatchCoachWatch -destination "id=$WATCH" -derivedDataPath build/dd-watchsim build -quiet || exit 1
fi

typeset -A RESULT
run() {   # $1 = nom, puis variables du scénario
  local name=$1; shift
  echo "\n######## $name"
  env "$@" "$ROOT/Tests/Scripts/e2e-session.sh" "$OUT/$name" > "$OUT/$name.log" 2>&1
  local code=$?
  sed -n '/=== VÉRIFICATION ===/,$p' "$OUT/$name.log"
  RESULT[$name]=$([[ $code == 0 ]] && echo OK || echo ÉCHEC)
}
mkdir -p "$OUT"

# 1. App montre ouverte, pause/reprise depuis la montre, fin à l'oral confirmée.
run montre-ouverte WATCH_FIRST=1
# 2. App montre fermée (écran éteint) : l'iPhone doit la lancer, sans double départ ni redémarrage.
run montre-fermee WATCH_FIRST=0

echo "\n######## RÉSUMÉ"
for k in ${(k)RESULT}; do echo "  ${RESULT[$k]}  $k"; done
echo "Détails : $OUT"
[[ ${(v)RESULT} != *ÉCHEC* ]]
