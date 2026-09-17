# WatchCoach

Coach vocal en direct pendant une séance de sport : l'Apple Watch fournit les métriques en temps réel,
l'iPhone tient une conversation vocale avec OpenAI (API Realtime, modèle `gpt-realtime`) et lui injecte
les métriques en continu. Usage personnel, pas prévu pour l'App Store.

## Architecture

```
Apple Watch (WatchCoachWatch)                 iPhone (WatchCoach)                    OpenAI
┌──────────────────────────────┐   WatchConnectivity   ┌────────────────────────┐   WebSocket   ┌────────────┐
│ mode « compagnon »           │ ───────────────────▶ │ CoachSession           │ ◀───────────▶ │ Realtime   │
│   app Exercice native +      │  MetricsSnapshot     │  · métriques → texte   │  audio PCM16  │ gpt-realtime│
│   WKExtendedRuntimeSession + │  (~1 s / ~10-60 s)   │    [MÉTRIQUES] injecté │  24 kHz       │            │
│   HKAnchoredObjectQuery      │                      │  · cues périodiques    │               │            │
│ mode « piloté »              │ ◀─────────────────── │  · micro ↔ haut-parleur│               │            │
│   HKWorkoutSession +         │  commandes           │    (AirPods conseillés)│               │            │
│   HKLiveWorkoutBuilder       │                      └────────────────────────┘               └────────────┘
└──────────────────────────────┘
```

### Deux modes côté montre

| Mode | Qui possède la séance | Fraîcheur des données | Limites |
|---|---|---|---|
| **Compagnon** (défaut) | l'app **Exercice** native | quelques secondes à ~1 min (dépend du rythme d'écriture de l'app native dans HealthKit) | la session d'arrière-plan expire après ~1 h : la montre vibre, rouvrir WatchCoach et toucher « Prolonger » |
| **Piloté** | WatchCoach (séance enregistrée dans Santé comme n'importe quelle app tierce) | ~1 s | on n'utilise pas l'app Exercice pendant la séance |

watchOS n'autorise qu'une seule `HKWorkoutSession` à la fois : c'est pour ça que le mode compagnon
ne « démarre » rien, il lit ce que l'app Exercice écrit.

## Mise en place (une fois)

1. Xcode 26+ installé et licence acceptée :
   `sudo xcodebuild -license accept && xcodebuild -runFirstLaunch && xcodebuild -downloadPlatform watchOS`
2. Ouvrir `WatchCoach.xcodeproj`. Dans *Signing & Capabilities* des deux cibles, choisir ton équipe
   (ou renseigner `DEVELOPMENT_TEAM` dans `project.yml` puis `xcodegen generate`).
   Les capacités HealthKit, Background Modes (audio côté iPhone ; workout-processing + physical-therapy
   côté montre) sont déjà dans les `Info.plist` / `.entitlements`.
3. Brancher l'iPhone, sélectionner le schéma **WatchCoach**, lancer : l'app montre est embarquée
   et installée avec l'app iPhone (accepter l'installation sur la montre si demandé).
4. Sur l'iPhone : ⚙️ Réglages → coller ta clé API OpenAI (stockée dans le trousseau), âge ou FC max,
   objectif de séance, voix.
5. Accepter les autorisations Santé (montre et iPhone) et micro.

Le projet est décrit dans `project.yml` ; après toute modification de ce fichier : `xcodegen generate`.

## Déroulé d'une séance

**Mode compagnon**
1. Sur l'iPhone : mode « Suivre l'app Exercice », type de séance, **Démarrer le coach**.
2. Sur la montre : lancer la séance dans l'app **Exercice**. Ouvrir WatchCoach et toucher
   « Suivre l'app Exercice » si l'iPhone n'a pas réussi à le faire à distance (la montre doit être
   joignable, c'est-à-dire WatchCoach ouvert à ce moment-là).
3. Le coach salue, puis intervient toutes les 60 s (réglable) et à chaque changement de zone cardiaque.
   Tu peux lui parler à tout moment ; il s'interrompt si tu parles.
4. **Terminer** sur l'iPhone : débrief, puis fermeture. Terminer aussi la séance dans l'app Exercice.

**Mode piloté**
1. iPhone : mode « Séance par WatchCoach », **Démarrer le coach** → la montre démarre la séance
   (via `HKHealthStore.startWatchApp`).
2. Pause / reprise / fin depuis la montre ou **Terminer** sur l'iPhone ; la séance est enregistrée dans Santé.

## Fichiers

- `Shared/MetricsSnapshot.swift` : modèle commun (métriques, zones FC, commandes, formatage).
- `WatchApp/WorkoutManager.swift` : les deux modes de capture, publication vers l'iPhone.
- `WatchApp/WatchSender.swift` : WatchConnectivity côté montre (sendMessage, puis file de secours).
- `iOS/PhoneConnectivity.swift` : réception des métriques, commandes, lancement de l'app montre.
- `iOS/RealtimeClient.swift` : WebSocket Realtime (événements GA, tolère les anciens noms `response.audio.*`).
- `iOS/AudioPipeline.swift` : micro → PCM16 24 kHz, lecture des réponses, annulation d'écho (`.voiceChat`).
- `iOS/CoachSession.swift` : orchestration (instructions, injection des métriques, cues, reconnexion, fin).
- `iOS/CoachConfig.swift`, `iOS/SettingsView.swift`, `iOS/KeychainStore.swift` : réglages et clé API.

## Points d'attention

- Écouteurs Bluetooth fortement conseillés (micro proche + annulation d'écho). Sur haut-parleur, le
  coach peut se déclencher lui-même si le volume est fort : monter `threshold` du VAD dans `CoachSession`.
- Coût : l'API Realtime facture l'audio entrant et sortant ; une séance d'une heure avec des cues toutes
  les minutes représente quelques dizaines de minutes d'audio.
- Le contexte de la conversation grossit avec les injections de métriques (toutes les 15 s par défaut) ;
  pour des séances très longues, augmenter « Métriques envoyées toutes les … s ».
- L'iPhone doit rester avec l'app active en arrière-plan (mode audio) : ne pas la tuer depuis
  le sélecteur d'apps.


## Intelligence Apple (bilan, mémoire, objectif dicté)

Le bilan de fin de séance, la mise à jour des notes de Jeffrey et la compréhension d'un objectif dicté passent
par le framework Foundation Models d'iOS 27 : d'abord le modèle serveur Apple sur **Private Cloud Compute**
(32K de contexte, raisonnement), sinon le modèle local de l'iPhone, sinon OpenAI. Réglable dans l'onglet Jeffrey
(carte Intelligence). La voix en séance reste sur l'API Realtime d'OpenAI.

Pour que le modèle serveur soit disponible, le compte développeur doit obtenir l'entitlement Private Cloud Compute :

1. Être inscrit au programme App Store Small Business (App Store Connect, Accords).
2. Demander l'entitlement : https://developer.apple.com/contact/request/private-cloud-compute/ (moins de 2 M de téléchargements).
3. Une fois accordé, régénérer les profils (`xcodebuild … -allowProvisioningUpdates`) ; TestFlight et ad hoc sont couverts.

Tant que l'entitlement manque, l'app le signale dans la carte Intelligence et utilise le modèle local, puis OpenAI.
Le modèle local exige Apple Intelligence activé (Réglages > Apple Intelligence et Siri) sur un iPhone 15 Pro ou plus récent.
