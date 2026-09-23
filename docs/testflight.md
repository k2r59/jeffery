# TestFlight — textes à coller

L'icône est déjà dans le build (jeu complet iPhone + montre, 1024 sans alpha). Il ne reste que du texte.

## Description de l'app bêta

Jeffrey est un coach sportif vocal. Il parle pendant la séance, s'appuie sur la fréquence cardiaque, l'allure,
la distance et le relief mesurés par l'Apple Watch, et s'adapte au niveau et à l'objectif de la personne.
On lui parle normalement : on lui demande un exercice, un chronomètre, un changement d'objectif, un point
sur l'effort. La montre affiche le chrono et les consignes ; le téléphone reste dans la poche.

## Ce qu'il faut tester

- Lancer une séance depuis l'iPhone ou depuis la montre (l'Apple Watch est obligatoire).
- Répondre à la question de départ : un temps, une distance, « à ma façon » ou « propose-moi un truc ».
- Faire dérouler un exercice proposé : annonces de blocs, décompte « 30 secondes », « 10 secondes ».
- Parler à Jeffrey en courant : lui demander l'allure, la fréquence cardiaque, un rappel, un changement d'objectif.
- Pause et reprise depuis la montre, fin de séance à la voix.
- Après la séance : bilan, ressenti, historique, tracé.

## Adresse de retour

rv@colard.net

## Notes pour la revue (testeurs externes seulement)

L'app exige iOS 27 et une Apple Watch jumelée : sans montre connectée, aucune séance ne peut démarrer.
La connexion se fait avec Apple, puis le compte doit être autorisé par l'administrateur (liste blanche du
serveur). **Avant toute revue externe, autoriser le compte du testeur Apple**, sinon l'app reste bloquée
sur « demande envoyée » et la revue échoue. Prévoir aussi un mot sur l'impossibilité de tester une vraie
séance en intérieur sans mouvement.

## Pour une soumission App Store (plus tard)

Captures obligatoires : iPhone 6,9 pouces et 6,5 pouces, plus l'Apple Watch. Aucune n'est nécessaire pour
TestFlight. Il faudra aussi une URL de politique de confidentialité et le formulaire « confidentialité des
données » (santé, localisation, audio).
