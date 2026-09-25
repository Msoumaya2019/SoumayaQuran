#!/usr/bin/env node
/**
 * Proxy de jetons Quran Foundation pour l'application Soumaya.
 *
 * Rôle unique : détenir le `client_secret` et échanger un grant
 * `client_credentials` contre un jeton d'accès de courte durée, que
 * l'application consomme. Le secret ne quitte jamais ce processus.
 *
 * Pourquoi c'est nécessaire : la Content API n'accepte que le grant
 * `client_credentials`, qui exige un client confidentiel. Un secret compilé
 * dans un APK ou un IPA est extractible ; il donnerait à n'importe qui le
 * contrôle du quota de l'application.
 *
 * Aucune dépendance : `node qf-token-proxy.mjs` suffit.
 *
 * Variables d'environnement :
 *   QF_CLIENT_ID         (requis) identifiant du projet, dev-console.quran.foundation
 *   QF_CLIENT_SECRET     (requis) secret du projet, affiché une seule fois
 *   QF_AUTH_BASE_URL     (option) défaut https://oauth2.quran.foundation
 *   PORT                 (option) défaut 8787
 *   RATE_LIMIT_PER_HOUR  (option) défaut 30 requêtes par IP et par heure
 *
 * Limite assumée : ce proxy est ouvrable par quiconque connaît son URL. Il
 * protège le *secret*, pas le *quota*. Le jeton délivré ne porte que le scope
 * `content`, en lecture seule. Pour fermer complètement l'accès, ajoutez une
 * attestation d'application (Firebase App Check, ou Play Integrity et
 * DeviceCheck côté mobile) et exigez-la en en-tête.
 */

import { createServer } from 'node:http';

const config = {
  clientId: process.env.QF_CLIENT_ID,
  clientSecret: process.env.QF_CLIENT_SECRET,
  authBaseUrl: process.env.QF_AUTH_BASE_URL ?? 'https://oauth2.quran.foundation',
  port: Number(process.env.PORT ?? 8787),
  rateLimitPerHour: Number(process.env.RATE_LIMIT_PER_HOUR ?? 30),
};

if (!config.clientId || !config.clientSecret) {
  console.error(
    'QF_CLIENT_ID et QF_CLIENT_SECRET sont requis.\n' +
      'Ces valeurs viennent de https://dev-console.quran.foundation',
  );
  process.exit(1);
}

/** Marge avant expiration : les jetons vivent 3600 s. */
const SAFETY_MARGIN_MS = 90_000;

let cached = null;
let inFlight = null;

/** Échange un jeton auprès de la Quran Foundation. */
async function exchangeToken() {
  const credentials = Buffer.from(
    `${config.clientId}:${config.clientSecret}`,
  ).toString('base64');

  const response = await fetch(`${config.authBaseUrl}/oauth2/token`, {
    method: 'POST',
    headers: {
      authorization: `Basic ${credentials}`,
      'content-type': 'application/x-www-form-urlencoded',
      accept: 'application/json',
    },
    // Le Content API n'accepte que ce grant ; le flux PKCE est réservé aux
    // User APIs.
    body: 'grant_type=client_credentials&scope=content',
  });

  const body = await response.text();

  if (!response.ok) {
    throw new Error(`Échange refusé (${response.status}) : ${body}`);
  }

  const parsed = JSON.parse(body);
  if (!parsed.access_token) {
    throw new Error(`Réponse sans access_token : ${body}`);
  }

  const expiresIn = Number(parsed.expires_in ?? 3600);
  cached = {
    token: parsed.access_token,
    expiresAt: Date.now() + expiresIn * 1000,
  };

  console.log(
    `[proxy] jeton renouvelé, valable ${expiresIn} s`,
  );
  return cached;
}

/** Renvoie un jeton valide, en mutualisant les appels concurrents. */
async function currentToken() {
  if (cached && Date.now() < cached.expiresAt - SAFETY_MARGIN_MS) {
    return cached;
  }
  inFlight ??= exchangeToken().finally(() => {
    inFlight = null;
  });
  return inFlight;
}

/** Compteur de requêtes par IP, fenêtré sur une heure. */
const buckets = new Map();

function isRateLimited(ip) {
  const now = Date.now();
  const windowMs = 3_600_000;
  const bucket = buckets.get(ip);

  if (!bucket || now - bucket.start >= windowMs) {
    buckets.set(ip, { start: now, count: 1 });
    return false;
  }

  bucket.count += 1;
  return bucket.count > config.rateLimitPerHour;
}

// Purge périodique : sans cela la table grossit indéfiniment.
setInterval(() => {
  const now = Date.now();
  for (const [ip, bucket] of buckets) {
    if (now - bucket.start >= 3_600_000) buckets.delete(ip);
  }
}, 600_000).unref();

function sendJson(response, status, payload) {
  const body = JSON.stringify(payload);
  response.writeHead(status, {
    'content-type': 'application/json; charset=utf-8',
    'cache-control': 'no-store',
    'content-length': Buffer.byteLength(body),
  });
  response.end(body);
}

const server = createServer(async (request, response) => {
  const url = new URL(request.url ?? '/', `http://${request.headers.host}`);

  if (url.pathname === '/health') {
    sendJson(response, 200, { ok: true, hasToken: cached !== null });
    return;
  }

  if (url.pathname !== '/qf/token') {
    sendJson(response, 404, { message: 'Chemin inconnu.', type: 'not_found' });
    return;
  }

  if (request.method !== 'GET') {
    sendJson(response, 405, {
      message: 'Seul GET est accepté.',
      type: 'invalid_request',
    });
    return;
  }

  const ip =
    request.headers['x-forwarded-for']?.split(',')[0]?.trim() ??
    request.socket.remoteAddress ??
    'inconnue';

  if (isRateLimited(ip)) {
    sendJson(response, 429, {
      message: 'Trop de demandes de jeton.',
      type: 'rate_limit_exceeded',
    });
    return;
  }

  try {
    const { token, expiresAt } = await currentToken();
    sendJson(response, 200, {
      access_token: token,
      token_type: 'Bearer',
      expires_in: Math.max(0, Math.floor((expiresAt - Date.now()) / 1000)),
    });
  } catch (error) {
    console.error('[proxy] échec :', error.message);
    // Le détail de l'erreur amont reste dans les journaux du serveur : il peut
    // contenir des informations sur les identifiants.
    sendJson(response, 502, {
      message: 'Échange de jeton impossible.',
      type: 'bad_gateway',
    });
  }
});

server.listen(config.port, () => {
  console.log(`[proxy] à l'écoute sur http://localhost:${config.port}`);
  console.log('[proxy] endpoint : GET /qf/token');
});
