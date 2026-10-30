import assert from 'node:assert/strict';
import { handleRequest, clientKey, resetMailCache } from './index.js';
import { addGoogle } from './mock-google.mjs';

let pass = 0;
async function t(name, fn) { await fn(); pass++; console.log('PASS ' + name); }

function mkEnv(opts) {
  const store = new Map();
  const rl = new Map();
  const sent = [];
  const env = {
    REPORTS: { put: async (k, v, o) => { ((k.startsWith('rl/') || k.startsWith('gmail/')) ? rl : store).set(k, { v, o }); }, get: async (k) => { const e = ((k.startsWith('rl/') || k.startsWith('gmail/')) ? rl : store).get(k); return e ? e.v : null; } },
    RL: { limit: async () => ({ success: !(opts && opts.limited) }) },
    _store: store, _rl: rl, _sent: sent
  };
  if (opts && opts.email) {
    resetMailCache();
    const g = addGoogle(env, { sendFails: opts.emailFails ? 500 : 0 }); env._sent = g.sent;
    env.REPORT_TO = 'to@example.com';
  }
  return env;
}
function req(body, o) {
  o = o || {};
  const headers = Object.assign({ 'content-type': 'application/json', 'x-fixit-app': 'family-it-fixit', 'cf-connecting-ip': '1.2.3.4' }, o.headers || {});
  if (o.noApp) { delete headers['x-fixit-app']; }
  return new Request('https://w.example/' + (o.path || 'report'), { method: o.method || 'POST', headers, body: (o.method === 'GET') ? undefined : (typeof body === 'string' ? body : JSON.stringify(body)) });
}
const good = { pcName: 'MOMS-LAPTOP', version: '1.1.0', report: 'hello report' };

await t('accepts a good report and stores it', async () => {
  const env = mkEnv(); const r = await handleRequest(req(good), env, 0);
  assert.equal(r.status, 202); const j = await r.json(); assert.equal(j.ok, true); assert.equal(j.stored, true); assert.equal(j.emailed, false);
  assert.equal(env._store.size, 1);
  const rec = JSON.parse([...env._store.values()][0].v); assert.equal(rec.pcName, 'MOMS-LAPTOP'); assert.equal(rec.report, 'hello report');
});
await t('scam kind is stored and flagged in email', async () => {
  const env = mkEnv({ email: true }); const r = await handleRequest(req(Object.assign({ kind: 'scam' }, good)), env);
  assert.equal(r.status, 202); assert.match((await r.json()).id, /^SCAM-/); assert.match(env._sent[0].subject, /SCAM ALERT/);
  assert.equal(JSON.parse([...env._store.values()][0].v).kind, 'scam');
});
await t('bad kind rejected', async () => { assert.equal((await handleRequest(req(Object.assign({ kind: 'x' }, good)), mkEnv())).status, 400); });
await t('rejects missing app header', async () => { assert.equal((await handleRequest(req(good, { noApp: true }), mkEnv())).status, 403); });
await t('rejects wrong app header', async () => { assert.equal((await handleRequest(req(good, { headers: { 'x-fixit-app': 'nope' } }), mkEnv())).status, 403); });
await t('rejects GET on /report', async () => { assert.equal((await handleRequest(req('', { method: 'GET' }), mkEnv())).status, 405); });
await t('unknown path is 404', async () => { assert.equal((await handleRequest(req(good, { path: 'x' }), mkEnv())).status, 404); });
await t('health ok', async () => { assert.equal((await handleRequest(req('', { method: 'GET', path: 'health' }), mkEnv())).status, 200); });
await t('rate limit gives 429', async () => { const env = mkEnv({ limited: true }); const r = await handleRequest(req(good), env); assert.equal(r.status, 429); assert.equal(env._store.size, 0); });
await t('wrong content type 415', async () => { assert.equal((await handleRequest(req(good, { headers: { 'content-type': 'text/plain' } }), mkEnv())).status, 415); });
await t('bad JSON 400', async () => { assert.equal((await handleRequest(req('{nope'), mkEnv())).status, 400); });
await t('missing fields 400', async () => {
  for (const b of [{ version: '1', report: 'x' }, { pcName: 'a', report: 'x' }, { pcName: 'a', version: '1' }, { pcName: 'a', version: 'bad version!', report: 'x' }, [1], { pcName: 'a', version: '1', report: '  ' }]) {
    assert.equal((await handleRequest(req(b), mkEnv())).status, 400);
  }
});
await t('too large by body is 413', async () => {
  const big = { pcName: 'a', version: '1', report: 'x'.repeat(512 * 1024) };
  assert.equal((await handleRequest(req(big), mkEnv())).status, 413);
});
await t('too large by content-length is 413', async () => {
  assert.equal((await handleRequest(req(good, { headers: { 'content-length': String(600 * 1024) } }), mkEnv())).status, 413);
});
await t('just under limit accepted', async () => {
  const ok = { pcName: 'a', version: '1', report: 'x'.repeat(500 * 1024) };
  assert.equal((await handleRequest(req(ok), mkEnv())).status, 202);
});
await t('control characters in pcName are cleaned', async () => {
  const env = mkEnv(); await handleRequest(req({ pcName: 'A\r\nBcc: evil', version: '1', report: 'x' }), env);
  const rec = JSON.parse([...env._store.values()][0].v); assert.ok(!/[\r\n]/.test(rec.pcName));
});
await t('email sent when binding configured', async () => {
  const env = mkEnv({ email: true }); const j = await (await handleRequest(req(good), env)).json();
  assert.equal(j.emailed, true); assert.equal(env._sent.length, 1); assert.match(env._sent[0].subject, /MOMS-LAPTOP/);
});
await t('email failure does not lose the report', async () => {
  const env = mkEnv({ email: true, emailFails: true }); const r = await handleRequest(req(good), env);
  assert.equal(r.status, 202); assert.equal((await r.json()).emailed, false); assert.equal(env._store.size, 1);
});
await t('nothing to deliver to gives 500', async () => {
  const env = mkEnv(); delete env.REPORTS; assert.equal((await handleRequest(req(good), env)).status, 500);
});
await t('health kind is stored with a HEALTH- id and its own email subject', async () => {
  const env = mkEnv({ email: true }); const r = await handleRequest(req(Object.assign({}, good, { kind: 'health' })), env);
  assert.equal(r.status, 202); assert.match((await r.json()).id, /^HEALTH-/); assert.match(env._sent[0].subject, /Weekly health check from MOMS-LAPTOP/);
  assert.equal(JSON.parse([...env._store.values()][0].v).kind, 'health'); assert.equal([...env._store.values()][0].o.metadata.kind, 'health');
});
await t('KV per-IP limit: 10 per minute, then 429, even if the ratelimit binding lets everything through', async () => {
  const env = mkEnv(); const codes = [];
  for (let i = 0; i < 13; i++) { codes.push((await handleRequest(req(good), env, 120000)).status); }
  assert.deepEqual(codes, [202, 202, 202, 202, 202, 202, 202, 202, 202, 202, 429, 429, 429]);
  assert.equal(env._store.size, 10);
  const other = await handleRequest(req(good, { headers: { 'cf-connecting-ip': '9.9.9.9' } }), env, 120000); assert.equal(other.status, 202);
  const later = await handleRequest(req(good), env, 120000 + 61000); assert.equal(later.status, 202);
  assert.ok([...env._rl.values()].every((e) => e.o.expirationTtl === 120));
});
await t('requests without the app header do not use up the limit', async () => {
  const env = mkEnv(); for (let i = 0; i < 20; i++) { await handleRequest(req(good, { noApp: true }), env, 0); }
  assert.equal(env._rl.size, 0); assert.equal((await handleRequest(req(good), env, 0)).status, 202);
});
await t('Durable Object limiter: allows 10 per address, then 429', async () => {
  const { RateLimiter } = await import('./index.js'); const objs = new Map();
  const env = mkEnv(); env.LIMITER = { idFromName: (n) => n, get: (id) => { if (!objs.has(id)) { const m = new Map(); objs.set(id, new RateLimiter({ storage: { get: async (k) => m.get(k), put: async (k, v) => { m.set(k, v); } } })); } return { fetch: (u) => objs.get(id).fetch(u) }; } };
  const codes = []; for (let i = 0; i < 12; i++) { codes.push((await handleRequest(req(good), env, 0)).status); }
  assert.deepEqual(codes, [202, 202, 202, 202, 202, 202, 202, 202, 202, 202, 429, 429]);
  assert.equal(env._rl.size, 0); // KV counter not used when the Durable Object is there
});
await t('limiter failure does not lose the report', async () => {
  const env = mkEnv(); env.LIMITER = { idFromName: (n) => n, get: () => ({ fetch: async () => { throw new Error('down'); } }) };
  assert.equal((await handleRequest(req(good), env, 0)).status, 202);
});
await t('IPv6 clients are counted by /64, IPv4 as is', async () => {
  assert.equal(clientKey('2a04:4e41:80:45bf::98d0:45bf'), '2a04:4e41:80:45bf'); assert.equal(clientKey('2a04:4e41:80:45bf:1:2:3:4'), '2a04:4e41:80:45bf'); assert.equal(clientKey('1.2.3.4'), '1.2.3.4');
});
await t('global cap: many different addresses together are still limited to 30 a minute', async () => {
  const mem = new Map(); const objs = new Map();
  const { RateLimiter } = await import('./index.js');
  const env = mkEnv(); env.LIMITER = { idFromName: (n) => n, get: (id) => { if (!objs.has(id)) { const m = new Map(); objs.set(id, new RateLimiter({ storage: { get: async (k) => m.get(k), put: async (k, v) => { m.set(k, v); } } })); } return { fetch: (u) => objs.get(id).fetch(u) }; } };
  const codes = []; for (let i = 0; i < 34; i++) { codes.push((await handleRequest(req(good, { headers: { 'cf-connecting-ip': '5.5.5.' + i } }), env, 0)).status); }
  assert.equal(codes.filter((c) => c === 202).length, 30); assert.equal(codes.filter((c) => c === 429).length, 4);
});
console.log('worker tests passed: ' + pass);
