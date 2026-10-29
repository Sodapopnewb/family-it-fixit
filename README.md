# Family Fix-It (v2.2)

A Windows tool for family. Big plain-language buttons fix the common problems by themselves, ask "Did that fix it?", and send Trey a report when they cannot.
Two small things can run in the background, and both have an on/off switch in the side bar: the **pop-up watcher** (on by default) and the optional **weekly check-in**.

## For the family (what to tell them)
**Installing (first time):** Trey sends you a link. Download the zip, right-click it, choose **Extract All**, open the new folder and double-click **Install-FamilyFixIt.cmd**. A black window shows 5 short steps, then **Family Fix-It** opens and a shortcut with the same name appears on your Desktop. If Windows asks "Are you sure you want to run this?", see *Install on a family PC* below.

**Using it:**
1. Double-click the **Family Fix-It** shortcut (or **Start-FixIt.cmd**). A window opens.
2. Click the button that matches the problem. Windows may ask "Do you want to allow this app to make changes?" - click **Yes**.
3. After a fix the tool asks **"Did that fix it?"**. If you click **No**, it sends Trey a report automatically.

The main buttons:
- **Fix my printer**, **Fix Acrobat in Outlook**, **Fix Outlook**
- **Fix my internet**, **My computer is slow**, **Fix sound, mic and camera**
- **Clean up my browser**, **Fix Windows Update**, **Fix OneDrive**
- **I see a scary pop-up** (red) - tells you not to call the number, to turn off Wi-Fi, to click nothing and to call Trey, and sends Trey an alert report. Trey never asks for codes or remote tools unless *you* called him.
- **If a web page takes over your whole screen** you do not have to find a button. A small box appears in the bottom right corner: *"Are you OK? Is a website scaring you?"* Click **Get me out of here** (or press **Ctrl + Shift + F** at any time). The browser is closed, you see *"You're safe. Don't call any number that page showed. Trey has been told."*, and Trey gets an alert. Click **I'm fine** if it is just a video you chose to watch full screen. When you open the browser again, do not click **Restore** if it asks.
- **Let Trey see my screen** - opens Zoho's page. Trey gives you a code; type it in and click Join. Only do this if YOU called Trey.
- **Send Trey a report** - saves a report on the Desktop and sends it to Trey ("Report sent to Trey"). If sending fails it says to send the Desktop file to Trey yourself.

The left side bar:
- **Restart the right way** - a full restart (not the half-restart Windows does by default).
- **Is it just me?** - checks Microsoft 365 / Outlook status and basic internet reachability.
- **Undo last fix** - puts back what the last fix changed. It says clearly when something cannot be undone (for example deleted temporary files).
- **What did I fix?** - a plain list of recent fixes: date, what it was, and whether it worked.
- **My files** - find a file by part of its name (Desktop, Documents, Downloads, Pictures, OneDrive), or see what you saved lately. Every result has two buttons: **Open the file** and **Show me where it is**. It only reads; it never changes or deletes files, and it will not run programs.
- **Install an app** - installs only the apps on Trey's approved list (default: Google Chrome, Zoom, Adobe Acrobat Reader, VLC) from Microsoft's official app source (winget). Nothing else can be installed from here.
- **My PC info** - a card with the PC name, the Windows version, the Family Fix-It version and a short **PC code** (like `7EH-HEJ`) in big letters. If Trey asks "what's your code?", read it out. **Copy** puts all of it on the clipboard so it can be pasted into an email.
- **Help me with...** - step-by-step guides with big numbered steps (print a PDF or web page, scan, attach a photo to an email, take a screenshot and send it to Trey, connect to Wi-Fi, join a video call, save a photo from an email, make text bigger, find something you downloaded, spot a scam email or text). Type a few words in the big box at the top and the list narrows as you type: *scan* finds the scanning guide, *picture* finds the photo guides, and small typing slips are forgiven (*scaner*). If nothing fits it says **"No guide for that yet - Send Trey a report?"** and the button sends Trey a short report saying what was searched. Every guide ends with **This didn't help - tell Trey**.
- **Simple mode** - a switch that shrinks the window to just six big buttons: **Fix my printer**, **Fix my internet**, **My computer is slow**, the red scary pop-up button, **Let Trey see my screen** and **Send Trey a report**. Switch it off in the same place to see everything again. The tool remembers the choice for each person.
- **Big text** and **High contrast** switches, the **Watch for scary pop-ups** switch (on by default) and the **weekly check-in** switch. The tool remembers them. (Simple mode hides the pop-up watcher and check-in switches; they keep running as they were.)

## For Trey
Files: `FamilyFixIt.ps1` (everything), `Start-FixIt.cmd` (launcher), `guides.json` (the help guides), `Install-FixIt.ps1` + `Install-FamilyFixIt.cmd` (installer), `apps.json` (approved apps), `tools/Publish-FixIt.ps1`, `tests/Test-FixIt.ps1`, `worker/` (the report receiver; it is in Trey's working folder and is not published to GitHub).

### Command line and practice mode
- **Practice mode (changes nothing):** `powershell -File FamilyFixIt.ps1 -Action Printer -WhatIf` (`-DryRun` is the same). It writes "Would do: ..." lines to the log and the screen.
- **One action without the window:** `-Action Printer|Acrobat|AcrobatRepair|Outlook|Network|Slow|Sound|Browser|WinUpdate|OneDrive|Scam|Screen|Report|Update|Restart|Status|Undo|History|Files|Install|PCInfo|Guides|Simple|HealthCheck|CheckInOn|CheckInOff|GuardianOn|GuardianOff|GuardianDemo|Guardian`.
  `-Action Guides -Query scanner` prints the best matching guide (and `-Action Guides` alone lists them all). `-Action Simple` flips Simple mode. `-Action PCInfo` shows the card.
  `-Action Files -Query budget` lists matching files. `-Action Install -App "VLC media player"` installs one approved app (without `-App` it lists them).
- **Log:** `%LOCALAPPDATA%\FamilyFixIt\logs\fixit-YYYY-MM-DD.log`. The history list is read from it, so please do not rename those files.
- **Undo journal:** `%LOCALAPPDATA%\FamilyFixIt\undo.json` (last 30 fixes). Browser backups are kept next to it.
- **Admin rights:** only the steps that need them ask Windows for permission. Per-user fixes never do.
- **Every fix is safe to re-run**: it checks first and only changes what is wrong.

### Install on a family PC (bootstrap installer)
`Install-FixIt.ps1` (plus the double-click wrapper `Install-FamilyFixIt.cmd`) sets a family PC up from nothing. No administrator rights.
1. Downloads `manifest.json` and the program files (`FamilyFixIt.ps1`, `Start-FixIt.cmd`, `README.md` and the optional `guides.json`) from `https://raw.githubusercontent.com/Sodapopnewb/family-it-fixit/main` (only those names are ever accepted).
2. Checks each file's SHA-256 and size against the manifest. If anything is wrong **nothing is installed** (and an existing working copy is left untouched).
3. Installs to `%LOCALAPPDATA%\FamilyFixIt` (old copies go to `previous\`).
4. Makes the shortcut **Family Fix-It** on the Desktop and in the Start menu (it starts the tool with no black window).
5. Runs `FamilyFixIt.ps1 -Action GuardianOn` and `-Action CheckInOn` from the installed folder, then opens the tool.
- **Safe to run again:** it downloads only files that are missing or different, re-makes missing shortcuts, and turns the two switches on again. If the program file changed it restarts the watcher so the new version runs. (A re-run is a repair, so it also switches the watcher and check-in back on.)
- **Practice run:** `.\Install-FixIt.ps1 -WhatIf` reads the list and prints what it would do. `-NoLaunch` skips opening the tool; `-InstallDir` and `-BaseUrl` override the defaults.
- **Log:** `%LOCALAPPDATA%\FamilyFixIt\logs\install-YYYY-MM-DD.log`.

**Two ways to give it to someone**
- **Download link (best for family):** a GitHub Release with one asset named exactly `Install-FamilyFixIt.zip` (made by the publish script in `release/`). The address that always gives the newest one:
  `https://github.com/Sodapopnewb/family-it-fixit/releases/latest/download/Install-FamilyFixIt.zip`
- **One line in PowerShell:** open PowerShell (not as administrator) and paste:
  `irm https://raw.githubusercontent.com/Sodapopnewb/family-it-fixit/main/Install-FixIt.ps1 | iex`
  This never saves the installer as a file, so Windows does not put its "downloaded from the internet" mark on it and there is no SmartScreen prompt.

**SmartScreen and the "downloaded from the internet" mark (Mark of the Web)**
Files saved by a browser carry a hidden "from the internet" mark, and files you **Extract All** from that zip inherit it. Windows may therefore warn before the `.cmd` runs. What the family will see, depending on the Windows version:
- *In the browser:* Edge or Chrome may say the file "isn't commonly downloaded". Click **...** then **Keep**, then **Keep anyway**.
- *Double-clicking Install-FamilyFixIt.cmd:* either a small **Open File - Security Warning** box (click **Run**), or a blue **Windows protected your PC** box: click **More info**, then **Run anyway**.
- *To avoid both:* right-click the zip, choose **Properties**, tick **Unblock** at the bottom, click **OK**, and only then **Extract All**.
- If they double-click the `.cmd` while still inside the zip (without extracting), the wrapper notices the script is missing and fetches it from GitHub itself (same as the one-line install).
- The warning appears because the installer is not code-signed (a certificate costs money). Nothing it installs carries the mark: the program files are downloaded by PowerShell, which does not add it.
- Run it as yourself, not "as administrator": an elevated window can belong to a different user, and the shortcuts would land on the wrong Desktop (the installer prints a note if it detects this).

**Publishing the installer** (needs your approval; nothing is uploaded by the script): `pwsh ./tools/Publish-FixIt.ps1 -Owner <your-github-name>` fills in your name, runs the secret scan and writes `dist/` (commit it to the repo root: it contains `Install-FixIt.ps1` and `Install-FamilyFixIt.cmd`) and `release/Install-FamilyFixIt.zip`. Create a GitHub Release (for example tag `v2.1.0`) and attach that zip with exactly that file name; the `/releases/latest/download/` link then always points at the newest release. Remember the installer pulls the program files from the `main` branch, so push `dist/` first.

### Guardian: the scary full-screen pop-up watcher
**What it does.** A hidden PowerShell process (one small check every 1.5 seconds, almost no CPU) looks at the front window. If a **browser** (`msedge, chrome, firefox, brave, opera, iexplore`) covers the whole monitor for two looks in a row (about 3 seconds), a small always-on-top box appears at the bottom right *without taking the keyboard focus*, so a stray keystroke cannot click it. It never sends or stores anything until the person clicks the red button or presses the hotkey.
- **Get me out of here** (or **Ctrl + Shift + F** from anywhere): force-closes every browser process, then shows *"You're safe. Don't call any number that page showed. Trey has been told."* and sends a **SCAM** alert (the same report as the red button) with the window title, the page address when Windows lets us read it, how the browser was started (kiosk / app mode / address), how many browser programs were closed, plus the usual extras: remote-control tools, recent installs and recent downloads. If sending fails, the box says to call Trey and a copy is saved on the Desktop.
- **I'm fine:** closes the box, never asks about that window again, and stays quiet about that browser for 30 minutes (so a full-screen video does not nag).
- The box is re-asserted on top every 1.5 seconds, so a page that grabs the top layer cannot cover it. It goes away by itself if the person escapes some other way.
- **Switch:** side bar **Watch for scary pop-ups** (on by default; the first time the window opens it turns itself on). It is a per-user Run entry `HKCU\Software\Microsoft\Windows\CurrentVersion\Run\FamilyFixItGuardian` (no administrator). Command line: `-Action GuardianOn` / `GuardianOff` (safe to repeat). If the person turns it off in the window it stays off (until the installer is run again).
- **See it without a scare:** `-Action GuardianDemo` shows the box right now. Nothing is closed or sent.
- **Practice mode:** `-Action Guardian -WhatIf` only describes it. A second copy exits at once (one watcher per user).
- **Log:** same daily log as the tool (`Guardian started`, `a full-screen msedge page was found`, `get me out`, `Closed N browser program(s)`, `finished (report sent: ...)`).
- **After the browser is closed ("restore pages")**: Edge, Chrome and Brave would otherwise offer *"Restore pages?"* and bring the scary page back. Before it is cleared, Guardian **backs up** the profile's session files and `Preferences` to `%LOCALAPPDATA%\FamilyFixIt\guardian-backup\<time>\` (the newest 5 are kept), then moves the last-session files aside (`Sessions\Session_*`, `Tabs_*`, old `Current/Last Session|Tabs`) and marks the profile as closed normally (`exit_type`, `exited_cleanly`). For Firefox it does the same with `sessionstore.jsonlz4` and `sessionstore-backups\`. The box also says *"do not click Restore"* as a second line of defence. The person's history, bookmarks and passwords are never touched. To undo: copy the files back from the backup folder.
- **Limits.** It cannot read the address bar of a full-screen page on every browser (it then says "not available" in the report). A kiosk/full-screen page that is *not* in one of those six browsers (for example a PWA-style window) is not caught; the hotkey still closes any browser. A full-screen browser video you want to watch will get one question (click **I'm fine**). If another program has exclusive control of the keyboard shortcut, the hotkey is unavailable (the log says so), and the box still works. Unsaved work in the browser is lost when it is closed: that is the point.

### What only a real Windows PC can test
Mock tests cover all the decisions (what counts as full screen, when to ask, what to close, what gets sent, the toggle, backups, install and repair). Check these on a real PC (Windows 10 and 11, PowerShell 5.1):
1. The toast **looks right** at 100%, 150% and 200% scaling and on a second monitor, sits in the bottom right, is red-framed, and the fonts are readable.
2. It **does not steal focus** (type in another window when it appears) and stays on top of a full-screen Edge, Chrome and Firefox page (F11, kiosk `--kiosk`, a video at full screen).
3. **Ctrl + Shift + F** works from any window (and says so in the log if another program owns it).
4. **Get me out** closes all of the signed-in person's browser windows, the calm message shows, a SCAM report arrives in KV, and the **Restore pages** bubble does **not** appear when Edge / Chrome / Firefox are reopened.
5. **I'm fine** stops further questions for that window and for 30 minutes.
6. The **Run entry starts it at sign-in**, with no black window flash; one process only (Task Manager); turning the switch off stops it.
7. **False positives:** a maximized window with the taskbar hidden, a full-screen YouTube video, a presentation, a game, a remote-desktop window.
8. The page address shows up in the report in at least one case; otherwise "not available".
9. Shortcuts: icon, **Desktop and Start menu** names, launching without a console, and the SmartScreen prompts described above for the downloaded zip.
10. The installer on a PC that already has Family Fix-It (update) and with the PC offline.
11. **My PC info**: the card looks right at 100%, 150% and 200%, the code is easy to read aloud, **Copy** puts the text on the clipboard (paste it into Notepad), and the code matches the recipe above computed on that PC.
12. **Help me with...**: the search box has focus when the window opens; the list filters smoothly as you type on an older/slow PC (no stutter); *scan*, *picture*, *wifi*, *scaner* and nonsense behave as described; Enter opens the first guide; Back returns with the search kept; **No guide for that yet** sends a report that arrives in KV; the guides read well with Big text and High contrast.
13. **Simple mode**: switch on and off; the window shrinks to six buttons with no gaps; it is still right at 150% and 200% scaling, with Big text and with High contrast; it is remembered after closing and reopening; the Guardian keeps running.
14. A change to `guides.json` published to GitHub appears in **Help me with...** on a PC that is online (no update prompt) and the saved copy is used offline.

### Reports (Cloudflare Worker + KV)
- The tool POSTs JSON `{pcName, version, kind, report}` with the header `X-FixIt-App: family-it-fixit` to `https://fixit-report.hg-fixit.workers.dev/report` (change with `-ReportUrl`). No secret is stored on family PCs.
- `kind` is `report`, `scam` (red button or the pop-up watcher, subject "SCAM ALERT") or `health` (weekly check-in).
- The Worker allows up to 512 KB, 10 requests a minute per client network and 30 a minute overall (a Durable Object counts them), then answers 429.
- **Email delivery is not working yet.** Cloudflare's email sending needs a domain on your Cloudflare account and a paid Workers plan, and this account has neither. Until then **every report is stored in the Worker's KV namespace `REPORTS` for 30 days**. To read them:
  - Cloudflare dashboard: Workers & Pages > KV > `REPORTS` > keys starting with `report/` (reports are `report/<time>-<id>`, scam alerts `report/SCAM-...`, weekly checks `report/HEALTH-...`).
  - Or API: list `GET /accounts/<id>/storage/kv/namespaces/<ns>/keys?prefix=report/` and read a key at `.../values/<key>`. The list shows PC name, version, kind and time as metadata.
  - When a sending domain exists, add a `send_email` binding named `EMAIL` and the variables `REPORT_TO` / `REPORT_FROM`; the Worker already forwards (the code is in `worker/index.js`).
- Worker tests: `node worker/test.mjs`.

### My PC info and the PC code
The code lets you match a report (or a phone call) to a PC without asking for a long name. **Recipe** (so you can work it out yourself from the PC name and MachineGuid shown in a report or on the PC): take `UPPERCASE(PC name) + "|" + lowercase(MachineGuid)`, encode as UTF-8, SHA-256 it, and for each of the first 6 bytes take `byte mod 22` and look it up in the alphabet `ACDEFGHJKMNPRTWXY34679` (no B/8, S/5, O/0, I/1/L, Z/2, Q, U, V, so it is easy to read aloud). Shown as `ABC-DEF`. `MachineGuid` is `HKLM\SOFTWARE\Microsoft\Cryptography`; if it cannot be read, only the name is used. PowerShell check:
`$h=[Security.Cryptography.SHA256]::Create().ComputeHash([Text.Encoding]::UTF8.GetBytes('MYPC|1b2c3d4e-...'));-join(0..5|%{'ACDEFGHJKMNPRTWXY34679'[$h[$_]%22]})`
The line `PC code: ABC-DEF` is in the header of every report (normal, scam and pop-up alerts) and in the weekly check-in. The Worker is unchanged. The code is not a secret and it is not a password; two PCs may in theory share a code (about 1 in 113 million), so use it together with the PC name.

### Help guides ("Help me with...")
`guides.json` holds the guides. Each one is `{ "id": "scan", "title": "Scan a paper", "keywords": ["scanner", "copy paper", "photocopy"], "steps": ["Step one.", "Step two."] }`.
- `id`: lowercase letters, numbers and `-`, up to 40 characters, unique. `title`: up to 60 characters. `steps`: 1 to 15 steps, up to 300 characters each (plain text, no links needed). `keywords`: up to 40 search words or short phrases (up to 40 characters each) that people might type instead of the title - synonyms (*picture* for *photo*), brand names (*zoom*), common slips. A comma-separated string also works. Up to 20 guides. Anything that does not fit is skipped and written to the log, never shown.
- **Remote updates.** `Publish-FixIt.ps1` checks the file (it stops on a bad or repeated id, too-long text or control characters) and copies the guides into `manifest.json` (`guides`). The tool reads the live manifest first, so a fix to a guide reaches everyone the next time they open **Help me with...** without a version bump or an update prompt. If the manifest cannot be read it uses the `guides.json` next to the program (installed and updated with a checksum like the other files), and if that is missing or broken a small built-in "take a screenshot" guide. Edit, run the publish script, commit `dist/`.
- **Search** (what you type is matched as you type, about a fifth of a second after you stop): filler words (*how do I, help me with, my*) are ignored; words match by family (*scan*, *scanner*, *scanning*), by the start of a word (*print* -> *printer*) and with one slip allowed (two for long words; a swapped pair of letters counts as one slip). Title words count most, then keywords, then words in the steps. When more than one word is typed at least half of them must match. A clear best guide hides weak maybes. No words (or only filler) shows every guide. Enter opens the top match. No match shows the friendly message and a **Send Trey a report** button (user-initiated; it goes out only when clicked).
- The guide screen has a **Back** button and **This didn't help - tell Trey**, which sends a report naming the guide.

### Simple mode
For people who only need the basics. The side-bar switch **Simple mode** (remembered per Windows user in `%LOCALAPPDATA%\FamilyFixIt\state.json`, key `SimpleMode`) rebuilds the window with only: Fix my printer, Fix my internet, My computer is slow, the red scary pop-up button, Let Trey see my screen, Send Trey a report. The tools list and the pop-up watcher and check-in switches are hidden (the watcher and check-in are not turned off). Big text and High contrast still work. `-Action Simple` flips it from the command line (`-WhatIf` remembers nothing).

### Weekly check-in
The family member can turn it on from the side bar. It creates a per-user scheduled task (Sundays 10:00, no admin) that quietly sends a health summary (disk, updates, restart waiting, Defender, OneDrive backup, uptime, tool version) as `kind: health`. No files, documents or passwords. Turning it off removes the task.

### Install-an-app list
The list lives in the update manifest (`apps` in `manifest.json`), so you can change it remotely by editing that file on GitHub (or edit `apps.json` and publish again). Each entry is `{ "id": "<exact winget id>", "name": "<button text>" }`. The tool ignores any entry whose id or name looks wrong, installs with `winget install --id <id> --exact --source winget`, skips apps already installed, and falls back to the built-in default list if it cannot read the manifest.

### Updates (GitHub)
- The tool checks `manifest.json` in a public GitHub repo when the window opens (only if online) and *asks* before updating. Default address: `https://raw.githubusercontent.com/Sodapopnewb/family-it-fixit/main/manifest.json`. While it says `Sodapopnewb`, updates are off (and the app list is the built-in one).
- To publish: `pwsh ./tools/Publish-FixIt.ps1 -Owner <your-github-name>`. It writes `dist/`, ready to commit to the repo root, with checksums and the app list, and `release/Install-FamilyFixIt.zip` for the GitHub Release. It refuses to continue if it finds an email address, a token, a password or a user folder path in the files.
- Bump `$script:FixItVersion` in `FamilyFixIt.ps1` before each publish.
- Checksums catch damaged downloads, not a hacked repo: use 2-factor on the GitHub account.
- Only `FamilyFixIt.ps1`, `Start-FixIt.cmd`, `README.md` and `guides.json` can be updated. Old copies are kept in `previous/`.

### Tests
`pwsh ./tests/Test-FixIt.ps1` runs on Mac/Linux/Windows with pretend Windows calls. The window, UAC prompts, audio, services, winget, Explorer and the scheduled task still need a test on a real PC.
