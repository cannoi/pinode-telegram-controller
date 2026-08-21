# Tích hợp Confirm Live Window + Telegram Menu (2026-08-21)

## Module 1 — Xác nhận lệnh quan trọng trên cửa sổ Live

- `Modules/Admin_Elevate.ps1` — tự nâng quyền Administrator một lần
- `Modules/Command_Confirm.ps1` — khóa Chat ID, xác nhận /ps /cmd qua Telegram, /reset /maintenance qua cửa sổ Live (Y/N)
- `Data/PiNodeMonitorLive_CMD_v2/PiNodeMonitorLive.ps1` — thêm `Test-PendingDangerousAction` (hiển thị cảnh báo, beep, chờ Y/N)

Hành vi mới:
- `/reset` và `/maintenance` → gửi pending_action.json → cửa sổ Live hỏi Y/N → mới chạy script
- `/cancel` cũng hủy pending Live
- Chat ID lạ vẫn bị bỏ qua (như cũ)

## Module 2 — MENU chatbot cho ID người dùng khai báo

- `Modules/Telegram_Menu.ps1`
  - `Set-PiNodeBotCommands`: gọi `setMyCommands` **một lần** (hoặc khi Chat ID đổi)
  - State: `State/bot_commands_set.json` — kiểm tra tồn tại + đúng ChatId → không gọi lại khi tắt/mở app
  - `Get-PiNodeStartMenuText` + handler `/start`

## File đã chỉnh trong Controller

- Load 3 module mới + gọi `Confirm-AdminRights` + `Set-PiNodeBotCommands`
- Handler `/reset`, `/maintenance`, `/cancel`, `/start`

## Cách dùng sau khi cập nhật

1. Giữ nguyên Config/PiNode_Config.ps1 (token + ChatId)
2. Chạy Start_Controller.bat (nên Run as Administrator)
3. Cửa sổ Live phải đang mở để xác nhận /reset /maintenance
4. Thử: `/maintenance` → nhìn cửa sổ Live nhấn Y
5. Menu lệnh Telegram cập nhật tự động lần đầu

