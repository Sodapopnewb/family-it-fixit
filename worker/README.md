# Family Fix-It report service

One Cloudflare Worker that receives the reports from Family Fix-It and decides who gets them.

- `POST /report` takes the JSON the program sends (`pcName`, `version`, `kind`, `report`, and for a helper other than Trey also `owner` and `helper` with `name`, `email`, `pcId`).
- A report for Trey goes to Trey (stored in KV for 30 days, and emailed when email is set up), as before.
- A report for another helper is emailed to that helper only after the helper said yes for that one PC. The first time a new helper address is seen the service sends ONE email asking them to say yes. Until they do, the report goes to Trey and the answer says so (`delivery: "trey"`, `helperStatus: "pending"`). Reports that were emailed to a confirmed helper are not stored.
- `GET /confirm/...` and `GET /stop/...` only show a page (so a mail scanner cannot confirm for anyone). The Yes and Stop buttons on those pages do the change.
- Limits: see "Who helps you?" in the main README. Everything counts through the `RateLimiter` Durable Object.

## Tests (no network, no account)

    node test.mjs
    node test-helper.mjs

## Deploy (needs Trey's OK, see the main README)

1. Put a domain on Cloudflare DNS and turn on sending for it. Email sending needs the Workers Paid plan.
2. Uncomment the lines marked EMAIL in `wrangler.jsonc` (`send_email` binding `EMAIL`, `REPORT_FROM`, `PUBLIC_URL`; optional `REPORT_TO`, `OPERATOR_EMAILS`, `MAX_CONFIRMS_PER_DAY`, `MAX_MAILS_PER_DAY`).
3. Run the tests, then `wrangler deploy` from this folder.
4. Try it with a real helper address.

Without step 2 nothing is emailed and every report goes to Trey, exactly as before.
