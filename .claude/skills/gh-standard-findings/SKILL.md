---
name: gh-standard-findings
description: Read and address GitHub Code Quality "standard" (CodeQL-style, rule-based) findings for a repository — the maintainability + reliability dashboard grouped by rule (via a browser session cookie) — then fix on a branch/PR. For the AI-suggestion findings use gh-ai-findings; for both at once use gh-code-quality.
allowed-tools: Bash, Read, Grep, Glob, Edit, MultiEdit, Write
---

# GitHub Code Quality — standard (rule-based) findings

The **CodeQL-style** findings at `https://github.com/<owner>/<repo>/security/quality` — maintainability +
reliability, grouped **by rule** (`cs/loss-of-precision`, `cs/path-combine`, …). NOT the AI suggestions
(those are `gh-ai-findings`). Same web-route + session-cookie mechanism; **no PAT/`gh` API**
(`gh api repos/<owner>/<repo>/code-scanning/alerts` → 403 unless GitHub Advanced Security is enabled).

Prereq: `GH_WEB_COOKIE` = the full `github.com` Cookie header (`user_session` +
`__Host-user_session_same_site`). **Security:** full account access — env-only, never commit, rotate
(log out) when done; expires ~2 wks. The script defaults to the current repo (`gh repo view`); pass
`<owner>/<repo>` to target another.

## Fetch

```bash
# rule summary (default): index grades + every rule, severity-sorted (error>warning>note).
GH_WEB_COOKIE='<cookie>' bash .claude/skills/gh-standard-findings/fetch-quality-findings.sh
#   each line: `severity xOpenCount category ruleId — title`. Rules are DYNAMIC (fetched live from /rules).

# drill into one rule → its open findings (file:line + message), auto-paginated:
GH_WEB_COOKIE='<cookie>' bash .claude/skills/gh-standard-findings/fetch-quality-findings.sh <owner>/<repo> --rule <ruleId>

# raw JSON (rules array, or ruleFindings with --rule) to drive fixes:
GH_WEB_COOKIE='<cookie>' bash .claude/skills/gh-standard-findings/fetch-quality-findings.sh --rule <ruleId> --json
```

Endpoints (all under `/security/quality`, `Accept: application/json`, paginate with `?after=<nextCursor>`):
`/rules` → `{count, rules[], nextCursor}` (rule = `{ruleId, title, severity, category, openCount, ...}`);
`/rules/<url-enc-ruleId>/findings` → `{openCount, ruleFindings[], nextCursor}`
(finding = `{filePath, startLine, endLine, message, findingState, codeSnippetLines}`).

## Workflow

1. Fetch the summary; **triage by severity**. Fix **error** rules first (real correctness bugs, e.g.
   loss-of-precision / overflow), then warnings.
2. High-count `note` rules are mostly style (path-combine, catch-all, LINQ nits). Do NOT churn the whole
   tree for them — batch a coherent subset, or dismiss on the dashboard, and only touch code where the change
   is a genuine improvement. Note what you skipped.
3. **Work on a feature branch — never commit straight to `main`.** Smallest change that satisfies intent.
4. Build + run the narrowest affected tests for the repo's stack.
5. Commit, push, open a PR (`gh pr create --base main`). These are dashboard findings (no PR threads) — they
   clear on the next scan after the fix lands on `main`.

## Limits / honesty

- No API — cookie-only, brittle (auth/expiry/undocumented JSON). Verify each fix with build/tests before
  claiming it. Some rule hits are false positives / intentional (e.g. a deliberate `catch`-all, P/Invoke) —
  dismiss with a reason rather than contort the code.
