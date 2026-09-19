# jeffrey-api — backend de Jeffrey (Cloudflare Worker)

Garde la clé OpenAI côté serveur, authentifie par Sign in with Apple, tient une liste blanche et délivre des jetons
éphémères Realtime (10 min, un par séance). Le profil, la mémoire et la conversation ne transitent jamais ici.

## Déploiement

```bash
cd server
npm install
npx wrangler login                      # une fois, ouvre le navigateur
npx wrangler secret put OPENAI_API_KEY  # la clé du compte OpenAI qui paie
npx wrangler secret put JWT_SECRET      # une chaîne aléatoire longue (openssl rand -base64 48)
npx wrangler deploy
```

L'URL affichée (`https://jeffrey-api.<compte>.workers.dev`) va dans `iOS/JeffreyAccount.swift` (`JeffreyBackend.baseURL`).

## Réglages (`wrangler.toml`)

- `ADMIN_EMAILS` : adresses Apple des administrateurs (sans quota, gèrent la liste blanche depuis l'app).
- `DAILY_SESSION_LIMIT` : séances par jour et par utilisateur autorisé.
- `REALTIME_MODEL`, `RESPONSES_MODEL`.
- KV `JEFFREY` : utilisateurs (`user:<id>`) et compteurs du jour (`usage:<id>:<date>`, 3 jours).

## Flux

1. L'app se connecte avec Apple → `POST /auth/apple` avec le jeton d'identité → le Worker le vérifie auprès d'Apple
   (signature, émetteur, bundle id), crée l'utilisateur en `pending` (ou `admin` si l'adresse est dans `ADMIN_EMAILS`),
   renvoie un jeton de session Jeffrey (30 jours).
2. L'administrateur passe l'utilisateur en `allowed` depuis l'onglet Jeffrey › Accès.
3. À chaque séance, `POST /session` → jeton éphémère OpenAI ; l'app ouvre le WebSocket Realtime avec.
4. Bilan de secours et mémoire : `POST /openai/responses` (proxy, mêmes droits).

Rôles : `admin`, `allowed`, `pending`, `blocked`.
