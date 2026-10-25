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
KEYS whitelist (tmux send-keys names): Enter, Escape, Tab, BTab, Up, Down, Left, Right, PageUp, PageDown, Home, End, BSpace, C-c, C-d, C-l, C-o, C-r, C-u, C-z, M-a, y, n, Space. (M-a = Alt+A opens the omp agent hub; C-o expands tool output (e.g. in an agent opened from the hub).)

API (JSON; errors as {error:"code"} with HTTP status):
- POST /api/login {password} -> 200 {ok:true} + Set-Cookie | 401 {error:"bad_password"} | 429 {error:"rate_limited", retryAfter:s}
- POST /api/logout[?all=1] -> 200 {ok:true}
- GET  /api/me -> 200 {ok:true} | 401
- GET  /api/meta -> {projects:[name...], harnesses:[...], keys:[...]}
- GET  /api/sessions -> {sessions:[{name, project|null, harness|null, created, attached:boolean, activity}]}
- POST /api/sessions {name, project, harness} -> 201 {name} | 409 {error:"exists"} | 400 {error:"invalid"}
- DELETE /api/sessions/:name -> 200 (kill-session) (needs X-PC header too)
- GET  /api/screen/:name?lines=N (N 50..2000, default 300) -> {text, rows, cols, cursor:{x,y}, hash} ; text = `tmux capture-pane -p -J -S -N` (plain text, no ANSI), trailing blank lines trimmed. Optional `?ansi=1` keeps SGR colours in `text` (see A6); also on /api/stream
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

## Amendment A4 (2026-10-25, user decision): device pairing replaces the password

- No password. Remove POST /api/login, passwordHash in the config, --set-password, scrypt and the login rate limiter. config.json keeps cookieSecret, projects and port.
- Only someone with a shell on the box can start a pairing.
  - The command is `node server.mjs --pair [device-name]`. install.sh also installs the wrapper `~/.local/bin/fcode-pair`, which runs it.
  - The CLI talks to the RUNNING server over the unix socket <configDir>/admin.sock. The socket has mode 600 and is usable by its owner only. The server creates it at start and removes a stale one.
  - The server creates a pending pairing code for the shell issuer. Its 6-digit code comes from crypto.randomInt. The code is valid for 120 s and allows at most 5 wrong attempts. The pending codes are per issuer (changed by A7: up to 3 in all); a new --pair replaces the shell's own code.
  - The CLI prints the code and the expiry time, then exits.
  - If the server is not running, the CLI says so and exits 1.
- POST /api/pair {code, name} requires X-PC: 1 and no other auth.
  - Success: 200 {ok:true, token} and Set-Cookie pc_sid, with the same flags as before.
  - Wrong or expired code: 401 {error:"bad_code"}. Five wrong attempts invalidate the pending code.
  - Global limit on /api/pair: 10 per minute and 30 per hour. Over the limit: 429 with Retry-After.
  - Codes are compared in constant time.
- Devices are stored in <configDir>/devices.json, mode 600.
  - Only the server writes the file, using the atomic write: tmp file, fsync, rename, directory fsync.
  - Format: {devices:[{id, name, keyHash: HMAC-SHA256(cookieSecret, token), createdAt}]}.
  - The token is returned once. It is never stored or logged.
  - A pairing succeeds only after the durable write succeeds. Otherwise: 500 {error:"storage"} and no token.
  - Devices survive server restarts. They do not expire; a device stays until it is revoked.
- Revocation:
  - `node server.mjs --devices` lists id, name and createdAt.
  - `--revoke <id>` and `--revoke all` go through admin.sock. The server writes devices.json first, then removes the device from memory and bumps gen for that device. In-flight jobs for that device stop at the gate.
  - If the write fails, the CLI prints the error and exits 1, and nothing changes.
  - POST /api/logout removes the calling device the same way. On failure: 500 storage.
  - POST /api/logout?all=1 removes all devices.
- Startup: if devices.json is missing, the device list is empty. If it is present but invalid, the server refuses to start: exit 1, with no secrets in the message.
- The run(ctx) gate checks that the device id still exists and gen is unchanged. This replaces the memory-session check.
- Rotating cookieSecret (a manual config edit) invalidates every device, because keyHash no longer matches. The server then rewrites devices.json as an empty list.
- Client (iOS): the token is stored in the Keychain. When the app is signed by Sideloadly, it has a normal keychain.

### A4 update r1 (2026-10-25, review round 1)
- Commit point = the rename of devices.json. After it succeeds, the change is committed: memory follows, a directory-fsync error is only logged (pair returns the token, revoke/logout succeed). A failure before or at the rename changes nothing (storage error).
- devices.json has `secretTag` = HMAC-SHA256(cookieSecret, "fcoding-devices") hex. At startup and on every config reload, a tag that does not match the current secret clears the devices from memory first, then rewrites devices.json empty with the new tag. If that rewrite fails, `purgePending` is set: the purge is retried before any other devices.json write, on every admin request and on each config refresh; meanwhile no device authenticates and pairing answers 500 storage. No tag + empty list = valid (first run); no tag + devices = mismatch.
- /api/pair counts against 10/min and 30/h before the body is read (oversized, slow and invalid bodies count too).
- parseDevices checks exact types (strings for id, name, keyHash, secretTag; number for createdAt) before any pattern check.
- admin.sock handles only the first line of a connection; admin() calls refreshConfig() first.
- The CLI prints the remaining time: "Mã ghép: 482913 (hết hạn sau 120 giây)".
- Device names lose C0, DEL, C1 (U+0080–U+009F) and bidi controls (U+200E/U+200F, U+202A–U+202E, U+2066–U+2069).
- install.sh quotes the paths in the fcode-pair wrapper and removes an obsolete passwordHash from config.json atomically (tmp, fsync, rename, mode 600; other fields kept).
- Accepted: anyone on the internet can use up the global 30/h pairing limit; the owner then waits up to 1 h.

### A4 update r3 (2026-10-25, review round 3: single instance; replaces every admin.sock probe)
- Instance lock first: before it loads config, devices or anything else, the server binds a Linux abstract-namespace unix socket used only as a lock, named NUL + "fcoding-lock-" + sha256(realpath(configDir)) hex, first 32 characters. EADDRINUSE means another live server owns this config dir: exit 1 with "Một máy chủ FCode khác đang dùng thư mục cấu hình này", touching nothing. The kernel frees the name when the process dies, so there is no stale lock. Nobody connects to it. Windows (local tests only): a named pipe with the same derived name.
- admin.sock: only the lock holder gets there. It unlinks any existing admin.sock and binds a new one (mode 600). There is no connect probe. A path that exists and is not a socket still refuses the start.
- Accepted trade-off: an abstract socket has no permissions, so another local user on the same box could hold the name and block a start, but could not take over the server. This is accepted because the box has a single user.

## Amendment A5 (2026-10-25, user decision): project list = attention-first inbox + harness dock
- New read endpoint GET /api/overview (auth like other reads; it goes through the read gate as ONE read job; internal tmux/git calls run sequentially inside that job, each with the existing exec timeout). Response:
  `{ now, projects: [{ name, branch, ahead, diff: {files, add, del} | null }], sessions: [{ name, project, harness, created, activity, attached, state, preview }] }`
  - `state`: "running" if session_activity is within 8 s of now; otherwise "waiting" if the last 6 non-empty lines of the visible pane match an approval/question pattern (case-insensitive: `(y/n)`, `[y/n]`, `[Y/n]`, `[y/N]`, `yes/no`, `do you want`, `allow`, `approve`, `proceed?`, `continue?`, `press enter`, a numbered choice line like `❯ 1.` or `> 1.`); otherwise "idle". The pattern list lives in one constant.
  - `preview`: the last non-empty pane line that is not prompt/box-drawing chrome, ANSI-stripped, control chars removed, trimmed, at most 160 chars (cut on a code-point boundary).
  - `branch`: `git -C <dir> rev-parse --abbrev-ref HEAD`; `diff`: from `git -C <dir> diff --shortstat HEAD` (null if not a git repo or on error); `ahead`: commits ahead of upstream or null. Git results are cached per project for 10 s.
  - Never include secrets or file contents beyond the preview line. Errors in one project/session give nulls for that item, not a failed response.
- Unread is client-side: the app stores the last `activity` it has seen per session.
- Inline answers use the existing POST /api/key and /api/send (e.g. send text "y" with enter).
- iOS: screen = inbox (header "FCode", subtitle "N phiên đang chờ bạn" when N>0, gear left, "+" right), project filter pills, sections "Cần bạn" (waiting; full preview + buttons: y/n prompts get "y · Đồng ý", "n · Từ chối", "Mở"; others "Trả lời", "Mở"), "Đang chạy" (project · branch · diff, one-line preview, thin activity bar), "Đang nghỉ" (compact, dimmed). Bottom: floating translucent harness dock (Tất cả / omp / claude / codex / shell, icon + label) filtering the list; "+" opens a sheet that skips the harness step when the dock has a harness selected. Poll /api/overview every 5 s while visible (pause in background), pull to refresh, swipe left on a row: "Đã đọc/Chưa đọc", "Xoá" (kill session with confirmation).
- A5 update (user, 2026-10-25): "Cần bạn" is always expanded. "Đang chạy" and "Đang nghỉ" are collapsed by default: one header row each (name, count, the harness badges of its sessions, chevron); tapping the row expands/collapses it with an animation. The expanded/collapsed state is remembered per section (UserDefaults). An empty section is hidden.
- A5 update 2 (user, 2026-10-25): the project filter row uses Cây A's chip rail instead of Cây B's pills: horizontal scrolling capsules "Tất cả", then each project; a chip shows an orange badge with the number of sessions waiting for the user, or a grey session count when none wait; the selected chip is white with dark text.
- A5 update 3 (user, 2026-10-25): harness colours — claude orange (#D97757), omp purple (#A78BFA), codex blue (#5AC8FA-like, as in the preview), shell grey. The codex glyph matches the official Codex mark (drawn as a vector, not a downloaded image).
- A5 update 4 (user, 2026-10-25): "+" always STARTS A NEW SESSION (it never reopens an old one; existing sessions are opened from the list). Server: POST /api/open accepts an optional `fresh: true`. With fresh, inside ONE mutation job the server picks the first free name among `<base>`, `<base>-2`, `<base>-3`, … (base = the existing project-harness name rule; the suffix is kept within the 32-char limit by shortening base) and creates it; it never reuses an existing session. Response `{name, created:true}`. Without fresh the old behaviour stays. iOS: the "+" sheet's project rows say "Phiên mới · đang có N phiên <harness>" (or "Phiên mới" when none) and call /api/open with fresh:true, then open the new session.
- A5 update 5 (2026-10-25): in /api/overview, `now`, `created` and `activity` are Unix epoch SECONDS (integers). When `state` is "waiting", `preview` is the question line: among the last 6 non-empty lines that match the approval/question pattern (cleaned the same way, at most 160 code points), the last one that is not a numbered option (`^[❯>›]?\s*\d+\.\s` after cleaning); if only numbered options match, the last of those. Example: "Do you want to proceed?" / "❯ 1. Yes" / "2. No" gives "Do you want to proceed?". So the client can detect y/n prompts from it; otherwise the existing preview rule applies. `activity` is the later of tmux `session_activity` and `window_activity` (tmux moves only window_activity on pane output), and `state` uses it.
- A5 update 6 (2026-10-25, final integration r3, option A): each overview session has `menu: boolean`. It is true when any of the last 6 cleaned, non-empty lines of the visible pane (all of them, not only the lines that matched a prompt pattern) matches CHOICE_RE `^[❯>›]?\s*\d+\.\s`, else false; null when the item failed. The client shows the y/n buttons only when `isYesNo(preview) && menu != true`, because on a numbered menu the letter + Enter would confirm the highlighted option.

## Amendment A6 (2026-10-25, FCode v1.1: coloured screen)

Applies to `GET /api/screen/:name` and `GET /api/stream/:name` (the SSE `screen` events carry the same JSON).

1. Optional query `ansi=1`.
   - With `ansi=1` the text keeps colours: the server runs `tmux capture-pane -p -e -J -t =<name>: -S -<lines>` (`-e` added).
   - Without it, or with any other value (`ansi=0`, `ansi=true`, empty), nothing changes: the same tmux call, no escapes. Apps installed before v1.1 keep working.
2. With `ansi=1` only SGR sequences (`ESC [ <params> m`) may appear in `text`. The server removes every other escape sequence: other CSI (cursor, erase, private modes), OSC (titles, OSC 8 hyperlinks), DCS/APC/PM/SOS, two-byte `ESC x` sequences, a lone ESC, and SO/SI (0x0E, 0x0F), so the text equals a plain capture. What stays is written in one simple form that a client can parse by splitting on `;`:
   - parameters are integers separated by `;`; `ESC [ m` is sent as `ESC [ 0 m`;
   - colours are `38;5;n`, `48;5;n`, `38;2;r;g;b`, `48;2;r;g;b` (n, r, g, b in 0..255); the colon forms (`38:2::r:g:b`) are rewritten, and a cut-off one is dropped; `4:0` becomes `24`, any other `4:x` becomes `4`, `5:3` (overline) becomes `53`, any other colon group is dropped;
   - the underline colour (`58`, `59`), colours that are cut off or out of range, and codes above 107 are dropped; a sequence with nothing left is dropped.
3. Server-side text matching never sees escapes: prompt detection, the preview and the inbox/overview state work on text with escapes removed. (`/api/overview` reads the pane without `-e` and also strips any escape it meets.)
4. `hash` covers exactly the `text` that is sent (plus size and cursor, as before). With `ansi=1` a colour-only change gives a new hash, so the stream sends a new event. Trailing lines that hold only SGR and blanks count as blank and are trimmed, like trailing blank lines today.
5. tmux targets: a call that needs a pane (`capture-pane`, `display-message`, `send-keys`, `paste-buffer`, `resize-window`, `set-option`) uses `-t =<name>:`; a bare `=<name>` does not resolve a pane ("can't find pane"). Calls that need only a session (`has-session`, `kill-session`) use `-t =<name>`.

## Amendment A7 (2026-10-26, QR pairing for a new device; r2 after review)

A new device can be paired with a QR code. The QR and every link carry ONLY the server address, never a code (the `fcode://` scheme is not exclusive on iOS: another app may receive the link). The user types the 6-digit code shown on the old device or in the terminal. Nothing permanent (cookieSecret, device token) is ever in a link.
- Config: optional `publicUrl`, a bare https origin (no path, query, fragment or credentials; normalised, a trailing slash is dropped). An invalid value is a config error (startup refuses, a reload keeps the previous config). It is the ONLY source of the origin in a link: Host, X-Forwarded-Host, Forwarded and Origin are never used.
- Links: `appLink` = `fcode://pair?server=<encodeURIComponent(publicUrl)>`; `shareLink` = `<publicUrl>/pair`. No code, no name.
- `POST /api/pair-code` {name?: string}: needs a paired device and X-PC like any other /api route (the app sends `{}`). Makes a pending code issued by the calling device and answers 200 `{code, expiresAt (ISO 8601), appLink, shareLink}`. The code is the same kind as `--pair` (6 digits, TTL 120 s, single use, redeemed by POST /api/pair).
  - Errors: 400 invalid (name not a string, bad JSON), 401, 403 (no X-PC), 409 `no_public_url` (no code is made).
  - The name (control and bidi characters and lone surrogates removed, cut on a code point to at most 64 UTF-16 units) becomes the device name, like `--pair [name]`.
- `GET|HEAD /pair` (no auth): a small Vietnamese HTML page with a button "Mở FCode" (the appLink) and "Chưa cài FCode? Cài file fcode.ipa trước.". The query string is ignored and never echoed; the page has no code and reads or changes no pairing state. `Cache-Control: no-store`. 503 when `publicUrl` is not configured.
- `fcode-pair [name] [--qr]` (install.sh wrapper -> `server.mjs --pair <name> [--qr]`; `--pair --qr` with no name means no name). With `--qr` it prints, in this order: the QR of the appLink (`qrencode -t ANSIUTF8`, apt package `qrencode`), "Link chia sẻ: <shareLink>", the code in big digits ("MÃ GHÉP:   4   8   2   9   1   3") and ONE line "Mã hết hạn sau N phút." (N from the TTL). Without qrencode it prints "Link mở app: <appLink>" and "cài qrencode để hiện mã QR" instead of the QR; without `publicUrl` a hint about it. Without `--qr` the output is the old two lines. The admin request `{cmd:'pair', name, links:true}` answers `links: {appLink, shareLink} | null`.
- Pending codes (changes A4's "one pending"): each records its issuer (a device id, or `shell` for the command). One pending code per issuer: a new one replaces that issuer's own. At most 3 in all; when a 4th is made the oldest DEVICE code goes, so a device never pushes the shell code out. Each has its own expiry (120 s) and attempt count; live codes are distinct. A wrong guess (also a malformed one) is one attempt against every live code; a code with 5 is gone. /api/pair limits (10/min, 30/h) are unchanged.
- A code dies with its issuer: `pair()` refuses a code whose issuing device is gone. Revoking a device (`--revoke <id>`, POST /api/logout) clears that device's pending codes; `--revoke all`, `logout?all=1` and a cookieSecret rotation clear ALL pending codes (the shell's too).
- The admin socket never lets an exception escape: a failing request answers `{ok:false, error:"internal"}`.
- A config edit is applied before any route or admin request reads auth or pairing state, and before POST /api/pair looks up or consumes a code; a cookieSecret rotation therefore clears every pending code before the next redemption.

## Amendment A8 (2026-10-26, home screen v2: quota, spend, box timer, projects, Codex reset)

Shared with the iOS worker in `contract-home-v2.md` (the Architect's copy). Server side as built:

- `GET /api/home` (auth like every /api route; GET, else 405) -> 200 `{generatedAt, box, accounts, totals, projects, updates}`, shape as in contract-home-v2.md. Each part has its own cache: quota 60 s, spend 5 min, projects 2 min, box timer and updates live. One refresh per part at a time; concurrent requests share it. A failing part never makes a 500: no quota yet -> `accounts: []`; quota failing after a success -> the last accounts with `stale: true`; spend failing -> `spend: null` and `totals: {spend: null, byHarness: []}`; a gh call failing -> that project's `prs` / `lastRun` null; no status.json -> `updates: {}`.
- Quota: `omp usage --json` plus `omp usage reset --json` (the listing gives each account's credential id), 30 s timeout each. FCode reads no credential file (omp's `agent.db` holds credentials and is never opened). Report <-> listing match: same provider, `accountId`, `orgId` (and email when both have one). `id` = the reset target `<provider>/<credentialId>` (e.g. `anthropic/1`, `openai-codex/4`); without a listing match `id` = `<provider>/~<8 hex>` and `resets.target` null. The last good listing is reused when a listing fails. `harness`: anthropic -> claude, openai-codex -> codex; other providers are not shown. Accounts in `accountsWithoutUsage` are shown with `windows: []`, `stale: true`.
  - Windows: one per omp limit that has a number (`amount.usedFraction`, or `used` in percent, or `used/limit`); a limit omp does not report is hidden. `key` = `scope.windowId` + `_<tier>` (`5h`, `7d`, `7d_fable`); `label` "5 giờ" / "7 ngày" / "7 ngày Fable" (`<n> giờ|ngày` + capitalised tier); `usedPercent` one decimal; `resetsAt` ISO or null (a window not started yet); `periodSeconds` from `durationMs`.
  - `plan`: raw `planType` / `subscriptionType` -> label (free Free, plus Plus, pro Pro, max Max, team Team, business Business, enterprise Enterprise, edu Edu; else the raw value capitalised); null when omp gives none. omp 18.12.6 gives a plan for Codex only, so Claude accounts have `plan: null`. Never branched on.
  - `stale`: omp fetched the report more than 10 min ago, or the last refresh failed. `rateLimited`: the report or account carries an error mentioning a rate limit / 429. `resets.available` = `redeemableCount` (usable now), else `availableCount`.
- Spend: local logs, read incrementally (each file from where the last scan stopped, whole lines only; a shrunk or replaced file is re-read; files not modified in 31 days skipped; a removed file dropped). Sources: omp `~/.omp/agent/sessions/**/*.jsonl` (assistant messages carry `provider`, `credentialId`, `usage`, `usage.cost.total`; `model_usage` lines too), Claude Code `$CLAUDE_CONFIG_DIR|~/.claude/projects`, Codex `$CODEX_HOME|~/.codex/{sessions,archived_sessions}`. Tokens include cache reads and writes. Cost: the log's own (omp `usage.cost.total`, Claude `costUSD`), else the bundled price table (`PRICES` in server.mjs, LiteLLM, read 2026-10-26), else tokens only (never a guessed dollar). Dedupe: omp `responseId`, Claude `message.id` (multi-line messages and sidechain replays), Codex session id + cumulative totals (a re-emitted snapshot and an archived copy count once).
  - Attribution: omp messages -> the account `<provider>/<credentialId>`; Codex logs -> the Codex account whose omp `accountId` equals the rollout's `creator_account_id`; everything else (Claude Code logs, omp `model_usage`) counts in the totals and its harness only.
  - Days are local calendar days of the server process (`TZ`); `daily30` = the 30 days ending today, oldest first. `weeklyEstimate` (Pane): spend logged inside the account's `7d` window (`resetsAt - periodSeconds` .. now) / (`usedPercent` / 100), only from 5 % used and when something was logged in the window; at >= 100 % the spend itself; null otherwise and for totals. `usd` 4 decimals, `tokens` integers. `totals.byHarness` = last-30-days usd per harness, largest first.
- Box timer: `sleepsAt` = last resume + `maxRunMinutes` (480); the last resume is the process start or a 30 s tick (also run on each /api/home) that came more than 90 s after the previous one. Past the estimate -> `sleepsAt: null`. `idlePauseMinutes` 30, `cooldownMinutes` 10, `source: "estimate"`.
- Projects: per config project, `git remote get-url origin` -> `repo` owner/repo (https, ssh, scp-like, also an ssh host alias whose name contains "github"; the URL itself never leaves the server), `branch` = current branch; `gh -R <repo> pr list --state open --limit 20 --json number,title,mergeable,statusCheckRollup` (a token without checks access fails that query: it is retried without `statusCheckRollup`, then `checks: null`) and `gh -R <repo> run list --limit 1`. `checks`: any failed conclusion -> failure, any not completed / pending -> pending, empty -> none, else success. `mergeable`: MERGEABLE true, CONFLICTING false, else null. `lastRun.status`: not completed -> in_progress, success/neutral/skipped -> success, else failure; `workflow` = gh `workflowName`.
- Updates: `~/.local/state/fcode-update/status.json`, tools omp, claude and codex only (other keys ignored); `result` one of updated|current|failed, else null.
- `POST /api/codex-reset` `{accountId, requestId}` (X-PC and auth like every POST): `requestId` 8-64 of `[A-Za-z0-9-]`, else 400 `invalid`; unknown account 404 `not_found`; a Claude account 400 `not_allowed`; no reset target 409 `no_target`; quota unavailable 503 `unavailable`. Runs `omp usage reset <target>` (45 s timeout) and maps its one-line answer: "Reset applied" -> reset; "already redeemed" / "another omp process spent" -> already; "nothing to reset" -> nothing_to_reset; "no saved resets available" -> no_credit; anything else -> error with a specific Vietnamese message (login expired, reset in progress, listing failed, offer changed, omp not runnable, not confirmed). 200 `{result, message}`.
  - Lock: one reset per account at a time; another `requestId` for that account meanwhile -> 409 `in_progress`; the same `requestId` joins the running one. A finished `requestId` gets the same answer for 15 min without running omp again (omp mints its own redeem id; the app's id is the server-side retry key). After reset/already the quota cache is dropped.
  - Log line: `codex-reset <accountId> <result>` only.
