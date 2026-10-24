# FCode cho iPhone

Ứng dụng FCode giúp bạn trò chuyện với các chương trình (omp, claude, codex, shell) đang chạy trên box, ngay trên iPhone. Gõ tiếng Việt (Telex) bình thường bằng bàn phím của iPhone.

Ứng dụng không có trên App Store. Bạn cài nó bằng **Sideloadly** trên máy tính (Windows hoặc Mac).

## 1. Tải file cài đặt

1. Trên máy tính, vào trang GitHub của dự án này, bấm **Releases**, chọn bản **"FCode (bản mới nhất)"** (nhãn `latest`).
2. Bấm vào **fcode.ipa** để tải về máy tính.

Mỗi lần có thay đổi mới, GitHub tự dựng lại và thay file `fcode.ipa` ở cùng chỗ đó.

## 2. Cài bằng Sideloadly

1. Cài **Sideloadly** (sideloadly.io) trên máy tính. Trên Windows cần cài thêm **iTunes** và **iCloud** bản tải từ trang Apple (không dùng bản Microsoft Store).
2. Cắm iPhone vào máy tính bằng cáp, mở khoá iPhone, bấm **Tin cậy** (Trust) nếu được hỏi.
3. Mở Sideloadly, kéo file **fcode.ipa** vào cửa sổ, nhập **Apple ID** của bạn, bấm **Start**. Nhập mật khẩu Apple ID (và mã xác minh) khi được hỏi.
4. Trên iPhone, lần đầu cài:
   - **Cài đặt → Cài đặt chung → Quản lý VPN & thiết bị**, chọn Apple ID của bạn, bấm **Tin cậy**.
   - **Cài đặt → Quyền riêng tư & Bảo mật → Chế độ nhà phát triển** (Developer Mode): bật, iPhone khởi động lại, rồi xác nhận **Bật**.
5. Mở **FCode** trên màn hình chính.

Với Apple ID miễn phí, ứng dụng chỉ chạy được 7 ngày; sau đó cắm máy và bấm **Start** lại trong Sideloadly. Cài đè bằng cùng Apple ID thì ghép máy vẫn được giữ, không phải ghép lại.

## 3. Ghép iPhone với box (lần đầu)

Không có mật khẩu. Chỉ người có quyền vào dòng lệnh của box mới ghép được máy.

1. Trên box, gõ lệnh `fcode-pair`. Box in ra **mã ghép 6 số**, mã có hạn **2 phút**.
2. Trên iPhone, mở FCode ở màn hình **Ghép máy**:
   - **Địa chỉ máy chủ**: địa chỉ công khai của box, bắt đầu bằng `https://`.
   - **Mã ghép**: gõ 6 số vừa thấy trên box.
3. Bấm **Ghép iPhone này**.

Sau khi ghép, iPhone nhớ box trong Keychain; mở ứng dụng là vào thẳng danh sách dự án. Box khởi động lại thì không phải ghép lại.

## 4. Cách dùng

- **Mở dự án**: chọn chương trình ở thanh phía trên (mặc định `omp`), rồi chạm vào tên dự án. Nếu phiên đã có thì ứng dụng mở lại phiên đó.
- **Phiên đang chạy**: chạm để mở; vuốt sang trái (hoặc nhấn giữ) để **Xoá**.
- **Trong phiên**:
  - Màn hình tự cuộn xuống dòng mới nhất. Nếu bạn cuộn lên để đọc, bấm **Xuống cuối** để quay lại.
  - **A-** / **A+**: chữ nhỏ hơn / to hơn.
  - Chấm màu: xanh lá = đang kết nối trực tiếp, vàng = đang cập nhật định kỳ, cam = đang kết nối, đỏ = mất kết nối.
  - Gõ nội dung vào ô nhập rồi bấm **Gửi** (gửi và nhấn Enter) hoặc **Gửi không Enter**. Bấm **Gửi** khi ô trống = chỉ nhấn Enter.
  - Nội dung đang soạn được giữ lại cho từng phiên (kể cả khi iPhone bị gỡ khỏi box và phải ghép lại). Nó bị xoá khi gửi thành công, khi bạn xoá phiên đó, hoặc khi bạn tự gỡ máy (**Gỡ iPhone này** / **Gỡ mọi thiết bị**).
  - Hàng phím nhanh: Esc, Ctrl+C, mũi tên, Tab, ⇧Tab, Enter, y, n. Nút **/** chèn các lệnh hay dùng (/model, /clear, …). Các phím được gửi đúng thứ tự bạn bấm.
  - Khi xoay ngang: ô nhập thấp lại để màn hình còn chỗ; bấm nút **bàn phím** bên trái ô nhập để hiện / ẩn hàng phím nhanh.
  - Khi bạn chuyển sang ứng dụng khác, kết nối tạm dừng; mở lại ứng dụng là tự kết nối lại.
- **Cài đặt** (bánh răng):
  - **Gỡ iPhone này**: gỡ điện thoại này khỏi box.
  - **Gỡ mọi thiết bị**: gỡ tất cả thiết bị đã ghép với box (có hỏi xác nhận).
  - Cả hai đều xoá ghép trên iPhone này ngay, kể cả khi box không trả lời. Muốn dùng lại thì gõ `fcode-pair` trên box và ghép lại.

## Khi gặp lỗi

- *"Mã sai hoặc đã hết hạn…"*: gõ lại `fcode-pair` trên box để lấy mã mới (mỗi mã chỉ thử sai được 5 lần).
- *"Thử quá nhiều lần, đợi N giây."*: đợi đủ thời gian rồi thử lại.
- *"Máy chủ không lưu được, thử lại."*: box không ghi được danh sách thiết bị; thử ghép lại với mã mới.
- *"iPhone này đã bị gỡ khỏi box, hãy ghép lại."*: máy này đã bị gỡ (trên box hoặc từ một máy khác); gõ `fcode-pair` trên box và ghép lại.
- *"Đã xoá ghép trên iPhone này, nhưng box chưa nhận lệnh gỡ…"*: trên box xem danh sách bằng `PC_CONFIG_DIR=/data/home/.fcoding node /data/home/fcoding/server.mjs --devices`, rồi gỡ hẳn bằng lệnh đó với `--revoke <id>` thay cho `--devices`.
- *"Phiên đã đóng."*: chương trình trong phiên đã thoát; bấm **Quay lại** rồi mở lại dự án.
- *"Box đang bận, thử lại sau."*: đợi vài giây rồi thử lại.
- *"Không kết nối được máy chủ."* / *"Không tìm thấy máy chủ."*: kiểm tra mạng và địa chỉ máy chủ.
