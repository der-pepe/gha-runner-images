---
name: gh-code-quality
description: Check BOTH GitHub Code Quality dashboards for a repository in one pass — the AI-suggestion findings and the CodeQL-style standard rule findings — and give a combined, prioritized picture. Use gh-ai-findings or gh-standard-findings to focus on just one.
allowed-tools: Bash, Read, Grep, Glob, Edit, MultiEdit, Write
---

# GitHub Code Quality — full sweep (both dashboards)

GitHub Code Quality exposes **two** dashboards under `/security/quality`:
- **AI findings** (AI suggestions) → skill `gh-ai-findings` + `fetch-ai-findings.sh`.
- **Standard findings** (CodeQL-style rules, maintainability + reliability) → skill `gh-standard-findings`
  + `fetch-quality-findings.sh`.

Both are web routes served as JSON, authed by the **`GH_WEB_COOKIE`** session cookie (not a PAT). Set it
once (full `github.com` Cookie header with `user_session` + `__Host-user_session_same_site`; env-only,
never commit, rotate when done). The scripts default to the current repo (`gh repo view`); pass
`<owner>/<repo>` to target another.

## Scan both

```bash
repo=""   # empty = current repo; or set to <owner>/<repo>

echo "===== AI findings ====="
bash .claude/skills/gh-ai-findings/fetch-ai-findings.sh $repo

echo "===== Standard (rule-based) findings ====="
bash .claude/skills/gh-standard-findings/fetch-quality-findings.sh $repo
```

Then, for the standard side, drill into the high-severity rules:
```bash
bash .claude/skills/gh-standard-findings/fetch-quality-findings.sh $repo --rule <error-or-warning-ruleId>
```

## Combined triage + workflow

Present one consolidated list, ordered by impact:
1. **AI findings** — usually few, specific, often genuine bugs → fix first.
2. **Standard `error` rules** — real correctness bugs → fix next.
3. **Standard `warning` rules** → fix where cheap + correct.
4. **Standard high-count `note` rules** (style: path-combine, catch-all, LINQ nits) → don't churn the tree;
   batch a coherent subset or dismiss with a reason.

Execution (same for both sources): **feature branch, never `main`**; smallest correct change; build + run the
narrowest affected tests for the repo's stack; commit → push → PR (`gh pr create --base main`). For AI
findings surfaced as **per-PR** review comments, also reply to + resolve each thread (see `gh-ai-findings`).
Dashboard findings have no threads — they clear on the next scan.

See `gh-ai-findings` and `gh-standard-findings` for the per-dashboard details, JSON shapes, and limits
(no API; cookie brittle; verify every fix with build/tests before claiming it).
