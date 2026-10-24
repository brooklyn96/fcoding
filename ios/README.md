# fcoding cho iPhone

Ứng dụng fcoding giúp bạn trò chuyện với các chương trình (omp, claude, codex, shell) đang chạy trên box, ngay trên iPhone. Gõ tiếng Việt (Telex) bình thường bằng bàn phím của iPhone.

Ứng dụng không có trên App Store. Bạn cài nó qua **LiveContainer**.

## 1. Tải file cài đặt

1. Trên iPhone, mở **Safari**.
2. Vào trang GitHub của dự án này, bấm **Releases**, chọn bản **"fcoding (bản mới nhất)"** (nhãn `latest`).
3. Bấm vào **fcoding.ipa** để tải về. File sẽ nằm trong ứng dụng **Tệp** (Files), thư mục **Tải về** (Downloads).

Mỗi lần có thay đổi mới, GitHub tự dựng lại và thay file `fcoding.ipa` ở cùng chỗ đó.

## 2. Cài vào LiveContainer

1. Mở **LiveContainer**.
2. Ở thẻ **Ứng dụng** (Apps), bấm nút **+** ở góc trên.
3. Chọn file **fcoding.ipa** vừa tải (trong **Tải về**).
4. Đợi vài giây, **fcoding** sẽ hiện trong danh sách. Bấm vào để mở.

Cập nhật bản mới: tải lại `fcoding.ipa` rồi làm lại bước 2. LiveContainer sẽ hỏi có thay bản cũ không, chọn đồng ý. Thông tin đăng nhập vẫn được giữ.

## 3. Đăng nhập lần đầu

1. **Địa chỉ máy chủ**: địa chỉ công khai của box, bắt đầu bằng `https://` (người quản trị box đưa cho bạn).
2. **Mật khẩu**: mật khẩu của fcoding.
3. Bấm **Đăng nhập**.

## 4. Cách dùng

- **Mở dự án**: chọn chương trình ở thanh phía trên (mặc định `omp`), rồi chạm vào tên dự án. Nếu phiên đã có thì ứng dụng mở lại phiên đó.
- **Phiên đang chạy**: chạm để mở; vuốt sang trái (hoặc nhấn giữ) để **Xoá**.
- **Trong phiên**:
  - Màn hình tự cuộn xuống dòng mới nhất. Nếu bạn cuộn lên để đọc, bấm **Xuống cuối** để quay lại.
  - **A-** / **A+**: chữ nhỏ hơn / to hơn.
  - Chấm màu: xanh lá = đang kết nối trực tiếp, vàng = đang cập nhật định kỳ, cam = đang kết nối, đỏ = mất kết nối.
  - Gõ nội dung vào ô nhập rồi bấm **Gửi** (gửi và nhấn Enter) hoặc **Gửi không Enter**. Bấm **Gửi** khi ô trống = chỉ nhấn Enter.
  - Nội dung đang soạn được giữ lại cho từng phiên (kể cả khi phải đăng nhập lại vì phiên hết hạn). Nó bị xoá khi gửi thành công, khi bạn xoá phiên đó, hoặc khi bạn tự đăng xuất (**Đăng xuất trên máy này** / **Đăng xuất mọi nơi**).
  - Hàng phím nhanh: Esc, Ctrl+C, mũi tên, Tab, ⇧Tab, Enter, y, n. Nút **/** chèn các lệnh hay dùng (/model, /clear, …). Các phím được gửi đúng thứ tự bạn bấm.
  - Khi xoay ngang: ô nhập thấp lại để màn hình còn chỗ; bấm nút **bàn phím** bên trái ô nhập để hiện / ẩn hàng phím nhanh.
  - Khi bạn chuyển sang ứng dụng khác, kết nối tạm dừng; mở lại ứng dụng là tự kết nối lại.
- **Cài đặt** (bánh răng):
  - **Đăng xuất trên máy này**: chỉ xoá đăng nhập trên điện thoại này.
  - **Đăng xuất mọi nơi**: thu hồi đăng nhập trên tất cả thiết bị. Điện thoại chỉ đăng xuất sau khi máy chủ xác nhận; nếu lỗi, bấm **Thử lại**.

## Khi gặp lỗi

- *"Sai mật khẩu."*: kiểm tra lại mật khẩu.
- *"Thử lại sau N giây."*: nhập sai nhiều lần, đợi đủ thời gian rồi thử lại.
- *"Máy chủ đã khởi động lại hoặc phiên hết hạn, đăng nhập lại."*: đăng nhập lại (máy chủ khởi động lại thì mọi thiết bị đều phải đăng nhập lại).
- *"Phiên đã đóng."*: chương trình trong phiên đã thoát; bấm **Quay lại** rồi mở lại dự án.
- *"Box đang bận, thử lại sau."*: đợi vài giây rồi thử lại.
- *"Không lưu được mật khẩu đăng nhập an toàn; app sẽ dùng cookie."*: điện thoại không cho lưu vào Keychain (thường gặp với LiveContainer). App vẫn dùng được và vẫn nhớ đăng nhập; chạm vào thông báo để ẩn.
- *"Không tìm thấy máy chủ."* / *"Không kết nối được máy chủ."*: kiểm tra mạng và địa chỉ máy chủ.
