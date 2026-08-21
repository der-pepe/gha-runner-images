---
name: gh-ai-findings
description: Read and address GitHub Code Quality "AI findings" (AI suggestions) for a repository — the repo-level AI-findings dashboard (via a browser session cookie) or the same findings as per-PR review-bot comments (via gh) — then fix on a branch/PR and reply/resolve threads. For the CodeQL-style standard rule findings use gh-standard-findings; for both at once use gh-code-quality.
allowed-tools: Bash, Read, Grep, Glob, Edit, MultiEdit, Write
---

# GitHub Code Quality — AI findings

The **AI-suggestion** findings (not the CodeQL-style rule findings — those are `gh-standard-findings`).
Two sources of the same findings:

1. **Repo-level dashboard** — `https://github.com/<owner>/<repo>/security/quality/ai-findings`.
   No public API; readable only as JSON via a **browser session cookie** (not a PAT).
2. **Per-PR review comments** — `github-code-quality[bot]` + `chatgpt-codex-connector[bot]` post the
   same findings as PR review comments; fully readable via `gh api`, no cookie.

The fetch script defaults to the current repo (`gh repo view`); pass `<owner>/<repo>` to target another.

## A. Repo-level dashboard (cookie)

Prereq: `GH_WEB_COOKIE` env var = the full `github.com` Cookie header (must include `user_session` +
`__Host-user_session_same_site`). See `fetch-ai-findings.sh` header for how to copy it from DevTools.
**Security:** that cookie = full account access — env-only, never commit, rotate (log out) when done;
it expires (~2 wks) and the JSON shape is undocumented.

```bash
# Invoke via `bash` so it works even if the exec bit didn't survive checkout (e.g. Windows).
GH_WEB_COOKIE='<cookie>' bash .claude/skills/gh-ai-findings/fetch-ai-findings.sh                   # current repo, summary
GH_WEB_COOKIE='<cookie>' bash .claude/skills/gh-ai-findings/fetch-ai-findings.sh <owner>/<repo> --json  # raw (fix-diffs)
```

JSON shape: `payload.repoCodeQualityAIFindingsRoute.fileFindings[]` → `{ filePath, commitOid,
findings: [ { message, startLine, endLine, fixFiles: [ { filePath, diffEntries } ] } ] }`.
Note: findings only appear on the repo where Code Quality is enabled — not on a fork/mirror.

## B. Per-PR review-bot findings (gh, no cookie)

```bash
# list findings on a PR, grouped by file (skip our own replies)
gh api "repos/<owner>/<repo>/pulls/<N>/comments?per_page=100" \
  --jq '.[] | select(.in_reply_to_id==null and (.user.login|test("code-quality|codex";"i")))
        | {id, path, line, user:.user.login, body}'
```

After fixing, reply + resolve each thread:
```bash
gh api "repos/<owner>/<repo>/pulls/<N>/comments/<commentId>/replies" -f body="Fixed in <sha>. <what>"
# resolve via GraphQL reviewThreads → resolveReviewThread(threadId)
gh api graphql -f query='{repository(owner:"<o>",name:"<r>"){pullRequest(number:<N>){
  reviewThreads(first:50){nodes{id isResolved comments(first:1){nodes{databaseId}}}}}}}'
gh api graphql -f query='mutation{resolveReviewThread(input:{threadId:"<id>"}){thread{isResolved}}}'
```

## Workflow

1. Fetch findings (A for the dashboard, B for a PR).
2. **Work on a feature branch — never commit straight to `main`.**
3. Apply each fix; prefer the smallest change that satisfies the intent. Some findings are judgment calls
   (reject with a reason when wrong — the AI suggestions are occasionally hallucinated). Don't backdate
   placeholder dates to today; use the real `git blame` date.
4. Build + run the narrowest affected tests for the repo's stack.
5. Commit, push the branch, open a PR (`gh pr create --base main`).
6. For the PR variant: reply to + resolve each thread. (Dashboard findings have no threads; they clear on rescan.)

## Limits / honesty

- The dashboard has **no API** — only the cookie path works, and it's brittle (auth, expiry, undocumented
  JSON). If the cookie is unavailable, fall back to opening a PR (path B).
- Verify outcomes: only claim a finding fixed after the build/tests pass.
- A PAT cannot replace the cookie — github.com web routes reject PATs, and there is no Code Quality API
  for any token/App/OAuth scope. The `user_session` cookie only comes from the login flow.
