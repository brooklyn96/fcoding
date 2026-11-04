## Báo chủ qua Zalo (fcode-notify, user rule 2026-11-05)
Main session only; sub-agents never call it. One-way notice to the owner; Hermes takes no action on it.
- Call `fcode-notify <project> <kind> "<short text>" [link]` at exactly these moments:
  - `merge-ready`: a PR is open and waits for the owner (no CI, a release window, or a rule that needs the owner); link = the PR URL.
  - `needs-yes`: you asked the owner a Yes/No (or any question) and cannot continue without the answer.
  - `stuck`: blocked for more than 10 minutes with no way forward (a sub-agent or Astra out of quota, your own 5-hour limit about to be reached, auth or access missing, the same error twice after research). A session already cut off by its own quota cannot call it.
  - `info`: only when the owner asked to be told when something finishes.
- Text: one plain line in Vietnamese, under 200 characters, saying what you need. Never a token, key, password, .env content, log or command.
- At most one call per moment; `notify: duplicate` or `error: rate-limited` means stop, do not retry.

(The block above is copied by hand into `~/.omp/agent/AGENTS.md`, like `box/agents-git.md`; this file is its single source.)
