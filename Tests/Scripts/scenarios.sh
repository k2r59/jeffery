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
# Panne voulue : le journal doit contenir chacune des lignes attendues (motifs grep), la séance s'arrêter d'elle-même.
run_expect() {   # $1 = nom, $2 = motifs séparés par « | », puis variables du scénario
  local name=$1 patterns=$2; shift 2
  echo "\n######## $name"
  env "$@" "$ROOT/Tests/Scripts/e2e-session.sh" "$OUT/$name" > "$OUT/$name.log" 2>&1
  local ok=OK
  for p in ${(s:|:)patterns}; do
    if grep -qF -- "$p" "$OUT/$name/journal.txt"; then echo "  OK        « $p »"; else echo "  ÉCHEC     ligne absente : « $p »"; ok=ÉCHEC; fi
  done
  RESULT[$name]=$ok
}
mkdir -p "$OUT"
# iPhone virtuel redémarré une fois en début de série : une fenêtre d'autorisation restée ouverte bloquerait tout.
xcrun simctl shutdown $PHONE 2>/dev/null; xcrun simctl boot $PHONE; xcrun simctl bootstatus $PHONE -b >/dev/null 2>&1; sleep 20

# 1. App montre ouverte, pause/reprise depuis la montre, fin à l'oral confirmée.
run montre-ouverte WATCH_FIRST=1
# 3. Santé jamais autorisée sur la montre : elle le dit, l'iPhone arrête et explique.
run_expect sante-refusee "Montre : Santé non autorisée|Arrêt de la séance : la montre n'a pas pu lancer" \
  WATCH_FIRST=1 WATCH_ENV=WATCHCOACH_FAKE_HEALTH_DENIED=1 STOP_AFTER=60 FAKE_USER=
# 4. Montre qui ne répond jamais : arrêt au bout de 25 s avec la marche à suivre.
run_expect montre-muette "aucune donnée 25 s après le départ|Arrêt de la séance : montre muette au départ" \
  WATCH_FIRST=1 WATCH_ENV=WATCHCOACH_IGNORE_START=1 STOP_AFTER=60 FAKE_USER=
# 5. Réglages audio refusés (erreur -10868) : repli sur le réglage « conversation », la séance démarre quand même.
run_expect audio-repli "réglage pleine qualité Bluetooth refusé|réglage standard refusé|Audio : réglage conversation|Montre : séance démarrée" \
  WATCH_FIRST=1 PHONE_ENV=WATCHCOACH_AUDIO_FAIL=highQuality,standard STOP_AFTER=60 FAKE_USER=
# 6. Aucun réglage audio possible : départ refusé et noté (journal envoyé au serveur, vérifié sur un vrai iPhone).
run_expect audio-impossible "réglage conversation refusé|Départ impossible : audio" \
  WATCH_FIRST=1 PHONE_ENV=WATCHCOACH_AUDIO_FAIL=highQuality,standard,voiceChat STOP_AFTER=40 FAKE_USER=
# 7. En dernier : App montre fermée (écran éteint), l'iPhone doit la lancer, sans double départ ni redémarrage.
# Ce réveil à distance fait demander l'autorisation Santé au simulateur ; sa fenêtre bloquerait les scénarios suivants.
run montre-fermee WATCH_FIRST=0

echo "\n######## RÉSUMÉ"
for k in ${(k)RESULT}; do echo "  ${RESULT[$k]}  $k"; done
echo "Détails : $OUT"
[[ ${(v)RESULT} != *ÉCHEC* ]]
