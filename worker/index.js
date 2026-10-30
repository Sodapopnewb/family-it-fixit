// Family Fix-It report receiver (Cloudflare Worker, ES module).
//
// POST /report  with header  X-FixIt-App: family-it-fixit  and JSON {pcName, version, kind, report}.
// No secrets are needed by the callers. The app header is a speed bump, not security:
// the real protections are the size limits, the rate limits and strict validation.
//
// "Who helps you?" (v2.3.14). The JSON may also carry  helper: {name, email, pcId}  and  owner: "<first name>".
//   * No helper, or the helper is the operator (Trey): the report is stored (and emailed to REPORT_TO when that is set), exactly as before.
//   * A different helper: the report goes to that helper by email ONLY after the helper has said yes, for that helper email AND that PC.
//     The first time a new (helper email, PC) pair is seen, the helper gets one email with a confirm link. Until they confirm, reports for
//     that pair go to the operator (stored, as before) and the answer says so ("delivery":"trey","helperStatus":"pending").
//   * A kind "hello" post only asks for the confirmation. It carries no report and stores nothing.
//   * Reports delivered to a confirmed helper are NOT stored in KV (the friend asked for their family's data to go to the helper, not to the operator).
//
// Anti-abuse: every route is rate limited per client address and in total; the confirm email is limited per client address, per helper email
// (1 a day, 3 in 30 days) and in total per day; a confirmed pair can send a bounded number of emails an hour; names are stripped of anything
// that could make a link or a header; the confirm and stop pages change nothing on GET (so mail scanners cannot confirm for anyone).
//
// Email goes out through the Gmail API as the one Gmail account of the operator (secrets GMAIL_CLIENT_ID, GMAIL_CLIENT_SECRET and
// GMAIL_REFRESH_TOKEN, variable MAIL_FROM; the scope is gmail.send only). Gmail allows about 500 messages a day, so the daily totals below
// stay well under that. When the Google token cannot be had, nothing is lost: reports go to the operator's own delivery path (KV) as before,
// the error is logged (wrangler tail) and the last error is kept in KV under gmail/last-error.

const MAX_BODY_BYTES = 512 * 1024 - 1; // reports must be smaller than 512 KB
const MAX_FORM_BYTES = 2048; // the confirm and stop pages post tiny forms
const MAX_EMAIL_BODY = 200 * 1024; // the part of a report that is put in a helper email
const APP_HEADER = 'x-fixit-app';
const APP_VALUE = 'family-it-fixit';
const TTL_SECONDS = 60 * 60 * 24 * 30; // keep stored reports for 30 days
const PENDING_TTL_SECONDS = 60 * 60 * 24 * 14; // an unanswered confirm link works for 14 days
const RATE_PER_MINUTE = 10; // per client address
const GLOBAL_PER_MINUTE = 30; // all clients together: a family of a few PCs never gets near this; a distributed flood does
const CONFIRM_PER_IP_HOUR = 5; // confirm emails one client address can cause in an hour
const CONFIRM_PER_HELPER_DAY = 1; // confirm emails to one helper address in a day (all PCs together)
const CONFIRM_PER_HELPER_MONTH = 3; // ... and in 30 days
const CONFIRM_PER_DAY_DEFAULT = 100; // confirm emails in total per day (env MAX_CONFIRMS_PER_DAY)
const REPORT_MAILS_PER_PC_HOUR = 12; // report emails for one confirmed (helper, PC) pair
const REPORT_MAILS_PER_HELPER_HOUR = 60; // report emails to one helper address in an hour
const REPORT_MAILS_PER_DAY_DEFAULT = 200; // report emails to helpers in total per day (env MAX_MAILS_PER_DAY)
const MAIL_TOTAL_PER_DAY_DEFAULT = 300; // every email the worker sends in a day, all kinds together (env MAX_TOTAL_MAILS_PER_DAY); Gmail's own limit is about 500
const MAIL_OPERATOR_RESERVE = 50; // emails to the operator may go this far past the total (a scam alert must still arrive)
const GOOGLE_TOKEN_URL = 'https://oauth2.googleapis.com/token';
const GMAIL_SEND_URL = 'https://gmail.googleapis.com/gmail/v1/users/me/messages/send';
const TOKEN_MARGIN_MS = 120 * 1000; // ask Google for a new access token when less than this is left
const TOKEN_ERROR_PAUSE_SECONDS = 300; // after a token error, do not ask Google again for this long (the reports go to the operator meanwhile)
const NAME_MAX = 40; // helper and owner names
const EMAIL_MAX = 120;

function json(status, obj, extra) {
  const headers = { 'content-type': 'application/json; charset=utf-8', 'cache-control': 'no-store' };
  if (extra) { for (const k of Object.keys(extra)) { headers[k] = extra[k]; } }
  return new Response(JSON.stringify(obj), { status: status, headers: headers });
}

function esc(s) {
  return String(s).replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;').replace(/'/g, '&#39;');
}

function page(title, bodyHtml, status) {
  const html = '<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">' +
    '<meta name="robots" content="noindex"><title>' + esc(title) + '</title>' +
    '<style>body{font-family:Segoe UI,Arial,sans-serif;max-width:34em;margin:2em auto;padding:0 1em;color:#1a1a1a;line-height:1.5}' +
    'h1{font-size:1.5em}button{font-size:1.1em;padding:.6em 1.2em;margin:.4em .4em .4em 0;border-radius:6px;border:1px solid #2b6cb0;background:#2b6cb0;color:#fff;cursor:pointer}' +
    'button.o{background:#fff;color:#2b6cb0}.s{color:#555;font-size:.9em}</style></head><body>' + bodyHtml + '</body></html>';
  return new Response(html, { status: status || 200, headers: { 'content-type': 'text/html; charset=utf-8', 'cache-control': 'no-store', 'x-robots-tag': 'noindex', 'referrer-policy': 'no-referrer' } });
}

async function readLimited(request, limit) {
  const declared = request.headers.get('content-length');
  if (declared !== null && Number(declared) > limit) { return null; }
  if (!request.body) { return ''; }
  const reader = request.body.getReader();
  const chunks = [];
  let total = 0;
  for (;;) {
    const r = await reader.read();
    if (r.done) { break; }
    total += r.value.byteLength;
    if (total > limit) { try { await reader.cancel(); } catch (e) { /* ignore */ } return null; }
    chunks.push(r.value);
  }
  const all = new Uint8Array(total);
  let off = 0;
  for (const c of chunks) { all.set(c, off); off += c.byteLength; }
  return new TextDecoder('utf-8', { fatal: false }).decode(all);
}

function cleanLine(value, max) {
  return String(value).replace(/[\u0000-\u001f\u007f]/g, ' ').trim().slice(0, max);
}

// A person's name for a sentence or a subject line: letters, digits, spaces, apostrophes and hyphens only. No dots, slashes, colons or at-signs,
// so a name can never turn into a link or an address.
export function cleanName(value, max) {
  if (typeof value !== 'string') { return ''; }
  return value.normalize('NFKC').replace(/[^\p{L}\p{N}\s'\u2019-]/gu, ' ').replace(/\s+/g, ' ').trim().slice(0, max || NAME_MAX).trim();
}

// One plain address, lower case. Returns '' when it is not one.
export function cleanEmail(value) {
  if (typeof value !== 'string') { return ''; }
  const e = value.trim().toLowerCase();
  if (e.length < 6 || e.length > EMAIL_MAX) { return ''; }
  if (!/^[a-z0-9][a-z0-9._%+'-]*@[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)*\.[a-z]{2,24}$/.test(e)) { return ''; }
  if (e.indexOf('..') >= 0) { return ''; }
  return e;
}

function cleanPcId(value) {
  return (typeof value === 'string' && /^[0-9a-f]{32}$/.test(value)) ? value : '';
}

async function sha256Hex(s) {
  const d = await crypto.subtle.digest('SHA-256', new TextEncoder().encode(s));
  return Array.from(new Uint8Array(d)).map((b) => b.toString(16).padStart(2, '0')).join('');
}

function randomToken() {
  const b = new Uint8Array(24); crypto.getRandomValues(b);
  return Array.from(b).map((x) => x.toString(16).padStart(2, '0')).join('');
}

function sameText(a, b) {
  a = String(a); b = String(b);
  if (a.length !== b.length) { return false; }
  let d = 0;
  for (let i = 0; i < a.length; i++) { d |= a.charCodeAt(i) ^ b.charCodeAt(i); }
  return d === 0;
}

function validate(data) {
  if (data === null || typeof data !== 'object' || Array.isArray(data)) { return 'Body must be a JSON object.'; }
  if (typeof data.pcName !== 'string' || data.pcName.trim() === '') { return 'pcName is required.'; }
  if (typeof data.version !== 'string' || !/^[0-9A-Za-z._-]{1,32}$/.test(data.version)) { return 'version is invalid.'; }
  if (data.kind !== undefined && data.kind !== 'report' && data.kind !== 'scam' && data.kind !== 'health' && data.kind !== 'hello') { return 'kind is invalid.'; }
  if (data.kind === 'hello') {
    if (data.helper === undefined || data.helper === null || typeof data.helper !== 'object') { return 'helper is required.'; }
  } else if (typeof data.report !== 'string' || data.report.trim() === '') { return 'report is required.'; }
  if (data.helper !== undefined && data.helper !== null) {
    if (typeof data.helper !== 'object' || Array.isArray(data.helper)) { return 'helper is invalid.'; }
    if (!cleanEmail(data.helper.email)) { return 'helper email is invalid.'; }
    if (!cleanName(data.helper.name, NAME_MAX)) { return 'helper name is invalid.'; }
    if (!cleanPcId(data.helper.pcId)) { return 'helper pcId is invalid.'; }
  }
  if (data.owner !== undefined && typeof data.owner !== 'string') { return 'owner is invalid.'; }
  return null;
}

function kindLead(kind) {
  return kind === 'scam' ? '[Family Fix-It] SCAM ALERT from ' : (kind === 'health' ? '[Family Fix-It] Weekly health check from ' : '[Family Fix-It] Report from ');
}

// The email to the operator (the legacy path). Unchanged except for one optional note line.
function buildEmail(rec, note) {
  return {
    subject: kindLead(rec.kind) + rec.pcName + ' (v' + rec.version + ')',
    text: (rec.kind === 'scam' ? 'SCAM ALERT - the person pressed the red button. Call them now.\n\n' : '') + (note ? note + '\n\n' : '') + 'Received: ' + rec.receivedAt + '\nPC: ' + rec.pcName + '\nTool version: ' + rec.version + '\n\n' + rec.report
  };
}

function who(owner, pcName) { return owner || pcName; }

// The email to a confirmed helper.
function buildHelperEmail(rec, owner, pcSafe, helperName, stopUrl) {
  const from = who(owner, pcSafe);
  const lead = rec.kind === 'scam' ? '[Family Fix-It] SCAM ALERT from ' : (rec.kind === 'health' ? '[Family Fix-It] Weekly health check from ' : '[Family Fix-It] Report from ');
  let body = rec.report;
  let cut = '';
  if (body.length > MAX_EMAIL_BODY) { body = body.slice(0, MAX_EMAIL_BODY); cut = '\n\n[The report was cut here because it is very long.]'; }
  return {
    subject: lead + from + ' (v' + rec.version + ')',
    text: (rec.kind === 'scam' ? 'SCAM ALERT - ' + from + ' pressed the red button. Call them now.\n\n' : '') +
      'Hi ' + helperName + ', this is a Family Fix-It report from ' + from + ' (PC: ' + pcSafe + ').\nReceived: ' + rec.receivedAt + '\nTool version: ' + rec.version + '\n\n' +
      body + cut +
      '\n\n--\nYou get this because ' + from + ' chose you as their Fix-It helper and you said yes.\nTo stop emails from this PC, or from everyone, open: ' + stopUrl + '\n'
  };
}

function buildConfirmEmail(owner, pcName, helperName, confirmUrl, stopUrl) {
  const from = who(owner, pcName);
  return {
    subject: from + ' wants you as their Fix-It helper',
    text: 'Hi ' + helperName + ',\n\n' +
      from + ' uses a free program called Family Fix-It on their Windows PC (' + pcName + '). It can fix common computer problems and, when they ask, send a report about the PC to someone they trust.\n\n' +
      from + ' picked you. If you say yes, reports from that PC will be emailed to you. The reports describe the PC (Windows version, printers, recent problems). They contain no files and no passwords.\n\n' +
      'To say yes (or no), open this link:\n' + confirmUrl + '\n\n' +
      'Nothing happens until you press a button on that page. If you do not know ' + from + ', just ignore this email: no reports will be sent to you, and this is the only email you will get about it.\n\n' +
      'To make sure you never get email from Family Fix-It, open: ' + stopUrl + '\n'
  };
}

// ---------- counters (one Durable Object per counter; the window is a parameter) ----------
export class RateLimiter {
  constructor(state) { this.state = state; }
  async fetch(request) {
    let w = 60;
    try { const q = parseInt(new URL(request.url).searchParams.get('w') || '60', 10); if (q >= 1 && q <= 60 * 60 * 24 * 31) { w = q; } } catch (e) { /* default */ }
    const slot = Math.floor(Date.now() / (w * 1000));
    let st = await this.state.storage.get('c');
    if (!st || st.m !== slot) { st = { m: slot, n: 0 }; }
    st.n += 1;
    await this.state.storage.put('c', st);
    return new Response(JSON.stringify({ n: st.n }), { headers: { 'content-type': 'application/json' } });
  }
}

// IPv6 clients rotate the last 64 bits, so count them by their /64 network. IPv4 stays as it is.
export function clientKey(ip) {
  if (ip.indexOf(':') < 0) { return ip; }
  return ip.split(':').slice(0, 4).join(':');
}

// Adds one to the named counter and returns its new value inside the window (seconds). Throws when it cannot count.
async function bump(env, name, windowSeconds, nowMs) {
  if (env.LIMITER) {
    const r = await env.LIMITER.get(env.LIMITER.idFromName(name)).fetch('https://limiter.internal/hit?w=' + windowSeconds);
    return (await r.json()).n;
  }
  if (!env.REPORTS) { throw new Error('no counter'); }
  const key = 'rl/' + name + '/' + Math.floor(nowMs / (windowSeconds * 1000));
  const seen = parseInt((await env.REPORTS.get(key)) || '0', 10) || 0;
  await env.REPORTS.put(key, String(seen + 1), { expirationTtl: Math.max(60, windowSeconds * 2) });
  return seen + 1;
}

// The request limit. Fails open (a counter hiccup must not lose a report), unlike the mail limits below, which fail closed.
async function overLimit(env, ip, nowMs) {
  if (env.LIMITER) {
    try {
      if ((await bump(env, 'ip:' + clientKey(ip), 60, nowMs)) > RATE_PER_MINUTE) { return true; }
      return (await bump(env, 'all', 60, nowMs)) > GLOBAL_PER_MINUTE;
    } catch (e) { return false; }
  }
  if (!env.REPORTS) { return false; }
  const key = 'rl/' + ip + '/' + Math.floor(nowMs / 60000);
  const seen = parseInt((await env.REPORTS.get(key)) || '0', 10) || 0;
  if (seen >= RATE_PER_MINUTE) { return true; }
  await env.REPORTS.put(key, String(seen + 1), { expirationTtl: 120 });
  return false;
}

// True when every counter is within its cap. Fails closed: if the worker cannot count, it does not send mail.
async function mailAllowed(env, nowMs, checks) {
  try {
    for (const c of checks) { if ((await bump(env, c[0], c[1], nowMs)) > c[2]) { return false; } }
    return true;
  } catch (e) { return false; }
}

function intEnv(v, dflt) { const n = parseInt(v, 10); return (n >= 0 && n < 1e9) ? n : dflt; }
function mailReady(env) { return !!(env.GMAIL_CLIENT_ID && env.GMAIL_CLIENT_SECRET && env.GMAIL_REFRESH_TOKEN && env.MAIL_FROM); }
// ---------- email through the Gmail API ----------
const encoder = new TextEncoder();
function toBase64(bytes) {
  let bin = '';
  for (let i = 0; i < bytes.length; i += 0x8000) { bin += String.fromCharCode.apply(null, bytes.subarray(i, i + 0x8000)); }
  return btoa(bin);
}
function base64Url(bytes) { return toBase64(bytes).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, ''); }
function wrap76(b64) { return b64.replace(/(.{76})/g, '$1\r\n'); }
function oneLine(s) { return String(s).replace(/[\r\n\u2028\u2029]+/g, ' ').trim(); }

// A header value that may hold non-ASCII text, as RFC 2047 encoded words (each at most 45 bytes of UTF-8, so a word stays under 75 characters).
export function encodeHeaderText(text) {
  const t = oneLine(text);
  if (/^[\x20-\x7e]*$/.test(t)) { return t; }
  const words = [];
  let cur = '';
  let curBytes = 0;
  for (const ch of t) {
    const n = encoder.encode(ch).length;
    if (curBytes + n > 45) { words.push(cur); cur = ''; curBytes = 0; }
    cur += ch; curBytes += n;
  }
  if (cur) { words.push(cur); }
  return words.map(function (w) { return '=?UTF-8?B?' + toBase64(encoder.encode(w)) + '?='; }).join('\r\n ');
}

// "Name <address>" -> a safe From header. Returns { header, address }.
function parseFrom(from) {
  const f = oneLine(from);
  const m = /^(.*?)\s*<([^<>\s,;"]+@[^<>\s,;"]+)>$/.exec(f);
  if (m) {
    const name = m[1].replace(/^"|"$/g, '');
    if (!name) { return { header: '<' + m[2] + '>', address: m[2] }; }
    const shown = /^[\x20-\x7e]*$/.test(name) ? '"' + name.replace(/(["\\])/g, '\\$1') + '"' : encodeHeaderText(name);
    return { header: shown + ' <' + m[2] + '>', address: m[2] };
  }
  if (/^[^<>\s,;"]+@[^<>\s,;"]+$/.test(f)) { return { header: f, address: f }; }
  throw new Error('MAIL_FROM is not a mail address');
}

// The text as a small, plain HTML page. Only links that start with linkBase (our own confirm and stop links) become clickable.
export function htmlFromText(text, linkBase) {
  let h = esc(text);
  if (linkBase) {
    const b = esc(linkBase);
    const re = new RegExp(b.replace(/[.*+?^${}()|[\]\\]/g, '\\$&') + '[^\\s<]*', 'g');
    h = h.replace(re, function (u) { return '<a href="' + u + '">' + u + '</a>'; });
  }
  return '<div style="font-family:Segoe UI,Arial,sans-serif;font-size:15px;line-height:1.5;color:#1a1a1a;white-space:pre-wrap">' + h + '</div>';
}

// The whole message (RFC 2822, UTF-8, plain text plus HTML) as base64url, which is what the Gmail API wants in "raw".
export function buildRawMessage(env, msg) {
  const from = parseFrom(env.MAIL_FROM);
  const to = oneLine(msg.to);
  if (!/^[^\s<>,;"()\\]+@[^\s<>,;"()\\]+$/.test(to)) { throw new Error('the recipient is not a mail address'); }
  const boundary = 'fixit-' + crypto.randomUUID().replace(/-/g, '');
  const lines = [
    'From: ' + from.header,
    'To: ' + to,
    'Subject: ' + encodeHeaderText(msg.subject),
    'MIME-Version: 1.0',
    'Auto-Submitted: auto-generated'
  ];
  if (msg.unsubscribe && /^https:\/\/[^\s<>]+$/.test(msg.unsubscribe)) {
    lines.push('List-Unsubscribe: <' + msg.unsubscribe + '>');
    lines.push('List-Unsubscribe-Post: List-Unsubscribe=One-Click');
  }
  lines.push('Content-Type: multipart/alternative; boundary="' + boundary + '"');
  const part = function (type, body) {
    return '--' + boundary + '\r\nContent-Type: ' + type + '; charset="UTF-8"\r\nContent-Transfer-Encoding: base64\r\n\r\n' + wrap76(toBase64(encoder.encode(body))) + '\r\n';
  };
  const text = String(msg.text).replace(/\r?\n/g, '\r\n');
  const raw = lines.join('\r\n') + '\r\n\r\n' + part('text/plain', text) + part('text/html', htmlFromText(msg.text, msg.linkBase)) + '--' + boundary + '--\r\n';
  return base64Url(encoder.encode(raw));
}

let tokenMemory = null; // { token, exp }
let tokenErrorUntil = 0;
export function resetMailCache() { tokenMemory = null; tokenErrorUntil = 0; }

async function noteTokenError(env, nowMs, what) {
  console.error('Gmail: ' + what);
  tokenErrorUntil = nowMs + TOKEN_ERROR_PAUSE_SECONDS * 1000;
  tokenMemory = null;
  if (env.REPORTS) {
    try {
      await env.REPORTS.put('gmail/err', what, { expirationTtl: TOKEN_ERROR_PAUSE_SECONDS });
      await env.REPORTS.put('gmail/last-error', JSON.stringify({ at: new Date(nowMs).toISOString(), error: what }), { expirationTtl: 60 * 60 * 24 * 30 });
    } catch (e) { /* the log line above is enough */ }
  }
}

// An access token for the one Gmail account: from memory, then from KV, then from Google (refresh-token flow). Throws when Google says no.
async function getAccessToken(env, nowMs, force) {
  if (!force) {
    if (tokenMemory && tokenMemory.exp - nowMs > TOKEN_MARGIN_MS) { return tokenMemory.token; }
    if (env.REPORTS) {
      const c = await getJson(env, 'gmail/token');
      if (c && c.t && c.exp - nowMs > TOKEN_MARGIN_MS) { tokenMemory = { token: c.t, exp: c.exp }; return c.t; }
    }
    if (nowMs < tokenErrorUntil) { throw new Error('Google refused the token a moment ago; not asking again yet'); }
    if (env.REPORTS) {
      const e = await env.REPORTS.get('gmail/err');
      if (e) { tokenErrorUntil = nowMs + 30000; throw new Error('Google refused the token a moment ago (' + e + '); not asking again yet'); }
    }
  }
  let r;
  try {
    r = await fetch(GOOGLE_TOKEN_URL, {
      method: 'POST',
      headers: { 'content-type': 'application/x-www-form-urlencoded' },
      body: new URLSearchParams({ client_id: env.GMAIL_CLIENT_ID, client_secret: env.GMAIL_CLIENT_SECRET, refresh_token: env.GMAIL_REFRESH_TOKEN, grant_type: 'refresh_token' }).toString()
    });
  } catch (e) {
    await noteTokenError(env, nowMs, 'could not reach Google for a token');
    throw new Error('could not reach Google for a token');
  }
  let body = null;
  try { body = await r.json(); } catch (e) { body = null; }
  if (!r.ok || !body || typeof body.access_token !== 'string' || !body.access_token) {
    const what = 'token request refused (' + r.status + (body && body.error ? ' ' + String(body.error).slice(0, 60) : '') + (body && body.error_description ? ': ' + String(body.error_description).slice(0, 120) : '') + ')';
    await noteTokenError(env, nowMs, what);
    throw new Error(what);
  }
  const secs = Math.max(60, Math.min(Number(body.expires_in) || 3600, 3600));
  tokenMemory = { token: body.access_token, exp: nowMs + secs * 1000 };
  tokenErrorUntil = 0;
  if (env.REPORTS) {
    try { await env.REPORTS.put('gmail/token', JSON.stringify({ t: body.access_token, exp: tokenMemory.exp }), { expirationTtl: Math.max(60, secs - 60) }); } catch (e) { /* memory is enough */ }
  }
  return body.access_token;
}

// Sends one message. msg = { to, subject, text, unsubscribe?, linkBase? }. Throws on any problem (the callers fall back to the operator path).
async function sendMail(env, nowMs, msg, opts) {
  if (!mailReady(env)) { throw new Error('email is not set up'); }
  const total = intEnv(env.MAX_TOTAL_MAILS_PER_DAY, MAIL_TOTAL_PER_DAY_DEFAULT) + (opts && opts.operator ? MAIL_OPERATOR_RESERVE : 0);
  if (!(await mailAllowed(env, nowMs, [['gd', 86400, total]]))) { throw new Error('the daily total of emails is reached'); }
  const raw = buildRawMessage(env, msg);
  const post = async function (token) {
    return await fetch(GMAIL_SEND_URL, { method: 'POST', headers: { authorization: 'Bearer ' + token, 'content-type': 'application/json' }, body: JSON.stringify({ raw: raw }) });
  };
  let res = await post(await getAccessToken(env, nowMs, false));
  if (res.status === 401) {
    if (env.REPORTS) { try { await env.REPORTS.delete('gmail/token'); } catch (e) { /* fine */ } }
    res = await post(await getAccessToken(env, nowMs, true));
  }
  if (!res.ok) {
    console.error('Gmail: send refused (' + res.status + ')');
    throw new Error('Gmail refused the message (' + res.status + ')');
  }
}

function baseUrl(env, request) { return String(env.PUBLIC_URL || new URL(request.url).origin).replace(/\/+$/, ''); }
function isOperator(env, email) {
  const list = String(env.OPERATOR_EMAILS || env.REPORT_TO || '').toLowerCase().split(/[\s,;]+/).filter(Boolean);
  return list.indexOf(email) >= 0;
}
async function getJson(env, key) {
  if (!env.REPORTS) { return null; }
  const v = await env.REPORTS.get(key);
  if (!v) { return null; }
  try { return JSON.parse(v); } catch (e) { return null; }
}
function linkFor(base, path, hid, token) { return base + path + '?id=' + hid + '&t=' + token; }

// ---------- the report path ----------
async function storeAndMailOperator(env, rec, textLen, receivedAt, id, note, nowMs) {
  let stored = false;
  let emailed = false;
  if (env.REPORTS) {
    await env.REPORTS.put('report/' + id, JSON.stringify(rec), {
      expirationTtl: TTL_SECONDS,
      metadata: { pcName: rec.pcName, version: rec.version, kind: rec.kind, receivedAt: receivedAt, bytes: textLen }
    });
    stored = true;
  }
  // Optional email copy to the operator. Dormant until the Gmail secrets, MAIL_FROM and REPORT_TO exist. A failure here never loses the report (it is in KV).
  if (env.REPORT_TO && mailReady(env)) {
    try {
      const mail = buildEmail(rec, note);
      await sendMail(env, nowMs, { to: env.REPORT_TO, subject: mail.subject, text: mail.text }, { operator: true });
      emailed = true;
    } catch (e) { emailed = false; }
  }
  return { stored: stored, emailed: emailed };
}

function recordId(kind, receivedAt) {
  return (kind === 'scam' ? 'SCAM-' : (kind === 'health' ? 'HEALTH-' : '')) + receivedAt.replace(/[:.]/g, '-') + '-' + crypto.randomUUID().slice(0, 8);
}

async function handleReport(request, env, nowMs, ip) {
  const ctype = (request.headers.get('content-type') || '').toLowerCase();
  if (ctype.indexOf('application/json') !== 0) { return json(415, { ok: false, error: 'Send JSON.' }); }
  const text = await readLimited(request, MAX_BODY_BYTES);
  if (text === null) { return json(413, { ok: false, error: 'Report is too large (limit 512 KB).' }); }
  let data;
  try { data = JSON.parse(text); } catch (e) { return json(400, { ok: false, error: 'Body is not valid JSON.' }); }
  const bad = validate(data);
  if (bad) { return json(400, { ok: false, error: bad }); }

  const receivedAt = new Date(nowMs).toISOString();
  const kind = data.kind === 'scam' ? 'scam' : (data.kind === 'health' ? 'health' : (data.kind === 'hello' ? 'hello' : 'report'));
  const rec = {
    receivedAt: receivedAt,
    pcName: cleanLine(data.pcName, 100),
    version: data.version,
    kind: kind,
    report: typeof data.report === 'string' ? data.report : ''
  };
  const owner = cleanName(data.owner, NAME_MAX);
  const pcSafe = cleanName(rec.pcName, NAME_MAX) || 'a PC'; // the only form of the PC name that is put in a mail to a stranger or on a confirm page

  // A helper who is not the operator?
  let helper = null;
  if (data.helper) {
    const email = cleanEmail(data.helper.email);
    if (env.REPORTS && !isOperator(env, email)) { helper = { email: email, name: cleanName(data.helper.name, NAME_MAX), pcId: cleanPcId(data.helper.pcId) }; }
  }
  if (kind === 'hello' && !helper) {
    return json(200, { ok: true, delivery: 'trey', helperStatus: 'none', confirmSent: false });
  }
  if (!helper) {
    const id = recordId(kind, receivedAt);
    const d = await storeAndMailOperator(env, rec, text.length, receivedAt, id, '', nowMs);
    if (!d.stored && !d.emailed) { return json(500, { ok: false, error: 'Could not save the report.' }); }
    return json(202, { ok: true, id: id, stored: d.stored, emailed: d.emailed, delivery: 'trey', helperStatus: 'none' });
  }

  const eh = await sha256Hex(helper.email);
  const hid = await sha256Hex(helper.email + '|' + helper.pcId);
  const base = baseUrl(env, request);
  const blocked = await env.REPORTS.get('hb/' + eh);
  let hp = await getJson(env, 'hp/' + hid);
  let status = blocked ? 'declined' : (hp ? hp.status : 'none');
  let confirmSent = false;
  let confirmReason = '';

  if (status === 'confirmed') {
    if (kind === 'hello') { return json(200, { ok: true, delivery: 'helper', helperStatus: 'confirmed', confirmSent: false }); }
    const caps = [
      ['mp:' + hid, 3600, REPORT_MAILS_PER_PC_HOUR],
      ['mh:' + eh, 3600, REPORT_MAILS_PER_HELPER_HOUR],
      ['md', 86400, intEnv(env.MAX_MAILS_PER_DAY, REPORT_MAILS_PER_DAY_DEFAULT)]
    ];
    let sent = false; let why = '';
    if (!mailReady(env)) { why = 'email-off'; }
    else if (!(await mailAllowed(env, nowMs, caps))) { why = 'limited'; }
    else {
      try {
        const mail = buildHelperEmail(rec, owner, pcSafe, hp.name || helper.name, linkFor(base, '/stop', hid, hp.token));
        await sendMail(env, nowMs, { to: helper.email, subject: mail.subject, text: mail.text, unsubscribe: linkFor(base, '/stop', hid, hp.token), linkBase: base });
        sent = true;
      } catch (e) { why = 'send-failed'; }
    }
    if (sent) {
      const id = recordId(kind, receivedAt);
      return json(202, { ok: true, id: id, stored: false, emailed: true, delivery: 'helper', helperStatus: 'confirmed' });
    }
    // The helper could not be reached right now: never lose the report, give it to the operator and say so.
    const id = recordId(kind, receivedAt);
    rec.helper = { name: helper.name, status: 'confirmed-but-' + why };
    const d = await storeAndMailOperator(env, rec, text.length, receivedAt, id, 'Note: ' + (owner || rec.pcName) + ' chose ' + helper.name + ' as helper, but the email to them could not go out (' + why + ').', nowMs);
    if (!d.stored && !d.emailed) { return json(500, { ok: false, error: 'Could not save the report.' }); }
    return json(202, { ok: true, id: id, stored: d.stored, emailed: d.emailed, delivery: 'trey', helperStatus: 'confirmed', reason: why });
  }

  // not confirmed (none, pending, stopped, declined): maybe ask once, then the operator keeps the report
  if (status === 'none' || status === 'pending') {
    const recent = (status === 'pending') && hp && (nowMs - hp.asked) < 24 * 3600 * 1000;
    if (recent) { confirmReason = 'recent'; }
    else if (!mailReady(env)) { confirmReason = 'email-off'; }
    else {
      const caps = [
        ['cip:' + clientKey(ip), 3600, CONFIRM_PER_IP_HOUR],
        ['ch:' + eh, 86400, CONFIRM_PER_HELPER_DAY],
        ['chm:' + eh, 30 * 86400, CONFIRM_PER_HELPER_MONTH],
        ['cd', 86400, intEnv(env.MAX_CONFIRMS_PER_DAY, CONFIRM_PER_DAY_DEFAULT)]
      ];
      if (!(await mailAllowed(env, nowMs, caps))) { confirmReason = 'limited'; }
      else {
        const token = randomToken();
        try {
          const mail = buildConfirmEmail(owner, pcSafe, helper.name, linkFor(base, '/confirm', hid, token), linkFor(base, '/stop', hid, token));
          await sendMail(env, nowMs, { to: helper.email, subject: mail.subject, text: mail.text, unsubscribe: linkFor(base, '/stop', hid, token), linkBase: base });
          await env.REPORTS.put('hp/' + hid, JSON.stringify({ status: 'pending', token: token, name: helper.name, eh: eh, owner: owner, pcName: pcSafe, asked: nowMs }), { expirationTtl: PENDING_TTL_SECONDS });
          confirmSent = true; confirmReason = 'sent'; status = 'pending';
        } catch (e) { confirmReason = 'send-failed'; }
      }
    }
  }
  if (kind === 'hello') {
    return json(200, { ok: true, delivery: 'trey', helperStatus: status, confirmSent: confirmSent, confirmReason: confirmReason });
  }
  const id = recordId(kind, receivedAt);
  rec.helper = { name: helper.name, status: status };
  const note = 'Note: ' + (owner || rec.pcName) + ' chose ' + helper.name + ' as their helper, who has not said yes yet (' + status + '). This report came to you for now.';
  const d = await storeAndMailOperator(env, rec, text.length, receivedAt, id, note, nowMs);
  if (!d.stored && !d.emailed) { return json(500, { ok: false, error: 'Could not save the report.' }); }
  return json(202, { ok: true, id: id, stored: d.stored, emailed: d.emailed, delivery: 'trey', helperStatus: status, confirmSent: confirmSent, confirmReason: confirmReason });
}

// ---------- the confirm and stop pages ----------
async function loadPair(env, id, token) {
  if (!/^[0-9a-f]{64}$/.test(id || '') || !token) { return null; }
  const hp = await getJson(env, 'hp/' + id);
  if (!hp || !hp.token || !sameText(hp.token, token)) { return null; }
  return hp;
}

function badLink() {
  return page('Link not valid', '<h1>This link no longer works</h1><p>It may be too old, or it was already used. If you still want to help, ask the person to set you up again in Family Fix-It.</p>', 404);
}

function form(action, id, token, fields, label, cls) {
  let inputs = '<input type="hidden" name="id" value="' + esc(id) + '"><input type="hidden" name="t" value="' + esc(token) + '">';
  for (const k of Object.keys(fields)) { inputs += '<input type="hidden" name="' + esc(k) + '" value="' + esc(fields[k]) + '">'; }
  return '<form method="post" action="' + action + '" style="display:inline">' + inputs + '<button type="submit"' + (cls ? ' class="' + cls + '"' : '') + '>' + esc(label) + '</button></form>';
}

async function handlePages(request, env, url, nowMs) {
  const isPost = request.method === 'POST';
  let id = url.searchParams.get('id') || '';
  let token = url.searchParams.get('t') || '';
  let action = '';
  if (isPost) {
    const raw = await readLimited(request, MAX_FORM_BYTES);
    if (raw === null) { return json(413, { ok: false, error: 'Too large.' }); }
    const f = new URLSearchParams(raw);
    id = f.get('id') || id; token = f.get('t') || token; action = f.get('action') || '';
    if (raw.indexOf('List-Unsubscribe=One-Click') >= 0) { action = 'pc'; }
  }
  const hp = await loadPair(env, id, token);
  if (!hp) { return badLink(); }
  const from = hp.owner || hp.pcName || 'Someone';
  const name = hp.name || 'there';

  if (url.pathname === '/confirm') {
    if (!isPost) {
      if (hp.status === 'confirmed') {
        return page('Already yes', '<h1>You already said yes</h1><p>Reports from ' + esc(from) + '\'s PC will keep coming to your email.</p>' + form('/stop', id, token, { action: 'pc' }, 'Stop emails from this PC', 'o'));
      }
      if (hp.status !== 'pending') { return badLink(); }
      return page('Be a Fix-It helper?',
        '<h1>' + esc(from) + ' wants you as their Fix-It helper</h1>' +
        '<p>Hi ' + esc(name) + '. ' + esc(from) + ' uses a free program called Family Fix-It on a Windows PC (' + esc(hp.pcName || '') + '). When something goes wrong, or they ask, it can email you a short report about that PC: Windows version, printers, recent problems. No files and no passwords.</p>' +
        '<p>Do you want to get those reports?</p>' +
        form('/confirm', id, token, {}, 'Yes, send me their reports') +
        form('/stop', id, token, { action: 'all' }, 'No, and do not email me again', 'o'));
    }
    if (hp.status === 'pending' || hp.status === 'confirmed') {
      if (hp.status === 'pending') { hp.status = 'confirmed'; hp.confirmedAt = nowMs; await env.REPORTS.put('hp/' + id, JSON.stringify(hp)); } // no expiry once confirmed
      return page('Thank you', '<h1>Thank you, you are all set</h1><p>Reports from ' + esc(from) + '\'s PC will now come to your email. Each one has a link at the bottom to stop them.</p>');
    }
    return badLink();
  }

  // /stop
  if (!isPost) {
    return page('Stop emails',
      '<h1>Stop Family Fix-It emails?</h1><p>Choose what you want. Nothing changes until you press a button.</p>' +
      form('/stop', id, token, { action: 'pc' }, 'Stop emails from ' + from + '\'s PC') +
      form('/stop', id, token, { action: 'all' }, 'Never email me about Family Fix-It', 'o'));
  }
  if (action === 'all') {
    const eh = hp.eh || '';
    if (eh) { await env.REPORTS.put('hb/' + eh, '1'); }
    await env.REPORTS.put('hp/' + id, JSON.stringify(Object.assign({}, hp, { status: 'declined' })), { expirationTtl: 60 * 60 * 24 * 365 });
    return page('Stopped', '<h1>Done</h1><p>You will not get any more Family Fix-It email at this address.</p>');
  }
  if (action === 'pc') {
    await env.REPORTS.put('hp/' + id, JSON.stringify(Object.assign({}, hp, { status: 'stopped' })), { expirationTtl: 60 * 60 * 24 * 365 });
    return page('Stopped', '<h1>Done</h1><p>You will not get any more reports from ' + esc(from) + '\'s PC.</p>');
  }
  return badLink();
}

export async function handleRequest(request, env, now) {
  const url = new URL(request.url);
  if (url.pathname === '/health' && request.method === 'GET') { return json(200, { ok: true }); }
  const nowMs = now === undefined ? Date.now() : now;
  const ip = request.headers.get('cf-connecting-ip') || 'unknown';

  if (url.pathname === '/confirm' || url.pathname === '/stop') {
    if (request.method !== 'GET' && request.method !== 'POST') { return json(405, { ok: false, error: 'Use GET or POST.' }, { allow: 'GET, POST' }); }
    if (await overLimit(env, ip, nowMs)) { return json(429, { ok: false, error: 'Too many requests. Try again in a minute.' }, { 'retry-after': '60' }); }
    return await handlePages(request, env, url, nowMs);
  }

  if (url.pathname !== '/report') { return json(404, { ok: false, error: 'Not found.' }); }
  if (request.method !== 'POST') { return json(405, { ok: false, error: 'Use POST.' }, { allow: 'POST' }); }
  if (request.headers.get(APP_HEADER) !== APP_VALUE) { return json(403, { ok: false, error: 'Not allowed.' }); }

  let limited = false;
  if (env.RL) { const rl = await env.RL.limit({ key: ip }); if (!rl.success) { limited = true; } }
  if (!limited) { limited = await overLimit(env, ip, nowMs); }
  if (limited) { return json(429, { ok: false, error: 'Too many reports. Try again in a minute.' }, { 'retry-after': '60' }); }

  return await handleReport(request, env, nowMs, ip);
}

export default {
  async fetch(request, env) {
    try { return await handleRequest(request, env); }
    catch (e) { return json(500, { ok: false, error: 'Server error.' }); }
  }
};
