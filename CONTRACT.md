# fcoding — shared contract (server <-> UI). Architect-owned; workers do not edit.

Goal: a mobile web app (PWA, iOS 16.7 Safari, iPhone X) to chat with coding harnesses (omp, claude, codex, shell) running in tmux sessions on instabox box `coder`, reached through a PUBLIC instabox URL (`instabox port publish coder 7681`). Vietnamese typing must be exact: text is typed in a native <textarea>, sent as UTF-8, and pasted into tmux as one block.

Files (one owner each):
- server.mjs — Node 22, built-ins only (no npm deps). Owner: sonnet-executor.
- public/index.html (+ inline CSS/JS), public/manifest.webmanifest, public/icon.svg — Owner: frontend-implementor.
- test/server.test.mjs — Owner: sonnet-executor.
- install.sh (box install + systemd --user unit) — Owner: sonnet-executor.

Runtime on the box: /data/home/fcoding/server.mjs. Config dir /data/home/.fcoding/ (mode 700): config.json (mode 600) holds { passwordHash (scrypt, salt, N/r/p), cookieSecret, projects: {name: absDir}, port: 7681 }. `node server.mjs --set-password` reads a password from stdin (or generates a random 24-char one and prints it ONCE) and writes the hash. Listen 0.0.0.0:7681 (only reachable through the instabox proxy).

Security invariants (must hold; Astra High reviews them):
S1 Every route except GET /, /index.html, /manifest.webmanifest, /icon.svg, POST /api/login requires a valid session cookie.
S2 Login: scrypt verify, constant-time compare; rate limit 5 failures / 15 min per client IP (X-Forwarded-For first hop if present, else socket) AND a global limit of 30 failures / hour, both answering 429 with Retry-After; no user enumeration (single password).
S3 Session cookie `pc_sid`: 32 random bytes, HttpOnly, Secure, SameSite=Strict, Path=/, Max-Age 30 days; server stores only sha256(sid); logout and "log out everywhere" (POST /api/logout?all=1) revoke.
S4 CSRF: every POST requires header `X-PC: 1` and, when an Origin header is present, it must equal the request's own origin (Host + https); reject otherwise (403).
S5 Commands only through child_process.execFile('tmux', [...args]) — never a shell. Session names must match ^[a-z0-9][a-z0-9-]{0,31}$. Key names only from the KEYS whitelist below. Projects and harnesses only from config / HARNESSES.
S6 Body size limit 64 KB; text field max 32 KB; JSON only.
S7 Security headers on every response: Content-Security-Policy "default-src 'self'; script-src 'self' 'unsafe-inline'; style-src 'self' 'unsafe-inline'; img-src 'self' data:; connect-src 'self'; frame-ancestors 'none'", X-Content-Type-Options nosniff, Referrer-Policy no-referrer, Cache-Control no-store on /api/*.
S8 Never log passwords, cookies or sent text; log only method, path, status, ms.

HARNESSES (command run inside the tmux session, cwd = project dir): omp -> `omp`, claude -> `claude`, codex -> `codex`, shell -> `bash -l`. tmux sessions get env LANG=C.UTF-8 LC_ALL=C.UTF-8.
KEYS whitelist (tmux send-keys names): Enter, Escape, Tab, BTab, Up, Down, Left, Right, PageUp, PageDown, Home, End, BSpace, C-c, C-d, C-l, C-r, C-u, C-z, y, n, Space.

API (JSON; errors as {error:"code"} with HTTP status):
- POST /api/login {password} -> 200 {ok:true} + Set-Cookie | 401 {error:"bad_password"} | 429 {error:"rate_limited", retryAfter:s}
- POST /api/logout[?all=1] -> 200 {ok:true}
- GET  /api/me -> 200 {ok:true} | 401
- GET  /api/meta -> {projects:[name...], harnesses:[...], keys:[...]}
- GET  /api/sessions -> {sessions:[{name, project|null, harness|null, created, attached:boolean, activity}]}
- POST /api/sessions {name, project, harness} -> 201 {name} | 409 {error:"exists"} | 400 {error:"invalid"}
- DELETE /api/sessions/:name -> 200 (kill-session) (needs X-PC header too)
- GET  /api/screen/:name?lines=N (N 50..2000, default 300) -> {text, rows, cols, cursor:{x,y}, hash} ; text = `tmux capture-pane -p -J -S -N` (plain text, no ANSI), trailing blank lines trimmed
- GET  /api/stream/:name -> text/event-stream; event "screen" with the same JSON whenever hash changes (poll tmux every 700 ms), comment ping every 15 s; ends on logout/session gone (event "gone")
- POST /api/send/:name {text, enter:boolean} -> 200; multi-line or long text uses `tmux load-buffer -b pc -` (stdin) + `tmux paste-buffer -p -d -b pc -t name` (bracketed paste); single line uses `send-keys -l -t name -- text`; then `send-keys Enter` if enter
- POST /api/key/:name {key, repeat?:1..20} -> 200 | 400 {error:"bad_key"}
- POST /api/resize/:name {cols, rows} (cols 20..300, rows 10..200) -> resize-window
Static: GET / serves public/index.html; manifest + icon.

UI requirements (frontend): Vietnamese labels; login screen; session list (create: name, project, harness; delete with confirm UI, not window.confirm); session view: monospace screen (auto-scroll unless user scrolled up; font-size A-/A+ saved in localStorage), SSE with reconnect + fallback polling, connection dot; bottom composer: <textarea> (Enter inserts newline; a big Gửi button sends with enter:true; a secondary "Gửi không Enter"), quick-key bar (Esc, Ctrl+C, ↑, ↓, ←, →, Tab, ⇧Tab, Enter, y, n, /) plus a "/lệnh" menu with common slash commands; send resize on load/orientation change computed from font metrics; iOS: apple-mobile-web-app-capable, viewport-fit=cover, safe-area insets, no zoom on focus (font-size >= 16px in textarea), works without any CDN; dark theme by default. Every fetch sends X-PC: 1 and credentials same-origin.

## Amendment A1 (2026-10-25): native iOS client replaces the web UI
- The client is a native SwiftUI app (folder ios/), not a web page. public/ is dropped: GET / returns a small plain-text "fcoding ok" (no auth needed); no static files, no manifest, no icon. The CSP header stays (harmless).
- Native client sends no Origin header: S4 still requires `X-PC: 1` on every POST/DELETE; Origin is checked only when present.
- Cookies: the app uses URLSession with HTTPCookieStorage (persistent). Login also returns the session id in the JSON body as {ok:true, token} ONLY when the request carries header `X-PC-Client: ios`; the server then also accepts `Authorization: Bearer <token>` as an alternative to the cookie (same sid store, same expiry, same revocation). Tokens are never logged.
- New route: POST /api/open {project, harness} -> 200 {name, created:boolean}. Session name = `<project>-<harness>` (sanitised to the name regex); if it exists, return it (created:false); else create it in the project dir with the harness command (created:true). This is the app's "quick open project" button.
- SSE (/api/stream/:name) must work for a non-browser client: send `retry: 3000`, flush each event immediately, no compression.

## Amendment A2 (2026-10-25): behind the instabox proxy, robustness
- Proxy facts (Architect probe): the instabox port proxy overwrites X-Forwarded-For with the real client IP, sends Host: 127.0.0.1:<port> and X-Forwarded-Proto: https, and normalises `//` to `/`. First-hop XFF is the client IP. Only the native app is a client; an Origin header, when present, must equal `https://` + (X-Forwarded-Host || Host), else 403 (browsers are not supported clients).
- /api/screen and SSE `cursor` are relative to the visible pane; `rows` is the visible pane height; `text` may include history above it (client maps y = lineCount - rows + cursor.y).
- Phone resize makes the window size manual; a laptop that attaches later runs `tmux resize-window -A` (documented in README).
- Fail closed: if sessions.json cannot be written, the server stops accepting any session (all protected routes 401) until a write succeeds; logout returns 500 in that case.
- Password change (`--set-password`) rotates cookieSecret; a running server notices the config change (mtime check before auth) and reloads the hash and secret, dropping all sessions immediately — no restart needed.
- Limits: at most 50 SSE streams (reserved before any await), at most 20 queued sends (503 {error:"busy"}), at most 8 concurrent tmux child processes; queued work for a closed request is cancelled.

## Amendment A3 (2026-10-25): simpler design after two failed rounds (supersedes conflicting parts of A2)
- Sessions live in MEMORY ONLY. There is no sessions.json. Any server restart logs out every device (the app shows login again). Revocation is therefore always durable. config.json is the only file; it holds passwordHash, cookieSecret, projects, port.
- Config: parse + validate a complete candidate before use; at startup an invalid/missing config refuses to start (exit 1); on reload failure keep the previous snapshot and retry on the next stamp change. --set-password writes hash + a rotated secret atomically (tmp, fsync, rename, dir fsync); a running server sees the new stamp, swaps config and drops all in-memory sessions. Strip only the trailing line ending from the stdin password.
- One execution gate for every tmux child: run(ctx, argv[, stdin]). ctx = {req, sid, gen}. After acquiring capacity and with no await before execFile, it re-checks: client not disconnected, session still valid and not expired, config generation unchanged; else it rejects without spawning. Every route passes ctx; there is no tmux call without ctx.
- Capacity: 8 child slots, 1 reserved for the active mutation. Reads (screen, SSE capture, sessions list, meta) take a free slot immediately or get 503 busy; reads never queue.
- Mutations (open, create, delete, send, key, resize) are whole jobs in ONE FIFO of at most 20 waiting jobs (overflow 503 busy), one active at a time. A multi-step job (paste then Enter; create then metadata; /api/open check-then-create) runs entirely inside its job, and every step goes through run(ctx). Disconnected jobs are removed promptly. Body is read (bounded) and auth re-checked after the body completes, before the job is queued. Auth/login/logout are not queued.
- SSE: auth check inside the guarded tick; no polling while paused; `last` advances only when the event is handed to write(); timers and the slot are released exactly once. `event: gone` carries data {"reason":"session"} or {"reason":"auth"}.
- Harness launch: the command runs as `env PATH=<HOME>/.local/bin:<HOME>/.bun/bin:/usr/local/bin:/usr/bin:/bin <harness>` (no reliance on the tmux server's or the unit's PATH). If the session is gone right after new-session, /api/open and POST /api/sessions return 500 {"error":"harness_exited"}. NOT_FOUND also matches "no such session".
- Screen trim: linear backward scan; removes only trailing blank lines.
- iOS: logout shows failure and offers retry; "Đăng xuất trên máy này" clears only local credentials, "Đăng xuất mọi nơi" clears locally only after the server confirms. On SSE gone with reason auth (or a 401 from /api/me) go to login; with reason session show "Phiên đã đóng".
