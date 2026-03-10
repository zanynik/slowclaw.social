# Hợp đồng tầm nhìn ZeroClaw

Tài liệu này chuyển hóa tầm nhìn sản phẩm thành các cổng kiểm soát ở cấp repository.

## 0. Tóm tắt

- **Mục đích:** biến tầm nhìn sản phẩm thành thứ có thể thực thi trong lập kế hoạch, triển khai và review.
- **Đối tượng:** contributor, maintainer, reviewer và coding agent.
- **Phạm vi:** lập kế hoạch tính năng, quyết định kiến trúc, mức sẵn sàng của PR và kết quả review.
- **Ngoài phạm vi:** thay thế các hợp đồng chi tiết theo hệ thống con trong `AGENTS.md`, `CONTRIBUTING.md` hoặc tài liệu tham chiếu runtime.

---

## 1. Tầm nhìn sản phẩm cốt lõi

ZeroClaw nên phát triển thành một cỗ máy nội dung và tuyển chọn cá nhân tối giản, gọn gàng, đa nền tảng; có thể thu thập đầu vào số cá nhân, tự động biến đổi nội dung, tuyển chọn feed cá nhân hóa và kết nối người dùng qua các giao thức xã hội mở.

Khi xuất hiện đánh đổi, mặc định ưu tiên theo thứ tự sau:

1. Quyền riêng tư và quyền kiểm soát của người dùng
2. Tính đơn giản và tải nhận thức thấp
3. Giao thức mở và tính di động
4. Khả năng mở rộng qua skills/tools/contracts
5. Tối ưu tiện lợi

---

## 2. Các bất biến sản phẩm không được vi phạm

| Mảng tầm nhìn | Hợp đồng ở repository |
|---|---|
| UX gọn gàng, tối giản | Từ chối các thay đổi thêm bước thao tác không cần thiết, bề mặt phân mảnh hoặc gánh nặng cấu hình có thể tránh được nếu không có lý do giá trị người dùng được ghi rõ. |
| Kiến trúc lấy AI làm trung tâm | Hành vi mới phải được tách thành hợp đồng tường minh, giao diện có kiểu và luồng có thể kiểm tra để agent có thể mở rộng và xác minh an toàn. |
| Ưu tiên hệ sinh thái mở | Ưu tiên hành vi phù hợp với BlueSky, Nostr, RSS và Atom hơn là khóa chặt vào nền tảng đóng. Tích hợp đóng phải là tùy chọn, không phải nền tảng cốt lõi. |
| Thiết kế mở rộng được | Ưu tiên trait implementation, tools, skills và điểm mở rộng kiểu plugin hơn là các trường hợp đặc biệt bị hardcode. |
| Mục tiêu đa nền tảng | Không thiết kế hành vi mới theo cách chỉ hoạt động trên một desktop OS trừ khi giới hạn đó là tạm thời, rõ ràng và được ghi tài liệu. |
| Vector hóa cục bộ hoặc do người dùng kiểm soát | Không biến xử lý vector từ xa thành mặc định. Nếu cần chạy từ xa, phải có ý định rõ ràng của người dùng và dùng credential do chính người dùng sở hữu. |
| Thu thập đa phương thức | Giữ định hướng hỗ trợ nhập liệu text, audio và video thay vì thu hẹp hệ thống quanh giả định chỉ có text. |
| Bộ máy biến đổi nội dung | Thêm các workflow tích hợp ban đầu theo cách cho phép mở rộng sau này bằng skills/tools do cộng đồng phát triển mà không phải viết lại hệ thống con. |
| Tuyển chọn cá nhân hóa | Thay đổi về feed/tuyển chọn nên tăng cường mức liên quan dựa trên đầu vào người dùng, embedding, độ tương đồng hoặc độ tương phản có chủ đích thay vì chỉ dựa trên độ phổ biến chung. |
| Kết nối và khám phá | Tính năng xã hội/khám phá nên ưu tiên sự tương hợp có ý nghĩa trên các hệ sinh thái mở thay vì phụ thuộc vào social graph đóng. |
| Duyệt nháp trước khi đăng | Luồng xuất bản phải giữ một giai đoạn duyệt/nháp riêng thay vì buộc đăng ngay lập tức. |
| Ranh giới xuất bản | BlueSky tiếp tục là đường xuất bản nội dung ngắn; Nostr tiếp tục là đường xuất bản nội dung dài/mở, trừ khi có thay đổi hợp đồng được ghi rõ. |
| Nạp feed mở | Không làm suy giảm hỗ trợ RSS/Atom hoặc coi đó là phần phụ. |

---

## 3. Cổng lập kế hoạch

Mọi đề xuất tính năng, kế hoạch hoặc issue làm thay đổi hành vi hướng người dùng phải trả lời rõ các câu hỏi sau:

1. Công việc này thúc đẩy yêu cầu tầm nhìn nào?
2. Yêu cầu tầm nhìn nào có thể bị suy yếu ngoài ý muốn?
3. Vì sao hình thái đơn giản nhất của iteration này là đủ?
4. Điểm mở rộng hiện có nào nên mang hành vi này?
5. Đường rollback là gì nếu thay đổi làm hại tính đơn giản, quyền riêng tư hoặc tính mở?

Nếu đề xuất không thể trả lời rõ các câu hỏi này thì chưa sẵn sàng để triển khai.

---

## 4. Quy tắc thiết kế cho các thay đổi tương lai

- Ưu tiên mở rộng qua traits, tools và skills trước khi thêm nhánh logic cắt ngang.
- Ưu tiên tích hợp giao thức mở trước khi phụ thuộc vào nền tảng sở hữu độc quyền.
- Giữ vector hóa theo hướng local-first và phạm vi credential hẹp.
- Giữ hành vi AI tường minh, có kiểu và có thể kiểm tra; tránh "ma thuật" chỉ nằm trong prompt mà không thể review.
- Giữ đường phát triển rõ ràng cho macOS, iOS, Windows và Android khi đưa vào các giả định UI/runtime.
- Giữ các workflow biến đổi tích hợp nhỏ gọn và dễ test; khả năng mở rộng từ cộng đồng phải vẫn thực hiện được mà không viết lại lõi.
- Xem nháp, xuất bản và nạp dữ liệu là các bề mặt riêng với hợp đồng tường minh.

---

## 5. Cổng PR

Mọi PR thay đổi hành vi, kiến trúc, tài liệu lập kế hoạch hoặc luồng hướng người dùng phải có mục `Vision Alignment` trong PR template.

Mục đó phải nêu rõ:

- các yêu cầu tầm nhìn bị ảnh hưởng
- tác động lên tính đơn giản/tải nhận thức
- liệu sự phù hợp với giao thức mở có được giữ nguyên hay không
- liệu khả năng mở rộng qua traits/tools/skills có được giữ nguyên hay không
- liệu các tác động đa nền tảng đã được hiểu hay chưa
- liệu các ràng buộc về quyền riêng tư/vector hóa cục bộ có được giữ nguyên hay không
- liệu hợp đồng về xuất bản hoặc nạp dữ liệu có thay đổi hay không

Nếu bất kỳ câu trả lời nào là tiêu cực, PR phải giải thích ngoại lệ và mô tả rollback.

---

## 6. Cổng review

Reviewer nên chặn hoặc yêu cầu thiết kế lại khi thay đổi:

- làm tăng độ phức tạp sản phẩm mà không có lý do hướng người dùng đủ mạnh
- hardcode hành vi vốn nên nằm sau một điểm mở rộng
- biến nền tảng đóng hoặc dịch vụ vector từ xa thành bắt buộc theo mặc định
- thu hẹp hỗ trợ đa nền tảng trong tương lai mà không nêu rõ phạm vi
- làm suy yếu hợp đồng về duyệt nháp, xuất bản hoặc nạp RSS/Atom
- tuyên bố phù hợp với tầm nhìn nhưng không có bằng chứng trong PR

---

## 7. Mặc định triển khai

Khi hướng đi đúng chưa rõ ràng, dùng các mặc định sau:

- mặc định chọn thay đổi nhỏ, có thể hoàn tác
- mặc định chọn giao thức mở thay vì API đóng
- mặc định chọn xử lý cục bộ/riêng tư thay vì tiện lợi từ xa
- mặc định chọn điểm mở rộng thay vì logic nhúng một lần
- mặc định chọn ràng buộc sản phẩm tường minh thay vì fallback âm thầm

---

## 8. Tài liệu quản trị liên quan

- [../../AGENTS.md](../../AGENTS.md)
- [../../CONTRIBUTING.md](../../CONTRIBUTING.md)
- [pr-workflow.md](pr-workflow.md)
- [reviewer-playbook.md](reviewer-playbook.md)

---

## 9. Ghi chú bảo trì

- **Chủ sở hữu:** các maintainer chịu trách nhiệm về hướng đi sản phẩm và quản trị repository.
- **Kích hoạt cập nhật:** khi tầm nhìn thay đổi, có thêm trụ cột sản phẩm hoặc xuất hiện xung đột review lặp lại về hướng sản phẩm.
- **Lần review cuối:** 2026-03-10.
