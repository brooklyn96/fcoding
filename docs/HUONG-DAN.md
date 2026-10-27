# FCode — Hướng dẫn chi tiết

Đây là bản đầy đủ. Muốn đọc nhanh, xem [README.md](../README.md).

## Mục lục

1. [FCode là gì](#1-fcode-là-gì)
2. [Cách hoạt động](#2-cách-hoạt-động)
3. [Cài máy chủ trên box](#3-cài-máy-chủ-trên-box)
   - [Danh sách dự án](#danh-sách-dự-án)
   - [Màn hình chính: hạn mức, chi phí, dự án](#màn-hình-chính-hạn-mức-chi-phí-dự-án)
4. [Mở link công khai](#4-mở-link-công-khai)
5. [Cài app lên iPhone bằng Sideloadly](#5-cài-app-lên-iphone-bằng-sideloadly)
6. [Ghép iPhone với box](#6-ghép-iphone-với-box)
   - [Ghép thêm iPhone bằng mã QR](#ghép-thêm-iphone-bằng-mã-qr)
   - [Xem và gỡ thiết bị](#xem-và-gỡ-thiết-bị)
7. [Dùng hằng ngày](#7-dùng-hằng-ngày)
   - [Thêm dự án từ app](#thêm-dự-án-từ-app)
   - [Gửi ảnh trong chat](#gửi-ảnh-trong-chat)
8. [Dùng từ laptop](#8-dùng-từ-laptop)
   - [Lệnh `fcode` (tùy chọn)](#lệnh-fcode-tùy-chọn)
   - [Đồng bộ phiên chat omp giữa laptop và box (`fcode phien`)](#đồng-bộ-phiên-chat-omp-giữa-laptop-và-box-fcode-phien)
   - [Tự đồng bộ khi mở agent (`fcode moc`)](#tự-đồng-bộ-khi-mở-agent-fcode-moc)
   - [Cài lệnh fcode trên máy Windows khác](#cài-lệnh-fcode-trên-máy-windows-khác)
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
- **Gửi ảnh trong chat** (v1.3.3): chụp ảnh hoặc chọn ảnh từ thư viện rồi gửi cho trợ lý ([xem mục 7](#gửi-ảnh-trong-chat)).
- **Laptop tự đồng bộ khi mở agent** (v1.3.3): bật một lần bằng `fcode moc bat` ([xem mục 8](#tự-đồng-bộ-khi-mở-agent-fcode-moc)).
- Chưa có: hội thoại **Claude Code** và **Codex** chưa được mang qua lại giữa laptop và box (hiện chỉ phiên omp và ghi chú dự án đi theo).

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
5. Cài bộ tự cập nhật omp, Claude Code, Codex (timer chạy mỗi 6 giờ; cần `sudo` không mật khẩu, thiếu thì chỉ cảnh báo và việc cài vẫn tiếp tục). Chi tiết trong [`box/README.md`](../box/README.md).
6. Tạo dịch vụ systemd của người dùng tên **`fcoding`**, bật chạy cùng hệ thống, tự chạy lại khi lỗi, rồi khởi động ngay. Cổng mặc định là **7681**.

**Cập nhật:** vào thư mục `fcoding`, chạy `git pull` rồi `bash install.sh` lại (script khởi động lại dịch vụ). Từ v1.3.4, khi cập nhật `fcode` ở laptop, hãy cập nhật server trên box như vậy (tốt nhất là cập nhật box trước). Dù box chạy server bản nào, trước khi gỡ dòng ghi chú của mình trong `.git/info/exclude` của một dự án, fcode trên box luôn bảo đảm trong thư mục `.fcode` của dự án đó và của mọi dự án khác trong `config.json` của box dùng chung file `.git/info/exclude` đó (worktree của cùng một kho, hoặc dự án là thư mục con của kho) có file `.gitignore` chỉ gồm dòng `*` (tạo thư mục `.fcode` nếu chưa có, đúng thư mục server mới dùng để chứa ảnh; file đó nếu có nội dung khác thì được thay bằng đúng dòng `*`, giống như server mới làm; không đi qua liên kết, và nếu `.fcode` hoặc file đó ở một dự án nào trong số đó là liên kết, hoặc git trên box không trả lời, thì fcode chưa gỡ, lần sau thử lại); lý do: nếu box vẫn chạy server bản 1.3.3 thì nhờ file này ảnh gửi từ app vẫn được giấu khỏi git, kể cả khi dòng `/.fcode/` mà server cũ thêm bị mất trong lúc gỡ. Vì thế thư mục `.fcode` có thể xuất hiện trong một dự án chưa từng nhận ảnh, kể cả dự án khác dùng chung file `.git/info/exclude`; git không hiện nó. Cập nhật server trên box vẫn là cách nên làm: server mới không ghi vào `.git/info/exclude` nữa.

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

Các dự án hiện trong app nằm trong `config.json`, mục `projects`. Sau lần cài đầu mục này **trống**, nên nút **+** trong app báo "Chưa có dự án nào trong cấu hình máy chủ" cho tới khi bạn thêm dự án. Cách thêm: bấm **+** rồi **Thêm dự án** trong app (xem [Thêm dự án từ app](#thêm-dự-án-từ-app)), hoặc chạy `fcode add <chủ/repo>` trên laptop (xem [mục 8](#8-dùng-từ-laptop)), hoặc sửa `config.json` trên box như dưới đây. Mỗi dự án là một tên và một đường dẫn tuyệt đối trên box:

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
| Máy staging của dự án (đang chạy / đang nghỉ) | `instabox ls --json` (cần khóa instabox, xem dưới) | mỗi 30 giây |
| Định dạng phiên omp, phiên bản omp | `omp --version` và dòng đầu các file phiên mới nhất trong `~/.omp/agent/sessions` | mỗi 10 phút |
| Giờ box ngủ | ước tính: lần box thức dậy gần nhất + 8 giờ (vẫn giữ đúng khi máy chủ khởi động lại, nhờ file `~/.fcoding/box-timer.json`; box khởi động lại thì tính lại từ đầu) | luôn |

- Mở phiên mới (nút "+" hoặc `fcode-new`) thì box chạy `fcode-git-sync <dự án>` trước và chờ tối đa 8 giây, để thẻ dự án có số commit "chậm / chưa đẩy" mới nhất. Lệnh này chỉ `fetch` và đếm lại, không bao giờ đổi thư mục làm việc (chỉ timer 5 phút của box mới tự kéo nhánh chính về khi nhánh đó rảnh và sạch; nó không đụng nhánh khác, không stash, không reset, không push). Cập nhật code ở các trường hợp còn lại là việc của agent (luật "Sync first"). Thẻ dự án có thêm `autoUpdated` / `autoSkip` để biết timer đã tự kéo hay vì sao không. Thiếu lệnh, lệnh lỗi hay quá 8 giây thì phiên vẫn được tạo (máy chủ chỉ ghi một dòng nhật ký). Máy chủ không bao giờ tắt tiến trình đồng bộ; nó tự chạy xong, và mở phiên khác cùng dự án lúc đó dùng chung lần đồng bộ đang chạy.
- Phiên omp gần đây của một dự án (app: "Phiên omp gần đây", nút "Tiếp tục"): `GET /api/projects/<dự án>/omp-sessions` liệt kê tối đa 10 phiên omp mới nhất có nội dung, lấy từ `~/.omp/agent/sessions/<tên thư mục mã hóa>/`. Máy chủ chỉ đọc hai dòng đầu mỗi file (tiêu đề và phần đầu), không bao giờ đọc nội dung tin nhắn. Phiên do laptop đồng bộ sang có file đánh dấu `<tên>.fcode-origin` nên hiện thẻ "laptop". Nút "Tiếp tục" (`POST .../omp-sessions/<id>/resume`) mở phiên tmux `<dự án>-omp-r-<8 ký tự cuối của id>` chạy `omp -r <id>`; bấm lại thì vào lại đúng phiên đó.
- Máy staging: nút "Bật" trong app chạy `instabox start <tên dự án> --no-wait` trên box (chỉ khi có máy tên trùng tên dự án trong `instabox ls`; không bao giờ dừng, xóa hay tạo máy). Cần khóa instabox: tạo file `~/.config/fcode/instabox.env` (chmod 600) chỉ có một dòng `export INSTABOX_API_KEY=...`, rồi `systemctl --user restart fcoding`. Dịch vụ chỉ đọc đúng dòng đó như chữ (không chạy file), không ghi khóa ra nhật ký, và không để khóa lọt vào các phiên tmux. Không có file thì app không hiện trạng thái staging.
- Bảo vệ định dạng: máy chủ chỉ hiểu phiên omp có `version` 3 (`KNOWN_VERSIONS` trong `server.mjs`, laptop dùng cùng danh sách). Khi omp cập nhật và đổi định dạng (phiên mới có version khác, header hỏng, hoặc omp đổi cách đặt tên thư mục), `GET /api/home` trả `omp.formatOk: false` kèm `reason`, danh sách phiên bỏ qua các phiên lạ, và app sẽ nhắc cập nhật FCode.
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

Hướng dẫn đầy đủ cho app nằm ở [ios/README.md, mục 4](../ios/README.md#4-cách-dùng). Tóm tắt:

**Màn hình chính** (thanh trên cùng chỉ có nút **?** Hướng dẫn và **⚙** Cài đặt). Phiên tự cập nhật mỗi 5 giây, hạn mức và dự án mỗi phút; kéo xuống để cập nhật ngay.

- **Vòng giờ box** (bên trái thẻ trên cùng): **Sleeps in** là thời gian box còn chạy trước khi tự nghỉ (tối đa 8 giờ, hoặc sớm hơn nếu rảnh 30 phút; đây là ước tính của máy chủ). Vòng chuyển vàng khi còn dưới 10 phút. **Wakes in** hiện khi box vừa nghỉ vì đã chạy đủ 8 giờ: lúc đó box chưa đánh thức lại được trong khoảng 10 phút. Chạm vào vòng để xem giờ chính xác. Về giờ nghỉ của box: box tự nghỉ khi 30 phút không ai dùng, và một box đang nghỉ tự dậy khi có thứ gì dùng tới nó (một lệnh, file, SSH, hoặc mở link công khai của nó, tức là app); đo thực tế, lần gửi đầu tiên tới link khi box đang nghỉ được trả lời sau khoảng 4 giây, không báo lỗi. Một lần chạy liền tối đa 8 giờ, hết thì box nghỉ. Box nghỉ bằng tay (`instabox suspend`) thì nằm yên cho tới khi bạn bật lại bằng tay. Box nghỉ chỉ tính tiền chỗ lưu trữ.
- **Ô hạn mức** (bên phải): mỗi lần một tài khoản, tự chuyển sang tài khoản kế mỗi 4 giây (giữ ngón tay trên ô để dừng). Chạm để mở màn hình **Hạn mức**.
- Dòng **đang chạy · chờ bạn**: chạm để nhảy tới phiên tương ứng.
- **Dự án** (trượt ngang): mỗi thẻ cho biết số PR đang mở, kết quả checks và lần deploy gần nhất ("đang đọc…" khi máy chủ vừa khởi động, "chưa đọc được GitHub" khi `gh` lỗi). Chạm thẻ để chỉ xem phiên của dự án đó; giữ lâu hoặc bấm **…** để mở phiên mới trong dự án đó.
- **Cần bạn**: phiên đang hỏi bạn, luôn mở sẵn. Câu hỏi có/không có nút **y · Đồng ý** và **n · Từ chối**; câu khác có nút **Trả lời**. Nút **Mở** mở phiên.
- **Đang chạy** và **Đang nghỉ**: chạm tiêu đề để mở hoặc thu gọn. App nhớ lựa chọn này.
- Chấm xanh dương cạnh tên phiên: có thay đổi bạn chưa xem. Mở phiên là tính đã đọc.
- Vuốt trái một phiên: **Đổi tên** hoặc **Đóng** (có hỏi xác nhận; chương trình trong phiên bị tắt).

**Tạo phiên mới**: bấm nút tròn **+** ở góc dưới bên phải. Chọn dự án, rồi chọn chương trình (omp, claude hoặc codex). Nút này luôn tạo phiên **mới** (tên như `web-claude`, `web-claude-2`, …) và không bao giờ mở lại phiên cũ; muốn vào phiên cũ thì mở từ danh sách. App không còn liệt kê shell, dù máy chủ vẫn chạy được shell. Dự án chưa có trong danh sách thì thêm bằng **Thêm dự án** ([xem bên dưới](#thêm-dự-án-từ-app)).

**Phiên omp gần đây và máy staging** (v1.3.2): trong một dự án, mục **Phiên omp gần đây** liệt kê các phiên omp mới nhất của dự án (cả phiên đồng bộ từ laptop, có thẻ "laptop"); bấm **Tiếp tục** để mở lại đúng phiên đó. Thẻ dự án có máy staging (máy instabox cùng tên dự án) thì có nút **Bật** để đánh thức máy đó. Chi tiết và cách cài khóa instabox nằm ở mục 3, "Màn hình chính".

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
| "Ảnh quá lớn" | Ảnh còn lớn hơn 10 MB dù đã thu nhỏ; chọn ảnh khác. |
| "Ảnh không đọc được" | Chọn lại một ảnh khác. |
| "Phiên đã đóng" (khi gửi ảnh) | Phiên đã thoát; mở lại phiên rồi gửi lại. |
| "Không gửi được ảnh, thử lại" | Kiểm tra mạng rồi gửi lại. Cũng hiện khi box đang nhận ảnh khác và từ chối ảnh này; đợi vài giây rồi gửi lại. |
| "Đang gửi ảnh khác, thử lại sau" | Box đang nhận ảnh khác; đợi vài giây rồi gửi lại. |
| "Không tải được ảnh, thử lại" | Ảnh chưa lấy hoặc chưa xử lý xong sau 60 giây; chọn hoặc chụp lại. |
| "Không kết nối được máy chủ." | Kiểm tra mạng, địa chỉ máy chủ và dịch vụ `fcoding` trên box. |

### Thêm dự án từ app

Từ v1.3.2, bạn thêm dự án GitHub vào box ngay trên iPhone, không cần laptop:

1. Bấm nút **+**, chọn **Thêm dự án**.
2. Dán link repo GitHub (`https://...`, `git@github.com:...` hoặc `chủ/repo` đều được), **hoặc** chọn một repo trong danh sách **Hoặc chọn repo** (có ô tìm; repo đã có trên box hiện "đã có trên box", repo chỉ-đọc hoặc đã lưu trữ thì bị làm mờ). Danh sách là 300 repo mới nhất, làm mới mỗi 60 giây. Ô **Tên** là tùy chọn, mặc định là tên repo viết thường.
3. Bấm **Thêm**. Box tải repo về `/data/workspace/<tên>`, cài một chốt chặn không cho đẩy thẳng lên `main` hoặc `master`, tạo một nhánh thử tạm `box/fcode-add-check-…` để chứng minh box ghi được rồi xóa nhánh đó, sau đó thêm dự án vào danh sách. Dự án hiện ra ngay lần tải lại đầu tiên (lúc đầu ghi "đang đọc…").

**Khóa GitHub.** Box thử token GitHub của chính nó trước; chỉ một lần đẩy thử thật mới quyết định token có ghi được hay không. Nếu token không ghi được, app hiện một **khóa công khai**: trên GitHub mở repo, vào **Settings → Deploy keys → Add key**, dán khóa, tick **Allow write access**, bấm **Add key**, rồi quay lại app bấm **Thử lại**. Mỗi repo một khóa.

**Lỗi có thể gặp** (mã app / mã thoát của script, cùng bộ mã cho `fcode add`):

| Mã (thoát) | Ý nghĩa và cách xử lý |
|---|---|
| `NEED_KEY` (40), `NEED_WRITE` (41) | Cần dán khóa công khai vào **Deploy keys** của repo (có tích ghi), rồi thử lại. |
| `WRITE_BLOCKED` (42) | Luật bảo vệ nhánh chặn `box/*`: hãy cho phép `box/*`. |
| `NET_FAIL` (43) | Lỗi mạng; thử lại. |
| `REPO_ARCHIVED` (44) | Repo đã lưu trữ (archived), không ghi được. |
| `DIR_CONFLICT` (11) | `/data/workspace/<tên>` đã có trên box hoặc không an toàn (liên kết tượng trưng, nằm ngoài thư mục làm việc). Box không bao giờ dùng lại thư mục có sẵn: chọn tên khác, hoặc xóa thư mục đó trên box. |
| `NAME_USED` (23), `CFG_CONFLICT` (21), `CFG_BROKEN` (22) | Tên hoặc cấu hình đang dùng cho dự án khác, hoặc file cấu hình/ssh trên box hỏng; đổi tên hoặc sửa trên box. |
| `CLONE_FAIL` (12) | Không tải được repo (xem dòng chi tiết). |
| `KEY_FAIL` (20), `ALIAS_FAIL` (21) | Box không tạo được khóa SSH hoặc không ghi được cấu hình SSH. |
| thoát 24 | Không cài được chốt chặn push lên `main`. |
| thoát 25 | Box không ghi được cấu hình đăng nhập GitHub cho repo này. |
| thoát 26 | Cấu hình git trên box đang chuyển hướng địa chỉ GitHub (`insteadOf`, `pushInsteadOf`, `pushurl`): gỡ trên box rồi chạy lại. |
| `ADDED_WARN` (30) | Đã thêm nhưng có mục cần xem lại, ví dụ không xóa được nhánh thử `box/fcode-add-check-…` (xóa nhánh đó trên GitHub). Dự án vẫn dùng được. |
| `TIMEOUT` (124 / 137) | Quá 10 phút nên bị dừng; chạy lại là an toàn. |

Thêm lại một dự án đã có (cùng tên, cùng repo) không làm gì và báo thành công (`ADDED`, thoát 0).

**Làm tay trên box**: `timeout --kill-after=30 600 bash /data/home/fcoding/fcode-add.sh <chủ/repo> <tên>` (script do `install.sh` cài; tự nó không có giới hạn thời gian, nên lệnh làm tay cần `timeout` như trên). Giới hạn 10 phút tự động chỉ áp dụng khi thêm từ app và bằng `fcode add`; thêm lỗi chỉ xóa thư mục do chính lần đó tạo ra, thư mục có sẵn từ trước không bao giờ bị xóa; thêm lại cùng một repo là an toàn. Cách làm tương đương trên laptop: `fcode add <chủ/repo> [tên]`.

### Gửi ảnh trong chat

Từ v1.3.3, bạn gửi ảnh cho trợ lý ngay trong phiên, ví dụ chụp một màn hình lỗi:

1. Trong phiên, chạm **nút bàn phím** để mở ô nhập, rồi bấm **nút ảnh** (hình bức ảnh) bên trái ô.
2. Chọn **Chụp ảnh** (mở camera; không hiện nếu máy không có camera) hoặc **Chọn ảnh** (chọn một ảnh trong thư viện). Lần đầu chụp, iPhone hỏi quyền camera: bấm **OK**. Lỡ từ chối thì lần sau bấm **Chụp ảnh**, app báo `Camera đang bị tắt cho FCode: vào Cài đặt → FCode → bật Camera`: vào **Cài đặt → FCode → bật Camera** rồi chụp lại.
3. App hiện `Đang gửi ảnh…`. Khi xong, app báo `Đã gắn ảnh — gõ lời nhắn rồi gửi`: đường dẫn ảnh đã nằm sẵn trong ô nhập của trợ lý, nhưng **chưa gửi** (app không tự bấm Enter). Trong lúc ảnh đang gửi, nút **Gửi** và nút ảnh tạm không bấm được (vẫn gõ chữ được), để tin nhắn không chạy trước ảnh. Muốn bỏ ảnh đó thì chạm vào dòng `Đang gửi ảnh…` khi còn dấu **×** ở cuối dòng (VoiceOver đọc gợi ý `Chạm để huỷ ảnh`, rồi báo `Đã huỷ ảnh`); nút **Gửi** dùng lại được ngay. Chỉ huỷ được trước khi ảnh bắt đầu gửi lên box; sau đó dấu × biến mất và chạm không còn tác dụng.
4. Gõ lời nhắn của bạn (ví dụ "sửa lỗi trong ảnh này") rồi gửi như bình thường.

Chi tiết cần biết:

- App tự thu nhỏ ảnh (cạnh dài tối đa 2048 điểm ảnh) và đổi mọi định dạng (kể cả HEIC) sang JPEG trước khi gửi. Ảnh vẫn lớn hơn 10 MB sau khi thu nhỏ thì bị từ chối (`Ảnh quá lớn`).
- Ảnh được lưu trên box ở thư mục `.fcode/uploads` trong dự án. FCode tự giấu thư mục này khỏi git bằng một file `.gitignore` nằm ngay trong `.fcode` (chỉ có dòng `*`), không sửa file nào của dự án hay của git, nên ảnh không hiện thành thay đổi và không bị đưa lên GitHub; dự án nằm trong thư mục con của một kho git lớn hơn cũng được giấu. Nếu bản cũ (1.3.3) đã thêm dòng `/.fcode/` vào `.git/info/exclude` thì dòng đó cứ để đó, không sao.
- Ảnh cũ hơn 7 ngày bị xoá vào lần kế tiếp bạn gửi ảnh vào dự án đó (không gửi ảnh vào dự án đó thì chưa xoá).
- Box nhận tối đa hai ảnh cùng lúc; ảnh thứ ba bị từ chối. Vì box đóng kết nối mà không đọc ảnh bị từ chối, thường app chỉ thấy lỗi mạng và báo `Không gửi được ảnh, thử lại` chứ không phải `Đang gửi ảnh khác, thử lại sau` (câu này chỉ hiện khi app nhận được câu trả lời của box). Cả hai trường hợp: đợi vài giây rồi gửi lại, gửi lại là được.
- Nếu app báo `Không tải được ảnh, thử lại` thì ảnh chưa lấy hoặc chưa xử lý xong sau 60 giây (từ thư viện hoặc từ camera): chọn hoặc chụp lại.
- Nếu app báo `Đã lưu ảnh nhưng chưa gắn được vào phiên` thì ảnh đã được lưu nhưng đường dẫn chưa vào được ô nhập (thường vì đường dẫn dự án có dấu cách). Bạn vẫn dùng được ảnh, chỉ cần nhờ trợ lý đọc ảnh mới nhất trong `.fcode/uploads`.

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
- `fcode sync`: kéo code mới của các project trong `syncRepos` về laptop, chỉ cập nhật khi đang ở main và không có thay đổi chưa lưu; liệt kê nhánh box và PR chờ merge. Lệnh cũng liệt kê các project có trên box nhưng chưa có trên laptop, rồi giúp bạn thêm từng project:
  - Tìm sẵn các bản clone đã có trên máy (Desktop kể cả OneDrive, Documents, `source\repos`, thư mục người dùng và thư mục cha của các thư mục trong `syncRepos`; tối đa 15 giây, in ra đã tìm ở đâu).
  - Hỏi bạn xác nhận hoặc chọn một thư mục tìm thấy, hoặc dán đường dẫn khác (mặc định `Desktop\<tên>`). Thư mục phải là git và có cùng origin GitHub với project; thư mục trống hoặc chưa có thì được clone về.
  - Thư mục được thêm vào `syncRepos` trong `%USERPROFILE%\.fcode\config.json` và đồng bộ ngay một lần.
  - Nếu đã đặt biến `FCODE_SYNC_REPOS` thì bước này được bỏ qua.
- `fcode add <chủ/repo> [tên]`: thêm một dự án GitHub vào box để omp làm việc và hiện trong danh sách của app. Lệnh chạy script đã cài sẵn trên box: nếu token GitHub của box ghi được thì xong luôn, không cần khóa. Nếu không, lệnh hiện khóa công khai kèm các bước dán vào trang GitHub của repo, chờ bạn bấm Enter rồi thử lại. Nếu box chưa có script, lệnh báo `cd ~/fcode-src && git pull && bash install.sh` (chạy trên box). Xong lệnh gợi ý chạy `fcode sync` để có project này cả trên laptop.
- `fcode pair [tên thiết bị]`: tạo mã ghép kèm mã QR cho iPhone mới (cần `publicUrl`, xem [mục 6](#ghép-thêm-iphone-bằng-mã-qr)).
- `fcode ipa`: tải bản app mới nhất về `Downloads\fcode.ipa`. Khi có bản mới, kéo file này vào Sideloadly và bấm Start; việc tự ký lại 7 ngày của Sideloadly chỉ gia hạn bản đang cài, không tự cập nhật. Không có `fcode` thì tải `fcode.ipa` từ **Releases** trên GitHub.

Thoát bằng **Ctrl+B** rồi **D**, phiên vẫn chạy tiếp.

### Đồng bộ phiên chat omp giữa laptop và box (`fcode phien`)

Chat omp ở laptop và chat omp ở box nằm ở hai nơi riêng. `fcode phien` chép phiên qua lại giữa hai máy để bên nào cũng thấy phiên của bên kia ngay trong omp: danh sách `/resume`, `omp -c` (phiên mới nhất của thư mục) và `omp -r <mã>`. Phiên chép sang là phiên omp bình thường của máy nhận (omp không biết nó từ máy khác tới), nên không cần lệnh riêng để mở lại.

Điều kiện: project có trong `syncRepos` của laptop (file `%USERPROFILE%\.fcode\config.json`) **và** trong danh sách project của FCode trên box (`fcode add`). Project chỉ có ở một bên thì bỏ qua. Một thư mục trên laptop khớp với project trên box theo tên hoặc theo origin GitHub (ví dụ thư mục `Desktop\New folder (2)` vẫn khớp). Project có trên box mà chưa có trên laptop được báo `project trên box chưa có trên laptop: <tên> (chạy fcode sync để thêm)`; lần chạy tự động không bao giờ hỏi hay clone. Mọi lần chép đều do laptop bắt đầu (box không với tới laptop được).

```sh
fcode phien                # đồng bộ mọi project
fcode phien deal-sync      # chỉ một project
fcode phien --thu          # chạy thử: chỉ liệt kê sẽ chép gì đi đâu, không chép gì (chỉ ghi lại giờ vừa kết nối box)
fcode phien tu-dong bat    # bật tự động (mỗi 10 phút, chạy ngầm, không hiện cửa sổ)
fcode phien tu-dong tat    # tắt tự động (trangthai để xem đang bật hay tắt)
```

Gõ `fcode` rồi bấm `p` trong danh sách cũng mở menu này (đồng bộ ngay, bật hoặc tắt tự động).

Luật đồng bộ (một phiên = một mã = một file `.jsonl` chỉ được nối thêm):

- Phiên chỉ có ở một máy: chép sang máy kia, kèm thư mục đi kèm (nhật ký lệnh, phiên con) và các file đính kèm (blob) phiên đó dùng. Chỉ đổi đúng dòng đầu của file (thư mục làm việc `cwd` thành đường dẫn project của máy nhận); mọi byte khác giữ nguyên, giờ sửa file giữ nguyên.
- Phiên có ở cả hai máy và một bên là phần đầu của bên kia (cùng cuộc trò chuyện, một bên đi tiếp): chép bản dài đè lên bản ngắn. Hai bản cùng độ dài thì so sha256; khác nội dung thì coi là khác nhau.
- Hai bản đã khác nhau (không bản nào là phần đầu của bản kia): không đụng vào cả hai, chỉ báo `phiên <mã> đã khác nhau ở hai máy, giữ nguyên cả hai`.
- Phiên vừa được ghi trong 30 giây gần nhất (đang chat) thì bỏ qua, lần sau đồng bộ tiếp (chép đúng đến chỗ đã quét, không chép phần omp ghi thêm giữa chừng). Phiên trống (chưa có tin nhắn) không chép.
- So từng file một: file chính `.jsonl`, từng file trong thư mục đi kèm và từng blob. File nào máy nhận đã có đủ thì không gửi lại. Hai file chính giống nhau chưa đủ để báo "giống nhau": thiếu blob hay file đi kèm ở máy nhận thì vẫn chép; blob mà cả hai máy đều thiếu thì báo phiên chưa đủ.
- Thứ tự đặt file ở máy nhận: blob, rồi file trong thư mục đi kèm, rồi phiên con, rồi file nhãn `.fcode-origin`, và **file chính sau cùng**. File chính chỉ được đặt (hoặc nối dài) khi mọi file nó cần đã có ở máy nhận; thiếu thì để lần sau và báo `<n> phiên chưa đặt file chính vì file đi kèm chưa đủ, lần sau làm tiếp`. Bị ngắt giữa chừng thì file chính cũ vẫn giữ nguyên.
- Trên box, file phiên đang được một chương trình mở (omp đang chạy phiên đó, xem qua `/proc`) thì không ghi đè, báo `<n> file đang mở trên box`, lần sau làm tiếp.
- Không bao giờ xóa gì ở cả hai máy, không đụng `agent.db` và các file dữ liệu khác của omp. Chạy lại ngay thì không chép gì thêm.
- Trên box, phiên chép từ laptop có thêm một file nhỏ `<tên phiên>.fcode-origin` (nội dung `laptop`) để app ghi nhãn "laptop"; không ghi gì vào chính file phiên.
- Nhớ đẩy code lên GitHub (`git push`) trước khi sang máy kia làm tiếp: phiên chỉ mang cuộc trò chuyện, không mang code.

Ghi chú ở thư mục gốc project: cùng lượt đồng bộ này chép hai chiều các file `HANDOFF*.md`, `CLAUDE.md`, `AGENTS.md`, `WORKFLOW.md`, `agent_state.md`, `TASK.md`, `CLAUDE.local.md`, **chỉ khi git không theo dõi file đó ở cả hai máy và nhánh chính trên GitHub (`origin`) cũng chưa có file đó** (file git đã theo dõi đi qua git, không đi qua đây). Máy nhận tự thêm hai dòng liền nhau vào `.git/info/exclude` (không sửa `.gitignore`): dòng `# fcode`, rồi dòng `/<tên file>`. Nhờ vậy file không hiện thành thay đổi và không làm vướng việc tự cập nhật code trên box. File nào chỉ một bên sửa từ lần đồng bộ trước thì chép sang bên kia; cả hai bên cùng sửa thì giữ nguyên và báo `handoff <file> khác nhau ở hai máy, giữ nguyên cả hai`. Fcode nhớ nội dung đã đồng bộ lần trước trong `%LOCALAPPDATA%\fcode\handoff-state.json` (từ v1.3.4, file này còn nhớ thêm các dòng cũ của bản 1.3.2 và 1.3.3, xem bên dưới). File bị xóa ở một bên thì không bị xóa ở bên kia (lần sau nó được chép lại). Khi git bắt đầu theo dõi một file mà fcode đã chép và giấu bằng `.git/info/exclude` (ví dụ file đó được đưa vào kho), fcode thôi đồng bộ file đó, chỉ gỡ đúng cặp hai dòng `# fcode` và `/<tên file>` do chính nó đã thêm (các dòng khác giữ nguyên), và báo một dòng `ghi chú <file> giờ do git theo dõi (trên <máy>): bản cũ trên <máy kia> xóa được`; fcode không bao giờ tự xóa bản cũ, bạn xóa tay rồi `git pull` để cập nhật code. Dòng này cũng hiện ở đầu menu `fcode` cho tới lần đồng bộ sau. Dòng này chỉ hiện khi fcode đã thật sự gỡ xong dòng giấu (riêng chạy thử `--thu` vẫn in dòng này mà không hỏi git và không gỡ gì; lần chạy thật vẫn có thể ra dòng giữ hoặc dòng lỗi). Nếu việc gỡ báo lỗi (xem "Lỗi của phần ghi chú" bên dưới) thì chỉ hiện dòng lỗi đó: dòng `xóa được` và dòng ở đầu menu chưa hiện, cho tới lần gỡ được. Trên box, fcode chỉ đặt file ghi chú khi chắc chắn git đã giấu file đó (thêm hai dòng `# fcode` và `/<tên file>` nếu cần, và đặt file sau khi hai dòng đã ghi xong); nếu git trên box không trả lời hoặc báo lỗi thì file đó chưa được đặt (lần sau thử lại), để không có file ghi chú nào hiện ra mà chưa được giấu. Nếu git đã giấu file đó sẵn thì không cần ghi gì vào `.git/info/exclude` và file vẫn được đặt. Nếu bạn đã tự có đúng dòng `/<tên file>` thì fcode không thêm cặp dòng của nó. Sau khi thêm (hoặc thấy không cần thêm), fcode hỏi lại git lần nữa và chỉ đặt file khi git trả lời là đã giấu: ví dụ một dòng `!<tên file>` trong `.gitignore` làm dòng trong `.git/info/exclude` mất tác dụng, khi đó file ghi chú chưa được đặt (không in dòng nào, lần sau thử lại). Ở laptop cũng vậy. Khi fcode cần ghi vào `.git/info/exclude` mà file đó (hoặc thư mục `.git/info`) của dự án ở box là một liên kết (symlink) thì box không ghi vào đó và chưa đặt file ghi chú đó: file được tính là bỏ qua, lần đồng bộ nào cũng thử lại và không in dòng nào. Nếu `.git/info/exclude` của dự án ở laptop là một liên kết (symlink) thì fcode không ghi vào đó và chưa đặt file ghi chú đó, rồi báo `[<dự án>] ghi chú <file>: .git/info/exclude là liên kết, fcode không ghi vào đó, chưa đặt` (lần đồng bộ nhanh khi mở agent chỉ ghi dòng này vào phien.log). Các dòng thông báo của phần ghi chú nằm ở mục "Lỗi của phần ghi chú" bên dưới.

**Dòng `# fcode` trong `.git/info/exclude`** (từ v1.3.4):

- Mỗi lần fcode giấu một file ghi chú, ở laptop hay ở box, nó thêm hai dòng liền nhau vào `.git/info/exclude` của máy đó: `# fcode`, rồi `/<tên file>`. Hai dòng được ghi cùng một lần. Nếu git đã giấu file đó rồi, hoặc bạn đã tự có đúng dòng `/<tên file>`, fcode không thêm gì. Cặp này là dấu để fcode biết dòng đó là của nó, kể cả khi mạng đứt giữa chừng.
- Khi git theo dõi file, fcode chỉ gỡ đúng cặp hai dòng đó. Mọi dòng khác của bạn giữ nguyên từng byte, kể cả kiểu xuống dòng và chữ có dấu. Một ngoại lệ nhỏ: nếu file `.git/info/exclude` của bạn không kết thúc bằng dấu xuống dòng, fcode thêm một dấu xuống dòng trước dòng `# fcode` và dấu đó vẫn ở lại sau khi gỡ; git không bị ảnh hưởng gì.
- Dòng `/<tên file>` do bạn tự viết (không có `# fcode` ngay phía trên) thì fcode không bao giờ đụng vào.
- Hai dự án dùng chung một file `.git/info/exclude` (worktree của cùng một kho) thì dùng chung dòng giấu đó. Khi git bắt đầu theo dõi file ở một dự án mà dự án kia vẫn còn bản chưa theo dõi được giấu nhờ dòng đó, fcode chưa gỡ và báo mỗi lần: `[<dự án>] ghi chú <file>: dự án khác cùng kho trên <box|laptop> còn dùng dòng giấu /<file>, fcode chưa gỡ`. Hãy giữ bản cũ của dự án này cho tới khi dự án kia không còn cần dòng đó (file đó vào git, bị xóa, không còn được giấu, hoặc cả hai dự án cùng được gỡ trong một lượt); khi ấy ở một lần chạy sau fcode tự gỡ dòng. Khi thông báo này hiện, dòng `bản cũ … xóa được` không được in cho file đó. Nếu bạn xóa bản cũ ở dự án này, hoặc chạy `git pull` trước, thì fcode không còn gỡ dòng đó nữa: bạn tự xóa hai dòng `# fcode` và `/<tên file>` trong `.git/info/exclude`. Trong lúc đó bản cũ vẫn bị git giấu, `git pull` ở dự án này sẽ ghi đè nó mà không báo. Fcode chỉ hỏi git về dự án đang có file đó ở thư mục gốc; nếu git lỗi hoặc không trả lời khi hỏi, fcode không coi đó là thông báo mà báo lỗi và thử lại ở lần sau. Dự án không có file đó thì không được hỏi và không gây lỗi.
- Bản 1.3.2 và 1.3.3 thêm dòng `/<tên file>` mà không có `# fcode`. Những dòng cũ đó fcode vẫn nhớ trong `handoff-state.json` và gỡ khi đến lúc; gỡ xong thì quên.
- **Đừng xóa riêng dòng `# fcode`.** Nếu bạn xóa riêng, git vẫn giấu file đó, nhưng fcode không còn biết dòng `/<tên file>` là của nó. Khi file vào git, fcode sẽ không gỡ dòng đó, và bản của bạn có thể bị `git pull` ghi đè mà không báo gì.
- Muốn tự quản một dòng: xóa cả hai dòng (git sẽ hiện file đó) hoặc giữ nguyên cả hai.
- Xóa `handoff-state.json` thì được, nhưng fcode quên hai thứ: nội dung đã đồng bộ lần trước (file khác nhau ở hai máy sẽ bị báo là khác nhau) và các dòng cũ của bản 1.3.2 và 1.3.3 (những dòng đó ở lại trong `.git/info/exclude`, fcode không gỡ giúp nữa).

**Lỗi của phần ghi chú.** Dòng lỗi (bốn dòng đầu) làm lần chạy kết thúc với mã lỗi 1; lần nhanh khi mở agent thì màn hình hiện `phien: không đồng bộ được, xem phien.log` và chi tiết nằm ở phien.log. Hai dòng cuối chỉ là thông báo hoặc cảnh báo, mã lỗi giữ nguyên. Bốn dòng bắt đầu bằng `[` được in thụt vào hai khoảng trắng (ở đây bỏ bớt cho dễ đọc).

- `lỗi: không ghi được trạng thái ghi chú (handoff-state.json): <lý do>`: không ghi được file trạng thái. Lần chạy dừng ngay ở đó. Việc đã làm xong vẫn giữ; các dòng `# fcode` đã thêm vẫn còn nên không mất gì.
- `lỗi: không đọc được trạng thái ghi chú (handoff-state.json): <lý do>`: file trạng thái bị hỏng hoặc không đúng dạng (nếu nội dung không bắt đầu bằng `{`, ví dụ là một số, `null`, một danh sách hoặc file trống, thì `<lý do>` là `không phải một đối tượng JSON`; nếu không thì `<lý do>` là lời báo lỗi khi đọc). Lần chạy dừng trước khi đổi bất cứ thứ gì, cho tới khi bạn sửa file hoặc xóa file đó.
- `[<dự án>] lỗi: ghi chú <file>: chưa gỡ được dòng /<file> của fcode trong .git/info/exclude (liên kết, hoặc git lỗi / không trả lời kịp), lần sau thử lại`: ở laptop, xảy ra khi `.git/info/exclude` (hoặc thư mục `.git/info`) là một liên kết nên fcode không ghi vào, hoặc khi git lỗi hay không trả lời lúc fcode kiểm tra xem dự án khác cùng kho (đang có file đó) có còn dùng dòng đó không. Dòng của fcode vẫn còn nguyên (cặp `# fcode` và `/<file>`, hoặc dòng `/<file>` không có `# fcode` của bản 1.3.2 và 1.3.3, cùng với phần fcode nhớ về nó trong `handoff-state.json`) nên lần đồng bộ sau thử gỡ lại; lần này chỉ hiện dòng lỗi; dòng `ghi chú <file> giờ do git theo dõi …` và dòng ở đầu menu chưa hiện, chúng chỉ hiện khi dòng đã được gỡ thật. Giữ bản cũ cho tới khi một lần chạy thật (không phải `--thu`) hiện dòng `xóa được`.
- `[<dự án>] lỗi: ghi chú <file>: box chưa gỡ được dòng /<file> của fcode trong .git/info/exclude (liên kết, git trên box lỗi, hoặc chưa tạo được .fcode/.gitignore), lần sau thử lại`: box không tìm được, không ghi được, hoặc thấy `.git/info/exclude` (hay thư mục `.git/info`) của dự án là một liên kết nên không ghi vào đó, vì vậy chưa gỡ. Box cũng chờ và thử lại khi `.fcode` hoặc file `.gitignore` trong đó (của dự án này hay của dự án khác dùng chung file `.git/info/exclude`) là một liên kết hoặc chưa tạo được, hoặc khi git trên box lỗi hay không trả lời (kể cả lúc kiểm tra xem dự án khác cùng kho có còn dùng dòng đó không). Fcode không quên gì, lần sau thử lại; lần này cũng chỉ hiện dòng lỗi, dòng `ghi chú <file> giờ do git theo dõi …` chưa hiện. Giữ bản cũ cho tới khi một lần chạy thật (không phải `--thu`) hiện dòng `xóa được`.
- `[<dự án>] ghi chú <file>: dự án khác cùng kho trên <box|laptop> còn dùng dòng giấu /<file>, fcode chưa gỡ`: đây là thông báo, không phải lỗi (mã lỗi giữ nguyên): file đó đã vào git ở một dự án nhưng một dự án khác cùng kho vẫn còn bản chưa theo dõi được giấu nhờ dòng đó, nên fcode giữ dòng và hỏi lại ở mỗi lần chạy. Cách xử lý: xem điểm về hai dự án dùng chung `.git/info/exclude` ở trên (giữ bản cũ). Thông báo này chỉ hiện khi chắc chắn có dự án khác còn dùng dòng; nếu git lỗi hoặc không trả lời thì fcode báo lỗi (xem hai dòng lỗi ở trên). Chạy tay thì dòng hiện trên màn hình; lần nhanh và lần tự động chỉ ghi vào phien.log.
- `[<thư mục>] không đọc được .git/info/exclude (<lý do>), bỏ qua ghi chú của dự án này lần này`: `<thư mục>` là đường dẫn thư mục dự án trên laptop, `<lý do>` là lời báo lỗi của PowerShell. Laptop không đọc được file đó (ví dụ phần mềm diệt virus đang giữ file). Ghi chú của dự án đó được bỏ qua trong lần này, phiên và các dự án khác vẫn đồng bộ, lần sau thử lại. Chạy tay thì dòng hiện trên màn hình; lần nhanh và lần tự động chỉ ghi vào phien.log. Box gặp chuyện tương tự thì cũng bỏ qua ghi chú của dự án đó lần này và không in dòng nào.

Tự động và box nghỉ: box gói miễn phí tự nghỉ sau 30 phút không dùng, và mỗi lần mở kết nối tới box đều tính là có người dùng. Vì vậy tự động chạy kiểu thưa: mỗi 10 phút nó chỉ hỏi `instabox ls` xem box có đang chạy không (không bao giờ đánh thức box). Box không chạy thì thôi. `instabox ls` lỗi hoặc trả về thứ không đọc được thì lần đó bỏ qua, không kết nối box và không đổi trạng thái đã lưu. Box vừa chuyển từ nghỉ sang chạy thì đồng bộ ngay một lần. Còn lại, chỉ đồng bộ khi lần mở kết nối gần nhất (của lần tự động hoặc lần chạy tay; lần đồng bộ nhanh khi mở agent không tính) đã cách từ **40 phút** trở lên, tức là lâu hơn 30 phút box tự nghỉ, nên box không ai dùng vẫn luôn được nghỉ. Lần bị lỗi cũng chỉ chờ đến mốc 40 phút sau, không thử lại dồn dập. Cả hai chiều đều chia theo file thành từng đợt tối đa 50 MB (mỗi đợt một kết nối, gửi xong đợt này mới làm đợt sau), nên đường truyền chậm hoặc bị ngắt giữa chừng thì các đợt đã xong vẫn nằm ở máy nhận và lần sau chỉ làm tiếp phần còn lại, kể cả một phiên rất lớn. Thứ tự: các đợt thường (tối đa 50 MB) làm trước theo cả hai chiều, rồi từng file lớn hơn 50 MB đi riêng một đợt, file nhỏ trước. Một đợt lỗi thì được ghi chú và lần chạy vẫn tiếp tục; chỉ hết giờ hoặc mất kết nối box mới dừng cả lần chạy. File lớn chưa chép xong thì báo `phiên lớn: <file> chưa chép xong — chạy fcode phien khi mạng tốt`, không bao giờ báo thành công; chạy tay (15 phút mỗi kết nối) sẽ làm nốt. Lần chạy tự động có tổng thời gian tối đa 7 phút: hết giờ thì dừng kết nối đang treo và không bắt đầu đợt mới (chạy tay: tối đa 15 phút mỗi kết nối). Thay đổi ở laptop hoặc ở box nhờ vậy sang bên kia chậm nhất sau khoảng 40 phút; muốn ngay thì gõ `fcode phien`. File lớn hơn 50 MB không đi theo lần đồng bộ nhanh khi mở agent (lần đó chỉ ghi vào phien.log `phiên lớn: <file> — lần nhanh không chép, để lần tự động hoặc fcode phien`); lần tự động hoặc `fcode phien` chép file đó. Chạy tay và chạy tự động dùng chung một khóa nên không giẫm lên nhau (chạy tay chờ lượt tự động xong). Chạy thử `--thu` không chép gì nhưng vẫn ghi lại giờ kết nối box, vì kết nối đó cũng tính là dùng box. Lý do và kết quả ghi ở `%USERPROFILE%\.fcode\phien.log` (mỗi dòng ghi ngay kèm giờ; file quá 200 KB thì được đổi tên thành `phien.log.1`, là phần nhật ký cũ hơn, rồi `phien.log` mới bắt đầu).

Dọn rác: mỗi lần chạy thật, fcode xóa các file tạm do chính nó để lại. Nó chỉ xóa file có tên **đúng hoàn toàn** theo các mẫu dưới đây, và chỉ ở chỗ nó đã tạo ra file đó. Tên chỉ giống một phần (ví dụ `fcode-phien-backup`, `x.jsonl.fcode-part-backup`, `exclude.part-backup`) thì không bao giờ bị đụng vào.

- Laptop: thư mục `%TEMP%\fcode-phien-<mã tiến trình>-<32 ký tự 0-9 a-f>` (không đi qua liên kết); thư mục cũ của v1.3.2 `%TEMP%\fcode-phien-<32 ký tự 0-9 a-f>` (không có mã tiến trình, chỉ xóa khi quá 1 giờ); file `<tên>.fcode-part-<mã tiến trình>-<6 ký tự 0-9 a-f>` trong thư mục phiên và thư mục blob (kể cả thư mục con), và ở thư mục gốc của các project được đồng bộ trong lần chạy đó; file `<tên file>.part-<mã tiến trình>` cạnh `handoff-state.json`, `phien-status.json`, `phien-auto.json` (trong `%LOCALAPPDATA%\fcode`) và cạnh `.git/info/exclude` của dự án (đúng chỗ git chỉ ra, kể cả khi dự án là worktree).
- Box: thư mục `$TMPDIR/fcode-phien-<8 ký tự>` của chính tài khoản đó (không đi qua liên kết, chỉ xóa khi quá 1 giờ); file `<tên>.fcode-part-<mã tiến trình>-<6 ký tự 0-9 a-f>` trong thư mục phiên và thư mục blob (chỉ xóa khi quá 1 giờ); file `exclude.fcode-part-<mã tiến trình>-<6 ký tự 0-9 a-f>` cạnh `.git/info/exclude`.

Khi nào xóa: ở laptop, file có mã tiến trình trong tên bị xóa khi quá 1 giờ hoặc khi lần chạy tạo ra nó (mã đó) đã không còn chạy; thư mục cũ của v1.3.2 không có mã nên chỉ xét giờ. Ở box, chỉ file `exclude.fcode-part-…` được xét theo mã tiến trình như vậy; hai loại còn lại trên box chỉ xét giờ (quá 1 giờ). Ở laptop, file tạm của một lần chạy đã bị dừng ngang (tắt cửa sổ, mất điện, bị ngắt hẳn) được xóa ngay ở lần đồng bộ kế tiếp (một lần tự động chỉ kiểm tra box mà không đồng bộ, hoặc một lần nhanh thấy đang có lần khác chạy, thì chưa dọn). Ngay đầu lần đồng bộ xóa thư mục tạm trong `%TEMP%` và các file `.part-<số>` cạnh ba file trạng thái ở trên; sau khi quét xong xóa tiếp `*.fcode-part-*` trong thư mục phiên, thư mục blob và thư mục gốc của các project được đồng bộ trong lần đó. File `exclude.part-<số>` (laptop) và `exclude.fcode-part-…` (box) cạnh `.git/info/exclude` bị xóa ở lần kế tiếp fcode ghi vào file `.git/info/exclude` của máy đó (khi đặt hoặc gỡ một ghi chú). Không xóa gì khác.

Khi omp đổi định dạng phiên (sau khi omp cập nhật): phiên có dòng đầu không đọc được hoặc `version` lạ (hiện chỉ hiểu version 3) **không được chép** và lần chạy báo `omp đổi định dạng phiên (version X) — chưa đồng bộ, báo Claude`; phiên cũ vẫn đồng bộ bình thường. Mỗi lần chạy ghi `%LOCALAPPDATA%\fcode\phien-status.json` (giờ chạy, kết quả, số file chép, phiên lạ, phiên bản omp hai máy, ghi chú đã chép và xung đột). Menu `fcode` hiện một dòng cảnh báo vàng ở đầu khi có phiên định dạng lạ hoặc lần tự động gần nhất bị lỗi. Hai máy khác phiên bản omp thì vẫn đồng bộ phiên đúng định dạng và thêm dòng `omp laptop <a> khác box <b>`.

### Tự đồng bộ khi mở agent (`fcode moc`)

Từ v1.3.3, bạn không cần nhớ gõ `fcode phien` nữa. Bật một lần:

```sh
fcode moc bat          # bật
fcode moc trang-thai   # xem đang bật hay tắt
fcode moc tat          # tắt
```

Sau khi bật, mỗi lần bạn gõ `omp`, `claude` hoặc `codex` trong thư mục của một dự án có trong `syncRepos` (hoặc trong thư mục con của nó), FCode làm theo thứ tự:

1. Đồng bộ dự án đó trước (như `fcode phien <dự án> --nhanh`; agent chờ tối đa 35 giây), rồi mở agent như bình thường với đúng các tham số bạn gõ.
2. Khi bạn đóng agent, FCode đồng bộ thêm một lần nữa ở chế độ ngầm (`fcode phien <dự án> --nhanh --nen`): không hiện cửa sổ, không làm bạn phải chờ. Lần này tự chờ khoảng 35 giây (để phiên vừa đóng kịp "nguội") rồi mới đồng bộ, và cũng dừng ở khoảng 20 giây.

Cần biết:

- **Màn hình êm**: đồng bộ xong bình thường thì không hiện gì (chi tiết ghi ở `%USERPROFILE%\.fcode\phien.log`). Nếu có chuyện, màn hình hiện tối đa **một dòng** ở cuối, và agent luôn được mở.
- **Không đánh thức box.** Box đang ngủ thì hiện `phien: box đang ngủ, bỏ qua` và agent mở ngay. Lần tự động mỗi 10 phút ở trên vẫn là phương án dự phòng.
- **Không đọc được trạng thái box thì là lỗi, không phải "ngủ".** Nếu `instabox ls` lỗi (ví dụ bạn chưa chạy `instabox login`), màn hình hiện `phien: không đồng bộ được, xem phien.log` và trong phien.log ghi `lỗi: không đọc được trạng thái box (instabox ls lỗi — đã chạy "instabox login" chưa?)`; agent vẫn mở.
- **Dừng ở khoảng 20 giây** mỗi lần (có thể dư vài giây khi một bước đang hoàn tất); FCode chỉ dừng giữa hai việc, không bao giờ bỏ dở một file, và các lệnh con (ssh, tar, kiểm tra box) cũng bị dừng đúng hạn. Hết giờ thì hiện `phien: hết 20 giây, phần còn lại chạy lần sau`; phần còn lại làm tiếp ở lần mở agent sau, hoặc ở lần tự động kế tiếp theo lịch thường (lần đồng bộ nhanh không đẩy lùi lịch đó). File lớn hơn 50 MB không bao giờ đi theo lần nhanh, mà để lần tự động hoặc `fcode phien` chép (lần nhanh chỉ ghi `phiên lớn: <file> — lần nhanh không chép, để lần tự động hoặc fcode phien` vào phien.log).
- **Ngắt hẳn ở 30 giây.** Nếu một lần đồng bộ nhanh vẫn chưa xong sau 30 giây (ví dụ một lệnh bị treo), FCode ngắt hẳn nó cùng mọi lệnh con của nó, màn hình hiện `phien: không đồng bộ được, xem phien.log` và phien.log ghi `lỗi: lần chạy nhanh vượt quá 30 giây nên bị ngắt hẳn …`; việc đang làm dở để lần sau, agent vẫn mở. Nếu Windows không cho FCode tạo lớp bảo vệ này, lần nhanh không đồng bộ gì, màn hình hiện cùng dòng `phien: không đồng bộ được, xem phien.log` và phien.log ghi lý do (`lỗi: không tạo được job bảo vệ cho lần chạy nhanh (…) — không đồng bộ`). Lần chạy tay `fcode phien` thì không bị ngắt như vậy.
- Đang có một lần đồng bộ khác chạy thì hiện `phien: đang có lần đồng bộ khác, bỏ qua` và mở agent luôn.
- **Đồng bộ lỗi không chặn agent**: agent vẫn mở, màn hình chỉ hiện đúng một dòng `phien: không đồng bộ được, xem phien.log`.
- Mở agent ở thư mục không thuộc dự án nào thì không đồng bộ gì, agent chạy như thường.
- **Tắt tạm trong cửa sổ này**: gõ `$env:FCODE_MOC = '0'`. Biến này giữ tới khi bạn đóng cửa sổ PowerShell; muốn bật lại ngay thì gõ `Remove-Item Env:FCODE_MOC`.
- **Giới hạn của lệnh bọc**: khi bật, `omp`, `claude`, `codex` là lệnh bọc của FCode nên không chuyển nguyên vẹn các tham số dạng `--` và `-x:giá-trị`, cũng như kết quả lỗi vào `$?`. Cần những trường hợp đó thì chạy thẳng `claude.exe`, `codex.exe` hoặc `omp.exe` (bỏ qua FCode).
- `fcode moc bat` thêm một khối giữa hai dòng `# >>> fcode moc >>>` và `# <<< fcode moc <<<` vào file profile của cả Windows PowerShell 5.1 và PowerShell 7 (`WindowsPowerShell\profile.ps1` và `PowerShell\profile.ps1` trong thư mục Documents của bạn, có thể nằm trong OneDrive). Nếu file đã có, FCode chép một bản dự phòng `profile.ps1.bak-fcode` trước lần sửa đầu tiên. `fcode moc tat` chỉ xoá đúng khối đó, các dòng khác của bạn giữ nguyên.
- **Dòng `# fcode` trong `.git/info/exclude`**: lần đồng bộ này cũng đặt ghi chú dự án (xem phần "Ghi chú ở thư mục gốc project" ở trên). Đừng xóa riêng dòng `# fcode`: git vẫn giấu file đó nhưng fcode không còn biết dòng đó là của nó, và bản của bạn có thể bị `git pull` ghi đè mà không báo. Muốn tự quản dòng đó thì xóa cả hai dòng hoặc giữ nguyên cả hai.
- Cần mở lại cửa sổ PowerShell sau khi bật hoặc tắt.

**Nếu không thấy tác dụng**: chạy `fcode moc trang-thai`. Lệnh cho biết từng file profile đã có khối hay chưa và chế độ chạy script (execution policy) của Windows PowerShell 5.1 (cùng của PowerShell 7 nếu máy có `pwsh`). Nếu chế độ của một bên là `Restricted` hoặc `AllSigned`, bên đó sẽ không nạp profile nên khối này không chạy; lệnh sẽ chỉ cách cho phép. FCode không bao giờ tự đổi chế độ này của bạn.

**Chưa có**: hội thoại Claude Code và Codex chưa được mang qua lại giữa laptop và box. Hiện chỉ phiên omp và ghi chú dự án được đồng bộ (như mô tả ở mục `fcode phien` phía trên); mở `claude` hoặc `codex` với `fcode moc` bật vẫn chỉ đồng bộ hai thứ đó.

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
- Hợp đồng giữa máy chủ và app nằm trong [`CONTRACT.md`](../CONTRACT.md) (các mục A1 trở đi là các thay đổi theo thời gian; ví dụ A4 thay mật khẩu bằng ghép máy, A5 thêm hộp thư tổng quan, A6 thêm màu cho màn hình, A7 ghép thêm máy bằng mã QR, A9 phiên omp của dự án và máy staging, A10 đồng bộ phiên omp giữa laptop và box, A11 thêm dự án từ app).
- Chạy thử trên máy bất kỳ, kể cả Windows (dùng tmux giả, không cần tmux):

  ```sh
  node --test test/server.test.mjs
  ```

- Thử với tmux thật, trên máy Linux có `tmux`, `node 22`, `curl` (script dùng socket tmux riêng nên không đụng phiên của bạn):

  ```sh
  bash test/tmux-integration.sh
  ```

- **App iOS** nằm trong thư mục `ios/` (SwiftUI, iOS 16 trở lên). Dự án Xcode được sinh bằng **XcodeGen** từ `ios/project.yml`. GitHub Actions (`.github/workflows/ios.yml`, máy macOS) dựng app **không ký** rồi đóng gói `fcode.ipa`. Khi chạy trên nhánh `main`, workflow đăng bản này lên bản phát hành trước (pre-release) tên **`latest`**. Việc ký được làm trên máy bạn, bằng Sideloadly. Hướng dẫn dùng app chi tiết hơn có trong [`ios/README.md`](../ios/README.md).
