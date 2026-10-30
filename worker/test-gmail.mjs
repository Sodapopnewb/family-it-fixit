// Tests for sending email through the Gmail API (OAuth refresh-token flow). Run:  node test-gmail.mjs   (no network: Google is pretended)
import assert from 'node:assert/strict';
import { handleRequest, RateLimiter, resetMailCache, encodeHeaderText, htmlFromText, buildRawMessage } from './index.js';
import { addGoogle, parseRaw, urlsSeen } from './mock-google.mjs';

let pass = 0;
let clock = 1000000; Date.now = () => clock;
async function t(name, fn) { await fn(); pass++; console.log('PASS ' + name); }
const errors = []; const realErr = console.error; console.error = (...a) => { errors.push(a.join(' ')); };

function mkEnv(o) {
  o = o || {};
  const kv = new Map(); const objs = new Map();
  const env = {
    REPORTS: { get: async (k) => { const e = kv.get(k); return e && !(e.x && clock >= e.x) ? e.v : null; }, put: async (k, v, opt) => { kv.set(k, { v: v, o: opt, x: opt && opt.expirationTtl ? clock + opt.expirationTtl * 1000 : 0 }); }, delete: async (k) => { kv.delete(k); } },
    LIMITER: { idFromName: (n) => n, get: (id) => { if (!objs.has(id)) { const m = new Map(); objs.set(id, new RateLimiter({ storage: { get: async (k) => m.get(k), put: async (k, v) => { m.set(k, v); } } })); } return { fetch: (u) => objs.get(id).fetch(new Request(u)) }; } },
    PUBLIC_URL: 'https://w.example', _kv: kv
  };
  resetMailCache();
  if (o.google !== false) { addGoogle(env, o.google || {}); }
  if (o.trey) { env.REPORT_TO = 'trey@example.com'; }
  return env;
}
const PC = 'a'.repeat(32);
function post(body, ip) { return new Request('https://w.example/report', { method: 'POST', headers: { 'content-type': 'application/json', 'x-fixit-app': 'family-it-fixit', 'cf-connecting-ip': ip || '1.2.3.4' }, body: JSON.stringify(body) }); }
function hello(extra) { return Object.assign({ pcName: 'MOMS-LAPTOP', version: '2.3.14', kind: 'hello', owner: 'Ann', helper: { name: 'Mike', email: 'mike@example.net', pcId: PC } }, extra || {}); }
function rep(extra) { return Object.assign({ pcName: 'MOMS-LAPTOP', version: '2.3.14', kind: 'report', report: 'the report text', owner: 'Ann', helper: { name: 'Mike', email: 'mike@example.net', pcId: PC } }, extra || {}); }
async function go(env, body, ip, now) { clock = now === undefined ? 1000000 : now; const r = await handleRequest(post(body, ip), env, clock); return { r: r, j: await r.json() }; }
function postForm(path, fields) { return new Request('https://w.example' + path, { method: 'POST', headers: { 'content-type': 'application/x-www-form-urlencoded', 'cf-connecting-ip': '7.7.7.7' }, body: new URLSearchParams(fields).toString() }); }
async function confirm(env, now) {
  const m = env._sent[env._sent.length - 1].text.match(/https:\/\/w\.example\/confirm\?id=([0-9a-f]{64})&t=([0-9a-f]{48})/);
  const r = await handleRequest(postForm('/confirm', { id: m[1], t: m[2] }), env, now === undefined ? 1000000 : now); assert.equal(r.status, 200);
}

// ---------------------------------------------------------------- the access token
await t('the token comes from Google with the refresh-token flow: client id, secret, refresh token, nothing else', async () => {
  const env = mkEnv(); urlsSeen.length = 0;
  const g = await go(env, hello()); assert.equal(g.j.confirmSent, true);
  const gg = env._google;
  assert.equal(gg.tokenCalls, 1);
  assert.deepEqual(Object.keys(gg.lastTokenForm).sort(), ['client_id', 'client_secret', 'grant_type', 'refresh_token']);
  assert.equal(gg.lastTokenForm.grant_type, 'refresh_token'); assert.equal(gg.lastTokenForm.refresh_token, gg.refresh);
  assert.deepEqual([...new Set(urlsSeen)].sort(), ['https://gmail.googleapis.com/gmail/v1/users/me/messages/send', 'https://oauth2.googleapis.com/token']);
});
await t('the token is reused from memory, then from KV, and refreshed shortly before it expires', async () => {
  const env = mkEnv(); const gg = env._google;
  await go(env, hello({ helper: { name: 'Mike', email: 'a1@example.net', pcId: PC } }), '1.1.1.1');
  await go(env, hello({ helper: { name: 'Mike', email: 'a2@example.net', pcId: PC } }), '1.1.1.2');
  assert.equal(gg.sendCalls, 2); assert.equal(gg.tokenCalls, 1);
  resetMailCache(); // a new worker instance: the token is still in KV
  await go(env, hello({ helper: { name: 'Mike', email: 'a3@example.net', pcId: PC } }), '1.1.1.3');
  assert.equal(gg.tokenCalls, 1);
  const kvTok = JSON.parse(env._kv.get('gmail/token').v); assert.ok(kvTok.t.startsWith('at-')); assert.ok(env._kv.get('gmail/token').o.expirationTtl >= 60 && env._kv.get('gmail/token').o.expirationTtl <= 3600);
  // 3599 s later minus the 120 s margin: still fine at 3400 s, new token at 3500 s
  await go(env, hello({ helper: { name: 'Mike', email: 'a4@example.net', pcId: PC } }), '1.1.1.4', 1000000 + 3400 * 1000);
  assert.equal(gg.tokenCalls, 1);
  await go(env, hello({ helper: { name: 'Mike', email: 'a5@example.net', pcId: PC } }), '1.1.1.5', 1000000 + 3500 * 1000);
  assert.equal(gg.tokenCalls, 2); assert.equal(gg.sent.length, 5);
});
await t('a 401 from Gmail gets one new token and one retry', async () => {
  const env = mkEnv(); const gg = env._google;
  await go(env, hello({ helper: { name: 'Mike', email: 'b1@example.net', pcId: PC } }), '2.2.2.1');
  gg.rejectNextToken = true;
  const g = await go(env, hello({ helper: { name: 'Mike', email: 'b2@example.net', pcId: PC } }), '2.2.2.2');
  assert.equal(g.j.confirmSent, true); assert.equal(gg.tokenCalls, 2); assert.equal(gg.sent.length, 2);
});

// ---------------------------------------------------------------- the message
await t('the message is RFC 2822 with UTF-8: headers, plain text part and a simple HTML part', async () => {
  const env = mkEnv();
  await go(env, hello({ owner: 'Jos\u00e9 \u00d1and\u00fa', helper: { name: 'Zo\u00eb', email: 'zoe@example.net', pcId: PC } }));
  const m = env._sent[0];
  assert.equal(m.from, '"Family Fix-It" <familyfixit.help@gmail.com>');
  assert.equal(m.to, 'zoe@example.net');
  assert.equal(m.subject, 'Jos\u00e9 \u00d1and\u00fa wants you as their Fix-It helper');
  assert.match(m.headers['subject'], /^=\?UTF-8\?B\?[A-Za-z0-9+/=]+\?=/); // really encoded on the wire, not raw UTF-8
  assert.match(m.raw, /^From: /); assert.equal(m.headers['mime-version'], '1.0'); assert.match(m.headers['content-type'], /^multipart\/alternative; boundary="fixit-[0-9a-f]{32}"$/);
  assert.equal(m.headers['auto-submitted'], 'auto-generated');
  assert.ok(m.text.startsWith('Hi Zo\u00eb,\n\nJos\u00e9 \u00d1and\u00fa uses a free program called Family Fix-It')); // non-ASCII survives
  assert.match(m.html, /^<div style="[^"]*white-space:pre-wrap">Hi Zo\u00eb,/);
  assert.match(m.html, /<a href="https:\/\/w\.example\/confirm\?id=[0-9a-f]{64}&amp;t=[0-9a-f]{48}">https:\/\/w\.example\/confirm/);
  assert.equal(m.headers['list-unsubscribe'].startsWith('<https://w.example/stop?id='), true); assert.equal(m.headers['list-unsubscribe-post'], 'List-Unsubscribe=One-Click');
});
await t('the "raw" value is base64url (no +, / or =) and every line of the message is at most 998 bytes', async () => {
  const env = mkEnv(); await go(env, hello());
  const sentBody = env._google.lastRawBytes; assert.ok(sentBody > 200);
  const raw = buildRawMessage(env, { to: 'x@example.net', subject: 'Hi', text: 'a'.repeat(5000) });
  assert.match(raw, /^[A-Za-z0-9_-]+$/);
  const p = parseRaw(raw); assert.equal(p.text, 'a'.repeat(5000));
  assert.ok(p.raw.split('\r\n').every((l) => Buffer.byteLength(l) <= 998));
  assert.ok(p.raw.split('\r\n').every((l) => Buffer.byteLength(l) <= 78 || l.startsWith('Content-Type') || l.startsWith('List-')));
});
await t('a report to a confirmed helper: text and HTML, report text escaped and not made clickable', async () => {
  const env = mkEnv({ trey: true }); await go(env, hello()); await confirm(env); env._sent.length = 0;
  const g = await go(env, rep({ kind: 'scam', report: 'Look <script>alert(1)</script> & https://evil.example/x\nline two' }));
  assert.equal(g.j.delivery, 'helper'); assert.equal(env._sent.length, 1);
  const m = env._sent[0];
  assert.equal(m.to, 'mike@example.net'); assert.match(m.subject, /^\[Family Fix-It\] SCAM ALERT from Ann \(v2\.3\.14\)$/);
  assert.match(m.text, /SCAM ALERT - Ann pressed the red button/); assert.match(m.text, /<script>alert\(1\)<\/script> & https:\/\/evil\.example\/x\nline two/);
  assert.ok(!m.html.includes('<script>')); assert.ok(m.html.includes('&lt;script&gt;')); assert.ok(m.html.includes('&amp; https://evil.example/x'));
  assert.ok(!/<a href="https:\/\/evil/.test(m.html)); assert.match(m.html, /<a href="https:\/\/w\.example\/stop\?id=/);
});
await t('header text: non-ASCII is encoded in words of at most 75 characters, line breaks cannot make a new header', async () => {
  const long = encodeHeaderText('\u00e9'.repeat(80));
  for (const w of long.split('\r\n ')) { assert.ok(w.length <= 75, w.length + ''); assert.match(w, /^=\?UTF-8\?B\?[A-Za-z0-9+/=]+\?=$/); }
  const back = long.replace(/\r\n /g, '').replace(/=\?UTF-8\?B\?([A-Za-z0-9+/=]+)\?=/g, (m, b) => Buffer.from(b, 'base64').toString('utf8')); assert.equal(back, '\u00e9'.repeat(80)); // no character is cut in half
  assert.equal(encodeHeaderText('Plain subject'), 'Plain subject');
  assert.equal(encodeHeaderText('A\r\nBcc: evil@example.net'), 'A Bcc: evil@example.net');
  const env = mkEnv();
  const raw = parseRaw(buildRawMessage(env, { to: 'x@example.net', subject: 'Line1\r\nBcc: evil@example.net', text: 't' }));
  assert.ok(!raw.names.includes('bcc')); assert.equal(raw.subject, 'Line1 Bcc: evil@example.net');
  assert.throws(() => buildRawMessage(env, { to: 'x@example.net\r\nBcc: evil@example.net', subject: 's', text: 't' }));
  assert.throws(() => buildRawMessage(env, { to: 'a@example.net, b@example.net', subject: 's', text: 't' }));
  assert.throws(() => buildRawMessage(Object.assign({}, env, { MAIL_FROM: 'not an address' }), { to: 'x@example.net', subject: 's', text: 't' }));
  assert.equal(parseRaw(buildRawMessage(Object.assign({}, env, { MAIL_FROM: 'familyfixit.help@gmail.com' }), { to: 'x@example.net', subject: 's', text: 't' })).from, 'familyfixit.help@gmail.com');
  assert.equal(htmlFromText('a < b & "c"', ''), '<div style="font-family:Segoe UI,Arial,sans-serif;font-size:15px;line-height:1.5;color:#1a1a1a;white-space:pre-wrap">a &lt; b &amp; &quot;c&quot;</div>');
});

// ---------------------------------------------------------------- when Google says no
await t('a token error: no helper email, the report still goes to the operator path, the error is logged and kept', async () => {
  const env = mkEnv({ trey: true, google: { tokenFails: 400 } }); errors.length = 0;
  const g = await go(env, rep());
  assert.equal(g.r.status, 202); assert.equal(g.j.delivery, 'trey'); assert.equal(g.j.stored, true); assert.equal(g.j.emailed, false);
  assert.equal(g.j.confirmSent, false); assert.equal(g.j.confirmReason, 'send-failed');
  assert.ok(errors.some((e) => /Gmail: token request refused \(400 invalid_grant/.test(e)));
  assert.ok(!errors.join('\n').includes(env._google.clientSecret) && !errors.join('\n').includes(env._google.refresh)); // no secret in the log
  const last = JSON.parse(env._kv.get('gmail/last-error').v); assert.match(last.error, /invalid_grant/); assert.ok(last.at);
  assert.equal([...env._kv.keys()].filter((k) => k.startsWith('report/')).length, 1);
});
await t('after a token error Google is not asked again for five minutes, then it is', async () => {
  const env = mkEnv({ google: { tokenFails: 400 } }); const gg = env._google;
  await go(env, hello({ helper: { name: 'Mike', email: 'c1@example.net', pcId: PC } }), '3.3.3.1');
  assert.equal(gg.tokenCalls, 1);
  for (let i = 2; i < 5; i++) { await go(env, hello({ helper: { name: 'Mike', email: 'c' + i + '@example.net', pcId: PC } }), '3.3.3.' + i, 1000000 + i * 1000); }
  assert.equal(gg.tokenCalls, 1); // quiet
  resetMailCache(); await go(env, hello({ helper: { name: 'Mike', email: 'c9@example.net', pcId: PC } }), '3.3.3.9', 1000000 + 30000);
  assert.equal(gg.tokenCalls, 1); // a new instance also sees the pause in KV
  gg.tokenFails = 0;
  const g = await go(env, hello({ helper: { name: 'Mike', email: 'c10@example.net', pcId: PC } }), '3.3.3.10', 1000000 + 301000);
  assert.equal(gg.tokenCalls, 2); assert.equal(g.j.confirmSent, true); assert.equal(gg.sent.length, 1);
});
await t('a confirmed helper while Google refuses the token: the report goes to the operator, nothing is lost', async () => {
  const env = mkEnv({ trey: true }); await go(env, hello()); await confirm(env);
  env._google.tokenFails = 401; resetMailCache(); env._kv.delete('gmail/token');
  const g = await go(env, rep(), '1.2.3.4', 1000000 + 7200 * 1000);
  assert.equal(g.r.status, 202); assert.equal(g.j.delivery, 'trey'); assert.equal(g.j.helperStatus, 'confirmed'); assert.equal(g.j.reason, 'send-failed'); assert.equal(g.j.stored, true);
});
await t('Google cannot be reached: same fallback, no crash', async () => {
  const env = mkEnv({ google: { tokenNetworkDown: true } }); errors.length = 0;
  const g = await go(env, hello()); assert.equal(g.r.status, 200); assert.equal(g.j.confirmSent, false); assert.equal(g.j.confirmReason, 'send-failed');
  assert.ok(errors.some((e) => /could not reach Google/.test(e)));
});
await t('Gmail refuses a message (403, 429, 500): fallback, and the pending record is not made', async () => {
  for (const code of [403, 429, 500]) {
    const env = mkEnv({ google: { sendFails: code } }); errors.length = 0;
    const g = await go(env, hello()); assert.equal(g.j.confirmReason, 'send-failed'); assert.equal(g.j.helperStatus, 'none');
    assert.ok([...env._kv.keys()].every((k) => !k.startsWith('hp/'))); assert.ok(errors.some((e) => e.includes('send refused (' + code + ')')));
  }
});
await t('a wrong client secret is a token error too (the answer is not mixed up with a good one)', async () => {
  const env = mkEnv(); env.GMAIL_CLIENT_SECRET = 'wrong';
  const g = await go(env, hello()); assert.equal(g.j.confirmSent, false); assert.equal(g.j.confirmReason, 'send-failed');
});
await t('any missing secret or MAIL_FROM means email is off (reports go to the operator as before)', async () => {
  for (const k of ['GMAIL_CLIENT_ID', 'GMAIL_CLIENT_SECRET', 'GMAIL_REFRESH_TOKEN', 'MAIL_FROM']) {
    const env = mkEnv(); delete env[k]; const gg = env._google;
    const g = await go(env, hello()); assert.deepEqual([g.j.confirmSent, g.j.confirmReason], [false, 'email-off']); assert.equal(gg.tokenCalls, 0);
  }
});

// ---------------------------------------------------------------- the daily totals
await t('the default totals: 100 confirm emails a day, then "limited"', async () => {
  const env = mkEnv(); let sent = 0; let limited = 0;
  for (let i = 0; i < 103; i++) {
    const g = await go(env, hello({ helper: { name: 'Mike', email: 'u' + i + '@example.net', pcId: PC } }), '10.0.' + Math.floor(i / 250) + '.' + (i % 250 + 1), 1000000 + i * 61000);
    if (g.j.confirmSent) { sent++; } else if (g.j.confirmReason === 'limited') { limited++; }
  }
  assert.equal(sent, 100); assert.equal(limited, 3); assert.equal(env._google.sent.length, 100);
});
await t('the daily total of all emails is 300; the operator copy may go 50 past it, then it stops (the report is still stored)', async () => {
  const env = mkEnv({ trey: true }); let emailed = 0; let notEmailed = 0;
  for (let i = 0; i < 352; i++) {
    const g = await go(env, { pcName: 'PC' + i, version: '1.0.0', report: 'r' + i }, '11.' + Math.floor(i / 250) + '.0.' + (i % 250 + 1), 1000000 + i * 61000);
    assert.equal(g.r.status, 202); assert.equal(g.j.stored, true);
    if (g.j.emailed) { emailed++; } else { notEmailed++; }
  }
  assert.equal(emailed, 350); assert.equal(notEmailed, 2);
});
await t('MAX_TOTAL_MAILS_PER_DAY lowers the total for helper emails too', async () => {
  const env = mkEnv(); env.MAX_TOTAL_MAILS_PER_DAY = '2'; const out = [];
  for (let i = 0; i < 4; i++) { const g = await go(env, hello({ helper: { name: 'Mike', email: 'v' + i + '@example.net', pcId: PC } }), '12.0.0.' + (i + 1), 1000000 + i * 61000); out.push(g.j.confirmSent); }
  assert.deepEqual(out, [true, true, false, false]); assert.equal(env._google.sent.length, 2);
});

console.error = realErr;
console.log('gmail tests passed: ' + pass);
