# FCode

Điều khiển các trợ lý lập trình (omp, Claude Code, Codex) đang chạy trên một máy Linux đám mây, ngay từ iPhone.

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

- Trò chuyện với **omp**, **Claude Code** hoặc **Codex** chạy trong tmux trên box. (Máy chủ vẫn chạy được **shell** (bash), nhưng app không còn liệt kê shell.)
- **Hộp thư tổng quan**: mọi phiên được chia thành **Cần bạn**, **Đang chạy** và **Đang nghỉ**. Việc cần bạn trả lời luôn nằm trên cùng.
- **Trả lời y/n ngay trên danh sách**, không cần mở phiên.
- **Hàng phím nhanh**: Esc, Ctrl+C, mũi tên, Tab, Shift+Tab, Enter, y, n, **Agents** và **^O** (chỉ trong phiên omp), cùng nút `/` cho các lệnh hay dùng.
- **Gõ tiếng Việt** bình thường bằng bàn phím iPhone; chữ được gửi nguyên vẹn lên box.
- **Phiên mới bằng nút +**: chọn chương trình và dự án, luôn tạo phiên mới.
- Ghép máy bằng **mã 6 số**, không có mật khẩu; iPhone mới ghép thêm được bằng **mã QR** (`fcode-pair --qr`, hoặc `fcode pair` trên laptop).
- Lệnh **`fcode`** trên laptop Windows: vào phiên, `fcode add` (thêm dự án GitHub vào box), `fcode pair`, cài bằng một dòng lệnh.
- Box **tự cập nhật** omp, Claude Code và Codex mỗi 6 giờ, không làm hỏng phiên đang mở.

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
Các phiên tmux: omp / claude / codex (shell: chỉ từ máy chủ)
```

- `server.mjs` là một file Node.js duy nhất, chỉ dùng thư viện có sẵn của Node 22. Không có gói ngoài, không có cơ sở dữ liệu.
- Máy chủ gọi lệnh `tmux` (và `git` ở chế độ chỉ đọc để hiện nhánh và số dòng thay đổi). Cho màn hình chính nó còn gọi `omp usage` (hạn mức) và `gh` (pull request, lần chạy CI); chính hai lệnh này kết nối ra internet, máy chủ thì không. Nó không bao giờ đọc file đăng nhập của omp, Claude hay Codex.
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
3. Lần cài đầu: tạo `config.json` với một khóa bí mật ngẫu nhiên và danh sách dự án **trống** (không có dự án mẫu). Thêm dự án của bạn theo mục "Danh sách dự án" bên dưới.
4. Cài lệnh `~/.local/bin/fcode-pair` (dùng để lấy mã ghép máy, xem [mục 6](#6-ghép-iphone-với-box)) và `~/.local/bin/fcode-new` (tạo phiên mới như nút "+" trong app: `fcode-new --projects`, `fcode-new --harnesses`, `fcode-new <dự án> <harness>`; chỉ in tên phiên, trùng tên thì thêm `-2`, `-3`…).
5. Cài bộ tự cập nhật omp, Claude Code, Codex (timer chạy mỗi 6 giờ; cần `sudo` không mật khẩu, thiếu thì chỉ cảnh báo và việc cài vẫn tiếp tục). Chi tiết trong [`box/README.md`](box/README.md).
6. Tạo dịch vụ systemd của người dùng tên **`fcoding`**, bật chạy cùng hệ thống, tự chạy lại khi lỗi, rồi khởi động ngay. Cổng mặc định là **7681**.

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

Các dự án hiện trong app nằm trong `config.json`, mục `projects`. Sau lần cài đầu mục này **trống**, nên nút **+** trong app báo "Chưa có dự án nào trong cấu hình máy chủ" cho tới khi bạn thêm dự án. Cách thêm: chạy `fcode add <chủ/repo>` trên laptop (xem [mục 8](#8-dùng-từ-laptop)), hoặc sửa `config.json` trên box như dưới đây. Mỗi dự án là một tên và một đường dẫn tuyệt đối trên box:

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

### Màn hình chính: hạn mức, chi phí, dự án

Màn hình chính của app lấy mọi thứ từ một địa chỉ của máy chủ (`GET /api/home`). Máy chủ gom dữ liệu như sau:

| Phần | Lấy từ đâu | Làm mới |
|---|---|---|
| Hạn mức Claude / Codex | `omp usage --json` (omp đã đăng nhập các tài khoản) | mỗi 60 giây |
| Chi phí và số token | file nhật ký trên box: `~/.omp/agent/sessions`, `~/.claude/projects`, `~/.codex/sessions` | mỗi 5 phút, chỉ đọc phần mới thêm |
| Pull request, CI | `gh` theo kho GitHub của từng dự án trong `config.json` | mỗi 2 phút |
| Phiên bản công cụ | `~/.local/state/fcode-update/status.json` (omp, claude, codex) | mỗi lần mở |
| Dự án chậm so với GitHub, cây chưa commit | `~/.local/state/fcode/git-sync.json` (timer `fcode-git-sync` trên box ghi) | mỗi lần mở |
| Giờ box ngủ | ước tính: lần box thức dậy gần nhất + 8 giờ (vẫn giữ đúng khi máy chủ khởi động lại, nhờ file `~/.fcoding/box-timer.json`; box khởi động lại thì tính lại từ đầu) | luôn |

- Mở phiên mới (nút "+" hoặc `fcode-new`) thì box chạy `fcode-git-sync <dự án>` trước và chờ tối đa 8 giây, để thẻ dự án có số commit "chậm / chưa đẩy" mới nhất. Lệnh này chỉ `fetch` và đếm lại, không bao giờ đổi thư mục làm việc: cập nhật code là việc của agent (luật "Sync first"). Thiếu lệnh, lệnh lỗi hay quá 8 giây thì phiên vẫn được tạo (máy chủ chỉ ghi một dòng nhật ký). Máy chủ không bao giờ tắt tiến trình đồng bộ; nó tự chạy xong, và mở phiên khác cùng dự án lúc đó dùng chung lần đồng bộ đang chạy.
- Một phần bị lỗi (ví dụ `gh` chưa đăng nhập) thì phần đó trống, các phần khác vẫn hiện. Hạn mức cũ được đánh dấu "cũ" nếu không làm mới được.
- Màn hình chính luôn trả lời nhanh: phần nào đã có thì hiện ngay và được làm mới ở nền. Lần mở đầu tiên sau khi máy chủ khởi động, phần nào chưa đọc xong trong 8 giây thì tạm trống và hiện ở lần tải sau.
- Chi phí là giá API niêm yết (bảng giá kèm trong `server.mjs`), không phải số tiền bạn trả theo gói. Chi phí của omp và của Codex được tính vào đúng tài khoản; chi phí từ Claude Code chạy riêng chỉ cộng vào tổng. Mẫu máy (model) không có trong bảng giá thì chỉ đếm token, không đoán tiền.
- "Ước tính cả tuần" của một tài khoản chỉ tính phần chi phí đã biết là của tài khoản đó. Claude Code chạy riêng (và vài lệnh nhỏ của omp như đặt tên phiên) cũng dùng hạn mức tuần nhưng không biết thuộc tài khoản nào, nên khi có chúng con số ước tính sẽ thấp hơn thực tế.
- Ngày (Hôm nay, Hôm qua, 30 ngày) tính theo giờ Việt Nam, bất kể box dùng múi giờ nào. Muốn đổi, thêm `"timeZone": "<múi giờ>"` (ví dụ `"Asia/Tokyo"`) vào `~/.fcoding/config.json`; máy chủ tự đọc lại, không cần khởi động lại.
- `gh` cần `GH_TOKEN` để đọc kho. Trên box instabox, dịch vụ tự lấy `GH_TOKEN` từ kho bí mật của instabox (giống như cửa sổ dòng lệnh), không ghi ra ổ đĩa. Nếu bạn vừa thêm token vào kho bí mật, khởi động lại dịch vụ: `systemctl --user restart fcoding`. Không có token thì phần dự án hiện "chưa đọc được GitHub". Nếu token không có quyền Checks thì kết quả checks của PR lấy từ các lần chạy GitHub Actions của commit đầu PR. "Deploy" trên thẻ dự án là lần chạy mới nhất của workflow có tên hoặc tên file chứa "deploy"; chưa có thì app hiện "deploy: chưa có".
- Nút Reset của Codex trong app chạy `omp usage reset <tài khoản>` trên box, mỗi tài khoản một lần một. Nếu reset chạy lâu hơn 15 giây, app báo "đang chạy" và bạn xem lại Hạn mức sau ít phút. Reset của Claude chỉ mở trang claude.ai.
- Đổi tên phiên (vuốt trên một phiên, "Đổi tên") dùng `tmux rename-session`; tên mới theo cùng luật như tên phiên. Tên dạng `<dự án>-<chương trình>` (ví dụ `deal-sync-claude`) dành cho phiên mở từ dự án đó, nên phiên khác không đổi sang tên này được.

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
- Nhập sai 5 lần thì mã bị hủy; chạy lại `fcode-pair` để lấy mã mới. Mỗi nơi tạo mã (lệnh `fcode-pair` hoặc từng iPhone đã ghép) chỉ có 1 mã đang chờ, tạo mã mới thì thay mã cũ của nơi đó; tổng cộng tối đa 3 mã cùng lúc.
- Máy chủ phải đang chạy thì lệnh mới in được mã.

Sau khi ghép, iPhone nhớ box trong Keychain. Mở app là vào thẳng danh sách; box khởi động lại cũng không phải ghép lại.

### Ghép thêm iPhone bằng mã QR

Không cần gõ địa chỉ máy chủ: iPhone mới quét mã QR bằng Camera, app FCode tự mở với địa chỉ máy chủ đã điền sẵn. Mã QR **không chứa mã 6 số**, nên bạn gõ mã 6 số đang hiện ở máy cũ (hoặc ở màn hình lệnh) vào app rồi bấm **Ghép**.

1. Làm một lần: thêm `publicUrl` vào `/data/home/.fcoding/config.json` (địa chỉ công khai ở [mục 4](#4-mở-link-công-khai), bắt đầu bằng `https://`, không có đường dẫn phía sau):

   ```json
   "publicUrl": "https://<địa-chỉ-công-khai>"
   ```

   Địa chỉ phải là tên miền chữ không dấu có ít nhất một dấu chấm (ví dụ `box.example.com`), hoặc địa chỉ IP, và chỉ có thể kèm số cổng. Tên có chữ có dấu (`xn--…`), tên không có dấu chấm (`localhost`), chữ `_` thì app từ chối, và lệnh `fcode-pair --qr` báo "publicUrl trong config.json không hợp lệ cho app" thay vì in mã QR không dùng được. Máy chủ chỉ tạo link từ địa chỉ này, không bao giờ lấy từ yêu cầu gửi tới. Chưa đặt thì không tạo được link và mã QR. Máy chủ tự đọc lại file, không cần khởi động lại.
2. Trên box, chạy `fcode-pair "iPhone mới" --qr`. Lệnh in mã QR (cần chương trình `qrencode`, cài bằng `sudo apt install qrencode`; thiếu thì in link và nhắc "cài qrencode để hiện mã QR"), link chia sẻ, rồi **mã 6 số cỡ lớn** và một dòng báo mã hết hạn sau 2 phút.
3. Trên iPhone mới, mở Camera và quét mã QR. Link chia sẻ (`<địa chỉ>/pair`) gửi qua AirDrop hay Zalo cũng được: mở nó sẽ ra trang có nút **Mở FCode**. Link không có mã nên gửi cho ai cũng không lộ gì ngoài địa chỉ máy chủ.
4. Trong app, gõ mã 6 số rồi bấm **Ghép**.

Từ một iPhone đã ghép, vào **Cài đặt → Thêm thiết bị (mã QR)** trong app cũng tạo được mã và QR như vậy (máy chủ cần có `publicUrl`).

Mã vẫn là mã ghép thường: dùng một lần, hết hạn sau 2 phút, nhập sai 5 lần thì hủy. Mỗi nơi tạo mã chỉ có 1 mã đang chờ (tạo mới thì thay mã cũ của nơi đó), tổng cộng tối đa 3 mã. Mở trang `/pair` không làm mất mã và trang này không có mã. Gỡ một iPhone khỏi box cũng hủy các mã nó đã tạo.

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

Hướng dẫn đầy đủ cho app nằm ở [ios/README.md, mục 4](ios/README.md#4-cách-dùng). Tóm tắt:

**Màn hình chính** (thanh trên cùng chỉ có nút **?** Hướng dẫn và **⚙** Cài đặt). Phiên tự cập nhật mỗi 5 giây, hạn mức và dự án mỗi phút; kéo xuống để cập nhật ngay.

- **Vòng giờ box** (bên trái thẻ trên cùng): **Sleeps in** là thời gian box còn chạy trước khi tự nghỉ (tối đa 8 giờ, hoặc sớm hơn nếu rảnh 30 phút; đây là ước tính của máy chủ). Vòng chuyển vàng khi còn dưới 10 phút. **Wakes in** là lúc box đang nghỉ 10 phút rồi tự dậy. Chạm vào vòng để xem giờ chính xác.
- **Ô hạn mức** (bên phải): mỗi lần một tài khoản, tự chuyển sang tài khoản kế mỗi 4 giây (giữ ngón tay trên ô để dừng). Chạm để mở màn hình **Hạn mức**.
- Dòng **đang chạy · chờ bạn**: chạm để nhảy tới phiên tương ứng.
- **Dự án** (trượt ngang): mỗi thẻ cho biết số PR đang mở, kết quả checks và lần deploy gần nhất ("đang đọc…" khi máy chủ vừa khởi động, "chưa đọc được GitHub" khi `gh` lỗi). Chạm thẻ để chỉ xem phiên của dự án đó; giữ lâu hoặc bấm **…** để mở phiên mới trong dự án đó.
- **Cần bạn**: phiên đang hỏi bạn, luôn mở sẵn. Câu hỏi có/không có nút **y · Đồng ý** và **n · Từ chối**; câu khác có nút **Trả lời**. Nút **Mở** mở phiên.
- **Đang chạy** và **Đang nghỉ**: chạm tiêu đề để mở hoặc thu gọn. App nhớ lựa chọn này.
- Chấm xanh dương cạnh tên phiên: có thay đổi bạn chưa xem. Mở phiên là tính đã đọc.
- Vuốt trái một phiên: **Đổi tên** hoặc **Đóng** (có hỏi xác nhận; chương trình trong phiên bị tắt).

**Tạo phiên mới**: bấm nút tròn **+** ở góc dưới bên phải. Chọn dự án, rồi chọn chương trình (omp, claude hoặc codex). Nút này luôn tạo phiên **mới** (tên như `web-claude`, `web-claude-2`, …) và không bao giờ mở lại phiên cũ; muốn vào phiên cũ thì mở từ danh sách. App không còn liệt kê shell, dù máy chủ vẫn chạy được shell.

**Hạn mức** (chạm ô hạn mức): tổng chi phí 30 ngày, rồi từng tài khoản: thanh dùng của từng khung giờ, xu hướng 30 ngày, chi phí "Hôm nay / Hôm qua / 30 ngày / Ước tính tuần". **Reset**: Codex dùng lượt reset ngay trong app (có hỏi xác nhận); Claude chỉ mở trang claude.ai. Xem thêm "Màn hình chính: hạn mức, chi phí, dự án" ở mục 3.

**Trong một phiên**:

- Khi bạn đang ở cuối, màn hình tự cuộn theo dòng mới. Nếu bạn cuộn lên để đọc, màn hình đứng yên dù có chữ mới; bấm nút tròn **↓** (hoặc cuộn về cuối) để theo lại. Gửi tin nhắn cũng đưa về cuối. **A-** / **A+** đổi cỡ chữ.
- Chấm màu báo kết nối: xanh lá là trực tiếp, vàng là cập nhật định kỳ, cam là đang kết nối, đỏ là mất kết nối.
- **Ô nhập mặc định được ẩn** để màn hình rộng hơn. Chạm nút **bàn phím** tròn ở góc dưới bên phải: ô nhập hiện ra và bàn phím bật lên ngay, chỉ cần một lần chạm. Muốn dời nút **bàn phím**: giữ và kéo nó đi, thả ra thì nút tự dạt vào mép trái hoặc phải gần nhất. Ứng dụng nhớ chỗ này.
- Gõ vào ô nhập rồi chạm nút gửi tròn ở mép phải ô: chữ được gửi kèm Enter. **Nhấn giữ** nút gửi để chọn **Gửi không Enter**. Chạm gửi khi ô trống chỉ gửi một lần Enter. Nội dung đang soạn được giữ lại cho từng phiên.
- Gửi xong, ô nhập **tự ẩn lại**. Muốn ẩn bằng tay: chạm nút **⌄** trên ô nhập, hoặc vuốt xuống ở thanh kéo (vạch nhỏ ở đầu ô) hay nền ô nhập.
- Nút **ghim** trên ô nhập: khi ghim, ô nhập hiện sẵn mỗi lần mở phiên và vẫn ở lại sau khi gửi. Bấm lần nữa để bỏ ghim. App nhớ lựa chọn này.
- **Màu và biểu tượng**: màn hình hiện đúng màu của chương trình (chữ, nền, đậm, nghiêng, gạch chân), nên dễ phân biệt lỗi, phần thêm/xóa của diff hay mục đang chọn. Các biểu tượng đặc biệt (nhánh git, thư mục…) hiện đúng nhờ font Nerd Font đi kèm app. Tên phiên ở thanh trên nằm trong nhãn màu theo chương trình (claude cam, omp tím, codex xanh).
- Link trong màn hình được gạch chân; chạm để mở trong trình duyệt. Link dài bị omp cắt xuống dòng thường vẫn mở đúng cả link. Nhấn giữ để chép chữ trên màn hình.
- Hàng phím nhanh: Esc, **Agents**, Ctrl+C, mũi tên, Tab, ⇧Tab, Enter, y, n, **^O**. Nút `/` chèn các lệnh hay dùng như `/model`, `/clear`. Phím được gửi đúng thứ tự bạn bấm.
- **Agents** (Alt+A): mở danh sách subagent của omp; trong đó dùng ↑↓ chọn, Enter mở, Esc đóng. **^O** (Ctrl+O) mở rộng nội dung. Hai phím **Agents** và **^O** chỉ hiện trong phiên omp.
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

Lệnh `fcode` nằm trong thư mục `laptop/` của kho mã này, chạy trên PowerShell hoặc cmd của Windows và không bắt buộc. Để vào phiên, `fcode` gọi `instabox ssh` cho bạn; ngoài ra còn có `fcode new` (mở phiên mới), `fcode sync` (dùng git ngay trên laptop), `fcode ipa` (tải app về máy), `fcode add` (thêm dự án) và `fcode pair` (ghép iPhone mới). Cách cài nằm ngay bên dưới, ở mục [Cài lệnh fcode trên máy Windows khác](#cài-lệnh-fcode-trên-máy-windows-khác).

Tên box và các thư mục mà `fcode sync` cập nhật nằm trong file `%USERPROFILE%\.fcode\config.json` (mục `box`, mặc định `coder`, và mục `syncRepos`). Biến môi trường `FCODE_BOX` chỉ dùng để đổi tên box tạm thời cho một lần chạy; `FCODE_SYNC_REPOS` cũng vậy cho danh sách thư mục.

```sh
fcode           # liệt kê các phiên, gõ số để vào
fcode 2         # vào thẳng phiên số 2
fcode web       # vào phiên theo tên (hoặc đầu tên, nếu chỉ khớp một phiên)
fcode --list    # (hoặc -l) chỉ liệt kê, không vào
fcode new       # mở phiên mới: chọn dự án và harness (hoặc gõ 0 trong danh sách)
```

- `fcode new`: mở phiên mới ngay từ laptop, giống nút "+" trong app: chọn dự án rồi harness, phiên hiện luôn trong app. Cần box có lệnh `fcode-new` (chạy lại `bash install.sh` trên box nếu chưa có).
- `fcode sync`: kéo code mới của các project trong `syncRepos` về laptop, chỉ cập nhật khi đang ở main và không có thay đổi chưa lưu; liệt kê nhánh box và PR chờ merge.
- `fcode add <chủ/repo> [tên]`: thêm một dự án GitHub vào box để omp làm việc và hiện trong danh sách của app. Lần đầu cho mỗi repo, lệnh hướng dẫn bạn dán một khóa vào trang GitHub của repo.
- `fcode pair [tên thiết bị]`: tạo mã ghép kèm mã QR cho iPhone mới (cần `publicUrl`, xem [mục 6](#ghép-thêm-iphone-bằng-mã-qr)).
- `fcode ipa`: tải bản app mới nhất về `Downloads\fcode.ipa`. Khi có bản mới, kéo file này vào Sideloadly và bấm Start; việc tự ký lại 7 ngày của Sideloadly chỉ gia hạn bản đang cài, không tự cập nhật. Không có `fcode` thì tải `fcode.ipa` từ **Releases** trên GitHub.

Thoát bằng **Ctrl+B** rồi **D**, phiên vẫn chạy tiếp.

### Đồng bộ phiên chat omp giữa laptop và box (`fcode phien`)

Chat omp ở laptop và chat omp ở box nằm ở hai nơi riêng. `fcode phien` chép phiên qua lại giữa hai máy để bên nào cũng thấy phiên của bên kia ngay trong omp: danh sách `/resume`, `omp -c` (phiên mới nhất của thư mục) và `omp -r <mã>`. Phiên chép sang là phiên omp bình thường của máy nhận (omp không biết nó từ máy khác tới), nên không cần lệnh riêng để mở lại.

Điều kiện: project có trong `syncRepos` của laptop (file `%USERPROFILE%\.fcode\config.json`) **và** trong danh sách project của FCode trên box (`fcode add`). Project chỉ có ở một bên thì bỏ qua. Mọi lần chép đều do laptop bắt đầu (box không với tới laptop được).

```sh
fcode phien                # đồng bộ mọi project
fcode phien deal-sync      # chỉ một project
fcode phien --thu          # chạy thử: chỉ liệt kê sẽ chép gì đi đâu, không chép, không ghi gì
fcode phien tu-dong bat    # bật tự động (mỗi 10 phút, chạy ngầm, không hiện cửa sổ)
fcode phien tu-dong tat    # tắt tự động (trangthai để xem đang bật hay tắt)
```

Gõ `fcode` rồi bấm `p` trong danh sách cũng mở menu này (đồng bộ ngay, bật hoặc tắt tự động).

Luật đồng bộ (một phiên = một mã = một file `.jsonl` chỉ được nối thêm):

- Phiên chỉ có ở một máy: chép sang máy kia, kèm thư mục đi kèm (nhật ký lệnh, phiên con) và các file đính kèm (blob) phiên đó dùng. Chỉ đổi đúng dòng đầu của file (thư mục làm việc `cwd` thành đường dẫn project của máy nhận); mọi byte khác giữ nguyên, giờ sửa file giữ nguyên.
- Phiên có ở cả hai máy và một bên là phần đầu của bên kia (cùng cuộc trò chuyện, một bên đi tiếp): chép bản dài đè lên bản ngắn. Hai bản cùng độ dài thì so sha256; khác nội dung thì coi là khác nhau.
- Hai bản đã khác nhau (không bản nào là phần đầu của bản kia): không đụng vào cả hai, chỉ báo `phiên <mã> đã khác nhau ở hai máy, giữ nguyên cả hai`.
- Phiên vừa được ghi trong 30 giây gần nhất (đang chat) thì bỏ qua, lần sau đồng bộ tiếp (chép đúng đến chỗ đã quét, không chép phần omp ghi thêm giữa chừng). Phiên trống (chưa có tin nhắn) không chép.
- Không bao giờ xóa gì ở cả hai máy, không đụng `agent.db` và các file dữ liệu khác của omp. Chạy lại ngay thì không chép gì thêm.
- Trên box, phiên chép từ laptop có thêm một file nhỏ `<tên phiên>.fcode-origin` (nội dung `laptop`) để app ghi nhãn "laptop"; không ghi gì vào chính file phiên.
- Nhớ đẩy code lên GitHub (`git push`) trước khi sang máy kia làm tiếp: phiên chỉ mang cuộc trò chuyện, không mang code.

Ghi chú ở thư mục gốc project: cùng lượt đồng bộ này chép hai chiều các file `HANDOFF*.md`, `CLAUDE.md`, `AGENTS.md`, `WORKFLOW.md`, `agent_state.md`, `TASK.md`, `CLAUDE.local.md`, **chỉ khi git không theo dõi file đó ở cả hai máy** (file git đã theo dõi đi qua git, không đi qua đây). Máy nhận tự thêm tên file vào `.git/info/exclude` (không sửa `.gitignore`) để file không hiện thành thay đổi và không làm vướng việc tự cập nhật code trên box. File nào chỉ một bên sửa từ lần đồng bộ trước thì chép sang bên kia; cả hai bên cùng sửa thì giữ nguyên và báo `handoff <file> khác nhau ở hai máy, giữ nguyên cả hai`. Trạng thái nằm ở `%LOCALAPPDATA%\fcode\handoff-state.json`. File bị xóa ở một bên thì không bị xóa ở bên kia (lần sau nó được chép lại). Khi git bắt đầu theo dõi một file mà fcode đã chép và giấu bằng `.git/info/exclude` (ví dụ file đó được đưa vào kho), fcode thôi đồng bộ file đó, chỉ gỡ đúng dòng `/<tên file>` do chính nó đã thêm (các dòng khác giữ nguyên), và báo một dòng `ghi chú <file> giờ do git theo dõi (trên <máy>): bản cũ trên <máy kia> xóa được`; fcode không bao giờ tự xóa bản cũ, bạn xóa tay rồi `git pull` để cập nhật code. Dòng này cũng hiện ở đầu menu `fcode` cho tới lần đồng bộ sau.

Tự động và box nghỉ: box gói miễn phí tự nghỉ sau 30 phút không dùng, và mỗi lần mở kết nối tới box đều tính là có người dùng. Vì vậy tự động chạy kiểu thưa: mỗi 10 phút nó chỉ hỏi `instabox ls` xem box có đang chạy không (không bao giờ đánh thức box). Box không chạy thì thôi. Box vừa chuyển từ nghỉ sang chạy thì đồng bộ ngay một lần. Còn lại, chỉ đồng bộ khi lần mở kết nối gần nhất (của bất kỳ lần chạy nào, kể cả chạy tay) đã cách từ **40 phút** trở lên, tức là lâu hơn 30 phút box tự nghỉ, nên box không ai dùng vẫn luôn được nghỉ. Lần bị lỗi cũng chỉ chờ đến mốc 40 phút sau, không thử lại dồn dập. Mỗi lần gửi lên box được chia thành từng đợt tối đa khoảng 50 MB (mỗi đợt một kết nối), nên đường truyền chậm hoặc bị ngắt giữa chừng thì các đợt đã gửi xong vẫn nằm trên box và lần sau làm tiếp phần còn lại. Thay đổi ở laptop hoặc ở box nhờ vậy sang bên kia chậm nhất sau khoảng 40 phút; muốn ngay thì gõ `fcode phien`. Chạy tay và chạy tự động dùng chung một khóa nên không giẫm lên nhau (chạy tay chờ lượt tự động xong). Lý do và kết quả ghi ở `%USERPROFILE%\.fcode\phien.log`.

Khi omp đổi định dạng phiên (sau khi omp cập nhật): phiên có dòng đầu không đọc được hoặc `version` lạ (hiện chỉ hiểu version 3) **không được chép** và lần chạy báo `omp đổi định dạng phiên (version X) — chưa đồng bộ, báo Claude`; phiên cũ vẫn đồng bộ bình thường. Mỗi lần chạy ghi `%LOCALAPPDATA%\fcode\phien-status.json` (giờ chạy, kết quả, số file chép, phiên lạ, phiên bản omp hai máy, ghi chú đã chép và xung đột). Menu `fcode` hiện một dòng cảnh báo vàng ở đầu khi có phiên định dạng lạ hoặc lần tự động gần nhất bị lỗi. Hai máy khác phiên bản omp thì vẫn đồng bộ phiên đúng định dạng và thêm dòng `omp laptop <a> khác box <b>`.
### Cài lệnh fcode trên máy Windows khác

Mở **Windows PowerShell**: bấm nút **Start**, gõ `PowerShell`, bấm Enter (không cần chạy bằng quyền admin). Rồi dán đúng một dòng này và bấm Enter:

```powershell
irm https://raw.githubusercontent.com/brooklyn96/fcoding/main/laptop/install.ps1 | iex
```

Lệnh cài sẽ lần lượt làm các việc sau, mỗi việc một dòng trên màn hình:

1. Chép lệnh `fcode` vào `%USERPROFILE%\.local\bin` và thêm thư mục đó vào PATH của bạn.
2. Cho phép PowerShell chạy lệnh `fcode` (chế độ RemoteSigned, chỉ áp dụng cho tài khoản của bạn). Nếu máy công ty khóa việc này bằng chính sách của quản trị viên, lệnh cài báo `✗` ở dòng "Lệnh fcode" và bạn cần nhờ quản trị viên cho phép chế độ RemoteSigned (khi đó `fcode.cmd` cũng không chạy được). Nếu không bật được vì lý do khác, gõ `fcode.cmd` thay cho `fcode`.
3. Tạo file cấu hình `%USERPROFILE%\.fcode\config.json` nếu chưa có (có rồi thì giữ nguyên).
4. Kiểm tra **GitHub CLI** (`gh`). Máy chưa có thì tự cài. Nếu Windows hỏi quyền, bấm **Yes**; bấm No cũng được, lệnh cài sẽ tự thử cách khác không cần quyền admin.
5. Kiểm tra **instabox**. Máy chưa có thì tải thẳng bản Windows từ trang chính thức của instabox và kiểm tra mã SHA256 của file. Không cần cài Node.js.
6. Hướng dẫn bạn đăng nhập, **chỉ với phần chưa đăng nhập**. Bạn không phải gõ mật khẩu vào cửa sổ này.

Bạn đăng nhập tối đa hai lần, theo thứ tự:

- **Bước 1/2, instabox**: trình duyệt mở ra, bạn đăng nhập rồi quay lại cửa sổ PowerShell. Nếu trình duyệt không mở, gõ `instabox login --device` và làm theo mã hiện ra.
- **Bước 2/2, GitHub**: GitHub hiện một mã 8 ký tự (dạng `ABCD-1234`). Chép mã đó, bấm Enter, dán mã vào trang GitHub vừa mở rồi bấm **Authorize**.

Cuối cùng có bảng kết quả, mỗi dòng là `✓` (xong) hoặc `✗` kèm việc cần làm. Gặp `✗` thì làm theo dòng đó rồi chạy lại đúng lệnh trên; chạy lại bao nhiêu lần cũng an toàn và chỉ làm phần còn thiếu. Xong thì **mở cửa sổ PowerShell mới** (Start, gõ `PowerShell`, Enter) rồi gõ `fcode help` để xem danh sách lệnh.

Nếu bạn đã tải kho mã này về máy, chạy `powershell -ExecutionPolicy Bypass -File .\laptop\install.ps1` trong thư mục kho mã cũng được.

**Sửa file cấu hình.** Mở `%USERPROFILE%\.fcode\config.json` bằng Notepad:

```json
{
  "instabox": "",
  "box": "coder",
  "syncRepos": ["C:/Users/ten-ban/code/du-an-1", "C:/Users/ten-ban/code/du-an-2"],
  "ipaRepo": "brooklyn96/fcoding",
  "ipaTag": "latest"
}
```

- `box`: tên box mà `fcode` sẽ vào (mặc định `coder`).
- `syncRepos`: các thư mục trên máy mà `fcode sync` cập nhật. Viết dấu gạch chéo `/` giữa các thư mục (hoặc gấp đôi dấu `\`), mỗi thư mục trong dấu ngoặc kép, cách nhau bằng dấu phẩy. Để trống `[]` nếu chưa dùng.
- `instabox`: đường dẫn đầy đủ tới `instabox.exe`. Để trống `""` là máy tự tìm.
- `ipaRepo`, `ipaTag`: nơi `fcode ipa` lấy file cài app iPhone. Thường không cần đổi.

File này chỉ do bạn sửa; lệnh cài không bao giờ ghi đè nó. Danh sách đầy đủ các lệnh: gõ `fcode help`.

## 9. Bảo mật

**Ghép máy bảo vệ điều gì.** Địa chỉ công khai ai cũng mở được, nhưng chỉ trang `fcoding ok` ở địa chỉ gốc là không cần đăng nhập. Mọi chức năng khác (xem màn hình, gửi chữ, tạo hoặc xóa phiên) đều đòi một mã thiết bị mà chỉ iPhone đã ghép mới có. Để ghép, phải có mã 6 số, và mã chỉ do người có quyền chạy lệnh trên box, hoặc một iPhone đã ghép (**Cài đặt → Thêm thiết bị**), tạo ra.

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
2. Gỡ máy bị mất bằng `--revoke <id>` (hoặc `--revoke all` nếu không chắc máy nào). Gỡ máy nào thì các mã ghép máy đó đã tạo cũng bị hủy ngay (`--revoke all` hủy mọi mã đang chờ). Nhớ xem lại danh sách thiết bị: nếu máy bị mất đã kịp ghép thêm máy khác thì gỡ cả máy đó.
3. Nếu nghi ngờ nặng hơn, đổi `cookieSecret` như trên để gỡ tất cả thiết bị (mọi mã đang chờ cũng bị hủy).
4. Vào các phiên đang chạy từ laptop và kiểm tra xem có lệnh nào lạ không.

## 10. Phát triển

- Máy chủ dùng **Node 22**, chỉ thư viện có sẵn (không `npm install`). Toàn bộ nằm trong `server.mjs`.
- Hợp đồng giữa máy chủ và app nằm trong [`CONTRACT.md`](CONTRACT.md) (các mục A1 đến A7 là các thay đổi theo thời gian; mục A4 thay mật khẩu bằng ghép máy, A5 thêm hộp thư tổng quan, A6 thêm màu cho màn hình, A7 ghép thêm máy bằng mã QR).
- Chạy thử trên máy bất kỳ, kể cả Windows (dùng tmux giả, không cần tmux):

  ```sh
  node --test test/server.test.mjs
  ```

- Thử với tmux thật, trên máy Linux có `tmux`, `node 22`, `curl` (script dùng socket tmux riêng nên không đụng phiên của bạn):

  ```sh
  bash test/tmux-integration.sh
  ```

- **App iOS** nằm trong thư mục `ios/` (SwiftUI, iOS 16 trở lên). Dự án Xcode được sinh bằng **XcodeGen** từ `ios/project.yml`. GitHub Actions (`.github/workflows/ios.yml`, máy macOS) dựng app **không ký** rồi đóng gói `fcode.ipa`. Khi chạy trên nhánh `main`, workflow đăng bản này lên bản phát hành trước (pre-release) tên **`latest`**. Việc ký được làm trên máy bạn, bằng Sideloadly. Hướng dẫn dùng app chi tiết hơn có trong [`ios/README.md`](ios/README.md).
