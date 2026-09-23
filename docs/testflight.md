# TestFlight — quoi coller, et où

L'icône est déjà dans le build (jeu complet iPhone + montre, 1024 sans couche alpha). Il ne reste que du texte.
Tout se passe sur appstoreconnect.apple.com, app Jeffrey, onglet **TestFlight**.

---

## 1. App Store Connect › TestFlight › Informations de test (colonne de gauche, « Informations de test »)

Ces champs sont communs à tous les builds. Ils ne sont obligatoires que pour les testeurs externes, mais
autant les remplir tout de suite.

**Adresse e-mail de contact**

```
rv@colard.net
```

**Prénom / Nom du contact**

```
Hervé Colard
```

**URL de politique de confidentialité** (obligatoire pour les testeurs externes)

```
https://jeffrey-api.dns-d5d.workers.dev/privacy
```

> Cette page n'existe pas encore : soit je l'ajoute au Worker (dis-le moi, c'est dix minutes), soit tu mets
> une page à toi. Le texte de la page est plus bas, section 5.

**Description de l'app bêta**

```
Jeffrey est un coach sportif vocal. Il parle pendant la séance, s'appuie sur la fréquence cardiaque, l'allure,
la distance et le relief mesurés par l'Apple Watch, et s'adapte au niveau et à l'objectif de chacun.

On lui parle normalement : lui demander un exercice, un chronomètre, un point sur l'effort, changer d'objectif
en courant. La montre affiche le temps et les consignes ; le téléphone reste dans la poche.

Une Apple Watch jumelée est indispensable : c'est elle qui mesure le cœur. Sans elle, aucune séance ne démarre.
```

---

## 2. App Store Connect › TestFlight › le build 1.0 (1) › « Nouveautés de cette version »

Ce texte est propre à chaque build : à réécrire à chaque envoi.

```
Première version de test.

À essayer :
• Démarrer une séance depuis l'iPhone ou depuis la montre.
• Répondre à la question de départ : un temps (« 30 minutes tranquille »), une distance (« 5 km »),
  « à ma façon » ou « propose-moi un truc ».
• Faire dérouler un exercice proposé : annonces de blocs, décompte « 30 secondes » puis « 10 secondes ».
• Parler à Jeffrey en courant : demander l'allure, la fréquence cardiaque, un rappel, un autre objectif.
• Pause et reprise depuis la montre, fin de séance à la voix.
• Après la séance : bilan, ressenti, historique, tracé.

À signaler :
• Les moments où Jeffrey ne comprend pas ou répond à côté.
• Les erreurs de détection entre marche et course.
• Tout chiffre annoncé qui ne correspond pas à la montre.
```

---

## 3. App Store Connect › TestFlight › Informations de revue (testeurs externes seulement)

Visible après avoir créé un groupe de testeurs externes, dans « Informations de revue bêta ».

**Notes**

```
L'app exige iOS 27 et une Apple Watch jumelée. Sans montre connectée à l'app, aucune séance ne peut démarrer :
c'est volontaire, la montre est le capteur.

La connexion se fait avec « Se connecter avec Apple », puis le compte doit être autorisé par l'administrateur.
Le compte utilisé pour la revue a été autorisé à l'avance.

Le coach est vocal : prévoir des écouteurs ou un environnement calme. En intérieur et sans mouvement, Jeffrey
se connecte et parle, mais la séance restera à l'arrêt (pas de cadence, pas de distance).
```

**Compte de démonstration** : laisser vide, la connexion se fait avec Apple.

> Avant d'envoyer en revue externe : lancer l'app une fois avec le compte Apple du testeur, puis l'autoriser
> dans l'app, onglet **Jeffrey › Accès et utilisateurs**. Sans ça l'app reste sur « demande envoyée » et la
> revue échoue.

---

## 4. Ajouter des testeurs

- **Internes** (jusqu'à 100 personnes de ton équipe App Store Connect) : TestFlight › Testeurs internes ›
  ajouter la personne, cocher le build. Disponible en quelques minutes, sans revue.
- **Externes** : TestFlight › Groupes › nouveau groupe › ajouter des adresses e-mail. Première revue d'Apple,
  en général sous 24 heures, puis chaque nouveau build passe une revue allégée.

Chaque testeur doit être autorisé par toi dans l'app (onglet Jeffrey › Accès), et chaque séance consomme la clé
OpenAI du serveur (4 séances par jour et par personne).

---

## 5. Texte de la page de politique de confidentialité

À publier telle quelle, sur le Worker ou sur une page à toi.

```
Politique de confidentialité — Jeffrey

Jeffrey est un coach sportif vocal. Voici ce qui est collecté et où cela va.

Reste sur ton iPhone, et n'est envoyé nulle part : ton profil (prénom, âge, taille, poids, niveau), tes
séances et leurs bilans, tes tracés GPS, les notes que Jeffrey garde de vous, la transcription de vos échanges.
Ces données sont effaçables depuis l'app (onglets Toi et Jeffrey).

Envoyé à OpenAI pendant la séance : ta voix, les réponses de Jeffrey, et les mesures de la séance (fréquence
cardiaque, allure, distance, relief) nécessaires au coaching. OpenAI traite ces données pour produire la
réponse vocale. Aucune donnée de santé n'est envoyée en dehors de la séance.

Envoyé à notre serveur (Cloudflare Workers) : uniquement ton identifiant Apple anonyme et le nombre de séances
du jour, pour vérifier ton accès et compter le quota. Ni ta voix, ni tes mesures, ni tes conversations n'y
transitent.

Apple Santé : l'app lit tes séances, ta fréquence cardiaque, ta distance et tes calories, et peut y écrire la
séance qu'elle enregistre. Ces échanges restent entre ton iPhone, ta montre et Apple Santé.

Position : utilisée pendant la séance pour le tracé et l'allure. Le tracé reste sur ton iPhone.

Aucune publicité, aucun traqueur, aucune revente de données.

Suppression : effacer l'app supprime tout ce qui est local. Pour supprimer ton compte du serveur, écris à
rv@colard.net.

Contact : rv@colard.net
```

---

## 6. Plus tard, pour une soumission App Store

Captures obligatoires : iPhone 6,9 pouces, iPhone 6,5 pouces, et Apple Watch. Inutiles pour TestFlight.
Il faudra aussi remplir le formulaire « Confidentialité des données » (santé, localisation, audio, identifiants)
et une description de l'app. Je peux générer les captures depuis le simulateur le moment venu.
