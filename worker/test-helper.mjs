// Tests for the "Who helps you?" paths of the worker. Run:  node test-helper.mjs   (no network, no Cloudflare account)
import assert from 'node:assert/strict';
import { handleRequest, cleanName, cleanEmail, RateLimiter, resetMailCache } from './index.js';
import { addGoogle } from './mock-google.mjs';

let pass = 0;
let clock = 1000000; Date.now = () => clock; // the counters read the clock; the tests move it
async function t(name, fn) { await fn(); pass++; console.log('PASS ' + name); }

function mkEnv(o) {
  o = o || {};
  const kv = new Map(); const sent = []; const objs = new Map();
  const env = {
    REPORTS: { get: async (k) => { const e = kv.get(k); return e ? e.v : null; }, put: async (k, v, opt) => { kv.set(k, { v: v, o: opt }); }, delete: async (k) => { kv.delete(k); } },
    LIMITER: { idFromName: (n) => n, get: (id) => { if (!objs.has(id)) { const m = new Map(); objs.set(id, new RateLimiter({ storage: { get: async (k) => m.get(k), put: async (k, v) => { m.set(k, v); } } })); } return { fetch: (u) => objs.get(id).fetch(new Request(u)) }; } },
    PUBLIC_URL: 'https://w.example',
    _kv: kv, _sent: sent
  };
  resetMailCache();
  if (o.email !== false) { addGoogle(env, { sendFails: o.emailFails ? 500 : 0 }); }
  if (o.trey) { env.REPORT_TO = 'trey@example.com'; }
  return env;
}
const PC = 'a'.repeat(32);
const PC2 = 'b'.repeat(32);
function helperBlock(email, pcId) { return { name: 'Mike', email: email || 'mike@example.net', pcId: pcId || PC }; }
function post(body, ip) {
  return new Request('https://w.example/report', { method: 'POST', headers: { 'content-type': 'application/json', 'x-fixit-app': 'family-it-fixit', 'cf-connecting-ip': ip || '1.2.3.4' }, body: JSON.stringify(body) });
}
function rep(extra) { return Object.assign({ pcName: 'MOMS-LAPTOP', version: '2.3.14', kind: 'report', report: 'the report text', owner: 'Ann', helper: helperBlock() }, extra || {}); }
function hello(extra) { return Object.assign({ pcName: 'MOMS-LAPTOP', version: '2.3.14', kind: 'hello', owner: 'Ann', helper: helperBlock() }, extra || {}); }
async function go(env, body, ip, now) { clock = now === undefined ? 1000000 : now; const r = await handleRequest(post(body, ip), env, now === undefined ? 1000000 : now); return { r: r, j: await r.json() }; }
function linkIn(text, path) { const m = text.match(new RegExp('https://w\\.example' + path + '\\?id=[0-9a-f]{64}&t=[0-9a-f]{48}')); return m ? m[0] : null; }
function getReq(u) { return new Request(u, { headers: { 'cf-connecting-ip': '7.7.7.7' } }); }
function postForm(path, fields, ip) { return new Request('https://w.example' + path, { method: 'POST', headers: { 'content-type': 'application/x-www-form-urlencoded', 'cf-connecting-ip': ip || '7.7.7.7' }, body: new URLSearchParams(fields).toString() }); }
async function confirmFlow(env) {
  const g = await go(env, hello()); assert.equal(g.j.confirmSent, true);
  const link = linkIn(env._sent[0].text, '/confirm'); assert.ok(link);
  const u = new URL(link);
  const p = await handleRequest(postForm('/confirm', { id: u.searchParams.get('id'), t: u.searchParams.get('t') }), env, 1000000);
  assert.equal(p.status, 200); return { id: u.searchParams.get('id'), t: u.searchParams.get('t') };
}

await t('name and email cleaning', async () => {
  assert.equal(cleanName('Mike <b>http://evil.example/x</b>'), 'Mike b http evil example x b');
  assert.equal(cleanName("  Anne-Marie  O'Neil\r\n"), "Anne-Marie O'Neil");
  assert.equal(cleanName('x'.repeat(100)).length, 40); assert.equal(cleanName(5), '');
  assert.equal(cleanEmail(' Mike@Example.NET '), 'mike@example.net');
  for (const bad of ['', 'a@b', 'a b@c.com', 'a@b..com', 'a@b.c', '<x>@y.com', 'a@b.com,c@d.com', 'a@b.com\r\nBcc: z@y.com', 'x'.repeat(130) + '@a.com']) { assert.equal(cleanEmail(bad), '', bad); }
});
await t('no helper: behaves as before (stored, delivery trey)', async () => {
  const env = mkEnv({ trey: true }); const b = rep(); delete b.helper; const g = await go(env, b);
  assert.equal(g.r.status, 202); assert.equal(g.j.stored, true); assert.equal(g.j.delivery, 'trey'); assert.equal(g.j.helperStatus, 'none');
  assert.equal(env._sent.length, 1); assert.equal(env._sent[0].to, 'trey@example.com');
});
await t('helper is the operator: same as no helper, no confirm email', async () => {
  const env = mkEnv({ trey: true }); const g = await go(env, rep({ helper: helperBlock('TREY@example.com') }));
  assert.equal(g.j.delivery, 'trey'); assert.equal(g.j.stored, true); assert.equal(env._sent.length, 1); assert.equal(env._sent[0].to, 'trey@example.com');
  const h = await go(env, hello({ helper: helperBlock('trey@example.com') })); assert.equal(h.r.status, 200); assert.equal(h.j.confirmSent, false); assert.equal(env._sent.length, 1);
});
await t('hello sends one confirm email to the helper, stores no report, never mails the operator', async () => {
  const env = mkEnv({ trey: true }); const g = await go(env, hello());
  assert.equal(g.r.status, 200); assert.deepEqual([g.j.delivery, g.j.helperStatus, g.j.confirmSent, g.j.confirmReason], ['trey', 'pending', true, 'sent']);
  assert.equal(env._sent.length, 1); const m = env._sent[0];
  assert.equal(m.to, 'mike@example.net'); assert.equal(m.from, '"Family Fix-It" <familyfixit.help@gmail.com>'); assert.equal(m.subject, 'Ann wants you as their Fix-It helper');
  assert.ok(linkIn(m.text, '/confirm')); assert.ok(linkIn(m.text, '/stop'));
  assert.ok([...env._kv.keys()].every((k) => k.startsWith('hp/') || k.startsWith('gmail/'))); // nothing under report/
});
await t('a report before the helper confirms goes to the operator, says so, and does not ask again within a day', async () => {
  const env = mkEnv({ trey: true }); await go(env, hello()); env._sent.length = 0;
  const g = await go(env, rep());
  assert.equal(g.r.status, 202); assert.deepEqual([g.j.delivery, g.j.helperStatus, g.j.stored], ['trey', 'pending', true]);
  assert.equal(env._sent.length, 1); assert.equal(env._sent[0].to, 'trey@example.com'); assert.match(env._sent[0].text, /has not said yes yet/);
  const k = [...env._kv.keys()].find((x) => x.startsWith('report/')); assert.equal(JSON.parse(env._kv.get(k).v).helper.name, 'Mike');
});
await t('report with no earlier hello asks the helper once and keeps the report', async () => {
  const env = mkEnv({ trey: true }); const g = await go(env, rep());
  assert.equal(g.j.confirmSent, true); assert.equal(g.j.delivery, 'trey'); assert.equal(env._sent.length, 2);
  assert.deepEqual(env._sent.map((m) => m.to).sort(), ['mike@example.net', 'trey@example.com']);
});
await t('the confirm link: GET shows a page and changes nothing; POST confirms', async () => {
  const env = mkEnv({ trey: true }); await go(env, hello());
  const link = linkIn(env._sent[0].text, '/confirm'); const u = new URL(link);
  const g = await handleRequest(getReq(link), env, 1000000); assert.equal(g.status, 200); const html = await g.text();
  assert.match(html, /Ann wants you as their Fix-It helper/); assert.match(html, /Yes, send me their reports/);
  assert.equal(JSON.parse(env._kv.get('hp/' + u.searchParams.get('id')).v).status, 'pending');
  const p = await handleRequest(postForm('/confirm', { id: u.searchParams.get('id'), t: u.searchParams.get('t') }), env, 1000000); assert.equal(p.status, 200); assert.match(await p.text(), /all set/);
  const rec = JSON.parse(env._kv.get('hp/' + u.searchParams.get('id')).v); assert.equal(rec.status, 'confirmed'); assert.equal(env._kv.get('hp/' + u.searchParams.get('id')).o, undefined);
});
await t('after confirming, reports go to the helper by email and are NOT stored', async () => {
  const env = mkEnv({ trey: true }); await confirmFlow(env); env._sent.length = 0;
  const g = await go(env, rep({ report: 'Printer is jammed' }));
  assert.equal(g.r.status, 202); assert.deepEqual([g.j.delivery, g.j.helperStatus, g.j.stored, g.j.emailed], ['helper', 'confirmed', false, true]);
  assert.equal(env._sent.length, 1); const m = env._sent[0]; assert.equal(m.to, 'mike@example.net'); assert.match(m.subject, /^\[Family Fix-It\] Report from Ann/);
  assert.match(m.text, /Printer is jammed/); assert.ok(linkIn(m.text, '/stop'));
  assert.ok(![...env._kv.keys()].some((k) => k.startsWith('report/')));
  const s = await go(env, rep({ kind: 'scam', report: 'SCAM' })); assert.match(env._sent[1].subject, /SCAM ALERT from Ann/); assert.equal(s.j.delivery, 'helper');
  const h = await go(env, hello()); assert.deepEqual([h.j.delivery, h.j.confirmSent], ['helper', false]); assert.equal(env._sent.length, 2);
});
await t('confirmation belongs to one PC: another PC with the same helper email is asked separately (and the operator keeps its report)', async () => {
  const env = mkEnv({ trey: true }); await confirmFlow(env); env._sent.length = 0;
  const g = await go(env, rep({ helper: helperBlock('mike@example.net', PC2) }), '5.5.5.5');
  assert.equal(g.j.delivery, 'trey'); assert.notEqual(g.j.helperStatus, 'confirmed');
  assert.equal(g.j.confirmSent, false); assert.equal(g.j.confirmReason, 'limited'); // 1 confirm email per helper per day
});
await t('a confirm email per helper per day, 3 per 30 days', async () => {
  const env = mkEnv({ trey: true }); const day = 86400000; const pcs = ['1', '2', '3', '4'].map((c) => c.repeat(32)); const res = [];
  for (let i = 0; i < 4; i++) { res.push((await go(env, hello({ helper: helperBlock('mike@example.net', pcs[i]) }), '1.1.1.' + i, 1000000 + i * day)).j.confirmSent); }
  assert.deepEqual(res, [true, true, true, false]);
  const two = await go(env, hello({ helper: helperBlock('mike@example.net', pcs[0]) }), '2.2.2.2', 1000000 + 3 * day + 5); assert.equal(two.j.confirmSent, false);
});
await t('abuse: one client address can cause only 5 confirm emails an hour, to different people', async () => {
  const env = mkEnv(); let n = 0;
  for (let i = 0; i < 9; i++) { const g = await go(env, hello({ helper: helperBlock('v' + i + '@example.net', String(i).repeat(32)) }), '9.9.9.9'); if (g.j.confirmSent) { n++; } }
  assert.equal(n, 5); assert.equal(env._sent.length, 5);
});
await t('abuse: the total confirm emails per day are capped', async () => {
  const env = mkEnv(); env.MAX_CONFIRMS_PER_DAY = '3'; let n = 0;
  for (let i = 0; i < 8; i++) { const g = await go(env, hello({ helper: helperBlock('w' + i + '@example.net', String(i).repeat(32)) }), '8.8.' + i + '.1'); if (g.j.confirmSent) { n++; } }
  assert.equal(n, 3);
});
await t('abuse: names cannot carry links into the email', async () => {
  const env = mkEnv(); await go(env, hello({ owner: 'Visit http://evil.example now', pcName: 'PC http://evil.example/x', helper: { name: 'Mike www.evil.example', email: 'mike@example.net', pcId: PC } }));
  const m = env._sent[0]; assert.ok(!/evil\.example/.test(m.subject)); const body = m.text.replace(/https:\/\/w\.example\/[^\s]+/g, ''); assert.ok(!/evil\.example/.test(body));
});
await t('bad helper data is a 400', async () => {
  for (const h of [{ name: 'Mike', email: 'nope', pcId: PC }, { name: '', email: 'a@b.com', pcId: PC }, { name: 'Mike', email: 'a@b.com', pcId: 'short' }, { name: 'M', email: 'a@b.com' }, 'x', []]) {
    assert.equal((await go(mkEnv(), rep({ helper: h }))).r.status, 400);
  }
  assert.equal((await go(mkEnv(), { pcName: 'a', version: '1', kind: 'hello' })).r.status, 400);
  assert.equal((await go(mkEnv(), rep({ owner: 5 }))).r.status, 400);
});
await t('size limit still applies to helper reports', async () => {
  const env = mkEnv(); const r = await handleRequest(post(rep({ report: 'x'.repeat(520 * 1024) })), env, 0); assert.equal(r.status, 413);
});
await t('very long reports are cut in the helper email, not rejected', async () => {
  const env = mkEnv({ trey: true }); await confirmFlow(env); env._sent.length = 0;
  const g = await go(env, rep({ report: 'y'.repeat(300 * 1024) })); assert.equal(g.r.status, 202); assert.ok(env._sent[0].text.length < 210 * 1024); assert.match(env._sent[0].text, /cut here/);
});
await t('sending limits for a confirmed PC: 12 an hour, then the operator keeps the report', async () => {
  const env = mkEnv({ trey: true }); await confirmFlow(env); env._sent.length = 0; const res = [];
  for (let i = 0; i < 14; i++) { res.push((await go(env, rep(), '3.3.3.' + i)).j.delivery); }
  assert.equal(res.filter((d) => d === 'helper').length, 12); assert.equal(res.filter((d) => d === 'trey').length, 2);
  assert.ok([...env._kv.keys()].filter((k) => k.startsWith('report/')).length === 2);
});
await t('if the helper email fails, the report goes to the operator and the answer says so', async () => {
  const env = mkEnv({ trey: true }); await confirmFlow(env); env._google.failTo = 'mike@example.net'; env._sent.length = 0;
  const g = await go(env, rep()); assert.equal(g.r.status, 202); assert.deepEqual([g.j.delivery, g.j.helperStatus, g.j.reason], ['trey', 'confirmed', 'send-failed']); assert.equal(g.j.stored, true);
});
await t('email not set up on the worker: reports keep going to the operator, hello says why', async () => {
  const env = mkEnv({ trey: true, email: false }); const h = await go(env, hello()); assert.deepEqual([h.j.confirmSent, h.j.confirmReason, h.j.helperStatus], [false, 'email-off', 'none']);
  const g = await go(env, rep()); assert.equal(g.r.status, 202); assert.equal(g.j.delivery, 'trey'); assert.equal(g.j.stored, true);
});
await t('a failing confirm email does not lose the report or crash', async () => {
  const env = mkEnv({ trey: true, emailFails: true }); const g = await go(env, rep()); assert.equal(g.r.status, 202); assert.equal(g.j.confirmSent, false); assert.equal(g.j.confirmReason, 'send-failed'); assert.equal(g.j.stored, true);
  assert.ok(![...env._kv.keys()].some((k) => k.startsWith('hp/')));
});
await t('limiter that cannot count: no mail goes out (fails closed), reports are still kept', async () => {
  const env = mkEnv({ trey: true }); await confirmFlow(env); env._sent.length = 0;
  const real = env.LIMITER; let calls = 0; env.LIMITER = { idFromName: real.idFromName, get: (id) => { calls++; if (calls > 2) { return { fetch: async () => { throw new Error('down'); } }; } return real.get(id); } };
  const g = await go(env, rep()); assert.equal(g.j.delivery, 'trey'); assert.equal(g.j.reason, 'limited'); assert.equal(g.j.stored, true);
});
await t('the stop page: GET changes nothing; "this PC" stops the PC, reports then go to the operator and no new confirm is sent', async () => {
  const env = mkEnv({ trey: true }); const { id, t: tok } = await confirmFlow(env); env._sent.length = 0;
  const g = await handleRequest(getReq('https://w.example/stop?id=' + id + '&t=' + tok), env, 1000000); assert.equal(g.status, 200); assert.match(await g.text(), /Never email me about Family Fix-It/);
  assert.equal(JSON.parse(env._kv.get('hp/' + id).v).status, 'confirmed');
  const p = await handleRequest(postForm('/stop', { id: id, t: tok, action: 'pc' }), env, 1000000); assert.equal(p.status, 200);
  assert.equal(JSON.parse(env._kv.get('hp/' + id).v).status, 'stopped');
  const r = await go(env, rep()); assert.deepEqual([r.j.delivery, r.j.helperStatus, r.j.confirmSent], ['trey', 'stopped', false]); assert.ok(!env._sent.some((m) => m.to === 'mike@example.net'));
});
await t('"never email me" blocks that address for every PC', async () => {
  const env = mkEnv({ trey: true }); const g = await go(env, hello()); const link = linkIn(env._sent[0].text, '/stop'); const u = new URL(link);
  const p = await handleRequest(postForm('/stop', { id: u.searchParams.get('id'), t: u.searchParams.get('t'), action: 'all' }), env, 1000000); assert.equal(p.status, 200);
  env._sent.length = 0;
  const r = await go(env, rep({ helper: helperBlock('mike@example.net', PC2) }), '4.4.4.4'); assert.deepEqual([r.j.delivery, r.j.helperStatus, r.j.confirmSent], ['trey', 'declined', false]);
  assert.equal(env._sent.filter((m) => m.to === 'mike@example.net').length, 0);
});
await t('wrong or missing token, or garbage id, shows the "no longer works" page and changes nothing', async () => {
  const env = mkEnv({ trey: true }); await go(env, hello()); const u = new URL(linkIn(env._sent[0].text, '/confirm')); const id = u.searchParams.get('id');
  for (const q of ['?id=' + id + '&t=' + 'f'.repeat(48), '?id=' + id, '?id=zzz&t=1', '']) {
    const g = await handleRequest(getReq('https://w.example/confirm' + q), env, 1000000); assert.equal(g.status, 404); assert.match(await g.text(), /no longer works/);
  }
  const p = await handleRequest(postForm('/confirm', { id: id, t: 'f'.repeat(48) }), env, 1000000); assert.equal(p.status, 404);
  assert.equal(JSON.parse(env._kv.get('hp/' + id).v).status, 'pending');
});
await t('page text is HTML-escaped (owner name with markup)', async () => {
  const env = mkEnv(); await go(env, hello({ owner: '<script>alert(1)</script>' }));
  const g = await handleRequest(getReq(linkIn(env._sent[0].text, '/confirm')), env, 1000000); const html = await g.text(); assert.ok(!html.includes('<script>alert'));
});
await t('the confirm and stop routes are rate limited per address', async () => {
  const env = mkEnv(); const codes = [];
  for (let i = 0; i < 13; i++) { codes.push((await handleRequest(getReq('https://w.example/confirm?id=x&t=y'), env, 0)).status); }
  assert.equal(codes.filter((c) => c === 429).length, 3);
});
await t('wrong methods on the pages', async () => { assert.equal((await handleRequest(new Request('https://w.example/stop', { method: 'PUT' }), mkEnv(), 0)).status, 405); });
await t('one-click unsubscribe style post stops the PC', async () => {
  const env = mkEnv({ trey: true }); const { id, t: tok } = await confirmFlow(env);
  const r = new Request('https://w.example/stop?id=' + id + '&t=' + tok, { method: 'POST', headers: { 'content-type': 'application/x-www-form-urlencoded', 'cf-connecting-ip': '6.6.6.6' }, body: 'List-Unsubscribe=One-Click' });
  assert.equal((await handleRequest(r, env, 0)).status, 200); assert.equal(JSON.parse(env._kv.get('hp/' + id).v).status, 'stopped');
});
await t('the pending record expires on its own after 14 days; a confirmed one does not', async () => {
  const env = mkEnv({ trey: true }); await go(env, hello()); const k = [...env._kv.keys()].find((x) => x.startsWith('hp/'));
  assert.equal(env._kv.get(k).o.expirationTtl, 14 * 86400);
});
console.log('helper tests passed: ' + pass);
