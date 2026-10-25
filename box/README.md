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

### Việc cần làm ở `install.sh` (do người khác phụ trách)

Thêm một dòng gọi `bash "$(dirname "$0")/box/install-autoupdate.sh"` sau khi cài `fcode-pair`.
