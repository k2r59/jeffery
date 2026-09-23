# App Store › Distribution — textes à coller

> Ces champs ne servent **pas** à TestFlight. Pour distribuer une bêta, seul l'onglet TestFlight compte
> (voir `docs/testflight.md`). Remplis ceci le jour où tu veux publier sur l'App Store.

Page : App Store Connect › Jeffrey › **Distribution** › App iOS Version 1.0.

---

## Sous-titre (30 caractères max)
Page « Informations sur l'app », pas sur celle-ci.

```
Ton coach vocal en courant
```

## Texte promotionnel (170 caractères max)
Modifiable à tout moment sans nouvelle version.

```
Un coach qui te parle pendant l'effort. Il lit ton cœur sur l'Apple Watch, s'adapte à ton niveau et t'accompagne à la voix, du premier pas au bilan.
```

## Description (4 000 caractères max)

```
Jeffrey est un coach sportif qui parle avec toi pendant ta séance.

Tu choisis ton sport, tu appuies sur un bouton, et il te demande simplement ce que tu veux faire aujourd'hui : un temps, une distance, une séance à ta façon, ou une proposition de sa part. Ensuite, le téléphone reste dans la poche.

IL VOIT CE QUE TU FAIS
L'Apple Watch mesure ton cœur, ta distance, ton allure, ta cadence. Jeffrey sait quand tu marches, quand tu cours, quand ça monte, quand tu t'arrêtes. Il intervient quand ça compte, et il se tait le reste du temps.

TU LUI PARLES NORMALEMENT
« Mon allure ? », « Préviens-moi dans cinq minutes », « Propose-moi un fractionné », « On passe à vingt-cinq minutes », « Sois plus discret ». Il répond, il lance le chronomètre, il change l'objectif. Rien à valider sur le téléphone.

DES SÉANCES QUI TE VONT
Il propose des séances adaptées à ton sport et à ton niveau, de la marche-course pour reprendre au fractionné au seuil. Il annonce chaque bloc, décompte les dernières secondes, et te dit quoi faire au moment exact.

LA MONTRE PARLE AUSSI
Le chronomètre, la zone cardiaque à tenir, l'allure cible, le profil d'une montée : tout s'affiche en grand au poignet, et la montre vibre aux changements. Pause et fin se commandent depuis la montre.

APRÈS L'EFFORT
Un bilan écrit de ta séance, ton ressenti, ton historique, ton tracé. Jeffrey garde des notes durables sur toi, une gêne, un objectif, une préférence, et s'en sert la fois suivante.

CE QU'IL TE FAUT
Une Apple Watch jumelée : c'est elle qui mesure ton cœur, sans elle aucune séance ne démarre. Des écouteurs sont conseillés. iOS 27 minimum.

Jeffrey n'est pas un professionnel de santé. Il ne pose aucun diagnostic et renvoie vers un médecin quand un signal sort de l'ordinaire.
```

## Mots-clés (100 caractères max, séparés par des virgules, sans espace après la virgule)

```
coach,course,running,marche,fractionné,cardio,vocal,apple watch,entraînement,allure,footing,gps
```

## URL de l'assistance (obligatoire)

```
https://jeffrey-api.dns-d5d.workers.dev/aide
```

## URL marketing (facultative)

Laisser vide, ou mettre la même que l'assistance.

## Copyright (200 caractères max)

```
2026 Hervé Colard
```

## Fichier de couverture géographique, Extrait d'app, App iMessage, Game Center

Rien à mettre : laisser vide, ne pas cocher Game Center.

---

## Informations utiles à la vérification de l'app

**Connexion requise** : décocher la case. Il n'y a ni nom d'utilisateur ni mot de passe, la connexion se fait
avec « Se connecter avec Apple », donc avec le compte du relecteur.

**Coordonnées**

```
Hervé Colard · rv@colard.net
```

**Remarques (4 000 caractères max)**

```
Fonctionnement et prérequis

Jeffrey est un coach sportif vocal. Il exige iOS 27 et une Apple Watch jumelée avec l'app montre installée :
la montre mesure la fréquence cardiaque, sans elle aucune séance ne peut démarrer. C'est volontaire.

Connexion : « Se connecter avec Apple », aucun mot de passe. Le compte est ensuite autorisé par
l'administrateur. Pour la vérification, l'autorisation automatique a été activée : le compte du relecteur sera
accepté dès sa première connexion.

Pour essayer sans sortir courir
1. Ouvrir l'app, suivre la configuration (intention, prénom, montre, micro, position, compte).
2. À l'étape finale, lancer le tour d'essai de deux minutes : Jeffrey se présente, demande de marcher
   quelques pas dans la pièce, confirme qu'il entend et que la montre transmet le cœur.
3. Pour une séance complète, appuyer sur « Démarrer » depuis l'écran d'accueil. Sans mouvement, la distance
   et l'allure restent à zéro, mais la conversation, le chronomètre et les affichages de la montre
   fonctionnent normalement.

Micro et son : l'app écoute en continu pendant la séance pour permettre la conversation. Des écouteurs sont
conseillés, sinon le haut-parleur suffit.

Santé : l'app lit la fréquence cardiaque, la distance, les calories et les séances, et enregistre la séance
qu'elle pilote. Position : utilisée pour le tracé et l'allure pendant la séance uniquement.
```

**Pièce jointe** : facultative. Une courte vidéo d'une séance aide la vérification si elle est refusée pour
« fonctionnalité non démontrable ».

## Publication de la version

« Publier cette version manuellement » est le choix prudent pour une première app.

---

## Ce qui reste à produire pour publier

- **Captures d'écran** : iPhone 6,5 pouces (1242 × 2688 ou 2688 × 1242) et iPhone 6,9 pouces, plus Apple Watch.
  Je peux les générer depuis le simulateur.
- **Deux pages web** : assistance et politique de confidentialité (texte prêt dans `docs/testflight.md`).
  À héberger sur le Worker ou ailleurs.
- **Formulaire « Confidentialité de l'app »** : déclarer santé, localisation, audio et identifiants.
- **Un point à régler avant la revue** : la liste blanche. Le relecteur d'Apple doit pouvoir utiliser l'app
  après sa connexion, donc son compte doit être autorisé, ou l'app doit accepter tout le monde le temps
  de la revue.
