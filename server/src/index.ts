// Backend de Jeffrey (Cloudflare Worker).
//
// Rôle : garder la clé OpenAI côté serveur et ne délivrer que des jetons éphémères Realtime aux utilisateurs
// autorisés. Le profil, la mémoire et la conversation ne passent jamais ici : l'app parle directement à OpenAI
// avec le jeton. Rien n'est journalisé hormis les compteurs de séances.
//
// Routes (JSON) :
//   POST /auth/apple            { identityToken, fullName? }  → { token, user }        connexion Sign in with Apple
//   GET  /me                    Bearer <token>                → { user, quota }
//   POST /session               Bearer <token>                → { clientSecret, expiresAt, model }   jeton Realtime
//   POST /openai/responses      Bearer <token>, corps Responses → réponse OpenAI (bilan de secours, mémoire)
//   GET  /admin/users           Bearer <token admin>          → { users }
//   POST /admin/users/:id       Bearer <token admin> { role } → { user }
//
// Rôles : admin (tout, sans quota) · allowed · pending (demande d'accès à valider) · blocked.
// Invitation : clé KV invite:<email> → rôle allowed à la connexion (npx wrangler kv key put --remote --binding JEFFREY …).

import { SignJWT, jwtVerify, createRemoteJWKSet } from "jose";

export interface Env {
  JEFFREY: KVNamespace;
  OPENAI_API_KEY: string;
  JWT_SECRET: string;
  APPLE_BUNDLE_ID: string;
  ADMIN_EMAILS: string;
  DAILY_SESSION_LIMIT: string;
  REALTIME_MODEL: string;
  RESPONSES_MODEL: string;
}

type Role = "admin" | "allowed" | "pending" | "blocked";

interface User {
  id: string;          // `sub` Apple, stable par app
  email: string | null;
  name: string | null;
  role: Role;
  createdAt: string;
  lastSeenAt: string;
  sessions: number;    // total de jetons délivrés
}

const APPLE_JWKS = createRemoteJWKSet(new URL("https://appleid.apple.com/auth/keys"));
const TOKEN_DAYS = 30;

const json = (data: unknown, status = 200, headers: Record<string, string> = {}) =>
  new Response(JSON.stringify(data), { status, headers: { "content-type": "application/json; charset=utf-8", ...headers } });
const error = (status: number, message: string) => json({ error: message }, status);

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    const url = new URL(request.url);
    const path = url.pathname.replace(/\/+$/, "") || "/";
    try {
      if (request.method === "POST" && path === "/auth/apple") return await authApple(request, env);
      if (path === "/") return json({ service: "jeffrey-api", ok: true });

      const user = await authenticate(request, env);
      if (!user) return error(401, "connexion requise");

      if (request.method === "GET" && path === "/me") return json({ user: publicUser(user), quota: await quota(user, env) });
      if (request.method === "POST" && path === "/session") return await mintSession(user, env);
      if (request.method === "POST" && path === "/openai/responses") return await proxyResponses(request, user, env);

      if (path.startsWith("/admin/")) {
        if (user.role !== "admin") return error(403, "réservé à l'administrateur");
        if (request.method === "GET" && path === "/admin/users") return json({ users: await listUsers(env) });
        const m = path.match(/^\/admin\/users\/([^/]+)$/);
        if (request.method === "POST" && m) return await updateUser(decodeURIComponent(m[1]), request, user, env);
      }
      return error(404, "route inconnue");
    } catch (e) {
      return error(500, e instanceof Error ? e.message : "erreur serveur");
    }
  },
};

// MARK: Connexion Apple

async function authApple(request: Request, env: Env): Promise<Response> {
  const body = (await request.json().catch(() => null)) as { identityToken?: string; fullName?: string } | null;
  if (!body?.identityToken) return error(400, "identityToken manquant");
  let payload;
  try {
    ({ payload } = await jwtVerify(body.identityToken, APPLE_JWKS, {
      issuer: "https://appleid.apple.com",
      audience: env.APPLE_BUNDLE_ID,
    }));
  } catch (e) {
    return error(401, `jeton Apple refusé : ${e instanceof Error ? e.message : "invalide"}`);
  }
  const sub = String(payload.sub ?? "");
  if (!sub) return error(401, "jeton Apple sans identifiant");
  const email = typeof payload.email === "string" ? payload.email.toLowerCase() : null;
  const now = new Date().toISOString();
  const admins = env.ADMIN_EMAILS.split(",").map((s) => s.trim().toLowerCase()).filter(Boolean);

  let user = await getUser(sub, env);
  if (!user) {
    user = { id: sub, email, name: body.fullName?.trim() || null, role: "pending", createdAt: now, lastSeenAt: now, sessions: 0 };
  }
  // Apple ne renvoie le nom qu'à la première connexion : on le garde s'il arrive plus tard.
  if (body.fullName?.trim() && !user.name) user.name = body.fullName.trim();
  if (email && !user.email) user.email = email;
  if (user.email && admins.includes(user.email)) user.role = "admin";
  // Invitation déposée par l'administrateur (clé KV invite:<email>) : accès ouvert dès la connexion, sans validation.
  if (user.role === "pending" && user.email && (await env.JEFFREY.get(`invite:${user.email}`))) {
    user.role = "allowed";
    await env.JEFFREY.delete(`invite:${user.email}`);
  }
  user.lastSeenAt = now;
  await putUser(user, env);

  const token = await new SignJWT({ role: user.role })
    .setProtectedHeader({ alg: "HS256" })
    .setSubject(user.id)
    .setIssuedAt()
    .setExpirationTime(`${TOKEN_DAYS}d`)
    .sign(secret(env));
  return json({ token, user: publicUser(user), quota: await quota(user, env) });
}

async function authenticate(request: Request, env: Env): Promise<User | null> {
  const auth = request.headers.get("authorization") ?? "";
  const token = auth.startsWith("Bearer ") ? auth.slice(7) : "";
  if (!token) return null;
  try {
    const { payload } = await jwtVerify(token, secret(env));
    const user = await getUser(String(payload.sub ?? ""), env);
    if (!user) return null;
    user.lastSeenAt = new Date().toISOString();
    return user;
  } catch {
    return null;
  }
}

// MARK: Jeton Realtime

async function mintSession(user: User, env: Env): Promise<Response> {
  const gate = await checkAccess(user, env);
  if (gate) return gate;
  const r = await fetch("https://api.openai.com/v1/realtime/client_secrets", {
    method: "POST",
    headers: { authorization: `Bearer ${env.OPENAI_API_KEY}`, "content-type": "application/json" },
    body: JSON.stringify({
      expires_after: { anchor: "created_at", seconds: 600 },
      session: { type: "realtime", model: env.REALTIME_MODEL },
    }),
  });
  if (!r.ok) return error(502, `OpenAI : ${r.status} ${(await r.text()).slice(0, 200)}`);
  const data = (await r.json()) as { value: string; expires_at: number };
  await bumpUsage(user, env);
  return json({ clientSecret: data.value, expiresAt: data.expires_at, model: env.REALTIME_MODEL });
}

/// Bilan de secours et mémoire : l'app envoie un corps Responses, le Worker ajoute la clé. Réponse renvoyée telle quelle.
async function proxyResponses(request: Request, user: User, env: Env): Promise<Response> {
  const gate = await checkAccess(user, env);
  if (gate) return gate;
  const body = await request.text();
  if (body.length > 200_000) return error(413, "corps trop volumineux");
  const r = await fetch("https://api.openai.com/v1/responses", {
    method: "POST",
    headers: { authorization: `Bearer ${env.OPENAI_API_KEY}`, "content-type": "application/json" },
    body,
  });
  return new Response(r.body, { status: r.status, headers: { "content-type": r.headers.get("content-type") ?? "application/json" } });
}

async function checkAccess(user: User, env: Env): Promise<Response | null> {
  if (user.role === "pending") return error(403, "accès en attente de validation");
  if (user.role === "blocked") return error(403, "accès désactivé");
  if (user.role === "admin") return null;
  const q = await quota(user, env);
  if (q.used >= q.limit) return error(429, `quota du jour atteint (${q.limit} séances)`);
  return null;
}

// MARK: Quotas

const day = () => new Date().toISOString().slice(0, 10);

async function quota(user: User, env: Env): Promise<{ used: number; limit: number; unlimited: boolean }> {
  const limit = Number(env.DAILY_SESSION_LIMIT) || 4;
  const used = Number((await env.JEFFREY.get(`usage:${user.id}:${day()}`)) ?? "0");
  return { used, limit, unlimited: user.role === "admin" };
}

async function bumpUsage(user: User, env: Env): Promise<void> {
  const key = `usage:${user.id}:${day()}`;
  const used = Number((await env.JEFFREY.get(key)) ?? "0") + 1;
  await env.JEFFREY.put(key, String(used), { expirationTtl: 3 * 86400 });
  user.sessions += 1;
  await putUser(user, env);
}

// MARK: Administration

async function listUsers(env: Env): Promise<ReturnType<typeof publicUser>[]> {
  const users: User[] = [];
  let cursor: string | undefined;
  do {
    const page = await env.JEFFREY.list({ prefix: "user:", cursor });
    for (const k of page.keys) {
      const u = await env.JEFFREY.get(k.name, "json") as User | null;
      if (u) users.push(u);
    }
    cursor = page.list_complete ? undefined : page.cursor;
  } while (cursor);
  users.sort((a, b) => b.lastSeenAt.localeCompare(a.lastSeenAt));
  return users.map(publicUser);
}

async function updateUser(id: string, request: Request, admin: User, env: Env): Promise<Response> {
  const body = (await request.json().catch(() => null)) as { role?: Role } | null;
  const roles: Role[] = ["admin", "allowed", "pending", "blocked"];
  if (!body?.role || !roles.includes(body.role)) return error(400, "rôle invalide");
  const user = await getUser(id, env);
  if (!user) return error(404, "utilisateur inconnu");
  if (user.id === admin.id && body.role !== "admin") return error(400, "tu ne peux pas te retirer l'administration");
  user.role = body.role;
  await putUser(user, env);
  return json({ user: publicUser(user) });
}

// MARK: Stockage

async function getUser(id: string, env: Env): Promise<User | null> {
  if (!id) return null;
  return (await env.JEFFREY.get(`user:${id}`, "json")) as User | null;
}

async function putUser(user: User, env: Env): Promise<void> {
  await env.JEFFREY.put(`user:${user.id}`, JSON.stringify(user));
}

function publicUser(u: User) {
  return { id: u.id, email: u.email, name: u.name, role: u.role, createdAt: u.createdAt, lastSeenAt: u.lastSeenAt, sessions: u.sessions };
}

function secret(env: Env): Uint8Array {
  if (!env.JWT_SECRET) throw new Error("JWT_SECRET manquant");
  return new TextEncoder().encode(env.JWT_SECRET);
}
