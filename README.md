# fcoding (server)

Máy chủ nhỏ chạy trên box instabox để app iOS điều khiển các phiên tmux (omp, claude, codex, shell). Chỉ cần Node 22 và tmux, không có thư viện ngoài.

## Cài trên box

```sh
# từ máy tính: chép server.mjs và install.sh lên box (ví dụ vào /tmp/fcoding), rồi chạy trên box:
bash /tmp/fcoding/install.sh
```

Script chép `server.mjs` vào `/data/home/fcoding`, tạo thư mục cấu hình `/data/home/.fcoding` (quyền 700) và bật dịch vụ `fcoding.service` (systemd --user, tự chạy lại khi lỗi, cổng 7681). Chạy lại script nhiều lần vẫn an toàn. Lần cài đầu tiên: đặt mật khẩu (bên dưới) rồi chạy `systemctl --user restart fcoding`; khi chưa có `config.json` hợp lệ, máy chủ không chạy.

Đăng nhập chỉ lưu trong bộ nhớ: mỗi lần dịch vụ khởi động lại, mọi thiết bị phải đăng nhập lại.

## Đặt mật khẩu

Để máy chủ tự tạo mật khẩu ngẫu nhiên (chỉ hiện MỘT lần, hãy ghi lại):

```sh
PC_CONFIG_DIR=/data/home/.fcoding node /data/home/fcoding/server.mjs --set-password </dev/null
```

Hoặc tự chọn (không để lại trong lịch sử lệnh; chỉ ký tự xuống dòng cuối bị bỏ, dấu cách đầu/cuối được giữ):

```sh
read -rs PW; printf '%s\n' "$PW" | PC_CONFIG_DIR=/data/home/.fcoding node /data/home/fcoding/server.mjs --set-password; unset PW
```

Đổi mật khẩu có hiệu lực ngay, không cần khởi động lại; mọi phiên đăng nhập cũ bị đăng xuất.

Danh sách dự án nằm trong `/data/home/.fcoding/config.json` (`"projects": {"tên": "/đường/dẫn/tuyệt/đối"}`). Máy chủ tự đọc lại file sau khi sửa, không cần khởi động lại; nếu file bị lỗi cú pháp, máy chủ giữ cấu hình cũ cho tới khi file được sửa đúng.

Các harness chạy với PATH cố định: `~/.local/bin`, `~/.bun/bin`, `/usr/local/bin`, `/usr/bin`, `/bin`.

## Mở cổng ra ngoài

```sh
instabox port publish <tên-box> 7681
```

Lệnh in ra địa chỉ công khai; nhập địa chỉ đó và mật khẩu vào app. Mở `GET /` sẽ thấy dòng `fcoding ok`.

## Nối từ laptop vào cùng phiên

```sh
tmux ls
tmux attach -t <tên-phiên>
```

Khi điện thoại chỉnh kích thước, cửa sổ tmux bị cố định theo điện thoại. Sau khi attach từ laptop, chạy một lần để cửa sổ lại theo màn hình đang dùng:

```sh
tmux set-option -wu window-size
```

## Giới hạn

- Tối đa 50 luồng xem màn hình cùng lúc và 8 tiến trình tmux đồng thời.
- Lệnh thay đổi (mở, tạo, xóa phiên, gửi chữ, phím, đổi kích thước) chạy lần lượt từng cái; tối đa 20 lệnh chờ, quá thì trả `503 busy`. Lệnh đọc (màn hình, danh sách) không phải chờ: hết chỗ thì trả `503 busy` ngay.
- Tin nhắn tối đa 32 KB, thân yêu cầu tối đa 64 KB.
- Đăng nhập sai: khóa 15 phút sau 5 lần theo từng địa chỉ IP, và 30 lần mỗi giờ cho cả hệ thống.

## Kiểm thử

```sh
node --test test/server.test.mjs      # chạy được trên Windows, không cần tmux (dùng tmux giả)
bash test/tmux-integration.sh          # Linux + tmux thật, dùng socket tmux riêng (-L), không đụng phiên của bạn
```
