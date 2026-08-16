# Pi Node Telegram Controller PRO

Trợ lý vận hành **Pi Node** 24/7 qua Telegram trên Windows.

Giám sát đồng bộ, cổng, Docker, RAM/CPU/nhiệt độ — cảnh báo sự cố thật, báo cáo định kỳ, điều khiển từ xa bằng lệnh hoặc tiếng Việt tự nhiên.

## Tính năng chính

- Smart Monitor: đọc PiCheck / Pi Desktop + fallback sensor hệ thống
- Phân mức sự cố: Soft / Warning / Critical (không báo giả khi thiếu PiCheck)
- Lịch tự động chỉnh trên Telegram (`/scheduler`)
- Phong cách trả lời theo người dùng (`/settings`: simple | balanced | numeric)
- AI (Gemini): phân tích lịch sử, tư vấn nâng cấp, chẩn đoán
- Lệnh: `/status` `/monitor` `/report` `/diagnostic` `/reset` `/cleanram` `/maintenance` `/docker` `/disk` `/logs` `/screenshot` `/ask` …

## Yêu cầu

- Windows 10/11
- PowerShell 5.1+
- Docker Desktop (cho Pi Node)
- Telegram Bot Token + Chat ID
- (Tuỳ chọn) Gemini API Key — [Google AI Studio](https://aistudio.google.com/apikey)

## Cài đặt nhanh

1. Clone repo hoặc tải ZIP:
   ```bash
   git clone https://github.com/cannoi/pinode-telegram-controller.git
   ```
2. Chạy `Setup_Config.bat` **hoặc** sửa `Config/PiNode_Config.ps1`:
   - `BotToken` — token từ @BotFather
   - `ChatId` — ID chat/nhóm
   - `GeminiApiKey` — nếu dùng AI
3. `Start_Controller.bat` (cửa sổ hiện) hoặc `Start_Controller_Hidden.bat`
4. Trên Telegram: `/help` → `/monitor` → `/settings`

## Lệnh cài đặt phong cách

| Lệnh | Mô tả |
|------|--------|
| `/settings` | Menu + giải thích |
| `/settings style simple` | Dễ hiểu, ít số thô |
| `/settings style balanced` | Cân bằng (mặc định) |
| `/settings style numeric` | Ưu tiên số liệu |
| `/scheduler` | Lịch quét, báo cáo, tự reset |

Chi tiết: xem `HUONG_DAN_SU_DUNG.txt`.

## Cấu trúc thư mục

```
Config/          # PiNode_Config.ps1 — token & ngưỡng
Controller/      # Bot chính (PowerShell)
Data/            # Monitor, diagnostic, knowledge, scripts
Commands/        # commands.json
Modules/         # Ghi chú module
*.bat            # Start / Stop / Setup / Task
```

## Bảo mật

- **Không** commit token/API key thật.
- File `Config/PiNode_Config.ps1` trong repo chỉ chứa placeholder.
- Runtime tạo `State/`, `Logs/`, history JSON — đã có trong `.gitignore`.

## SoloHost / Docker

Bản này chạy **native Windows PowerShell** (OCR cửa sổ Pi Desktop, Task Scheduler).  
Package SoloHost cần image Linux riêng và registry công khai — xem nhánh/docs SoloHost nếu có.

## Phiên bản

**v2.9 SMART_OPS** — dựa trên v2.8 SMART_ROBUST:

- Giữ đủ pipeline monitor / diagnostic / reset / scheduler
- Thêm `/settings` và nhận định vận hành theo phong cách khách
- Severity thông minh, nhiệt độ fallback, ít báo động giả

## Hỗ trợ

Issues: https://github.com/cannoi/pinode-telegram-controller/issues

Ủng hộ phát triển: xem lệnh `/donate` trên bot.
