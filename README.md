# FCode

Điều khiển các trợ lý lập trình (omp, Claude Code, Codex) đang chạy trên một máy Linux đám mây, ngay từ iPhone.

## FCode là gì

FCode là một app iPhone kèm một máy chủ nhỏ. Máy chủ chạy trên **box** (máy Linux đám mây của instabox); mỗi trợ lý chạy trong một phiên tmux nên vẫn sống khi bạn khóa điện thoại. Bạn trò chuyện với trợ lý, trả lời y/n, xem hạn mức và chi phí ngay trên điện thoại, và vào lại đúng phiên đó từ laptop.

## Cách hoạt động

- **Box**: chạy `server.mjs` (Node 22, không cần cài thêm gói) và các phiên tmux.
- **Link công khai**: `instabox port publish` đưa cổng 7681 của box ra một địa chỉ `https://7681-<id>.instabox.tech`.
- **App iPhone**: ghép với box bằng mã 6 số (không có mật khẩu), rồi nói chuyện với box qua link đó.
- **Laptop**: lệnh `fcode` (tùy chọn) để vào phiên, thêm dự án, ghép iPhone và đồng bộ phiên omp.

## Bắt đầu nhanh

1. **Cài máy chủ trên box** (cần Node 22 và tmux):
   `git clone https://github.com/brooklyn96/fcoding.git && cd fcoding && bash install.sh`
2. **Mở link công khai** (chạy trên laptop): `instabox port publish <tên-box> 7681`. Mở link trong trình duyệt, thấy `fcoding ok` là được.
3. **Cài app lên iPhone**: tải `fcode.ipa` ở mục **Releases** của GitHub, cài bằng **Sideloadly** (Apple ID miễn phí chạy được 7 ngày, ký lại bằng cách cài đè).
4. **Ghép iPhone**: trên box chạy `fcode-pair "iPhone của tôi"`, rồi nhập địa chỉ link và mã 6 số vào app.
5. **(Tùy chọn) Lệnh `fcode` trên laptop Windows**: mở PowerShell, dán `irm https://raw.githubusercontent.com/brooklyn96/fcoding/main/laptop/install.ps1 | iex`.

## Dùng hằng ngày

- **Danh sách phiên**: chia **Cần bạn** (trên cùng, trả lời y/n ngay trên danh sách), **Đang chạy**, **Đang nghỉ**.
- **Phiên mới**: nút **+**, chọn dự án rồi chọn omp, claude hoặc codex; cũng có `fcode new` trên laptop.
- **Thêm dự án từ app** (v1.3.2): **+** rồi **Thêm dự án**, dán link GitHub hoặc chọn trong danh sách rồi bấm **Thêm**; box tự tải về `/data/workspace/<tên>`. Chỉ cần dán khóa (Deploy key) vào GitHub khi token GitHub của box không ghi được; app hướng dẫn từng bước.
- **Phiên omp gần đây** (v1.3.2): bấm **Tiếp tục** để mở lại một phiên omp của dự án, kể cả phiên làm từ laptop.
- **Máy staging** (v1.3.2): thẻ dự án có nút **Bật** để đánh thức máy instabox cùng tên (cần khóa instabox trên box).
- **Đồng bộ phiên omp laptop và box** (v1.3.2): `fcode phien` chép phiên qua lại; `fcode phien tu-dong bat` bật tự động (mỗi 10 phút, không giữ box thức). Ghi chú dự án không nằm trong git (`CLAUDE.md`, `TASK.md`...) đi theo. Phiên lớn chép dần theo từng phần; chưa xong thì chạy lại `fcode phien` khi mạng tốt.
- **Box tự cập nhật code** (v1.3.2): box tự kéo code mới về khi dự án đang rảnh và sạch.
- **`fcode sync`** (v1.3.2): kéo code mới về laptop, và với project có trên box mà chưa có trên laptop thì tìm bản clone sẵn có (hoặc clone mới), thêm vào `syncRepos` rồi đồng bộ ngay.
- **`fcode add <chủ/repo>`** (v1.3.2): thêm dự án vào box; có token GitHub ghi được thì xong ngay, không thì lệnh chỉ cách dán khóa.
- **Từ laptop**: `fcode` liệt kê và vào phiên (thoát bằng Ctrl+B rồi D); `fcode pair` ghép iPhone mới bằng mã QR; `fcode ipa` tải app bản mới.

## Bảo mật

- Không có mật khẩu: chỉ iPhone đã ghép mới dùng được box. Mã ghép 6 số, hạn 2 phút, dùng một lần, sai 5 lần thì hủy.
- Box chỉ lưu dạng băm của mã thiết bị; mã thật nằm trong Keychain của iPhone.
- Máy chủ không ghi nội dung bạn gõ vào nhật ký và không có máy chủ trung gian: dữ liệu chỉ đi giữa box và điện thoại.
- Mất iPhone: trên box chạy `PC_CONFIG_DIR=/data/home/.fcoding node /data/home/fcoding/server.mjs --revoke all`, rồi ghép lại máy còn dùng.

## Hướng dẫn chi tiết

Cài đặt từng bước, ghép máy, mã QR, màn hình chính, lệnh laptop, luật đồng bộ phiên, lỗi thường gặp và bảo mật đầy đủ: [docs/HUONG-DAN.md](docs/HUONG-DAN.md). Hướng dẫn dùng app: [ios/README.md](ios/README.md).

## Phát triển

- Máy chủ: Node 22, chỉ thư viện có sẵn, toàn bộ trong `server.mjs`; hợp đồng máy chủ - app ở [CONTRACT.md](CONTRACT.md).
- Thử: `node --test test/server.test.mjs` (không cần tmux) và `bash test/tmux-integration.sh` (cần tmux thật).
- App iOS ở `ios/` (SwiftUI, XcodeGen); GitHub Actions dựng `fcode.ipa` không ký và đăng lên bản phát hành `latest`.
