# FCode

Điều khiển các trợ lý lập trình (omp, Claude Code, Codex, shell) đang chạy trên một máy Linux đám mây, ngay từ iPhone.

## Mục lục

1. [FCode là gì](#1-fcode-là-gì)
2. [Cách hoạt động](#2-cách-hoạt-động)
3. [Cài máy chủ trên box](#3-cài-máy-chủ-trên-box)
4. [Mở link công khai](#4-mở-link-công-khai)
5. [Cài app lên iPhone bằng Sideloadly](#5-cài-app-lên-iphone-bằng-sideloadly)
6. [Ghép iPhone với box](#6-ghép-iphone-với-box)
7. [Dùng hằng ngày](#7-dùng-hằng-ngày)
8. [Dùng từ laptop](#8-dùng-từ-laptop)
9. [Bảo mật](#9-bảo-mật)
10. [Phát triển](#10-phát-triển)

## 1. FCode là gì

FCode là một ứng dụng iPhone kèm một máy chủ nhỏ. Máy chủ chạy trên box (máy Linux đám mây của instabox). Ứng dụng cho bạn trò chuyện với các chương trình đang làm việc trên box mà không cần ngồi trước máy tính. Mỗi chương trình chạy trong một phiên tmux, nên phiên vẫn sống khi bạn khóa điện thoại, và bạn có thể vào lại cùng phiên đó từ laptop.

Tính năng chính:

- Trò chuyện với **omp**, **Claude Code**, **Codex** hoặc **shell** (bash) chạy trong tmux trên box.
- **Hộp thư tổng quan**: mọi phiên được chia thành **Cần bạn**, **Đang chạy** và **Đang nghỉ**. Việc cần bạn trả lời luôn nằm trên cùng.
- **Trả lời y/n ngay trên danh sách**, không cần mở phiên.
- **Hàng phím nhanh**: Esc, Ctrl+C, mũi tên, Tab, Shift+Tab, Enter, y, n và nút `/` cho các lệnh hay dùng.
- **Gõ tiếng Việt** bình thường bằng bàn phím iPhone; chữ được gửi nguyên vẹn lên box.
- **Phiên mới bằng nút +**: chọn chương trình và dự án, luôn tạo phiên mới.
- Ghép máy bằng **mã 6 số**, không có mật khẩu.

## 2. Cách hoạt động

```
iPhone (app FCode)
   │  HTTPS
   ▼
Link công khai của instabox  (https://7681-<id>.instabox.tech)
   │
   ▼
server.mjs trên box  (cổng 7681)
   │  tmux
   ▼
Các phiên tmux: omp / claude / codex / shell
```

- `server.mjs` là một file Node.js duy nhất, chỉ dùng thư viện có sẵn của Node 22. Không có gói ngoài, không có cơ sở dữ liệu.
- Máy chủ chỉ gọi lệnh `tmux` (và `git` ở chế độ chỉ đọc để hiện nhánh và số dòng thay đổi). Nó không tự kết nối ra internet.
- Dữ liệu chỉ đi giữa box và điện thoại của bạn, qua đường HTTPS của instabox. FCode không có máy chủ riêng, không gửi thống kê đi đâu.
- Lưu ý: bản thân omp, Claude Code, Codex vẫn nói chuyện với dịch vụ AI của chúng như khi bạn chạy chúng ở bất kỳ nơi nào khác. FCode không can thiệp vào việc đó.

## 3. Cài máy chủ trên box

Cần trên box: **Node 22** và **tmux**. Các chương trình bạn muốn dùng (`omp`, `claude`, `codex`) phải đã được cài sẵn trên box, trong `~/.local/bin`, `~/.bun/bin`, `/usr/local/bin`, `/usr/bin` hoặc `/bin` (FCode chỉ tìm trong các thư mục này).

Lấy mã nguồn về box rồi chạy script cài đặt:

```sh
git clone https://github.com/brooklyn96/fcoding.git
cd fcoding
bash install.sh
```

Script `install.sh` làm các việc sau, và chạy lại nhiều lần vẫn an toàn:

1. Chép `server.mjs` vào `/data/home/fcoding`.
2. Tạo thư mục cấu hình `/data/home/.fcoding` (quyền 700).
3. Lần cài đầu: tạo `config.json` với một khóa bí mật ngẫu nhiên và một dự án mẫu là thư mục home.
4. Cài lệnh `~/.local/bin/fcode-pair` (dùng để lấy mã ghép máy, xem [mục 6](#6-ghép-iphone-với-box)).
5. Tạo dịch vụ systemd của người dùng tên **`fcoding`**, bật chạy cùng hệ thống, tự chạy lại khi lỗi, rồi khởi động ngay. Cổng mặc định là **7681**.

**Cập nhật:** vào thư mục `fcoding`, chạy `git pull` rồi `bash install.sh` lại (script khởi động lại dịch vụ).

Các tệp quan trọng:

| Đường dẫn | Nội dung |
|---|---|
| `/data/home/fcoding/server.mjs` | Máy chủ |
| `/data/home/.fcoding/config.json` | Cấu hình: khóa bí mật, danh sách dự án, cổng |
| `/data/home/.fcoding/devices.json` | Các iPhone đã ghép (chỉ lưu dạng băm) |

Kiểm tra dịch vụ:

```sh
systemctl --user status fcoding
journalctl --user -u fcoding -n 50
```

### Danh sách dự án

Các dự án hiện trong app nằm trong `config.json`, mục `projects`. Mỗi dự án là một tên và một đường dẫn tuyệt đối trên box:

```json
{
  "cookieSecret": "<chuỗi ngẫu nhiên do install.sh tạo, đừng chia sẻ>",
  "projects": {
    "web": "/data/home/<thư-mục-dự-án-web>",
    "api": "/data/home/<thư-mục-dự-án-api>"
  },
  "port": 7681
}
```

- Tên dự án nên gồm chữ thường, số và dấu gạch ngang (tên này được dùng để đặt tên phiên, ví dụ `web-claude`).
- Máy chủ tự đọc lại file sau khi bạn lưu, không cần khởi động lại (riêng `port` chỉ có tác dụng sau khi khởi động lại dịch vụ). Nếu file bị lỗi cú pháp, máy chủ giữ cấu hình cũ cho tới khi bạn sửa đúng.
- Mỗi phiên mới chạy trong thư mục của dự án đã chọn.

## 4. Mở link công khai

Máy chủ nghe ở cổng 7681 trên box. Để iPhone vào được, hãy công khai cổng này bằng công cụ `instabox` (chạy trên laptop):

```sh
instabox port publish <tên-box> 7681
```

Lệnh in ra một địa chỉ dạng:

```
https://7681-<id>.instabox.tech
```

Hãy chép địa chỉ này, bạn sẽ nhập nó vào app ở bước ghép máy. Để kiểm tra, mở địa chỉ trong trình duyệt: nếu thấy dòng chữ `fcoding ok` là máy chủ đang chạy.

Địa chỉ công khai thì ai biết cũng mở được trang đó, nhưng mọi chức năng khác đều cần iPhone đã ghép (xem [mục 9](#9-bảo-mật)).

## 5. Cài app lên iPhone bằng Sideloadly

FCode không có trên App Store. Bạn cài app bằng **Sideloadly** trên máy tính Windows hoặc Mac. Cần iPhone dùng iOS 16 trở lên.

### Tải file cài đặt

1. Vào trang GitHub của dự án (`github.com/brooklyn96/fcoding`), bấm **Releases**.
2. Chọn bản **FCode (bản mới nhất)** (nhãn `latest`) và tải file **`fcode.ipa`** về máy tính.

File này do GitHub Actions tự dựng lại mỗi khi nhánh `main` thay đổi phần ứng dụng iOS, nên tải lại là có bản mới.

### Cài bằng Sideloadly

1. Cài **Sideloadly** (sideloadly.io). Trên Windows, cài thêm **iTunes** và **iCloud** bản tải từ trang của Apple (không dùng bản Microsoft Store; nếu đã có bản Microsoft Store thì gỡ bản đó trước).
2. Cắm iPhone vào máy tính bằng cáp, mở khóa iPhone, bấm **Tin cậy** nếu được hỏi.
3. Mở Sideloadly, kéo file `fcode.ipa` vào cửa sổ, nhập **Apple ID** của bạn rồi bấm **Start**. Nhập mật khẩu Apple ID (và mã xác minh) khi được hỏi.
4. Lần cài đầu, trên iPhone cần tin cậy nhà phát triển:
   - Vào **Cài đặt → Cài đặt chung → Quản lý VPN & thiết bị**, chọn Apple ID của bạn rồi bấm **Tin cậy**.
5. Trên iOS 16 trở lên cần bật **Chế độ nhà phát triển**:
   - Vào **Cài đặt → Quyền riêng tư & Bảo mật → Chế độ nhà phát triển**, bật lên, để iPhone khởi động lại rồi xác nhận **Bật**.
6. Mở **FCode** trên màn hình chính.

### Gia hạn 7 ngày

Với Apple ID miễn phí, app chỉ chạy được **7 ngày** rồi phải ký lại. Cách làm: cắm iPhone, mở Sideloadly và bấm **Start** lại với cùng file `fcode.ipa`. Cài đè bằng cùng Apple ID thì việc ghép máy vẫn được giữ, bạn không phải ghép lại. Sideloadly cũng có thể tự ký lại app sau vài ngày bằng một chương trình chạy nền trên máy tính (máy tính phải bật và kết nối được với iPhone, qua cáp hoặc cùng Wi-Fi); xem hướng dẫn của Sideloadly nếu muốn dùng.

Muốn lên bản mới: chạy `fcode ipa` rồi cài file đó bằng Sideloadly (giữ nguyên ghép máy). Máy không có `fcode` thì vào **Releases** trên GitHub, tải `fcode.ipa` như ở mục "Tải file cài đặt" rồi cài bằng Sideloadly.

## 6. Ghép iPhone với box

FCode không dùng mật khẩu. Chỉ người đang có quyền vào dòng lệnh của box mới ghép được máy mới. Cách làm:

1. Trên box, chạy:

   ```sh
   fcode-pair "iPhone của tôi"
   ```

   Tên trong ngoặc là tên hiển thị của máy trong danh sách thiết bị (bỏ trống cũng được). Lệnh in ra một **mã 6 số**, ví dụ `482913`.

2. Trên iPhone, mở FCode ở màn hình **Ghép máy**:
   - **Địa chỉ máy chủ**: địa chỉ công khai ở [mục 4](#4-mở-link-công-khai) (bắt đầu bằng `https://`).
   - **Mã ghép**: gõ 6 số vừa thấy.
3. Bấm **Ghép iPhone này**.

Lưu ý về mã:

- Mã có hạn **2 phút** và chỉ dùng được **một lần**.
- Nhập sai 5 lần thì mã bị hủy; chạy lại `fcode-pair` để lấy mã mới (mã mới thay mã cũ).
- Máy chủ phải đang chạy thì lệnh mới in được mã.

Sau khi ghép, iPhone nhớ box trong Keychain. Mở app là vào thẳng danh sách; box khởi động lại cũng không phải ghép lại.

### Xem và gỡ thiết bị

Trên box:

```sh
# xem các thiết bị đã ghép (mã, ngày ghép, tên)
PC_CONFIG_DIR=/data/home/.fcoding node /data/home/fcoding/server.mjs --devices

# gỡ một thiết bị theo mã
PC_CONFIG_DIR=/data/home/.fcoding node /data/home/fcoding/server.mjs --revoke <id>

# gỡ tất cả
PC_CONFIG_DIR=/data/home/.fcoding node /data/home/fcoding/server.mjs --revoke all
```

Trong app, vào **Cài đặt** (biểu tượng bánh răng):

- **Gỡ iPhone này**: gỡ điện thoại này khỏi box. Máy luôn được xóa ghép ngay trên iPhone, kể cả khi box không trả lời. Nếu box không trả lời, máy vẫn còn trong danh sách trên box; gỡ nốt bằng `--revoke <id>`.
- **Gỡ mọi thiết bị**: gỡ tất cả máy đã ghép (có hỏi xác nhận). iPhone chỉ đăng xuất khi box xác nhận; nếu lỗi, bấm **Thử lại**.

Muốn dùng lại sau khi bị gỡ thì chạy `fcode-pair` trên box và ghép lại.

## 7. Dùng hằng ngày

**Màn hình chính** gom mọi phiên trên box, tự cập nhật mỗi 5 giây (kéo xuống để cập nhật ngay).

- **Cần bạn**: phiên đang hỏi bạn điều gì đó (ví dụ `(y/n)`, "Do you want…", "Proceed?"). Luôn mở sẵn và hiện đủ câu hỏi.
  - Câu hỏi có/không có hai nút **y · Đồng ý** và **n · Từ chối**.
  - Câu hỏi khác có nút **Trả lời** (mở phiên, con trỏ nằm sẵn ở ô nhập).
  - Nút **Mở** vào phiên để xem toàn bộ.
- **Đang chạy**: phiên có màn hình vừa thay đổi trong 8 giây gần nhất. Hiện dự án, nhánh git, số dòng thêm/bớt và một dòng xem trước.
- **Đang nghỉ**: phiên đang yên, hiện mờ. Hai mục này mặc định thu gọn; chạm vào tiêu đề để mở, app nhớ lựa chọn của bạn.
- **Hàng dự án** (trượt ngang): chạm **Tất cả** hoặc một dự án để lọc. Số cam là số phiên đang chờ bạn, số xám là số phiên.
- **Thanh chương trình ở dưới** (Tất cả / omp / claude / codex / shell): lọc theo chương trình.
- Chấm xanh dương cạnh tên phiên: có thay đổi bạn chưa xem. Mở phiên là tính đã đọc.
- Vuốt trái một phiên: **Đã đọc / Chưa đọc**, hoặc **Xoá** (có hỏi xác nhận; chương trình trong phiên sẽ bị tắt).

**Tạo phiên mới**: bấm **+** ở góc phải. Chọn chương trình, rồi chọn dự án. Nút này luôn tạo phiên **mới** (tên như `web-claude`, `web-claude-2`, …) và không bao giờ mở lại phiên cũ; muốn vào phiên cũ thì mở từ danh sách. Nếu thanh dưới đang lọc một chương trình thì bước chọn chương trình được bỏ qua.

**Trong một phiên**:

- Màn hình tự cuộn xuống dòng mới nhất. Nếu bạn cuộn lên để đọc, bấm **Xuống cuối** để quay lại. **A-** / **A+** đổi cỡ chữ.
- Chấm màu báo kết nối: xanh lá là trực tiếp, vàng là cập nhật định kỳ, cam là đang kết nối, đỏ là mất kết nối.
- **Ô nhập mặc định được ẩn** để màn hình rộng hơn. Chạm nút **bàn phím** tròn ở góc dưới bên phải: ô nhập hiện ra và bàn phím bật lên ngay, chỉ cần một lần chạm.
- Gõ vào ô nhập rồi chạm nút gửi tròn ở mép phải ô: chữ được gửi kèm Enter. **Nhấn giữ** nút gửi để chọn **Gửi không Enter**. Chạm gửi khi ô trống chỉ gửi một lần Enter. Nội dung đang soạn được giữ lại cho từng phiên.
- Gửi xong, ô nhập **tự ẩn lại**. Muốn ẩn bằng tay: chạm nút **⌄** trên ô nhập, hoặc vuốt xuống ở thanh kéo (vạch nhỏ ở đầu ô) hay nền ô nhập.
- Nút **ghim** trên ô nhập: khi ghim, ô nhập hiện sẵn mỗi lần mở phiên và vẫn ở lại sau khi gửi. Bấm lần nữa để bỏ ghim. App nhớ lựa chọn này.
- **Màu và biểu tượng**: màn hình hiện đúng màu của chương trình (chữ, nền, đậm, nghiêng, gạch chân), nên dễ phân biệt lỗi, phần thêm/xóa của diff hay mục đang chọn. Các biểu tượng đặc biệt (nhánh git, thư mục…) hiện đúng nhờ font Nerd Font đi kèm app. Tên phiên ở thanh trên nằm trong nhãn màu theo chương trình (claude cam, omp tím, codex xanh).
- Hàng phím nhanh: Esc, Ctrl+C, mũi tên, Tab, ⇧Tab, Enter, y, n. Nút `/` chèn các lệnh hay dùng như `/model`, `/clear`. Phím được gửi đúng thứ tự bạn bấm.
- Agents (Alt+A): mở danh sách subagent của omp; trong đó dùng ↑↓ chọn, Enter mở, Esc đóng.
- Khi chuyển sang app khác, kết nối tạm dừng; mở lại là tự kết nối lại.

**Khi gặp lỗi**

| Thông báo | Cách xử lý |
|---|---|
| "Mã sai hoặc đã hết hạn…" | Chạy lại `fcode-pair` trên box, lấy mã mới. |
| "Thử quá nhiều lần, đợi N giây." | Đợi đủ thời gian rồi thử lại. |
| "iPhone này đã bị gỡ khỏi box, hãy ghép lại." | Chạy `fcode-pair` trên box và ghép lại. |
| "Phiên đã đóng." | Chương trình trong phiên đã thoát; bấm **Quay lại** rồi mở lại dự án. |
| "Box đang bận, thử lại sau." | Đợi vài giây. |
| "Không kết nối được máy chủ." | Kiểm tra mạng, địa chỉ máy chủ và dịch vụ `fcoding` trên box. |

## 8. Dùng từ laptop

Mọi phiên là phiên tmux thật trên box, nên bạn vào cùng phiên với điện thoại từ laptop và thấy đúng những gì điện thoại thấy:

```sh
instabox ssh <tên-box> -- tmux ls
instabox ssh <tên-box> -- -tt tmux -u attach -t <tên-phiên>
```

`-tt` (đặt trước `tmux`) bắt ssh mở một màn hình thật; thiếu nó, tmux báo `open terminal failed: not a terminal`. `-u` để chữ tiếng Việt hiện đúng.

Để thoát mà **không tắt** phiên: bấm **Ctrl+B**, thả ra rồi bấm **D**.

Khi điện thoại mở một phiên, app đặt kích thước cửa sổ tmux theo màn hình điện thoại và giữ cố định như vậy. Nếu vào từ laptop thấy khung hình nhỏ hoặc có dấu chấm ở mép, cho cửa sổ theo lại màn hình đang dùng bằng một trong hai cách:

- Ngay trong tmux: bấm **Ctrl+B**, thả ra, gõ `:` rồi nhập `set-option -wu window-size` và bấm Enter.
- Hoặc từ laptop:

  ```sh
  instabox ssh <tên-box> -- tmux set-option -wu -t <tên-phiên> window-size
  ```

Đừng gõ lệnh này vào ô chat của omp, Claude Code hay Codex: nó sẽ được gửi cho trợ lý như một tin nhắn. Lần sau điện thoại mở lại phiên, kích thước lại theo điện thoại.

### Lệnh `fcode` (tùy chọn)

Trên máy Windows của chủ dự án có một lệnh `fcode` (PowerShell, kèm bản gọi cho Git Bash và cmd) để vào phiên nhanh hơn. Nó không nằm trong kho mã này và không bắt buộc. Để vào phiên, `fcode` gọi `instabox ssh` cho bạn; ngoài ra còn có `fcode sync` (dùng git ngay trên laptop) và `fcode ipa` (tải app về máy). Tên box lấy từ biến môi trường `FCODE_BOX`, nếu không đặt thì là `coder`.

```sh
fcode           # liệt kê các phiên, gõ số để vào
fcode 2         # vào thẳng phiên số 2
fcode web       # vào phiên theo tên (hoặc đầu tên, nếu chỉ khớp một phiên)
fcode --list    # (hoặc -l) chỉ liệt kê, không vào
```

- `fcode sync`: kéo code mới của 3 project về laptop, chỉ cập nhật khi đang ở main và không có thay đổi chưa lưu; liệt kê nhánh box và PR chờ merge.
- `fcode ipa`: tải bản app mới nhất về `Downloads\fcode.ipa` (giữ bản trước là `fcode.prev.ipa`). Khi có bản mới, kéo file này vào Sideloadly và bấm Start; việc tự ký lại 7 ngày của Sideloadly chỉ gia hạn bản đang cài, không tự cập nhật. Không có `fcode` thì tải `fcode.ipa` từ **Releases** trên GitHub.

Thoát bằng **Ctrl+B** rồi **D**, phiên vẫn chạy tiếp.

## 9. Bảo mật

**Ghép máy bảo vệ điều gì.** Địa chỉ công khai ai cũng mở được, nhưng chỉ trang `fcoding ok` ở địa chỉ gốc là không cần đăng nhập. Mọi chức năng khác (xem màn hình, gửi chữ, tạo hoặc xóa phiên) đều đòi một mã thiết bị mà chỉ iPhone đã ghép mới có. Để ghép, phải có mã 6 số, và mã chỉ được tạo ra bởi người có quyền chạy lệnh trên box.

**Mã ghép:** ngẫu nhiên, 6 số, hạn 2 phút, dùng một lần, tối đa 5 lần nhập sai. Nhiều người cùng thử thì tổng số lần ghép bị giới hạn **10 lần mỗi phút và 30 lần mỗi giờ** cho cả hệ thống (vượt quá thì nhận lỗi 429 kèm thời gian chờ). Giới hạn này tính chung cho mọi người trên internet, nên người lạ có thể dùng hết 30 lượt; khi đó bạn chờ tối đa 1 giờ rồi ghép lại. Ghép máy hiếm khi cần nên điều này được chấp nhận.

**Dữ liệu lưu trên box:**

- `devices.json` chỉ lưu **dạng băm** của mã thiết bị, không lưu chính mã. Ai đọc được file này cũng không dùng nó để đăng nhập.
- Mã thiết bị chỉ nằm trong Keychain của iPhone. Máy chủ không ghi nội dung bạn gõ hay màn hình vào nhật ký (chỉ ghi phương thức, đường dẫn, mã trạng thái và thời gian).
- Thư mục cấu hình và các file trong đó chỉ chủ tài khoản đọc được. Nếu thư mục hay file là liên kết tượng trưng (symlink) hoặc thuộc người khác, máy chủ từ chối khởi động.

**Các lớp bảo vệ khác:** lệnh được chạy bằng `tmux` trực tiếp, không qua shell; tên phiên, phím gửi, dự án và chương trình đều chỉ nhận những giá trị nằm trong danh sách cho phép; mỗi yêu cầu thay đổi đều phải có tiêu đề riêng của app; kích thước yêu cầu và nội dung gửi có giới hạn (64 KB và 32 KB).

**Đổi khóa bí mật.** Nếu sửa `cookieSecret` trong `config.json` (kể cả khi máy chủ đang tắt), **mọi thiết bị bị gỡ** và phải ghép lại từng máy. Chuỗi mới phải là base64 của ít nhất 32 byte, tạo bằng:

```sh
node -e 'console.log(require("crypto").randomBytes(32).toString("base64"))'
```

**Mất iPhone thì làm gì:**

1. Trên box, xem thiết bị: `PC_CONFIG_DIR=/data/home/.fcoding node /data/home/fcoding/server.mjs --devices`.
2. Gỡ máy bị mất bằng `--revoke <id>` (hoặc `--revoke all` nếu không chắc máy nào).
3. Nếu nghi ngờ nặng hơn, đổi `cookieSecret` như trên để gỡ tất cả thiết bị.
4. Vào các phiên đang chạy từ laptop và kiểm tra xem có lệnh nào lạ không.

## 10. Phát triển

- Máy chủ dùng **Node 22**, chỉ thư viện có sẵn (không `npm install`). Toàn bộ nằm trong `server.mjs`.
- Hợp đồng giữa máy chủ và app nằm trong [`CONTRACT.md`](CONTRACT.md) (các mục A1 đến A6 là các thay đổi theo thời gian; mục A4 thay mật khẩu bằng ghép máy, A5 thêm hộp thư tổng quan, A6 thêm màu cho màn hình).
- Chạy thử trên máy bất kỳ, kể cả Windows (dùng tmux giả, không cần tmux):

  ```sh
  node --test test/server.test.mjs
  ```

- Thử với tmux thật, trên máy Linux có `tmux`, `node 22`, `curl` (script dùng socket tmux riêng nên không đụng phiên của bạn):

  ```sh
  bash test/tmux-integration.sh
  ```

- **App iOS** nằm trong thư mục `ios/` (SwiftUI, iOS 16 trở lên). Dự án Xcode được sinh bằng **XcodeGen** từ `ios/project.yml`. GitHub Actions (`.github/workflows/ios.yml`, máy macOS) dựng app **không ký** rồi đóng gói `fcode.ipa`. Khi chạy trên nhánh `main`, workflow đăng bản này lên bản phát hành trước (pre-release) tên **`latest`**. Việc ký được làm trên máy bạn, bằng Sideloadly. Hướng dẫn dùng app chi tiết hơn có trong [`ios/README.md`](ios/README.md).
