# Pi Node Telegram Controller PRO — Windows Edition

Trợ lý giám sát và vận hành Pi Node trên Windows qua Telegram.

## Có gì trong bản này?

- Telegram `/status`, `/monitor`, `/report`, `/diagnostic`
- `/docker`, `/disk`, `/logs`, `/screenshot`
- `/cleanram`
- `/maintenance` + `/confirm` + `/cancel`
- `/reset` + `/confirmreset` + `/cancel`
- `/scheduler`
- `/ask` với Hermes
- Natural Language với Gemini
- Lịch sử Node và lịch sử hội thoại
- Smart Monitor + cảnh báo theo ngưỡng
- Diagnostic PRO
- Screenshot/OCR PiCheck
- Windows Task Scheduler auto-start
- Các script PowerShell bảo trì, mạng và Docker

## Bảo mật

**Không commit Bot Token, Chat ID hoặc Gemini API Key.**

Bản GitHub chỉ chứa cấu hình mẫu. Sau khi tải source về Windows:

1. Chạy `Setup_Config.bat` hoặc `Setup_Config.ps1`.
2. Nhập Telegram Bot Token, Chat ID và Gemini API Key.
3. Chạy `Start_Controller.bat` bằng quyền Administrator lần đầu nếu cần.
4. Gửi `/status` và `/monitor` trong Telegram.

`Config/PiNode_Config.ps1` được `.gitignore` để tránh đẩy credential lên GitHub.

## Kiến trúc

```text
Telegram
   ↓
Controller/PiNode_Telegram_Controller_PRO_v2.0.ps1
   ├── Smart Monitor
   ├── Diagnostic PRO
   ├── Gemini
   ├── Hermes
   ├── Docker
   ├── Windows metrics
   └── Maintenance / Recovery
```

## Lưu ý quyền

Các thao tác thay đổi hệ thống như reset mạng, firewall, Docker/WSL, maintenance cần quyền Administrator và/hoặc xác nhận Telegram.

Không cho Gemini tự chạy PowerShell tùy ý. AI chỉ định tuyến vào các route đã đăng ký trong Controller.

## GitHub

Repository nên giữ nguyên cấu trúc thư mục của project nhưng **không commit**:
- `Config/PiNode_Config.ps1`
- Logs
- State
- history runtime
- cache/temporary files
- `__pycache__` / `.pyc` nếu có

## Phiên bản

Windows Edition dựa trên bộ chức năng `v2.8 SMART ROBUST` được đóng gói lại theo hướng GitHub-safe.
