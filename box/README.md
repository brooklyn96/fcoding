## Tự động cập nhật omp, claude, codex, opencode, cmd

Một timer chạy dưới quyền người dùng (systemd user unit, cần `loginctl enable-linger`) cập nhật 5 công cụ mỗi 6 giờ.

Cài (chạy lại nhiều lần cũng an toàn):

```bash
bash box/install-autoupdate.sh
```

Script cài `~/.local/bin/fcode-update`, hai unit `fcode-update.service` / `fcode-update.timer` trong `~/.config/systemd/user`, rồi bật timer. Ngay khi timer được bật, mốc `OnStartupSec=5min` đã qua nên systemd chạy ngay một lượt. Chạy lại script cài (kể cả khi file đổi) không kích hoạt thêm lượt nào, vì timer đã có mốc chạy trước.

Lịch chạy: 00:00, 06:00, 12:00, 18:00 giờ UTC (box dùng UTC; tức 07:00, 13:00, 19:00, 01:00 giờ Việt Nam), cộng 5 phút sau khi box khởi động, trễ ngẫu nhiên tới 5 phút. Box tạm dừng sau 30 phút rảnh nên timer chỉ chạy khi box đang thức; lượt bị lỡ được bù ở lần thức sau.

Mỗi lượt, với từng công cụ:

- so phiên bản đang cài với bản mới nhất (`npm view <gói> version`; omp dùng `omp update --check`);
- khác nhau thì cập nhật (`omp update`, hoặc `sudo npm install -g <gói>@<bản>`; thư mục npm toàn cục thuộc root nên unit chạy bằng người dùng và dùng sudo chỉ cho npm);
- **công cụ đang chạy thì bỏ qua** (`skipped_busy`) và thử lại lượt sau, nên phiên đang mở không bị hỏng. "Đang chạy" nghĩa là có tiến trình chạy từ thư mục cài của công cụ (mọi tên lệnh: `cmd`, `cmdc`, `command-code`, `commandcode`, `opencode2`, ...). Dịch vụ nền `opencode serve --service` không tính; khi không có phiên OpenCode nào, script dừng dịch vụ đó (`opencode service stop`), cập nhật, rồi bật lại (`opencode service start`) nếu trước đó đang chạy;
- mọi lệnh đều có timeout; chỉ một lượt chạy tại một thời điểm (`flock`).

Kết quả:

- `~/.local/state/fcode-update/log`: một dòng cho mỗi công cụ mỗi lượt, giữ khoảng 500 dòng cuối;
- `~/.local/state/fcode-update/status.json`: `{công_cụ: {from, to, at, result, error}}`, `result` là `updated`, `current`, `skipped_busy` hoặc `failed`, ghi nguyên tử để app đọc.

Chạy tay: `systemctl --user start fcode-update.service` hoặc `fcode-update [công_cụ ...]`.

### Tắt trình tự cập nhật riêng của từng công cụ

Các công cụ này chạy dưới quyền người dùng nên không ghi được vào thư mục npm của root; chúng sẽ báo lỗi hoặc đua với timer. `install-autoupdate.sh` tắt chúng bằng cấu hình của chính công cụ:

| Công cụ | Cách tắt |
|---|---|
| claude | `DISABLE_AUTOUPDATER=1` trong `/etc/claude-code/managed-settings.json` (box instabox đã có sẵn); nếu thiếu, script thêm `env.DISABLE_AUTOUPDATER` vào `~/.claude/settings.json` |
| Command Code (cmd) | `{"autoUpdate": false}` trong `~/.commandcode/updates.json` |
| OpenCode | `{"autoupdate": false}` trong `~/.config/opencode/opencode.json` (log ghi `update check skipped reason=policy-disabled`) |
| omp | không cần: tự cập nhật chỉ khi gọi `omp update` |

### Việc cần làm ở `install.sh` (do người khác phụ trách)

Thêm một dòng gọi `bash "$(dirname "$0")/box/install-autoupdate.sh"` sau khi cài `fcode-pair`. Nếu `fcoding.service` khởi chạy phiên tmux, có thể thêm `OPENCODE_DISABLE_AUTOUPDATE=1` vào môi trường phiên; `install-autoupdate.sh` đã tắt qua cấu hình nên không bắt buộc.
