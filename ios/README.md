# Box Chat cho iPhone

Ứng dụng Box Chat giúp bạn trò chuyện với các chương trình (omp, claude, codex, shell) đang chạy trên box, ngay trên iPhone. Gõ tiếng Việt (Telex) bình thường bằng bàn phím của iPhone.

Ứng dụng không có trên App Store. Bạn cài nó qua **LiveContainer**.

## 1. Tải file cài đặt

1. Trên iPhone, mở **Safari**.
2. Vào trang GitHub của dự án này, bấm **Releases**, chọn bản **"Box Chat (bản mới nhất)"** (nhãn `latest`).
3. Bấm vào **BoxChat.ipa** để tải về. File sẽ nằm trong ứng dụng **Tệp** (Files), thư mục **Tải về** (Downloads).

Mỗi lần có thay đổi mới, GitHub tự dựng lại và thay file `BoxChat.ipa` ở cùng chỗ đó.

## 2. Cài vào LiveContainer

1. Mở **LiveContainer**.
2. Ở thẻ **Ứng dụng** (Apps), bấm nút **+** ở góc trên.
3. Chọn file **BoxChat.ipa** vừa tải (trong **Tải về**).
4. Đợi vài giây, **Box Chat** sẽ hiện trong danh sách. Bấm vào để mở.

Cập nhật bản mới: tải lại `BoxChat.ipa` rồi làm lại bước 2. LiveContainer sẽ hỏi có thay bản cũ không, chọn đồng ý. Thông tin đăng nhập vẫn được giữ.

## 3. Đăng nhập lần đầu

1. **Địa chỉ máy chủ**: địa chỉ công khai của box, bắt đầu bằng `https://` (người quản trị box đưa cho bạn).
2. **Mật khẩu**: mật khẩu của Box Chat.
3. Bấm **Đăng nhập**.

## 4. Cách dùng

- **Mở dự án**: chọn chương trình ở thanh phía trên (mặc định `omp`), rồi chạm vào tên dự án. Nếu phiên đã có thì ứng dụng mở lại phiên đó.
- **Phiên đang chạy**: chạm để mở; vuốt sang trái (hoặc nhấn giữ) để **Xoá**.
- **Trong phiên**:
  - Màn hình tự cuộn xuống dòng mới nhất. Nếu bạn cuộn lên để đọc, bấm **Xuống cuối** để quay lại.
  - **A-** / **A+**: chữ nhỏ hơn / to hơn.
  - Chấm màu: xanh lá = đang kết nối trực tiếp, vàng = đang cập nhật định kỳ, cam = đang kết nối, đỏ = mất kết nối.
  - Gõ nội dung vào ô nhập rồi bấm **Gửi** (gửi và nhấn Enter) hoặc **Gửi không Enter**. Bấm **Gửi** khi ô trống = chỉ nhấn Enter.
  - Hàng phím nhanh: Esc, Ctrl+C, mũi tên, Tab, ⇧Tab, Enter, y, n. Nút **/** chèn các lệnh hay dùng (/model, /clear, …).
- **Cài đặt** (bánh răng): **Đăng xuất**, hoặc **Đăng xuất mọi nơi** để thoát trên tất cả thiết bị.

## Khi gặp lỗi

- *"Sai mật khẩu."*: kiểm tra lại mật khẩu.
- *"Thử lại sau N giây."*: nhập sai nhiều lần, đợi đủ thời gian rồi thử lại.
- *"Phiên đăng nhập đã hết hạn."*: đăng nhập lại.
- *"Không tìm thấy máy chủ."* / *"Không kết nối được máy chủ."*: kiểm tra mạng và địa chỉ máy chủ.
