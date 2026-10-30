#!/usr/bin/env bash
# Run-ScreenCheck.sh - starts the Family Fix-It pre-release SCREEN CHECK on GitHub (a Windows machine there), waits for it,
# and downloads the screenshots and the findings report to  <out>/<version>/ .
#
#   tools/Run-ScreenCheck.sh [-r REF] [-o OUTDIR] [-R OWNER/REPO]
#     REF    the branch or tag to check (default: main)
#     OUTDIR where results go (default: /workspace/family-it-fixit/screencheck)
#
# Needs the GitHub CLI (gh) signed in with permission to run workflows. Never touches a family PC.
# Exit code: 0 = no findings, 1 = the check found something (results are still downloaded), 2 = the check itself could not run.
set -u
REF="main"; OUT="/workspace/family-it-fixit/screencheck"; REPO="Sodapopnewb/family-it-fixit"; WF="screencheck.yml"
while getopts "r:o:R:" o; do case "$o" in r) REF="$OPTARG";; o) OUT="$OPTARG";; R) REPO="$OPTARG";; *) echo "usage: $0 [-r ref] [-o outdir] [-R owner/repo]"; exit 2;; esac; done
command -v gh >/dev/null || { echo "gh (GitHub CLI) is not installed"; exit 2; }

echo "Starting the screen check on $REPO @ $REF ..."
before=$(gh run list -R "$REPO" -w "$WF" -L 1 --json databaseId -q '.[0].databaseId' 2>/dev/null || echo 0)
gh workflow run "$WF" -R "$REPO" --ref "$REF" || { echo "Could not start the workflow (is $WF on that branch?)"; exit 2; }
run=""
for i in $(seq 1 30); do
  sleep 4
  run=$(gh run list -R "$REPO" -w "$WF" -L 1 --event workflow_dispatch --json databaseId -q '.[0].databaseId' 2>/dev/null || true)
  [ -n "$run" ] && [ "$run" != "$before" ] && break
  run=""
done
[ -n "$run" ] || { echo "The run did not appear in time."; exit 2; }
echo "Run $run: https://github.com/$REPO/actions/runs/$run"
gh run watch "$run" -R "$REPO" --interval 15 >/dev/null 2>&1
concl=$(gh run view "$run" -R "$REPO" --json conclusion -q .conclusion)
echo "Finished: $concl"

tmp=$(mktemp -d)
gh run download "$run" -R "$REPO" -D "$tmp" >/dev/null 2>&1 || echo "Warning: some artifacts could not be downloaded."
ver=$(python3 - "$tmp" <<'PY'
import json,glob,sys
for f in glob.glob(sys.argv[1] + '/**/findings.json', recursive=True):
    try:
        v = json.load(open(f, encoding='utf-8-sig')).get('version')
        if v: print(v); break
    except Exception: pass
PY
)
[ -n "$ver" ] || ver="unknown-$run"
dest="$OUT/$ver"
rm -rf "$dest"; mkdir -p "$dest"
cp -a "$tmp"/. "$dest"/ && rm -rf "$tmp"
echo "$run" > "$dest/RUN_ID.txt"; echo "https://github.com/$REPO/actions/runs/$run" > "$dest/RUN_URL.txt"
echo "Results: $dest"
[ -f "$dest/screencheck-report/findings.md" ] && sed -n '1,12p' "$dest/screencheck-report/findings.md"
case "$concl" in success) exit 0;; failure) exit 1;; *) exit 2;; esac
