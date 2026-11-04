## Tự động cập nhật omp, claude, codex

Một timer chạy dưới quyền người dùng (systemd user unit, cần `loginctl enable-linger`) cập nhật 3 công cụ (omp, claude, codex) mỗi 6 giờ. Việc cập nhật **không bao giờ sửa file đang chạy**, nên phiên đang mở không bị hỏng và không cần kiểm tra "công cụ có đang chạy không".

Cài (chạy lại nhiều lần cũng an toàn):

```bash
bash box/install-autoupdate.sh
```

Script cài `~/.local/bin/fcode-update`, hai unit `fcode-update.service` / `fcode-update.timer` trong `~/.config/systemd/user`, tạo thư mục `/opt/fcode-tools` (chủ là người dùng), rồi bật timer. Ngay khi timer được bật, mốc `OnStartupSec=5min` đã qua nên systemd chạy ngay một lượt; chạy lại script cài không kích hoạt thêm lượt nào, vì timer đã có mốc chạy trước.

Lịch chạy: 00:00, 06:00, 12:00, 18:00 giờ UTC (box dùng UTC; tức 07:00, 13:00, 19:00, 01:00 giờ Việt Nam), cộng 5 phút sau khi box khởi động, trễ ngẫu nhiên tới 5 phút. Box tạm dừng sau 30 phút rảnh nên timer chỉ chạy khi box đang thức; lượt bị lỡ được bù ở lần thức sau.

### Cách bố trí (claude, codex)

```
/opt/fcode-tools/<công_cụ>/<phiên_bản>/      mỗi phiên bản là một prefix npm riêng (bin/, lib/node_modules/)
/opt/fcode-tools/<công_cụ>/current           symlink tới một phiên bản
/usr/local/bin/<tên_lệnh>                    symlink tới /opt/fcode-tools/<công_cụ>/current/bin/<tên_lệnh>
```

Mọi tên lệnh trong `bin` của gói đều được trỏ (`claude`, `codex`). Mỗi lượt, với từng công cụ:

1. so phiên bản đang chạy (`current`) với bản mới nhất (`npm view <gói> version`); phiên bản phải đúng dạng semver `X.Y.Z[-tiền_tố]`, nếu không thì bỏ qua và ghi `failed`; không bao giờ hạ cấp;
2. khác nhau thì `npm install -g --prefix /opt/fcode-tools/<công_cụ>/<bản> <gói>@<bản>` (không cần sudo, vì thư mục thuộc người dùng) và chạy thử `<lệnh> --version` ngay trong thư mục đó; sai thì xoá thư mục tạm và ghi `failed`, `current` không đổi. Cài vào thư mục tạm `.new.<bản>.<pid>` rồi mới đổi tên thành `<bản>`; thư mục phiên bản đã có thì **không bao giờ bị xoá hay ghi đè** khi kiểm tra lỗi (nếu nó hỏng mà không phải `current` và không ai dùng thì được dời sang `.bad.*`). Mỗi lần cài dùng một cache npm tạm, xoá ngay sau đó; dưới 2 GB trống thì không cài và ghi `failed`;
3. đổi `current` bằng một phép đổi tên nguyên tử (symlink tạm rồi `mv -T`), nên không có lúc nào thiếu lệnh; sau đó đảm bảo các symlink trong `/usr/local/bin` (cần sudo, chỉ cho việc này; việc này chạy ở **mọi** lượt nên một lần chuyển bị gián đoạn sẽ được hoàn tất);
4. dọn: giữ bản hiện tại, 2 bản được bật gần nhất, và mọi bản mà một tiến trình đang chạy có thể đang dùng. Nhật ký `/opt/fcode-tools/<công_cụ>/activations` ghi (bản, boot_id, uptime) mỗi lần đổi `current`; một tiến trình bắt đầu lúc T chỉ có thể dùng bản đang là `current` tại T (cộng bản ngay trước đó, đề phòng lệch vài giây quanh lúc đổi), hoặc bản có bằng chứng trực tiếp (exe, thư mục làm việc, file đang mở, vùng nhớ ánh xạ, đường dẫn trên dòng lệnh). Khi exe hoặc các file ánh xạ của tiến trình cho biết nó đã nạp bản nào thì bằng chứng đó thắng, không ghim thêm theo giờ khởi động. Giới hạn: giờ khởi động là lúc fork pid, nên công cụ chỉ chạy bằng node mà được `exec` từ một shell đã mở nhiều ngày sẽ được ghim theo bản đang là `current` lúc shell đó khởi động; với claude và codex vẫn an toàn vì file chạy chính nằm trong thư mục bản và được nhận ra qua bằng chứng. Các bản còn lại bị xoá, nên dung lượng luôn có giới hạn dù có phiên sống lâu. Thư mục dở dang (không có trong nhật ký, cũ hơn 1 giờ) cũng bị xoá. Nghi ngờ thì giữ.

Tiến trình đang chạy giữ nguyên thư mục phiên bản nó khởi động từ, nên phiên cũ chạy tiếp bình thường; phiên mới dùng bản mới.

**Lần chạy đầu tiên** chuyển bản cài toàn cục cũ (`/usr/local/lib/node_modules`) sang bố cục trên: cài đúng phiên bản đang có vào `/opt/fcode-tools/<công_cụ>/<bản>`, kiểm tra, đổi `current`, trỏ lệnh. Bản cũ trong `/usr/local/lib/node_modules` bị xoá khi không còn gì dùng nó; nếu còn phiên cũ đang chạy thì để lại và thử xoá ở lượt sau.

**Bảo mật:** `/opt/fcode-tools` thuộc người dùng quoc. Trên box này quoc đã có sudo không mật khẩu nên không mất gì; nếu box có thêm người dùng khác hoặc quoc mất sudo thì nên cài vào thư mục tạm, `sudo chown -R root:root` rồi chuyển vào thư mục thuộc root.

### omp

`omp update` tự thay file bằng cách đổi tên nguyên tử (file mới có inode mới, file cũ được đổi tên rồi xoá), nên phiên omp đang chạy vẫn chạy bình thường (đã kiểm tra trên bản sao). omp không cần bố cục trên.

### Kết quả

- `~/.local/state/fcode-update/log`: một dòng cho mỗi công cụ mỗi lượt (kèm dòng ghi chú khi chuyển hoặc dọn), giữ khoảng 500 dòng cuối;
- `~/.local/state/fcode-update/status.json`: `{công_cụ: {from, to, at, result, error}}`, `result` là `updated`, `current` hoặc `failed` (`skipped_busy` không còn dùng), ghi nguyên tử để app đọc.

Chạy tay: `systemctl --user start fcode-update.service` hoặc `fcode-update [công_cụ ...]`. Mọi lệnh đều có timeout; chỉ một lượt chạy tại một thời điểm (`flock`).

Từ server qua HTTPS: `POST /api/tools/update` (thân rỗng hoặc `{}`) chạy đúng `systemctl --user start --no-block fcode-update.service` (202 `{"started":true}`; 409 `{"error":"running"}` nếu đang chạy; 500 `{"error":"start failed"}`), `GET /api/tools/update` trả `{running, versions:{omp,claude,codex}, last_run, last_ok}` đọc từ `status.json`. Lệnh cố định, không nhận tham số nào từ yêu cầu.

### Quay lại bản cũ (rollback)

```bash
ls /opt/fcode-tools/claude                       # các bản còn giữ
fcode-update --rollback claude 2.1.288        # quay lại bản đó
fcode-update --resume claude                  # cho phép cập nhật tiếp
```

`--rollback` kiểm tra bản đó chạy được, đổi `current` nguyên tử, ghi vào nhật ký `activations` (để dọn dẹp biết phiên mới thuộc bản nào), đảm bảo các symlink và đặt file `hold` để lượt chạy sau không nâng cấp lại. Phiên đang chạy không bị ảnh hưởng. `--resume` xoá `hold`; lượt sau sẽ nâng lên bản mới nhất.

### Tắt trình tự cập nhật riêng của từng công cụ

Để chỉ có timer này thay file, `install-autoupdate.sh` tắt trình tự cập nhật riêng của claude bằng cấu hình của chính công cụ:

| Công cụ | Cách tắt |
|---|---|
| claude | `DISABLE_AUTOUPDATER=1` trong `/etc/claude-code/managed-settings.json` (box instabox đã có sẵn); nếu thiếu, script thêm `env.DISABLE_AUTOUPDATER` vào `~/.claude/settings.json` |
| omp | không cần: tự cập nhật chỉ khi gọi `omp update` |

### Cài cùng `install.sh`

`install.sh` tự chạy `box/install-autoupdate.sh` sau khi cài `fcode-pair` (nếu có thư mục `box/` cạnh nó). Nếu bước này lỗi (ví dụ thiếu sudo không mật khẩu) thì chỉ cảnh báo, việc cài fcoding vẫn tiếp tục.

## Theo dõi độ lệch git so với GitHub

Một timer thứ hai (`fcode-git-sync.timer`, cài cùng `install-autoupdate.sh`) chạy mỗi 5 phút và 1 phút sau khi box khởi động. Script `~/.local/bin/fcode-git-sync` chỉ xem, trừ một việc duy nhất: **kéo nhanh (fast-forward) nhánh mặc định khi project đang rảnh và sạch** (bước 3, chỉ ở lượt chạy của timer; lượt `fcode-git-sync <tên project>` chỉ xem, không bao giờ kéo). Nó không bao giờ tạo commit, checkout, reset, stash, rebase, xoá hay push; mọi nhánh và tag khác giữ nguyên. Với từng project trong `~/.fcoding/config.json` (`projects`; tên hoặc đường dẫn có ký tự điều khiển bị bỏ qua):

1. `git fetch` về `refs/remotes/origin/*` (timeout 60 giây, không hỏi gì; dùng khoá deploy riêng của repo). Lệnh fetch ghi rõ URL và refspec, nên refspec / prune / tagopt cấu hình sẵn trong repo không làm nó đụng vào nhánh hay tag cục bộ. URL là URL **đầu tiên** của `origin` (như `git fetch origin`), và không ghi `.git/FETCH_HEAD`;
2. đếm, chỉ đọc: `behindDefault` = số commit trên `origin/<nhánh mặc định>` (theo `origin/HEAD`, mặc định `main`) mà HEAD chưa có; `aheadOfOrigin` = số commit của HEAD không nằm trên nhánh `origin/*` nào (tức là chỉ có trên box; `null` nếu không tính được); `dirty` = có thay đổi chưa commit (kể cả file chưa theo dõi);
3. tự kéo code mới (chỉ lượt chạy của timer): `git merge --ff-only --no-overwrite-ignore origin/<nhánh mặc định>` (không hook, không fsmonitor, không submodule, không stash, không gc tự động), **chỉ khi tất cả đều đúng**: `behindDefault` > 0 và `aheadOfOrigin` = 0; HEAD đang ở đúng nhánh mặc định; không có thay đổi nào của file đã theo dõi (file chưa theo dõi không tính); không có merge / rebase / cherry-pick / revert / bisect đang dở và không có `index.lock`; không có khoá cấu hình `filter.*` nào (bất kỳ `filter.<tên>.…`: smudge, process, clean, required...) ở **bất kỳ** phạm vi nào (repo, toàn cục, hệ thống), vì checkout có thể chạy mã ngoài và chậm, hoặc chết giữa chừng khi driver `required` lỗi (Git LFS...); script không đọc thuộc tính (`.gitattributes`) nào. **Hệ quả đã chấp nhận:** chạy `git lfs install` toàn cục trên box sẽ tắt việc tự kéo cho mọi project (`autoSkip` = `filters`, kể cả repo không dùng LFS); vẫn an toàn vì agent luôn sync đầu task; lượt chạy chưa quá 10 phút (quá thì không bắt đầu merge, để `TimeoutStartSec` của systemd không bao giờ cắt ngang một lệnh merge); và **không có tiến trình nào của cùng user có thư mục làm việc nằm trong cây làm việc của repo** (gốc của `git rev-parse --show-toplevel`, không phải thư mục con được cấu hình; đọc `/proc/<pid>/cwd`, so khớp tiền tố theo đường dẫn thật có dấu `/` cuối; phủ omp, claude, codex, shell và pane tmux; máy không có `/proc` thì coi như đang bận). Lệnh merge **không bao giờ bị giới hạn thời gian hay bị kill** (kill giữa chừng để lại cây làm việc nửa mới nửa cũ). File chưa theo dõi **hoặc bị ignore** (ví dụ `TASK.md`, `CLAUDE.md` trong `.git/info/exclude`) mà commit mới sẽ ghi đè thì merge lỗi và file giữ nguyên. Kéo lỗi thì checkout giữ nguyên. Sau khi kéo xong, `behindDefault` được tính lại;
4. ghi `~/.local/state/fcode/git-sync.json` (ghi nguyên tử, chế độ 600): mỗi project có `branch`, `default`, `dirty`, `behindDefault`, `aheadOfOrigin`, `lastFetchAt`, `error`, `autoUpdated`, `autoSkip`, cùng `updatedAt` ở ngoài cùng. `autoUpdated` = lượt chạy này đã kéo code (`true`/`false`). `autoSkip` = `null` (không có gì để kéo, hoặc đã kéo) hoặc lý do không kéo dù đang chậm: `late`, `in_progress`, `on_branch`, `dirty`, `ahead`, `filters`, `busy`, `ff_failed` (lệnh merge lỗi, ví dụ file chưa theo dõi sẽ bị ghi đè hoặc nhánh đã rẽ khỏi `origin`). `error` chỉ là một lý do ngắn (`fetch failed: ...`, `fetch timed out after Ns`, ...), kèm tối đa dòng đầu của git với mật khẩu trong URL và token (`ghp_`, `github_pat_`, `x-access-token`...) đã bị che.

Ứng dụng đọc file này và hiện "chậm N commit" (`behindDefault` > 0), "N commit chưa đẩy" (`aheadOfOrigin` > 0) hoặc "có sửa chưa lưu" (`dirty`). Timer chỉ đưa nhánh mặc định của project **đang rảnh và sạch** lên mới; còn lại **cập nhật code vẫn là việc của agent**, theo luật "Sync first" trong `box/agents-git.md`: đầu mỗi task và trước `gh pr create` chạy `git fetch origin` rồi cập nhật nhánh từ `origin/main` (rebase nếu nhánh chưa đẩy, merge nếu đã đẩy). **Box không bao giờ tự đẩy (push) hộ**: nếu thấy "chưa đẩy" / "chưa lưu", hãy nhờ agent commit và push nhánh của nó.

Một project lỗi không làm dừng các project khác; chỉ một lượt chạy tại một thời điểm (`flock`); không in gì ra màn hình. Chạy tay: `fcode-git-sync` hoặc `systemctl --user start fcode-git-sync.service`. Chạy riêng một project: `fcode-git-sync <tên project>` (server gọi lệnh này ngay trước khi tạo phiên mới): chỉ project đó được fetch và đếm (**không bao giờ kéo nhanh**: `autoUpdated` luôn `false`, `autoSkip` luôn `null`), chỉ mục của nó trong `git-sync.json` được cập nhật (các mục khác giữ nguyên), toàn bộ lượt chạy xong trong khoảng 55 giây (chờ khoá tối đa 15 giây + fetch 30 giây + 5 giây chờ tắt + đếm) và luôn thoát với mã 0; lỗi chỉ nằm trong mục của project. Tên không có trong cấu hình: in một dòng ra stderr, không đổi state. Khi nhận TERM/INT/HUP script dọn file tạm rồi thoát; file state luôn ghi bằng file tạm rồi đổi tên. Timer không có `GH_TOKEN` của riêng nó (unit systemd không có môi trường đăng nhập), nên để fetch được project private thêm bằng đường token (origin https + `!gh auth git-credential`) nó lấy `GH_TOKEN` chỉ qua đoạn khởi động chung `start.sh` (bản đã cài ở `~/fcoding/start.sh`, hoặc `start.sh` cạnh script khi chạy từ bản checkout; chính `start.sh` chỉ đọc nội dung chữ trong file, không chạy file, không lấy biến nào khác như `INSTABOX_API_KEY`; script này không tự đọc file). File bí mật phải chỉ gồm các dòng đơn giản dạng `TÊN=giá trị` (có thể có `export` ở đầu; dòng trống và dòng bắt đầu bằng `#` được bỏ qua; không dùng tên OPTIND, HISTCMD, MAILCHECK, RANDOM, SRANDOM, SECONDS):

- giá trị viết trần chỉ được gồm chữ, số và các dấu `_ . / : @ % + , = ~ ^ -`; có dấu cách hoặc ký tự khác (như `!`, `?`, `&`, `$`) thì đặt cả giá trị trong nháy đơn `'...'` (trong đó không có `'`); trong nháy kép `"..."` không có `$`, dấu huyền (`` ` ``) hay `\`;
- giá trị của `GH_TOKEN` dài 1 đến 255 ký tự, chỉ gồm chữ cái không dấu (a-z, A-Z), số và `_`;
- file là file bình thường (không phải thư mục), tối đa 64 KB, chỉ là văn bản thuần, không có ký tự điều khiển (dòng `#` cũng vậy);
- chỉ một dòng sai là không có token. Khi không có token, dòng `start.sh -v` trong `journalctl --user -u fcoding` cho biết lý do (lệnh và các từ trạng thái: `docs/HUONG-DAN.md`, mục 3).

Không có `start.sh` hoặc không có token thì fetch chạy không token; timer luôn bỏ `GH_TOKEN` và `GITHUB_TOKEN` kế thừa từ môi trường (gh sẽ dùng `GITHUB_TOKEN` nếu còn). Token chỉ nằm trong môi trường của tiến trình, không ghi ra file hay log.

`install-autoupdate.sh` chỉ cài script và hai unit rồi bật timer; nó **không** sửa file hướng dẫn của agent. Nội dung luật Git cho agent nằm ở `box/agents-git.md` (nguồn duy nhất); người quản trị tự đưa mục đó vào `~/.omp/agent/AGENTS.md`, `~/.claude/CLAUDE.md` và `~/AGENTS.md`.

Kiểm thử (thư mục tạm, không đụng box thật): `bash test/git-sync.test.sh`.

## Báo chủ: fcode-notify

Phiên omp chính (main session) để lại một tin một chiều cho chủ máy. `fcode-notify` chỉ **ghi thêm một dòng vào file hộp thư** trên box; nó không gửi gì, không gọi mạng, không chạy nội dung tin. Một máy khác (Hermes) tự kéo file này **chỉ-đọc** qua ssh bằng một khoá riêng chỉ chạy được một lệnh cố định (đọc cuối file) rồi chuyển tin sang Zalo của chủ. Tin chỉ để báo, không phải lệnh: không có đường nào từ tin sang hành động.

```bash
fcode-notify <project> <kind> "<nội dung>" [link]
```

- `<project>`: `^[a-z0-9][a-z0-9._-]{0,39}$`. `<kind>`: `merge-ready`, `needs-yes`, `stuck` hoặc `info`. `[link]`: để trống hoặc URL `https://…` tối đa 160 ký tự.
- Nội dung: ký tự điều khiển và ký tự vô hình (ESC, TAB/CR/LF thành một dấu cách, U+200B, U+202E…) bị bỏ; dấu cách liền nhau gộp thành một; cắt còn tối đa 300 **ký tự** (không cắt giữa một chữ). UTF-8 sai hoặc rỗng sau khi làm sạch thì bị từ chối. Tiếng Việt và emoji giữ nguyên.
- Mỗi lần gọi in đúng một dòng rồi thoát:

| Dòng in ra | Mã thoát | Ý nghĩa |
|---|---|---|
| `notify: queued <id>` | 0 | đã ghi |
| `notify: duplicate` | 0 | cùng project + kind + nội dung + link đã ghi trong 30 phút qua; không ghi thêm |
| `error: usage` / `bad-project` / `bad-kind` / `bad-text` / `bad-link` | 65 | bị từ chối, không ghi gì |
| `error: rate-limited` | 75 | quá 6 tin cho project này hoặc quá 15 tin tổng trong 60 phút qua; không ghi gì |
| `error: io` | 1 | lỗi khoá hoặc ghi; file cũ giữ nguyên |

- Hộp thư: `~/.local/state/fcode/notify/outbox.tsv` (thư mục 700, file 600), mỗi tin một dòng, 6 cột cách nhau bằng TAB: `id  epoch  project  kind  nội_dung  link`. Chỉ giữ 50 dòng mới nhất; mỗi lần ghi là file tạm + `mv` dưới `flock` (`outbox.lock`). Hermes đọc bằng `tail -c 65536` của file này và tự kiểm tra lại từng dòng.
- `install.sh` cài `fcode-notify` vào `~/.local/bin`, và tạo sẵn thư mục hộp thư (700) cùng một file `outbox.tsv` **rỗng** (600) bằng `: >>` (không bao giờ cắt file đang có), để lần kéo đầu tiên của Hermes đọc được file thay vì báo lỗi; file rỗng là hợp lệ, `fcode-notify` ghi tiếp vào đó.
- Lệnh cố định chạy qua bash của user (`/bin/bash`), bash này đọc `~/.bashrc` cả với lệnh ssh không tương tác. `~/.bashrc` **không được in gì** cho shell không tương tác (giữ đoạn chặn `case $- in *i*) ;; *) return;; esac` ở đầu file): mọi chữ in thêm sẽ nối vào dữ liệu và làm Hermes bỏ mất tin.
- Luật cho agent (khi nào được gọi) nằm ở `box/agents-notify.md`; người quản trị tự đưa vào `~/.omp/agent/AGENTS.md`, như `box/agents-git.md`.
- Biến thử nghiệm `FCODE_NOTIFY_DIR` và `FCODE_NOTIFY_NOW` chỉ có tác dụng khi `FCODE_NOTIFY_TEST=1`.

Kiểm thử (thư mục tạm, không đụng hộp thư thật): `bash test/fcode-notify.test.sh`.
