#!/usr/bin/env bash
# Fetch GitHub "Code Quality → AI findings" (repo-level) as JSON and summarize.
#
# These findings live in a GitHub web dashboard with NO public REST/GraphQL API
# (code-scanning/dependabot/secret-scanning all return 404/gated). The page is a
# React/Remix route that serves JSON when asked with `Accept: application/json`,
# but it is a *web* route — it authenticates with a browser SESSION COOKIE, not a
# PAT/`gh` token. So this script needs GH_WEB_COOKIE, not GITHUB_TOKEN.
#
# Usage:
#   GH_WEB_COOKIE='<full github.com Cookie header>' ./fetch-ai-findings.sh [owner/repo] [--json]
#
#   owner/repo  defaults to the current repo (gh repo view).
#   --json      print the raw JSON instead of the human summary (for fix-diffs etc).
#
# Get the cookie: browser DevTools → Network → open
#   https://github.com/<owner>/<repo>/security/quality/ai-findings → click the
#   request → copy the entire request `Cookie:` header. It MUST include
#   user_session + __Host-user_session_same_site (not just _gh_sess).
#
# SECURITY: that cookie grants full account access. Keep it in the env var only,
# never commit it, and rotate it (log out / revoke the session) when done. It also
# expires (~2 weeks) and the JSON shape is undocumented — treat this as best-effort.
set -euo pipefail

repo=""
raw=false
for a in "$@"; do
  case "$a" in
    --json) raw=true ;;
    -*)     echo "unknown flag: $a" >&2; exit 2 ;;
    *)      repo="$a" ;;
  esac
done
if [ -z "$repo" ]; then
  repo="$(gh repo view --json nameWithOwner --jq .nameWithOwner)"
fi
: "${GH_WEB_COOKIE:?set GH_WEB_COOKIE to your github.com Cookie header (see header comment)}"

url="https://github.com/${repo}/security/quality/ai-findings"

# Pass the cookie as a raw header via a 0600 curl config file (--config) rather than -b "$VAR",
# so the secret never lands in the process argument list (visible to other users via `ps`).
cfg="$(mktemp)"; chmod 600 "$cfg"
printf 'header = "Cookie: %s"\n' "$GH_WEB_COOKIE" > "$cfg"
trap 'rm -f "$cfg"' EXIT
json="$(curl -fsS -H 'Accept: application/json' --config "$cfg" "$url" 2>/dev/null || true)"

if [ -z "$json" ]; then
  echo "fetch failed for $repo: empty response (cookie expired/invalid, or network/SSO block)." >&2
  echo "→ re-copy the github.com Cookie header (must include user_session + __Host-user_session_same_site)." >&2
  exit 1
fi
if echo "$json" | jq -e '.error' >/dev/null 2>&1; then
  echo "fetch failed for $repo: $(echo "$json" | jq -r '.error')" >&2
  echo "→ check: cookie still valid, repo correct, Code Quality enabled on this repo (not the mirror)." >&2
  exit 1
fi

if $raw; then echo "$json"; exit 0; fi

echo "$json" | jq -r '
  .payload.repoCodeQualityAIFindingsRoute as $r
  | "repo: \($r.owner)/\($r.repo)   branch: \($r.defaultBranch)",
    "findings: \([$r.fileFindings[].findings[]] | length) across \($r.fileFindings | length) file(s)",
    "",
    ( $r.fileFindings[] as $f
      | $f.findings[]
      | "• \($f.filePath):\(.startLine)-\(.endLine)\n  \(.message)\n" )'
