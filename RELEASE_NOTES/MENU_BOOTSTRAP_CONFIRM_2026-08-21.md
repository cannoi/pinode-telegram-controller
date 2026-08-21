# Menu bootstrap + xác nhận Live (2026-08-21)

## Menu lệnh Telegram
- **Không** tự `setMyCommands` khi khởi động.
- Sau **≥60 giây** Controller ổn định → quét **một lần duy nhất** trong phiên.
- Nếu `getMyCommands` thiếu lệnh cốt lõi → gửi tin giải thích rõ.
- User xác nhận: `/confirmmenu` → mới nạp menu.
- Bỏ qua: `/skipmenu`.
- Tắt/mở lại Controller → sau 60s quét lại (nếu vẫn thiếu menu).

## Xác nhận 2 bước (cửa sổ Live)
- `/reset` và `/maintenance` **mỗi lần** đều hỏi Y/N trên cửa sổ Live Monitor.
- Không lưu “đã duyệt” khi tắt/mở lại Controller.
- Mỗi lệnh nguy hiểm = một lần xác nhận mới trên window.

## Lệnh mới
- `/confirmmenu` — đồng ý nạp menu
- `/skipmenu` — bỏ qua lần này
