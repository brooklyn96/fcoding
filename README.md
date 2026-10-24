# fcoding (server)

Máy chủ nhỏ chạy trên box instabox để app iOS điều khiển các phiên tmux (omp, claude, codex, shell). Chỉ cần Node 22 và tmux, không có thư viện ngoài.

## Cài trên box

```sh
# từ máy tính: chép server.mjs và install.sh lên box (ví dụ vào /tmp/fcoding), rồi chạy trên box:
bash /tmp/fcoding/install.sh
```

Script chép `server.mjs` vào `/data/home/fcoding`, tạo thư mục cấu hình `/data/home/.fcoding` (quyền 700) và bật dịch vụ `fcoding.service` (systemd --user, tự chạy lại khi lỗi, cổng 7681). Chạy lại script nhiều lần vẫn an toàn. Lần cài đầu, script tạo `config.json` với một khóa bí mật ngẫu nhiên và cài lệnh `~/.local/bin/fcode-pair`.

## Ghép nối điện thoại (không có mật khẩu)

Chỉ người có shell trên box mới ghép được thiết bị. Trên box chạy:

```sh
fcode-pair "iPhone"
```

Lệnh in ra mã 6 số. Nhập mã vào app trong 120 giây. Mã dùng được một lần; nhập sai 5 lần thì mã bị hủy; chạy lại lệnh sẽ thay mã cũ. Máy chủ phải đang chạy (nếu không, lệnh báo lỗi).

Thiết bị đã ghép được lưu trong `/data/home/.fcoding/devices.json` (chỉ lưu dạng băm, không lưu mã đăng nhập) và vẫn còn sau khi máy chủ khởi động lại.

```sh
PC_CONFIG_DIR=/data/home/.fcoding node /data/home/fcoding/server.mjs --devices          # danh sách thiết bị
PC_CONFIG_DIR=/data/home/.fcoding node /data/home/fcoding/server.mjs --revoke <id>      # gỡ một thiết bị
PC_CONFIG_DIR=/data/home/.fcoding node /data/home/fcoding/server.mjs --revoke all       # gỡ tất cả
```

Đổi `cookieSecret` trong `config.json` sẽ gỡ mọi thiết bị (kể cả khi đổi lúc máy chủ đang tắt); sau đó phải ghép lại từng điện thoại.

Danh sách dự án nằm trong `/data/home/.fcoding/config.json` (`"projects": {"tên": "/đường/dẫn/tuyệt/đối"}`). Máy chủ tự đọc lại file sau khi sửa, không cần khởi động lại; nếu file bị lỗi cú pháp, máy chủ giữ cấu hình cũ cho tới khi file được sửa đúng.

Các harness chạy với PATH cố định: `~/.local/bin`, `~/.bun/bin`, `/usr/local/bin`, `/usr/bin`, `/bin`.

## Mở cổng ra ngoài

```sh
instabox port publish <tên-box> 7681
```

Lệnh in ra địa chỉ công khai; nhập địa chỉ đó và mã ghép nối vào app. Mở `GET /` sẽ thấy dòng `fcoding ok`.

## Nối từ laptop vào cùng phiên

```sh
tmux ls
tmux attach -t <tên-phiên>
```

Khi điện thoại chỉnh kích thước, cửa sổ tmux bị cố định theo điện thoại. Sau khi attach từ laptop, chạy một lần để cửa sổ lại theo màn hình đang dùng:

```sh
tmux set-option -wu window-size
```

## Màn hình tổng quan của app

App hỏi `GET /api/overview` mỗi 5 giây khi đang mở. Máy chủ trả về từng phiên với trạng thái: "đang chạy" (màn hình có thay đổi trong 8 giây gần nhất), "cần bạn" (vài dòng cuối là câu hỏi như `(y/n)`, `Do you want`, `Proceed?`) hoặc "đang nghỉ". Mỗi phiên chỉ kèm một dòng xem trước. Nếu phiên đang chờ bạn, dòng đó chính là câu hỏi. Với mỗi dự án, máy chủ trả thêm nhánh git, số dòng thay đổi và số commit chưa đẩy lên. Máy chủ chỉ đọc git, không bao giờ khóa git, nên không cản agent đang làm việc. Kết quả git được giữ 10 giây.

Nút "+" trong app luôn tạo phiên mới (`fresh: true`), đặt tên `<dự án>-<harness>`, `-2`, `-3`, …, không bao giờ mở lại phiên cũ.

## Giới hạn

- Tối đa 50 luồng xem màn hình cùng lúc và 8 tiến trình tmux đồng thời. Một lần lấy tổng quan chỉ dùng một chỗ đọc; các lệnh tmux và git bên trong chạy lần lượt.
- Lệnh thay đổi (mở, tạo, xóa phiên, gửi chữ, phím, đổi kích thước) chạy lần lượt từng cái; tối đa 20 lệnh chờ, quá thì trả `503 busy`. Lệnh đọc (màn hình, danh sách) không phải chờ: hết chỗ thì trả `503 busy` ngay.
- Tin nhắn tối đa 32 KB, thân yêu cầu tối đa 64 KB.
- Ghép nối (`/api/pair`): tối đa 10 lần mỗi phút và 30 lần mỗi giờ cho cả hệ thống; quá thì trả `429` kèm `Retry-After`. Giới hạn này tính chung cho mọi người trên internet, nên người lạ có thể dùng hết 30 lượt trong một giờ; khi đó hãy chờ tối đa 1 giờ rồi ghép lại. Ghép nối hiếm khi cần, nên điều này được chấp nhận.

## Kiểm thử

```sh
node --test test/server.test.mjs      # chạy được trên Windows, không cần tmux (dùng tmux giả)
bash test/tmux-integration.sh          # Linux + tmux thật, dùng socket tmux riêng (-L), không đụng phiên của bạn
```
