// Tests for ./get-gmail-token against a pretend Google token endpoint (no network). Run:  node test-token-script.mjs
import assert from 'node:assert/strict';
import http from 'node:http';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import crypto from 'node:crypto';
import { spawn } from 'node:child_process';

let pass = 0;
async function t(name, fn) { await fn(); pass++; console.log('PASS ' + name); }
const SCRIPT = new URL('./get-gmail-token', import.meta.url).pathname;
const REFRESH = 'RT-SECRET-' + crypto.randomBytes(8).toString('hex');

const seen = []; let mode = 'ok';
const srv = http.createServer((req, res) => {
  let b = ''; req.on('data', (c) => { b += c; }); req.on('end', () => {
    const f = Object.fromEntries(new URLSearchParams(b).entries()); seen.push(f);
    res.setHeader('content-type', 'application/json');
    if (f.grant_type === 'refresh_token') { if (f.refresh_token === REFRESH) { res.end(JSON.stringify({ access_token: 'AT', expires_in: 3599, scope: 'https://www.googleapis.com/auth/gmail.send' })); } else { res.statusCode = 400; res.end(JSON.stringify({ error: 'invalid_grant', error_description: 'Token has been expired or revoked.' })); } return; }
    if (f.code !== 'GOOD-CODE') { res.statusCode = 400; res.end(JSON.stringify({ error: 'invalid_grant', error_description: 'Bad Request' })); return; }
    if (mode === 'norefresh') { res.end(JSON.stringify({ access_token: 'AT', expires_in: 3599, scope: 'https://www.googleapis.com/auth/gmail.send' })); return; }
    if (mode === 'morescope') { res.end(JSON.stringify({ access_token: 'AT', refresh_token: REFRESH, scope: 'https://www.googleapis.com/auth/gmail.send https://mail.google.com/' })); return; }
    res.end(JSON.stringify({ access_token: 'AT', refresh_token: REFRESH, expires_in: 3599, scope: 'https://www.googleapis.com/auth/gmail.send' }));
  });
});
await new Promise((r) => srv.listen(0, '127.0.0.1', r));
const TOKEN_URL = 'http://127.0.0.1:' + srv.address().port + '/token';

function run(args, stdinLines, extraEnv, onOut) {
  return new Promise((resolve) => {
    const env = Object.assign({}, process.env, { GMAIL_CLIENT_ID: 'cid.apps.googleusercontent.com', GMAIL_CLIENT_SECRET: 'csecret', GMAIL_TOKEN_URL: TOKEN_URL }, extraEnv || {});
    const p = spawn(SCRIPT, args, { env: env }); let out = ''; let err = '';
    p.stdout.on('data', (d) => { out += d; if (onOut) { onOut(out, p); } }); p.stderr.on('data', (d) => { err += d; });
    p.on('close', (code) => resolve({ code: code, out: out, err: err }));
    let fed = false;
    if (stdinLines !== null) { p.stdout.on('data', () => { if (!fed && out.includes('Paste the address')) { fed = true; p.stdin.end(typeof stdinLines === 'function' ? stdinLines(out) : stdinLines); } }); }
  });
}
const tmp = () => fs.mkdtempSync(path.join(os.tmpdir(), 'gmt-'));
function urlOf(out) { return new URL(out.match(/https?:\/\/\S+\?\S+/)[0]); }

await t('the printed link asks for send-only, offline, with a fresh consent, PKCE and a loopback redirect', async () => {
  const d = tmp(); const r = await run(['--out', path.join(d, 'secrets', 'tok.txt')], 'nothing\n');
  const u = urlOf(r.out); const q = u.searchParams;
  assert.equal(u.origin + u.pathname, 'https://accounts.google.com/o/oauth2/v2/auth');
  assert.equal(q.get('scope'), 'https://www.googleapis.com/auth/gmail.send'); assert.equal(q.get('access_type'), 'offline'); assert.equal(q.get('prompt'), 'consent');
  assert.equal(q.get('redirect_uri'), 'http://127.0.0.1:8085'); assert.equal(q.get('response_type'), 'code'); assert.equal(q.get('code_challenge_method'), 'S256');
  assert.equal(q.get('client_id'), 'cid.apps.googleusercontent.com'); assert.ok(q.get('state').length >= 16);
  assert.equal(r.code, 1); // "nothing" is taken as a bare code, which the pretend Google refuses
  assert.ok(!fs.existsSync(path.join(d, 'secrets', 'tok.txt')));
});
await t('paste the browser address: token saved with mode 600, folder 700, .gitignore, and the token is never printed', async () => {
  const d = tmp(); const out = path.join(d, 'secrets', 'gmail-refresh-token.txt'); seen.length = 0;
  const r = await run(['--out', out, '--port', '9123'], (o) => { const q = urlOf(o).searchParams; return 'http://127.0.0.1:9123/?state=' + q.get('state') + '&code=GOOD-CODE&scope=x\n'; });
  assert.equal(r.code, 0, r.err + r.out);
  assert.equal(fs.readFileSync(out, 'utf8'), REFRESH + '\n');
  assert.equal((fs.statSync(out).mode & 0o777).toString(8), '600'); assert.equal((fs.statSync(path.dirname(out)).mode & 0o777).toString(8), '700');
  assert.equal(fs.readFileSync(path.join(path.dirname(out), '.gitignore'), 'utf8'), '*\n');
  assert.ok(!(r.out + r.err).includes(REFRESH)); assert.ok(r.out.includes(out)); assert.match(r.out, /wrangler secret put GMAIL_REFRESH_TOKEN < /);
  assert.equal(fs.readdirSync(path.dirname(out)).filter((n) => n.includes('.tmp-')).length, 0);
  const f = seen[0]; assert.equal(f.grant_type, 'authorization_code'); assert.equal(f.redirect_uri, 'http://127.0.0.1:9123'); assert.equal(f.client_secret, 'csecret'); assert.equal(f.code, 'GOOD-CODE');
  // the verifier matches the challenge in the printed link
  const ch = urlOf(r.out).searchParams.get('code_challenge'); assert.equal(crypto.createHash('sha256').update(f.code_verifier).digest('base64url'), ch);
});
await t('a bare code pasted on its own also works', async () => {
  const d = tmp(); const out = path.join(d, 's', 't.txt'); const r = await run(['--out', out], 'GOOD-CODE\n');
  assert.equal(r.code, 0); assert.equal(fs.readFileSync(out, 'utf8').trim(), REFRESH);
});
await t('an address from another sign-in (wrong state) or an error answer saves nothing', async () => {
  for (const line of ['http://127.0.0.1:8085/?state=WRONG&code=GOOD-CODE\n', 'http://127.0.0.1:8085/?error=access_denied\n', '\n']) {
    const d = tmp(); const out = path.join(d, 's', 't.txt'); const r = await run(['--out', out], line);
    assert.equal(r.code, 1); assert.ok(!fs.existsSync(out)); assert.ok(!(r.out + r.err).includes(REFRESH)); assert.match(r.err, /Nothing was saved|Stopped/);
  }
});
await t('no refresh token in the answer: tells how to fix it and saves nothing; extra permissions are refused', async () => {
  for (const [m, re] of [['norefresh', /did not hand out a refresh token/], ['morescope', /more than the send-only/]]) {
    mode = m; const d = tmp(); const out = path.join(d, 's', 't.txt');
    const r = await run(['--out', out], (o) => 'http://127.0.0.1:8085/?state=' + urlOf(o).searchParams.get('state') + '&code=GOOD-CODE\n');
    assert.equal(r.code, 1); assert.match(r.err, re); assert.ok(!fs.existsSync(out)); assert.ok(!(r.out + r.err).includes(REFRESH));
  }
  mode = 'ok';
});
await t('a code Google refuses: the reason is shown, nothing saved', async () => {
  const d = tmp(); const out = path.join(d, 's', 't.txt');
  const r = await run(['--out', out], (o) => 'http://127.0.0.1:8085/?state=' + urlOf(o).searchParams.get('state') + '&code=OLD-CODE\n');
  assert.equal(r.code, 1); assert.match(r.err, /invalid_grant/); assert.ok(!fs.existsSync(out));
});
await t('--listen catches the redirect on this machine', async () => {
  const d = tmp(); const out = path.join(d, 's', 't.txt'); let fired = false;
  const r = await run(['--out', out, '--listen', '--port', '9124'], null, null, (o) => {
    if (!fired && o.includes('Waiting here')) { fired = true; const st = urlOf(o).searchParams.get('state'); setTimeout(() => { http.get('http://127.0.0.1:9124/?state=' + st + '&code=GOOD-CODE', (res) => res.resume()); }, 200); }
  });
  assert.equal(r.code, 0, r.err); assert.equal(fs.readFileSync(out, 'utf8').trim(), REFRESH); assert.ok(!(r.out + r.err).includes(REFRESH));
});
await t('--check: works for the saved token, says so plainly when it does not, never prints the token', async () => {
  const d = tmp(); const out = path.join(d, 't.txt');
  let r = await run(['--out', out, '--check'], null); assert.equal(r.code, 1); assert.match(r.err, /No saved token/);
  fs.writeFileSync(out, REFRESH + '\n', { mode: 0o600 });
  r = await run(['--out', out, '--check'], null); assert.equal(r.code, 0); assert.match(r.out, /^OK/); assert.ok(!(r.out + r.err).includes(REFRESH));
  fs.writeFileSync(out, 'revoked-token\n');
  r = await run(['--out', out, '--check'], null); assert.equal(r.code, 1); assert.match(r.err, /does NOT work: invalid_grant/); assert.ok(!(r.out + r.err).includes('revoked-token'));
});
await t('without the client id and secret it stops with plain instructions', async () => {
  const r = await run([], null, { GMAIL_CLIENT_ID: '', GMAIL_CLIENT_SECRET: '' }); assert.equal(r.code, 2); assert.match(r.err, /Set GMAIL_CLIENT_ID and GMAIL_CLIENT_SECRET/);
});
srv.close();
console.log('token script tests passed: ' + pass);
