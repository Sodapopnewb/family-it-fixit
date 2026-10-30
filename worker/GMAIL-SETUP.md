# Set up Gmail sending for the report service (one time, about 20 minutes)

The report service sends its emails (the "will you be my helper?" email and the reports for helpers) through the Gmail
account made for Family Fix-It. Nothing here is deployed by the program or its tests. Steps 1 to 7 only create the
Google side and a private token file. Step 8 (giving the three values to the Worker and deploying) is done only when Trey says go.

You need: a browser signed in to the Family Fix-It Gmail account (the one the emails will come from), and the Linux box
with Node 18 or newer. Google changes the wording of its pages now and then; the names below are what Google's pages say today.

## Part A - Google Cloud (in the browser, signed in as the Family Fix-It Gmail account)

1. Open https://console.cloud.google.com/ . Check the round picture at the top right shows the Family Fix-It Gmail
   account. If a page asks you to agree to the terms, tick the box and continue. No billing or credit card is needed.
2. Click the project picker at the top left (next to "Google Cloud"), then **New project**.
   Project name: `Family Fix-It mail`. Leave Organization/Location as they are. Click **Create**, wait a few
   seconds, then pick the new project in the project picker.
3. Turn on the Gmail API: open https://console.cloud.google.com/apis/library/gmail.googleapis.com , make sure the
   project at the top is `Family Fix-It mail`, and click **Enable**.
4. Set up the consent screen ("Google Auth Platform"): open https://console.cloud.google.com/auth/overview and click **Get started**.
   - App information: App name `Family Fix-It`. User support email: pick the Family Fix-It Gmail address. Next.
   - Audience: choose **External**. Next.
   - Contact information: type the Family Fix-It Gmail address. Next.
   - Tick the box that you agree to the Google API Services User Data Policy, click **Continue**, then **Create**.
5. Give it only the send permission. Left menu **Data Access** > **Add or remove scopes**. In "Manually add scopes" paste
   `https://www.googleapis.com/auth/gmail.send` and click **Add to table**, then tick it in the table, **Update**, then **Save**.
   It is listed as a "sensitive" scope. That is expected. Add no other scope.
6. Test users, then publish. Left menu **Audience**.
   - Under "Test users" click **Add users**, type the Family Fix-It Gmail address, **Save**. (Keep it there; it does no harm.)
   - **Read this before the next click.** While the app says "Testing", Google ends every refresh token 7 days after it
     was granted, and the report service would stop sending mail a week later. So move the app to production now:
     under "Publishing status" click **Publish app**, then **Confirm**. The status becomes "In production".
   - What that means (checked against Google's help pages on 2026-10-30):
     - Allowed for the send permission. No security assessment is needed (the send permission is "sensitive", not "restricted").
     - The app is not verified, so Google shows a warning, "Google hasn't verified this app", at sign-in. You click through it once (step 10).
     - An unverified app may have at most 100 people ever sign in to it. Only the Family Fix-It Gmail account signs in, so that is 1 of 100.
       Google verification is only needed if you ever go over that, and is not needed here.
     - Do NOT click "Prepare for verification" or "Submit for verification".
     - If this page offers no Publish button or asks for a domain or logo, stop and tell Trey. Do not invent one.
7. Make the key pair for the program. Left menu **Clients** > **Create client**.
   - Application type: **Desktop app**. Name: `fixit-worker`. Click **Create**.
   - A box shows the **Client ID** and **Client secret**. Click **Download JSON** and keep that file private, or copy both values
     into a password manager. (You can open the client again later on the Clients page to see the secret.)
   - Desktop app is the right type: it accepts a redirect to http://127.0.0.1 on any port, which is what the script uses.

## Part B - on the Linux box (get the token, never shown on screen)

8. Open a terminal in the `worker` folder of the Family Fix-It checkout and give the script the two values (they stay in this terminal only):

        export GMAIL_CLIENT_ID='paste the Client ID here'
        export GMAIL_CLIENT_SECRET='paste the Client secret here'
        ./get-gmail-token

9. The script prints a long link. Open it in any browser, even one on another computer. Sign in as the Family Fix-It Gmail account.
10. Google says **"Google hasn't verified this app"**. That is our own app. Click **Advanced**, then **Go to Family Fix-It (unsafe)**.
    Then it shows what the app asks for: only "Send email on your behalf". Click **Continue** (or **Allow**).
11. The browser then shows an error page ("This site can't be reached" / "refused to connect") at an address beginning with
    `http://127.0.0.1:8085/?state=`. That is normal and expected when the browser is not on the Linux box. Copy the whole address from
    the address bar, go back to the terminal, paste it at "Paste the address" and press Enter.
    (If the browser IS on the Linux box you can run `./get-gmail-token --listen` instead and nothing needs pasting.)
12. The script says "Saved the refresh token (not shown)" and the file name, normally
    `/workspace/family-it-fixit/secrets/gmail-refresh-token.txt` (mode 600; the folder is 700 and ignores everything in git).
    Check it any time with `./get-gmail-token --check` (prints only OK or the error).
    - If it says "did not hand out a refresh token": open https://myaccount.google.com/permissions in the browser signed in
      as the Gmail account, remove "Family Fix-It", and run the script again.
    - Important: do this part AFTER step 6 published the app. A token made while the app said "Testing" stops after 7 days.
      If you did it in the wrong order, publish, then run the script again; the new token replaces the old one.

## Part C - giving it to the Worker (ONLY when Trey says go; this changes the live service)

13. In the `worker` folder, one at a time (each asks for the value; the third reads the file so the token is never shown):

        npx wrangler secret put GMAIL_CLIENT_ID
        npx wrangler secret put GMAIL_CLIENT_SECRET
        npx wrangler secret put GMAIL_REFRESH_TOKEN < /workspace/family-it-fixit/secrets/gmail-refresh-token.txt

    `MAIL_FROM` is already set in `wrangler.jsonc` to the Family Fix-It Gmail name and address. Then run `node test.mjs && node test-helper.mjs && node test-gmail.mjs`
    and `npx wrangler deploy`. Try it with a real helper address: choose Someone else in the program, click Yes in the email, send a report.

## Things that can stop the token later (all checked against Google's docs, 2026-10-30)

- The token stops if it is not used for 6 months (the Worker uses it with every email, so this only matters if the service sits unused).
- Changing the Gmail account's password revokes tokens that carry Gmail scopes. After any password change run step 8 to 12 again, then `wrangler secret put GMAIL_REFRESH_TOKEN`.
- Removing the app at myaccount.google.com/permissions, or deleting the Cloud project or the OAuth client, stops it. Google also deletes an OAuth client nobody has used for 6 months.
- Putting the app back to "Testing" brings back the 7-day limit.
- When this happens the Worker does not lose anything: reports keep going to Trey's storage (KV) with a note, the error is written to the Worker log, and the last
  error is kept at the KV key `gmail/last-error` (it says `invalid_grant` for a dead token).
- A normal Gmail account can send about 500 messages a day. The Worker stops at 300 a day (100 confirmation emails, 200 helper reports, plus 50 more for copies to Trey).
