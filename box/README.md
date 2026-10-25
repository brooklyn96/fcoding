## Tự động cập nhật omp, claude, codex, opencode, cmd

Một timer chạy dưới quyền người dùng (systemd user unit, cần `loginctl enable-linger`) cập nhật 5 công cụ mỗi 6 giờ. Việc cập nhật **không bao giờ sửa file đang chạy**, nên phiên đang mở không bị hỏng và không cần kiểm tra "công cụ có đang chạy không".

Cài (chạy lại nhiều lần cũng an toàn):

```bash
bash box/install-autoupdate.sh
```

Script cài `~/.local/bin/fcode-update`, hai unit `fcode-update.service` / `fcode-update.timer` trong `~/.config/systemd/user`, tạo thư mục `/opt/fcode-tools` (chủ là người dùng), rồi bật timer. Ngay khi timer được bật, mốc `OnStartupSec=5min` đã qua nên systemd chạy ngay một lượt; chạy lại script cài không kích hoạt thêm lượt nào, vì timer đã có mốc chạy trước.

Lịch chạy: 00:00, 06:00, 12:00, 18:00 giờ UTC (box dùng UTC; tức 07:00, 13:00, 19:00, 01:00 giờ Việt Nam), cộng 5 phút sau khi box khởi động, trễ ngẫu nhiên tới 5 phút. Box tạm dừng sau 30 phút rảnh nên timer chỉ chạy khi box đang thức; lượt bị lỡ được bù ở lần thức sau.

### Cách bố trí (claude, codex, opencode, cmd)

```
/opt/fcode-tools/<công_cụ>/<phiên_bản>/      mỗi phiên bản là một prefix npm riêng (bin/, lib/node_modules/)
/opt/fcode-tools/<công_cụ>/current           symlink tới một phiên bản
/usr/local/bin/<tên_lệnh>                    symlink tới /opt/fcode-tools/<công_cụ>/current/bin/<tên_lệnh>
```

Mọi tên lệnh đều được trỏ (cmd, cmdc, command-code, commandcode, opencode, opencode2, claude, codex). Mỗi lượt, với từng công cụ:

1. so phiên bản đang chạy (`current`) với bản mới nhất (`npm view <gói> version`); phiên bản phải đúng dạng semver `X.Y.Z[-tiền_tố]`, nếu không thì bỏ qua và ghi `failed`; không bao giờ hạ cấp;
2. khác nhau thì `npm install -g --prefix /opt/fcode-tools/<công_cụ>/<bản> <gói>@<bản>` (không cần sudo, vì thư mục thuộc người dùng) và chạy thử `<lệnh> --version` ngay trong thư mục đó; sai thì xoá thư mục và ghi `failed`, `current` không đổi;
3. đổi `current` bằng một phép đổi tên nguyên tử (symlink tạm rồi `mv -T`), nên không có lúc nào thiếu lệnh; sau đó đảm bảo các symlink trong `/usr/local/bin` (cần sudo, chỉ cho việc này);
4. dọn: giữ bản hiện tại và 2 bản được bật gần nhất; bản cũ hơn chỉ bị xoá khi không có tiến trình nào dùng (exe, thư mục làm việc, file đang mở, vùng nhớ ánh xạ, hay đường dẫn trên dòng lệnh) và không có phiên nào của công cụ đó đã bắt đầu trước bản hiện tại. Nghi ngờ thì giữ.

Tiến trình đang chạy giữ nguyên thư mục phiên bản nó khởi động từ, nên phiên cũ chạy tiếp bình thường; phiên mới dùng bản mới.

**Lần chạy đầu tiên** chuyển bản cài toàn cục cũ (`/usr/local/lib/node_modules`) sang bố cục trên: cài đúng phiên bản đang có vào `/opt/fcode-tools/<công_cụ>/<bản>`, kiểm tra, đổi `current`, trỏ lệnh. Bản cũ trong `/usr/local/lib/node_modules` bị xoá khi không còn gì dùng nó; nếu còn phiên cũ đang chạy thì để lại và thử xoá ở lượt sau.

### omp

`omp update` tự thay file bằng cách đổi tên nguyên tử (file mới có inode mới, file cũ được đổi tên rồi xoá), nên phiên omp đang chạy vẫn chạy bình thường (đã kiểm tra trên bản sao). omp không cần bố cục trên.

### OpenCode: dịch vụ nền

OpenCode v2 có một dịch vụ nền dùng chung (`opencode serve --service`). Script **không** dừng hay bật dịch vụ này, và không bao giờ khởi động nó từ unit. Khi có client mới thuộc phiên bản khác, chính OpenCode so phiên bản của dịch vụ với phiên bản của nó và thay dịch vụ (kèm chuyển giao terminal) nên dịch vụ cũ không bị dùng lại. Lưu ý: client OpenCode cũ đang mở có thể mất backend khi client bản mới thay dịch vụ; đó là cách OpenCode tự hoạt động.

### Kết quả

- `~/.local/state/fcode-update/log`: một dòng cho mỗi công cụ mỗi lượt (kèm dòng ghi chú khi chuyển hoặc dọn), giữ khoảng 500 dòng cuối;
- `~/.local/state/fcode-update/status.json`: `{công_cụ: {from, to, at, result, error}}`, `result` là `updated`, `current` hoặc `failed` (`skipped_busy` không còn dùng), ghi nguyên tử để app đọc.

Chạy tay: `systemctl --user start fcode-update.service` hoặc `fcode-update [công_cụ ...]`. Mọi lệnh đều có timeout; chỉ một lượt chạy tại một thời điểm (`flock`).

### Quay lại bản cũ (rollback)

```bash
ls /opt/fcode-tools/claude                              # các bản còn giữ
ln -sfn 2.1.288 /opt/fcode-tools/claude/current         # quay lại bản đó (phiên đang chạy không bị ảnh hưởng)
touch /opt/fcode-tools/claude/hold                      # giữ nguyên, lượt sau không nâng cấp lại
rm /opt/fcode-tools/claude/hold                         # cho phép cập nhật tiếp
```

Không có file `hold` thì lượt chạy sau sẽ nâng lại lên bản mới nhất.

### Tắt trình tự cập nhật riêng của từng công cụ

Để chỉ có timer này thay file, `install-autoupdate.sh` tắt trình tự cập nhật riêng bằng cấu hình của chính công cụ:

| Công cụ | Cách tắt |
|---|---|
| claude | `DISABLE_AUTOUPDATER=1` trong `/etc/claude-code/managed-settings.json` (box instabox đã có sẵn); nếu thiếu, script thêm `env.DISABLE_AUTOUPDATER` vào `~/.claude/settings.json` |
| Command Code (cmd) | `{"autoUpdate": false}` trong `~/.commandcode/updates.json` |
| OpenCode | `{"autoupdate": false}` trong `~/.config/opencode/opencode.json` (log ghi `update check skipped reason=policy-disabled`) |
| omp | không cần: tự cập nhật chỉ khi gọi `omp update` |

### Việc cần làm ở `install.sh` (do người khác phụ trách)

Thêm một dòng gọi `bash "$(dirname "$0")/box/install-autoupdate.sh"` sau khi cài `fcode-pair`. Nếu `fcoding.service` khởi chạy phiên tmux, có thể thêm `OPENCODE_DISABLE_AUTOUPDATE=1` vào môi trường phiên; `install-autoupdate.sh` đã tắt qua cấu hình nên không bắt buộc.
