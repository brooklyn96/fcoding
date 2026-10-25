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

Mẹo: iPhone chỉ báo tên chung là "iPhone", nên mọi máy trong danh sách thiết bị của box đều mang tên đó. Muốn đặt tên riêng, trên box gõ kèm tên khi lấy mã, ví dụ `fcode-pair "iPhone X của tôi"`; box sẽ dùng tên này.

Sau khi ghép, iPhone nhớ box trong Keychain; mở ứng dụng là vào thẳng danh sách dự án. Box khởi động lại thì không phải ghép lại.

**Thêm một iPhone mới bằng mã QR** (khi đã có một iPhone ghép rồi):

1. Trên iPhone cũ: **Cài đặt → Thêm thiết bị (mã QR)**. Mã dùng 1 lần, hết hạn sau **2 phút** (có đồng hồ đếm ngược; hết hạn thì bấm **Tạo mã mới**).
2. Trên iPhone mới (đã cài FCode): mở **Camera**, quét mã, chạm thông báo **Mở trong FCode**, rồi bấm **Ghép**. Không quét được thì bấm **Gửi link** để gửi link qua AirDrop hoặc Zalo.

## 4. Cách dùng

- **Màn hình chính** gom mọi phiên trên box, việc cần bạn lên đầu. Danh sách tự cập nhật mỗi 5 giây; kéo xuống để cập nhật ngay.
  - Dòng chữ cam dưới **FCode** cho biết bao nhiêu phiên đang chờ bạn.
  - **Hàng dự án** (trượt ngang): chạm **Tất cả** hoặc một dự án để chỉ xem phiên của dự án đó. Số cam = số phiên đang chờ bạn; số xám = số phiên.
  - **Cần bạn**: phiên đang hỏi bạn, luôn mở sẵn, hiện đầy đủ câu hỏi. Câu hỏi có/không có nút **y · Đồng ý** và **n · Từ chối** (gửi y hoặc n kèm Enter); câu khác có nút **Trả lời** (mở phiên, con trỏ ở ô nhập). Nút **Mở** mở phiên.
  - **Đang chạy** và **Đang nghỉ**: mặc định thu gọn thành một dòng; chạm để mở hoặc thu gọn. Ứng dụng nhớ lựa chọn này.
  - Chấm xanh dương cạnh tên = có thay đổi bạn chưa xem. Mở phiên là tính đã đọc.
  - Vuốt trái một phiên: **Đã đọc / Chưa đọc**, hoặc **Xoá** (có hỏi xác nhận; chương trình trong phiên bị tắt).
  - **Thanh dưới cùng** (Tất cả / omp / claude / codex / shell): chỉ xem phiên của một chương trình.
- **Phiên mới** (nút **+** góc phải): luôn tạo một phiên MỚI, không mở lại phiên cũ (phiên cũ mở từ danh sách). Chọn chương trình rồi chọn dự án; nếu thanh dưới đang chọn một chương trình thì bỏ qua bước chọn chương trình.
- **Cài đặt**: nút bánh răng góc trái.
- **Trong phiên**:
  - Thanh trên cùng: nhãn tên phiên có màu theo chương trình (cam = claude, tím = omp, xanh = codex). Tên dài thì bị cắt ở giữa.
  - Chữ trên màn hình có màu như trên laptop; các biểu tượng nhỏ (nhánh git, thư mục, …) hiện đúng nhờ font biểu tượng đi kèm ứng dụng.
  - Khi bạn đang ở cuối, màn hình tự cuộn theo dòng mới. Nếu bạn cuộn lên để đọc, màn hình đứng yên dù có chữ mới; bấm nút tròn **↓** (hoặc cuộn về cuối) để theo lại. Gửi tin nhắn cũng đưa về cuối.
  - Link trong màn hình được gạch chân; chạm để mở trong trình duyệt. Link dài bị omp cắt xuống dòng thường vẫn mở đúng cả link. Nhấn giữ để chép chữ trên màn hình.
  - Chỉ trong phiên omp; ở chương trình khác, hoặc khi có chữ đứng trước link, link bị cắt dòng chỉ mở phần đầu.
  - Link bị cắt ngay trước một chữ thường (không có - / _ …) có thể chỉ mở được phần đầu.
  - **A-** / **A+**: chữ nhỏ hơn / to hơn.
  - Chấm màu: xanh lá = đang kết nối trực tiếp, vàng = đang cập nhật định kỳ, cam = đang kết nối, đỏ = mất kết nối.
  - Khung gõ mặc định được ẩn để màn hình rộng hơn. Bấm nút tròn **bàn phím** ở góc phải dưới: khung gõ hiện ra và bàn phím iPhone bật lên luôn.
  - Muốn dời nút **bàn phím**: giữ và kéo nó đi, thả ra thì nút tự dạt vào mép trái hoặc phải gần nhất. Ứng dụng nhớ chỗ này.
  - Ẩn khung gõ: bấm nút **⌄** ở cuối hàng phím, hoặc vuốt xuống trên thanh nhỏ ở đầu khung gõ (hay trên nền của khung).
  - Sau khi gửi xong, khung gõ tự ẩn. Bấm nút **ghim** (hình đinh ghim) để giữ khung gõ luôn hiện: khi đã ghim, mở phiên là thấy khung gõ và gửi xong nó vẫn ở đó. Bấm lại để bỏ ghim. Khi đã ghim, sau mỗi lần gửi bàn phím sụp xuống rồi bật lên lại trong chốc lát; đó là bình thường (để ô nhập được xoá sạch khi gõ tiếng Việt).
  - Ô nhập cao 1 dòng, tự giãn tới 4 dòng khi bạn gõ dài.
  - Nút tròn **↑** bên phải ô nhập = **Gửi** (gửi rồi nhấn Enter). Bấm khi ô trống = chỉ nhấn Enter. **Giữ lâu** nút này để chọn **Gửi không Enter**.
  - Nội dung đang soạn được giữ lại cho từng phiên (kể cả khi ẩn khung gõ, hay khi iPhone bị gỡ khỏi box và phải ghép lại). Nó bị xoá khi gửi thành công, khi bạn xoá phiên đó, hoặc khi bạn tự gỡ máy (**Gỡ iPhone này** / **Gỡ mọi thiết bị**).
  - Hàng phím nhanh: Esc, Ctrl+C, mũi tên, Tab, ⇧Tab, Enter, y, n. Nút **/** chèn các lệnh hay dùng (/model, /clear, …). Các phím được gửi đúng thứ tự bạn bấm.
  - Chỉ trong phiên omp: thêm phím **Agents**, **^O** và lệnh **/hub**. Xem các agent con của omp: bấm **Agents** (mở danh sách agent), chọn bằng ↑ / ↓, bấm **Enter** để mở, **Esc** để quay ra; **^O** mở rộng một mục.
  - Khi xoay ngang: ô nhập thấp lại để màn hình còn chỗ; nút ghim và **⌄** nằm cạnh ô nhập; bấm nút **phím nhanh** bên trái ô nhập để hiện / ẩn hàng phím nhanh.
  - Khi bạn chuyển sang ứng dụng khác, kết nối tạm dừng; mở lại ứng dụng là tự kết nối lại.
- **Cài đặt** (bánh răng):
  - **Gỡ iPhone này**: gỡ điện thoại này khỏi box.
  - **Gỡ mọi thiết bị**: gỡ tất cả thiết bị đã ghép với box (có hỏi xác nhận).
  - **Gỡ iPhone này** xoá ghép trên iPhone này ngay, kể cả khi box không trả lời.
  - **Gỡ mọi thiết bị** chỉ đăng xuất iPhone này khi box xác nhận; nếu lỗi, iPhone vẫn đăng nhập và có nút **Thử lại**.
  - Muốn dùng lại thì gõ `fcode-pair` trên box và ghép lại.

## Khi gặp lỗi

- *"Mã sai hoặc đã hết hạn…"*: gõ lại `fcode-pair` trên box để lấy mã mới (mỗi mã chỉ thử sai được 5 lần).
- *"Thử quá nhiều lần, đợi N giây."*: đợi đủ thời gian rồi thử lại.
- *"Máy chủ không lưu được, thử lại."*: box không ghi được danh sách thiết bị; thử ghép lại với mã mới.
- *"iPhone này đã bị gỡ khỏi box, hãy ghép lại."*: máy này đã bị gỡ (trên box hoặc từ một máy khác); gõ `fcode-pair` trên box và ghép lại.
- *"Đã xoá ghép trên iPhone này, nhưng box chưa nhận lệnh gỡ…"*: trên box xem danh sách bằng `PC_CONFIG_DIR=/data/home/.fcoding node /data/home/fcoding/server.mjs --devices`, rồi gỡ hẳn bằng lệnh đó với `--revoke <id>` thay cho `--devices`.
- *"Phiên đã đóng."*: chương trình trong phiên đã thoát; bấm **Quay lại** rồi mở lại dự án.
- *"Box đang bận, thử lại sau."*: đợi vài giây rồi thử lại.
- *"Không kết nối được máy chủ."* / *"Không tìm thấy máy chủ."*: kiểm tra mạng và địa chỉ máy chủ.
