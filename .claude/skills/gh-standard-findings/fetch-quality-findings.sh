#!/usr/bin/env bash
# Fetch GitHub "Code Quality" STANDARD (rule-based) findings as JSON and summarize.
#
# Companion to fetch-ai-findings.sh. Same mechanism: the /security/quality pages are React/Remix
# *web* routes that serve JSON with `Accept: application/json`, authenticated by a browser SESSION
# COOKIE (GH_WEB_COOKIE), not a PAT/gh token. (`gh api .../code-scanning/alerts` returns 403 — these
# quality findings are a separate product, web-route-only.)
#
# Endpoints (all under https://github.com/<owner>/<repo>/security/quality):
#   (index)                            -> .payload.repoCodeQualityIndexRoute  {grades + counts}
#   /rules                             -> {count, rules[], nextCursor}         (rule kinds — DYNAMIC)
#       rule = {ruleId, title, severity(error|warning|note), category(reliability|maintainability),
#               openCount, dismissedCount, language}
#   /rules/<url-enc-ruleId>/findings   -> {openCount, ruleFindings[], nextCursor}
#       finding = {number, filePath, startLine, endLine, message, findingState, codeSnippetLines[]}
#   Pagination (both list endpoints): append ?after=<nextCursor> until nextCursor is empty.
#
# Usage:
#   GH_WEB_COOKIE='<cookie>' ./fetch-quality-findings.sh [owner/repo]                 # rule summary (default)
#   GH_WEB_COOKIE='<cookie>' ./fetch-quality-findings.sh [owner/repo] --rule <ruleId> # findings for one rule
#   ... --json                                                                        # raw JSON (rules, or findings with --rule)
#
#   owner/repo defaults to the current repo (gh repo view).
#
# SECURITY: the cookie grants full account access — env var only, never commit, rotate (log out) when done.
# It expires (~2 weeks) and the JSON shape is undocumented; treat as best-effort.
set -euo pipefail

repo=""; rule=""; raw=false
while [ $# -gt 0 ]; do
  case "$1" in
    --json) raw=true ;;
    --rule) shift; rule="${1:-}"; [ -z "$rule" ] && { echo "--rule needs a ruleId" >&2; exit 2; } ;;
    -*)     echo "unknown flag: $1" >&2; exit 2 ;;
    *)      repo="$1" ;;
  esac
  shift
done
[ -z "$repo" ] && repo="$(gh repo view --json nameWithOwner --jq .nameWithOwner)"
: "${GH_WEB_COOKIE:?set GH_WEB_COOKIE to your github.com Cookie header (see fetch-ai-findings.sh header)}"

# Cookie via a 0600 curl --config file so the secret never lands in the process arg list (ps-visible).
cfg="$(mktemp)"; chmod 600 "$cfg"
printf 'header = "Cookie: %s"\n' "$GH_WEB_COOKIE" > "$cfg"
tmp="$(mktemp)"
trap 'rm -f "$cfg" "$tmp"' EXIT

api() { # $1 = path under /security/quality (with leading slash; "" = index)
  curl -fsS -H 'Accept: application/json' --config "$cfg" \
    "https://github.com/${repo}/security/quality$1" 2>/dev/null || true
}
urlenc_rule() { printf '%s' "$1" | jq -sRr @uri; }  # ruleIds look like "cs/path-combine"; @uri handles / and any other chars

# ── Per-rule findings (paginated) ─────────────────────────────────────────────
if [ -n "$rule" ]; then
  enc="$(urlenc_rule "$rule")"; after=""; : > "$tmp"
  while :; do
    q="/rules/$enc/findings"; [ -n "$after" ] && q="$q?after=$after"
    page="$(api "$q")"
    [ -z "$page" ] && { echo "fetch failed for $repo rule '$rule' (cookie expired/invalid, or bad ruleId)." >&2; exit 1; }
    echo "$page" | jq -c '.ruleFindings[]?' >> "$tmp"
    after="$(echo "$page" | jq -r '.nextCursor // ""')"
    [ -z "$after" ] && break
  done
  if $raw; then jq -s '.' "$tmp"; exit 0; fi
  echo "$rule — $(wc -l < "$tmp") open finding(s):"
  echo ""
  jq -r '"• \(.filePath):\(.startLine)-\(.endLine)\n  \(.message)"' "$tmp"
  exit 0
fi

# ── Rule summary (default) ────────────────────────────────────────────────────
after=""; : > "$tmp"
while :; do
  q="/rules"; [ -n "$after" ] && q="$q?after=$after"
  page="$(api "$q")"
  [ -z "$page" ] && { echo "fetch failed for $repo (cookie expired/invalid, or Code Quality off on this repo/mirror)." >&2; exit 1; }
  echo "$page" | jq -c '.rules[]?' >> "$tmp"
  after="$(echo "$page" | jq -r '.nextCursor // ""')"
  [ -z "$after" ] && break
done

if $raw; then jq -s '.' "$tmp"; exit 0; fi

api "" | jq -r '.payload.repoCodeQualityIndexRoute
  | "repo: \(.owner)/\(.repo)   branch: \(.branch)   scanned: \(.lastScanAt)",
    "maintainability: \(.maintainability.grade) (\(.maintainability.findingsCount))    reliability: \(.reliability.grade) (\(.reliability.findingsCount))"'
echo "rules: $(wc -l < "$tmp")   (drill in with --rule <ruleId>)"
echo ""
# sort by severity (error > warning > note), then open count desc — numeric sort done in jq.
jq -s -r '
  def rank: if .severity=="error" then 0 elif .severity=="warning" then 1 else 2 end;
  sort_by([rank, -(.openCount)])[]
  | [.severity, (.openCount|tostring), .category, .ruleId, .title] | @tsv' "$tmp" \
  | awk -F'\t' '{printf "  %-7s x%-5s %-15s %s — %s\n", $1, $2, $3, $4, $5}'
