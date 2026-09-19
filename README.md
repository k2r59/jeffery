# Jeffrey

Coach sportif vocal pour iPhone et Apple Watch. Jeffrey parle avec toi pendant la séance, lit en direct ce que mesure
la montre (fréquence cardiaque, distance, allure, énergie) et ce que capte l'iPhone (marche, course, arrêt, cadence,
montée, descente), intervient quand ça compte, puis rédige un bilan et retient ce qui compte pour la fois suivante.

Projet personnel, installé hors App Store en signature de développement.

## Ce que fait l'app

**Pendant la séance**
- Conversation vocale continue avec Jeffrey (API Realtime d'OpenAI) : micro ouvert dès la connexion, il finit sa phrase
  si tu lui parles par-dessus, puis répond. Un « Je regarde. » avec sa propre voix confirme qu'il a entendu quand sa
  réponse tarde.
- Métriques de la montre toutes les secondes, complétées par le GPS de l'iPhone (tracé, distance et allure de secours).
- Détection sur l'iPhone : marche / course / arrêt et cadence (mouvement), plat / montée / descente et dénivelé
  cumulé (baromètre).
- Coaching de fond utile (kilomètres passés avec le temps du split, allure vs objectif, technique, respiration) et
  réactions immédiates aux événements : galère dans une côte, passage à la marche, fréquence cardiaque en zone 5,
  arrêt prolongé, sommet, descente raide, dérive de fatigue, objectif atteint.
- Objectif de séance (durée, distance ou libre) fixé avant de partir, dicté en langage naturel ou par boutons ; en cours
  de route, Jeffrey peut le changer après ton accord à l'oral, rien à toucher sur le téléphone.
- Chronomètre piloté par Jeffrey (blocs, fractionné travail/récup) : l'app sonne et le prévient, il n'a jamais à compter.
- Séances types : à l'accueil, Jeffrey demande si on fait la séance à sa façon ou s'il propose un exercice (on peut aussi
  le lui demander à tout moment). S'il propose, il demande juste « comme d'habitude, plus doux ou plus
  costaud ? », propose deux séances adaptées au sport choisi et au niveau (catalogue `iOS/WorkoutLibrary.swift`,
  7 sports × 3 niveaux), et déroule celle qu'on choisit bloc par bloc avec le chronomètre. Tout à l'oral, rien à valider
  sur le téléphone ; la carte chrono (iPhone, montre, écran verrouillé) montre le bloc en cours et sa position.
- La montre est obligatoire : sans montre joignable, pas de départ ; montre perdue plus de deux minutes, séance arrêtée.
- Parcours de référence : rejouer une sortie précédente avec le relief à venir et un « fantôme » (avance ou retard).
- Musique : elle continue, s'atténue quand Jeffrey parle, et sa voix passe au-dessus.

**Après la séance**
- Écran « Bien joué » : chrono, distance, FC, tracé, objectif, ressenti (facile, bien, intense).
- Bilan écrit par un modèle de langage à partir d'un dossier complet (profil, données Santé, séance, historique des
  séances dans l'app, marche/course, dénivelé), avec un conseil pour la prochaine fois et une ligne de prudence si
  un signal est inhabituel. Jamais de diagnostic médical.
- Mémoire longue : Jeffrey extrait de la conversation ce qui compte sur la durée (gêne, objectif, préférence) et s'en
  sert aux séances suivantes. Tout est lisible et modifiable dans l'onglet Toi.

**Écrans iPhone** : Aujourd'hui (semaine, dernière sortie, départ), Séances (historique groupé, parcours sur carte,
refaire un parcours), Toi (profil, mesures, forme, contexte, mémoire), Jeffrey (présence, voix avec aperçu, musique,
montre, intelligence).

**Montre** : miroir et télécommande de l'iPhone. Un bouton « Démarrer avec Jeffrey » lance la séance sur l'iPhone ;
la montre affiche le chrono, l'objectif, la FC et l'état de Jeffrey (arrive, écoute, parle, dernière phrase) ;
glisser vers la gauche donne Pause et Terminer. La montre reste le capteur cardiaque.

## Architecture

```
Apple Watch (WatchCoachWatch)                    iPhone (WatchCoach)                          Services
┌───────────────────────────────┐   WatchConnectivity  ┌─────────────────────────────┐  WebSocket  ┌──────────────────┐
│ capteur :                     │ ───────────────────▶ │ CoachSession                │ ◀─────────▶ │ OpenAI Realtime  │
│  · compagnon de l'app Exercice│  MetricsSnapshot     │  · métriques → [MÉTRIQUES]  │  PCM16 24k  │  (voix, outils)  │
│    (session étendue +         │                      │  · événements → cues        │             └──────────────────┘
│     lecture HealthKit)        │ ◀─────────────────── │  · objectif, référence      │  HTTPS      ┌──────────────────┐
│  · ou séance pilotée          │  commandes,          │ ActivityMonitor (mouvement, │ ◀─────────▶ │ OpenAI Responses │
│    (HKWorkoutSession + GPS)   │  état miroir         │   cadence, baromètre)       │             │  (bilan secours) │
│ miroir + télécommande         │                      │ RouteRecorder (GPS)         │             └──────────────────┘
└───────────────────────────────┘                      │ AudioPipeline (micro, voix) │  in-process ┌──────────────────┐
                                                       │ AppleAnalyst (bilan,        │ ◀─────────▶ │ Foundation Models│
                                                       │   mémoire, objectif dicté)  │             │ Apple : PCC/local│
                                                       └─────────────────────────────┘             └──────────────────┘
```

### Deux modes de capture (réglage iPhone, onglet Jeffrey)

| Mode | Qui possède la séance | Fraîcheur | Notes |
|---|---|---|---|
| **Suivre l'app Exercice** (défaut) | l'app Exercice native | quelques secondes à ~1 min | la montre se cale sur le vrai début de la séance native (série dense de mesures cardiaques) et détecte sa fin ; session d'arrière-plan d'environ 1 h, à prolonger depuis la montre si elle vibre |
| **Séance par Jeffrey** | l'app Jeffrey (enregistrée dans Santé avec tracé GPS) | ~1 s | on n'utilise pas l'app Exercice pendant la séance |

watchOS n'autorise qu'une seule séance HealthKit active à la fois : c'est la raison du mode compagnon.

### Intelligence

| Rôle | Moteur |
|---|---|
| Voix en séance | OpenAI Realtime (`gpt-realtime`), clé API dans le trousseau |
| Bilan, mémoire, objectif dicté | Apple Foundation Models : Private Cloud Compute (32K, raisonnement) puis modèle local de l'iPhone, puis OpenAI (`gpt-5-mini`) en secours. Réglable dans l'onglet Jeffrey. |

Le modèle serveur Apple exige l'entitlement Private Cloud Compute sur le compte développeur (programme App Store
Small Business, moins de 2 M de téléchargements) : https://developer.apple.com/contact/request/private-cloud-compute/.
Sans lui, l'app le signale et utilise le modèle local (Apple Intelligence activé, iPhone 15 Pro ou plus récent), puis OpenAI.

Autres fournisseurs étudiés : Grok (API vocale compatible Realtime, remplacement quasi direct pour la voix), Gemini Live
(voix native, protocole différent), Claude (texte uniquement). Non branchés.

## Installation

Prérequis : Xcode 27, iPhone sous iOS 27 avec Apple Watch, compte développeur Apple, [xcodegen](https://github.com/yonaskolb/XcodeGen).

1. `xcodegen generate` (le projet Xcode est généré depuis `project.yml` ; à refaire après toute modification de ce fichier).
2. Dans `project.yml`, `DEVELOPMENT_TEAM` porte l'équipe de signature ; les identifiants sont `dev.promo.watchcoach`
   et `dev.promo.watchcoach.watchkitapp`.
3. Mode développeur activé sur l'iPhone et la montre ; la montre doit être jumelée au Mac (Device Hub) pour être
   enregistrée dans le profil. Compilation avec enregistrement de la montre :
   ```bash
   xcodebuild -project WatchCoach.xcodeproj -scheme WatchCoachWatch -destination "id=<UDID montre>" -allowProvisioningUpdates -allowProvisioningDeviceRegistration build
   xcodebuild -project WatchCoach.xcodeproj -scheme WatchCoach -destination "id=<UDID iPhone>" -allowProvisioningUpdates build
   ```
4. Installation :
   ```bash
   APP=build/DerivedData/Build/Products/Debug-iphoneos/WatchCoach.app
   xcrun devicectl device install app --device <UDID iPhone> $APP
   xcrun devicectl device install app --device <UDID montre> $APP/Watch/WatchCoachWatch.app
   ```
5. Premier lancement : onboarding (intention, prénom, mesures depuis Santé, clé OpenAI), autorisations micro,
   Santé, position, mouvement, Musique.

## Utilisation

1. Écouteurs Bluetooth conseillés.
2. Sur la montre, « Démarrer avec Jeffrey » (ou sur l'iPhone, « Démarrer avec Jeffrey » puis l'objectif).
   En mode compagnon, lancer aussi la séance dans l'app Exercice, avant ou après.
3. Parler à Jeffrey quand on veut. Pause et Terminer depuis la montre ou l'iPhone. Terminer la séance dans l'app
   Exercice déclenche le débrief tout seul.
4. Bilan, ressenti, puis « Terminer le bilan ».

## Structure du code

- `Shared/` : modèles communs (métriques, commandes, état miroir, zones FC, symbole et logo Jeffrey).
- `iOS/CoachSession.swift` : orchestration de la séance (Realtime, métriques, événements, objectif, miroir montre, bilan).
- `iOS/RealtimeClient.swift`, `iOS/AudioPipeline.swift` : WebSocket Realtime, capture micro et lecture, atténuation musique.
- `iOS/ActivityMonitor.swift`, `iOS/RouteRecorder.swift`, `iOS/ReferenceRoute.swift` : mouvement, baromètre, GPS, parcours de référence.
- `iOS/SessionAnalyst.swift`, `iOS/AppleAnalyst.swift`, `iOS/JeffreyMemory.swift`, `iOS/SessionLog.swift` : bilan, mémoire, journal.
- `iOS/RootView.swift` et les vues `TodayView`, `SessionsView`, `YouView`, `JeffreyView`, `LiveSessionView`, `ObjectiveView`, `SessionEndView`, `OnboardingView`.
- `WatchApp/` : `WorkoutManager` (capture), `WatchSender` (connectivité, miroir), `WatchContentView` (télécommande).
- `iOS/Assets.xcassets` : pack d'assets Jeffrey (icône, logos, pictogrammes Lucide, couleurs). Licence Lucide dans `LICENCE-LUCIDE.txt`.

## Journal de séance

À la fin de chaque séance, l'app écrit `derniere-seance.txt` dans ses Documents (visible dans Fichiers > Sur mon iPhone > Jeffrey) :
tout ce que Jeffrey a dit et entendu, horodaté, plus les événements internes (chrono, changement d'objectif, montre, GPS).
C'est le premier réflexe quand une séance s'est mal passée. `sessions.json`, au même endroit, garde l'historique et les bilans.

## Tests

- `Tests/Unit` : logique pure (objectifs, zones, parcours de référence et fantôme, mémoire, appariement des séances, miroir montre).
- `Tests/UI` : parcours réels dans le simulateur (onboarding, onglets, réglages, objectif, blocage sans montre).
- Séance simulée de bout en bout (Debug uniquement) avec une montre et un coach factices : lancer l'app avec
  `WATCHCOACH_FAKE_WATCH=1 WATCHCOACH_FAKE_REALTIME=1 WATCHCOACH_AUTOSTART=1 WATCHCOACH_GOAL_MIN=2 WATCHCOACH_STOP_AFTER=150`
  (via `SIMCTL_CHILD_…` avec `simctl launch`). La montre factice envoie une FC réaliste et de la distance, le coach factice
  répond, déclenche le chrono et débriefe ; le journal et `sessions.json` en sortent comme en vrai.
  `WATCHCOACH_NO_HEALTH=1` évite HealthKit, `WATCHCOACH_RESET=1` repart d'une app vierge.
- Commande : `xcodebuild -scheme WatchCoach -destination 'id=<simulateur>' test`. Séance simulée clé en main : `Tests/Scripts/sim-session.sh`.

## Limites connues

- Avec des écouteurs Bluetooth, l'écoute via leur micro bascule iOS en mode mains libres : la musique perd en qualité
  pendant la séance.
- Une app iOS ne peut pas afficher ni piloter Spotify ou Deezer ; la carte musique gère Apple Music et propose des
  raccourcis vers les autres lecteurs.
- Le baromètre est amorti dans une poche fermée ; la course très lente ressemble quelques secondes à une marche rapide.
- Les seuils d'intervention (8 bpm, -30 % d'allure, 5 % de pente, 45 s d'arrêt) sont des réglages de départ.
- Signature de développement : l'app expire selon l'équipe (un an pour une équipe payante).
