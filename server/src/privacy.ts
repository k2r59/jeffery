// Politique de confidentialité, servie sur GET /privacy (URL déclarée dans App Store Connect).
export const PRIVACY_HTML = `<!doctype html>
<html lang="fr">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Jeffrey · Confidentialité</title>
<style>
  :root { color-scheme: light dark; }
  body { font: 16px/1.6 -apple-system, BlinkMacSystemFont, "Helvetica Neue", sans-serif; max-width: 720px; margin: 0 auto; padding: 32px 20px 64px; background: #101411; color: #F2F0E7; }
  h1 { font-size: 30px; margin-bottom: 4px; } h1 span { color: #D4FF4B; }
  h2 { font-size: 19px; margin-top: 32px; color: #D4FF4B; }
  p, li { color: #E2E0D6; } .muted { color: #97A48C; font-size: 14px; }
  a { color: #D4FF4B; } hr { border: 0; border-top: 1px solid #2c3529; margin: 40px 0; }
</style>
</head>
<body>
<h1><span>J</span>effrey · Politique de confidentialité</h1>
<p class="muted">Dernière mise à jour : 1er octobre 2026</p>

<p>Jeffrey est un coach sportif vocal pour iPhone et Apple Watch. Cette page explique quelles données l'app utilise, où elles vont et comment les supprimer.</p>

<h2>Ce qui reste sur ton iPhone et ta montre</h2>
<ul>
  <li>Ton profil (prénom, âge, taille, poids, niveau, objectifs), la mémoire de Jeffrey, tes séances, leurs bilans et leurs tracés GPS.</li>
  <li>Les données de l'app Santé (fréquence cardiaque, distance, calories, séances d'entraînement) : lues et enregistrées dans Santé, jamais envoyées au serveur de Jeffrey.</li>
  <li>Ta position pendant une séance, pour le tracé et l'allure.</li>
</ul>

<h2>Ce que conserve le serveur de Jeffrey</h2>
<ul>
  <li>Ton compte : l'identifiant anonyme fourni par « Se connecter avec Apple », l'adresse e-mail et le nom si tu as choisi de les partager, ton statut d'accès et les dates de création et de dernière connexion.</li>
  <li>Un compteur de séances (total, et par jour pendant 3 jours) pour appliquer la limite quotidienne.</li>
</ul>
<p>Le serveur ne reçoit ni ta voix, ni ce que tu dis, ni tes données de santé, ni ta position.</p>

<h2>Ce qui passe par OpenAI</h2>
<ul>
  <li>Pendant une séance, ta voix et les mesures de la séance (temps, distance, allure, fréquence cardiaque) sont envoyées directement à OpenAI pour que Jeffrey te comprenne et te réponde.</li>
  <li>À la fin d'une séance, un résumé (mesures, échanges, ton profil sportif) est envoyé à OpenAI pour rédiger le bilan et mettre à jour la mémoire de Jeffrey.</li>
  <li>OpenAI traite ces données via son API, qui ne les utilise pas pour entraîner ses modèles. Voir <a href="https://openai.com/policies/privacy-policy">la politique de confidentialité d'OpenAI</a>.</li>
  <li>Si tu choisis « Apple AI », la conversation reste sur ton iPhone ou passe par le cloud privé d'Apple, sans OpenAI.</li>
</ul>

<h2>Ce que Jeffrey ne fait pas</h2>
<ul>
  <li>Pas de publicité, pas de suivi publicitaire, pas de revente de données.</li>
  <li>Pas de partage avec des tiers autres qu'OpenAI, dans le seul but de faire fonctionner le coach.</li>
</ul>

<h2>Supprimer tes données</h2>
<p>Supprimer l'app efface ce qui est sur ton iPhone et ta montre ; tes séances dans Santé se gèrent depuis l'app Santé. Pour supprimer ton compte sur le serveur, écris à <a href="mailto:herve.colard@promo.dev">herve.colard@promo.dev</a> : il est effacé sous 30 jours.</p>

<h2>Contact</h2>
<p>Hervé Colard · <a href="mailto:herve.colard@promo.dev">herve.colard@promo.dev</a></p>

<hr>

<h2>English summary</h2>
<p>Jeffrey is a voice fitness coach for iPhone and Apple Watch. Your profile, coach memory, workouts, Health data and location stay on your devices. The Jeffrey server only stores your account (anonymous Sign in with Apple identifier, e-mail and name if you share them, access status, dates) and a session counter. During a workout, your voice and workout metrics are sent directly to OpenAI so the coach can understand and answer; a summary is sent at the end to write the report. No advertising, no tracking, no data sale. To delete your account, e-mail <a href="mailto:herve.colard@promo.dev">herve.colard@promo.dev</a>.</p>
</body>
</html>`;
