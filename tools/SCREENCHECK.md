# Pre-release screen check

Run this before telling anyone a build is live. It opens every window of Family Fix-It on a GitHub Windows machine, takes
pictures, and fails if any text is cut off, any button or label is empty, controls overlap or hang outside their window, or the
pop-up watcher's tray icon is missing.

From the box:  `tools/Run-ScreenCheck.sh -r main`  (or `-r v2.3.13` for a tag). Results land in
`/workspace/family-it-fixit/screencheck/<version>/` (`screencheck-report/findings.md`, one folder of screenshots per run).
By hand: GitHub -> Actions -> "Screen check" -> Run workflow. It also runs when a `v*` tag is pushed.

## How it works
- `tools/ScreenCheck.ps1` loads `FamilyFixIt.ps1 -LibraryOnly` (no start-up, no edit to the program) and opens each window from a list that
  is built from the program itself (every help topic, every plan, every guide in guides.json, so new windows are picked up by themselves).
- A timer in the window loop waits for the window to settle, measures it, saves a picture (PrintWindow) and closes it. Windows' own message
  boxes are found by class and pressed closed.
- Measuring: text vs. the control size with TextRenderer and GetPreferredSize; tile buttons (their text is painted, not a property) are
  re-measured with the same rectangles the paint code uses, plus a pixel check that something is drawn where the label should be;
  parent/window bounds; overlaps; sideways scroll bars; window larger than the screen.
- Tray: the icon is created with the program's own code and checked: visible, not the stock "i", not blank at 16/20/24/32 px, hover text
  <= 63 characters, menu items match the plan. A best-effort look at the taskbar is reported for information only.
- Nine runs (1.0 / 1.5 / 2.0 scale x Normal / Big text / High contrast), one fresh Windows process each; `ScreenCheck-Report.ps1` joins them
  and the job fails on any finding. `Set-ScreenSize.ps1` makes the runner screen 1920x1080 first.

## DPI method (and its limit)
The program draws every size and font as `base x $script:UiScale` (no WinForms auto-scale), and reads the display scale once at start.
The check sets `UiScale` to 1.0 / 1.5 / 2.0 (x1.25 more for Big text) in a fresh process. It does **not** change real Windows DPI (that needs a
sign-out), so Windows-drawn parts (title bars, message-box frames, scroll bars) stay at 100%. The watcher toast reads the real screen scale, so
it is only checked at 100%. Message boxes are pictured, not measured. Needs a real PC: real monitor scaling, a second monitor, touch, other Windows languages.
