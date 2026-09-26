#!/usr/bin/env python3
"""Vérifie un journal de séance (Documents/journaux/seance-*.txt) contre les règles de Jeffrey.

Usage : Tests/Scripts/check-journal.py journal.txt [autres journaux…]
Chaque règle rend OK, ATTENTION ou ÉCHEC ; code de sortie 1 dès qu'une règle échoue.
Les règles « montre » ne s'appliquent qu'aux journaux qui contiennent la trace « Montre : … » (depuis le 26/09/2026).
"""
import re
import sys

LINE = re.compile(r"^(\d+):(\d\d)  (·|Jeffrey|Lui)  (.*)$")


def parse(path):
    events = []
    for raw in open(path, encoding="utf-8"):
        m = LINE.match(raw.rstrip("\n"))
        if m:
            events.append((int(m[1]) * 60 + int(m[2]), m[3], m[4]))
    return events


def mmss(t):
    return f"{t // 60:02d}:{t % 60:02d}"


def check(events):
    results = []

    def add(level, rule, detail):
        results.append((level, rule, detail))

    info = [(t, x) for t, w, x in events if w == "·"]
    coach = [(t, x) for t, w, x in events if w == "Jeffrey"]
    end_t = events[-1][0] if events else 0

    # 1. Un seul départ envoyé à la montre (et au moins un : un journal vide ou sans départ est un échec).
    starts = [t for t, x in info if x in ("Départ envoyé à la montre.", "Séance lancée sur la montre.")]
    if not starts:
        add("ÉCHEC", "départ unique", "aucun départ envoyé à la montre (séance jamais lancée ?)")
    elif len(starts) > 1:
        add("ÉCHEC", "départ unique", "départ envoyé " + ", ".join(map(mmss, starts)))
    else:
        add("OK", "départ unique", f"{len(starts)} départ")

    # 2 à 5. Liaison montre (trace « Montre : »).
    watch = [(t, x) for t, x in info if x.startswith("Montre : ")]
    if not watch:
        add("?", "liaison montre", "journal sans trace montre (ancien) : non vérifiable")
    else:
        started = [x for _, x in watch if "séance démarrée" in x]
        silent = [t for t, x in watch if "aucune donnée 20 s" in x]
        if silent or not started:
            add("ÉCHEC", "montre démarrée", "aucune donnée de la montre après le départ")
        else:
            s = int(re.search(r"(\d+) s après", started[0])[1])
            add("OK" if s <= 15 else "ÉCHEC", "montre démarrée", f"premières données {s} s après le départ (max 15)")
        hr = [x for _, x in watch if "premier cœur" in x]
        if hr:
            s = int(re.search(r"(\d+) s après", hr[0])[1])
            add("OK" if s <= 30 else "ATTENTION", "premier cœur", f"{s} s après le départ (attendu ≤ 30)")
        elif end_t > 60:
            add("ÉCHEC", "premier cœur", "aucun battement reçu")
        restarts = [t for t, x in watch if "redémarrée côté montre" in x]
        add("ÉCHEC" if restarts else "OK", "pas de redémarrage montre",
            ("redémarrée à " + ", ".join(map(mmss, restarts))) if restarts else "séance montre continue")
        gaps = [t for t, x in watch if "aucune mesure depuis 30 s" in x]
        add("ÉCHEC" if gaps else "OK", "mesures continues",
            ("trou de mesures à " + ", ".join(map(mmss, gaps))) if gaps else "aucun trou de plus de 30 s")

    # 6. Confirmation orale avant de lancer un exercice ou de finir.
    for i, (t, w, x) in enumerate(events):
        m = re.match(r"Outil (end_session|start_workout) confirmed=1", x) if w == "·" else None
        if not m:
            continue
        before = events[:i]
        q = max((j for j, (_, ww, xx) in enumerate(before) if ww == "Jeffrey" and "?" in xx), default=None)
        answered = q is not None and any(ww == "Lui" for _, ww, _ in before[q + 1:])
        refused = any(ww == "·" and "refusé" in xx for _, ww, xx in events[i + 1:i + 3])
        if answered:
            add("OK", f"confirmation {m[1]}", f"{mmss(t)} : réponse entendue après la question")
        elif refused:
            add("OK", f"confirmation {m[1]}", f"{mmss(t)} : appelé sans réponse, refusé par l'app")
        else:
            add("ÉCHEC", f"confirmation {m[1]}", f"{mmss(t)} : appelé sans réponse à la question, et exécuté")

    # 7. Chronos : décompte dit à l'oral et bloc suivant à la seconde.
    chronos = [(t, x) for t, x in info if x.startswith("Chrono : ")]
    stops = [t for t, x in info if x.startswith("Arrêt de la séance")]
    stop_t = stops[0] if stops else end_t
    for k, (t, x) in enumerate(chronos):
        m = re.search(r", (\d+) s$", x)
        if not m:
            continue
        n = int(m[1])
        due = t + n
        if due > stop_t - 1:
            continue
        label = x[len("Chrono : "):x.rfind(",")]
        nxt = [tt for tt, xx in info if tt >= t + 1 and (xx.startswith("Chrono : ") or xx.startswith("Programme terminé"))]
        if nxt:
            drift = nxt[0] - due
            if abs(drift) > 3:
                add("ÉCHEC", "bloc à l'heure", f"« {label} » ({mmss(t)}, {n} s) : suite à {mmss(nxt[0])}, écart {drift:+d} s")
        for step in (30, 10):
            if n <= step + 5:
                continue
            said = [tt for tt, xx in coach if xx.strip().rstrip(".") == f"{step} secondes" and t < tt <= due]
            if not said:
                add("ÉCHEC", "décompte oral", f"« {label} » ({mmss(t)}) : « {step} secondes » jamais dit")
            elif abs(said[0] - (due - step)) > 4:
                add("ATTENTION", "décompte oral", f"« {label} » : « {step} secondes » à {mmss(said[0])}, attendu {mmss(due - step)}")
    if chronos:
        if not any(r[1] in ("bloc à l'heure", "décompte oral") for r in results):
            add("OK", "chronos", f"{len(chronos)} blocs à l'heure, décomptes dits")

    # 8. Objectif pas annoncé avant la fin du programme qui l'a fixé.
    goal = [t for t, x in info if x.startswith("Objectif atteint")]
    prog_start = [t for t, x in info if x.startswith("Programme : ")]
    prog_end = [t for t, x in info if x.startswith("Programme terminé")]
    if goal and prog_start and prog_end and prog_start[0] < goal[0] < prog_end[0] - 3:
        add("ÉCHEC", "objectif et programme", f"objectif atteint à {mmss(goal[0])}, programme fini à {mmss(prog_end[0])}")

    # 9. Mot de fin après l'arrêt.
    if stops:
        reason = next(x for t, x in info if t == stops[0] and x.startswith("Arrêt de la séance"))
        silent_end = any(k in reason for k in ("fermée", "injoignable", "avant le début"))
        farewell = [x for t, x in coach if t >= stops[0]]
        if not silent_end:
            add("OK" if farewell else "ÉCHEC", "mot de fin", farewell[0][:60] if farewell else "aucune phrase après l'arrêt")

    # 10. Vocabulaire de Jeffrey.
    kilo = [(t, x) for t, x in coach if re.search(r"\bkilos?\b", x, re.I)]
    add("ÉCHEC" if kilo else "OK", "« kilomètre » en entier",
        "; ".join(f"{mmss(t)} « {x[:50]} »" for t, x in kilo) or "jamais « kilo »")
    gait = [(t, x) for t, x in coach
            if re.search(r"\btu (marches|cours|es en (train de )?(marche|course|courir|marcher))\b|\b(de nouveau|toujours) en (course|marche)\b", x, re.I)]
    add("ATTENTION" if gait else "OK", "pas d'avis marche/course",
        "; ".join(f"{mmss(t)} « {x[:60]} »" for t, x in gait) or "aucun")
    return results


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        return 2
    failed = False
    for path in sys.argv[1:]:
        print(f"== {path}")
        for level, rule, detail in check(parse(path)):
            print(f"  {level:<9} {rule} : {detail}")
            failed |= level == "ÉCHEC"
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
