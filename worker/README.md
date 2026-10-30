# Family Fix-It report service

One Cloudflare Worker that receives the reports from Family Fix-It and decides who gets them.

- `POST /report` takes the JSON the program sends (`pcName`, `version`, `kind`, `report`, and for a helper other than Trey also `owner` and `helper` with `name`, `email`, `pcId`).
- A report for Trey goes to Trey (stored in KV for 30 days, and emailed when email is set up), as before.
- A report for another helper is emailed to that helper only after the helper said yes for that one PC. The first time a new helper address is seen the service sends ONE email asking them to say yes. Until they do, the report goes to Trey and the answer says so (`delivery: "trey"`, `helperStatus: "pending"`). Reports that were emailed to a confirmed helper are not stored.
- `GET /confirm/...` and `GET /stop/...` only show a page (so a mail scanner cannot confirm for anyone). The Yes and Stop buttons on those pages do the change.
- Limits: see "Who helps you?" in the main README. Everything counts through the `RateLimiter` Durable Object.

## Email: the Gmail API

Email goes out through the Gmail API as the Family Fix-It Gmail account. No other mail service is used.

- **Secrets** (set with `wrangler secret put`): `GMAIL_CLIENT_ID`, `GMAIL_CLIENT_SECRET`, `GMAIL_REFRESH_TOKEN`. **Var:** `MAIL_FROM` (`Family Fix-It <the Gmail address>`, already in `wrangler.jsonc`). Optional vars: `REPORT_TO`, `OPERATOR_EMAILS`, `PUBLIC_URL`. If any of the four is missing, email is off: nothing is sent and every report goes to Trey (stored in KV), as before.
- **Token.** The refresh token is swapped for a short-lived access token at `https://oauth2.googleapis.com/token`. The access token is kept in memory and in KV (`gmail/token`) until about two minutes before it expires, so most emails need no token request. A 401 from Gmail gets one new token and one retry.
- **Sending.** `POST https://gmail.googleapis.com/gmail/v1/users/me/messages/send` with the message as base64url RFC 2822: UTF-8 encoded subject, plain text plus a simple HTML part (only our own confirm and stop links are clickable), `Auto-Submitted`, and on helper emails `List-Unsubscribe` (one click). The only permission used is `https://www.googleapis.com/auth/gmail.send`.
- **When Google says no** (dead or revoked token, network, Gmail refusing): reports are not lost. A helper who cannot be emailed gets the "send-failed" answer and the report goes to Trey's storage with a note; Trey's own copy is skipped but the report stays in KV. The error is written with `console.error` (visible in `wrangler tail`, never with a secret in it) and kept in KV: `gmail/last-error` (`{at, error}`, 30 days). After a token error Google is not asked again for 5 minutes (`gmail/err`).
- **Daily caps** (a normal Gmail account may send about 500 a day): 100 confirm emails (`MAX_CONFIRMS_PER_DAY`), 200 helper report emails (`MAX_MAILS_PER_DAY`), 300 emails in all (`MAX_TOTAL_MAILS_PER_DAY`); copies to Trey may use 50 more than the total. All other limits (per hour, per address, 30 days) are unchanged.
- **Setting it up:** `GMAIL-SETUP.md` (Google Cloud project, consent screen, the one-time token). `./get-gmail-token` runs on the Linux box: it prints the Google sign-in link (send permission only, offline access), takes the pasted address (or `--listen`), and saves the refresh token in a private file (mode 600) without showing it. `./get-gmail-token --check` tests the saved token.
- **Testing mode warning:** while the Google app is "Testing", refresh tokens die after 7 days. Publish the app ("In production"; allowed for this permission, shows an unverified-app screen once) before getting the token.

## Tests (no network, no account; Google is pretended in `mock-google.mjs`)

    node test.mjs
    node test-helper.mjs
    node test-gmail.mjs
    node test-token-script.mjs

(`npm test` runs all four.)

## Deploy (needs Trey's OK, see the main README)

1. Do `GMAIL-SETUP.md` parts A and B (Google project, then the token file).
2. `wrangler secret put GMAIL_CLIENT_ID`, `GMAIL_CLIENT_SECRET`, `GMAIL_REFRESH_TOKEN` (the last one from the file: `... < /workspace/family-it-fixit/secrets/gmail-refresh-token.txt`). Check `MAIL_FROM` in `wrangler.jsonc`; add `PUBLIC_URL`, `REPORT_TO`, `OPERATOR_EMAILS` if wanted.
3. Run the tests, then `wrangler deploy` from this folder.
4. Try it with a real helper address.

Without step 2 nothing is emailed and every report goes to Trey, exactly as before.
