// A pretend Google for the worker tests (no network): the OAuth token endpoint and the Gmail send endpoint.
// Every test environment gets its own refresh token, so the messages "sent" through it are kept apart.
let counter = 0;
const byRefresh = new Map();
const byAccess = new Map();
const realFetch = globalThis.fetch;

function b64urlToBytes(s) { return Buffer.from(s.replace(/-/g, '+').replace(/_/g, '/'), 'base64'); }

function decodeWords(v) {
  return v.replace(/(\?=)\s+(?==\?UTF-8\?B\?)/g, '$1').replace(/=\?UTF-8\?B\?([A-Za-z0-9+/=]+)\?=/g, (m, b) => Buffer.from(b, 'base64').toString('utf8'));
}

// Reads the raw RFC 2822 message the worker built.
export function parseRaw(raw) {
  const text = b64urlToBytes(raw).toString('utf8');
  const [head, ...rest] = text.split('\r\n\r\n');
  const body = rest.join('\r\n\r\n');
  const headers = {}; const names = [];
  for (const line of head.replace(/\r\n[ \t]+/g, ' ').split('\r\n')) {
    const i = line.indexOf(':'); const k = line.slice(0, i).toLowerCase(); headers[k] = line.slice(i + 1).trim(); names.push(k);
  }
  const m = /boundary="([^"]+)"/.exec(headers['content-type'] || '');
  const parts = {};
  if (m) {
    for (const seg of body.split('--' + m[1])) {
      const ph = /Content-Type: ([a-z/]+); charset="UTF-8"\r\nContent-Transfer-Encoding: base64\r\n\r\n([\s\S]*?)\r\n$/.exec(seg.replace(/^\r\n/, ''));
      if (ph) { parts[ph[1]] = Buffer.from(ph[2].replace(/\r\n/g, ''), 'base64').toString('utf8'); }
    }
  }
  return { raw: text, headers, names, subject: decodeWords(headers['subject'] || ''), from: decodeWords(headers['from'] || ''), to: headers['to'], text: (parts['text/plain'] || '').replace(/\r\n/g, '\n'), html: parts['text/html'] || '' };
}

function jsonRes(status, obj) { return new Response(JSON.stringify(obj), { status: status, headers: { 'content-type': 'application/json' } }); }

export const urlsSeen = [];
globalThis.fetch = async function (url, init) {
  url = String(url);
  urlsSeen.push(url);
  if (url === 'https://oauth2.googleapis.com/token') {
    const f = new URLSearchParams(init.body);
    const g = byRefresh.get(f.get('refresh_token'));
    if (!g) { return jsonRes(400, { error: 'invalid_grant', error_description: 'Bad Request' }); }
    g.tokenCalls++;
    g.lastTokenForm = Object.fromEntries(f.entries());
    if (g.tokenFails) { return jsonRes(g.tokenFails, { error: 'invalid_grant', error_description: 'Token has been expired or revoked.' }); }
    if (g.tokenNetworkDown) { throw new TypeError('network down'); }
    if (f.get('client_id') !== g.clientId || f.get('client_secret') !== g.clientSecret || f.get('grant_type') !== 'refresh_token') { return jsonRes(401, { error: 'invalid_client' }); }
    const at = 'at-' + g.id + '-' + (++g.issued);
    byAccess.set(at, g);
    return jsonRes(200, { access_token: at, expires_in: g.expiresIn, scope: 'https://www.googleapis.com/auth/gmail.send', token_type: 'Bearer' });
  }
  if (url === 'https://gmail.googleapis.com/gmail/v1/users/me/messages/send') {
    const auth = (init.headers && (init.headers.authorization || init.headers.Authorization)) || '';
    const g = byAccess.get(auth.replace(/^Bearer /, ''));
    if (!g) { return jsonRes(401, { error: { code: 401, message: 'Invalid Credentials' } }); }
    g.sendCalls++;
    if (g.rejectNextToken) { g.rejectNextToken = false; byAccess.delete(auth.replace(/^Bearer /, '')); return jsonRes(401, { error: { code: 401, message: 'Invalid Credentials' } }); }
    const m = parseRaw(JSON.parse(init.body).raw);
    g.lastRawBytes = init.body.length;
    if (g.sendFails) { return jsonRes(g.sendFails, { error: { code: g.sendFails, message: 'nope' } }); }
    if (g.failTo && m.to === g.failTo) { return jsonRes(400, { error: { code: 400, message: 'Invalid To header' } }); }
    g.sent.push(m);
    return jsonRes(200, { id: 'm' + g.sent.length, threadId: 't', labelIds: ['SENT'] });
  }
  return realFetch(url, init);
};

// Adds the Gmail settings to an env object and returns the pretend account (env._google).
export function addGoogle(env, opts) {
  opts = opts || {};
  const id = ++counter;
  const g = Object.assign({ id: id, clientId: 'cid-' + id + '.apps.googleusercontent.com', clientSecret: 'secret-' + id, refresh: 'refresh-' + id, expiresIn: 3599,
    sent: [], tokenCalls: 0, sendCalls: 0, issued: 0, tokenFails: 0, sendFails: 0, tokenNetworkDown: false, failTo: '', rejectNextToken: false }, opts);
  byRefresh.set(g.refresh, g);
  env.GMAIL_CLIENT_ID = g.clientId; env.GMAIL_CLIENT_SECRET = g.clientSecret; env.GMAIL_REFRESH_TOKEN = g.refresh;
  env.MAIL_FROM = 'Family Fix-It <familyfixit.help@gmail.com>';
  env._google = g; env._sent = g.sent;
  return g;
}
