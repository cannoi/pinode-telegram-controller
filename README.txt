﻿PI NODE TELEGRAM CONTROLLER PRO

Đọc hướng dẫn đầy đủ: HUONG_DAN_SU_DUNG.txt

Cài nhanh:
1. Start_Controller.bat
2. Nhập Bot Token + Chat ID + Gemini Key
3. Telegram: /status hoặc /monitor

Tạo Key miễn phí:
- Bot: https://t.me/BotFather
- AI Google: https://aistudio.google.com/apikey

Ủng hộ: /donate — MB Bank 0905428801 — TRAN HUU NGHI


AI NGON NGU TU NHIEN (GEMINI)
------------------------------
Controller co the dung Google Gemini de hieu tin nhan Telegram khong theo lenh.
Vi du: "May toi the nao roi?", "Tien hanh bao cao nhanh", "May ngay nay Pi Node toi on khong?", "Cho toi xem Docker", "Chup anh man hinh".
Gemini duoc nap san Knowledge Base ve muc dich app, cai dat, cau truc file, chuc nang tung script, lenh, scheduler va xu ly su co.
Cau hoi can du lieu thuc te se duoc chuyen thanh thao tac Controller; AI khong tu y chay PowerShell.
Maintenance va Reset van yeu cau xac nhan de tranh thao tac nguy hiem.



--- v2.3 NATURAL LANGUAGE + DYNAMIC HISTORY ---
Tin nhan tu nhien co tin nhan xac nhan da nhan va dang phan tich. Cac cau hoi thong ke tuan/thang/khoang N ngay duoc quy doi thanh so ngay va tinh tu node_history.json. Gemini duoc cap du lieu history gioi han de phan tich nhanh khi can.


V2.4 SMART STATISTICS:
- Natural language hiểu câu hỏi theo ngữ nghĩa.
- Thống kê động theo 1/7/14/30/90/180/365 ngày và N ngày/tuần/tháng.
- Nếu hỏi một chỉ số cụ thể trong quá khứ (nhiệt độ/RAM/CPU...), Controller trả thống kê đúng chỉ số thay vì báo cáo tổng quát.
- Câu hỏi nhiệt độ có min/max/trung bình/trung vị/dải 25-75%, đỉnh nhiệt, các dải phổ biến và tỷ lệ mẫu >=70°C.


## Diagnostic PRO Integration
The main Controller now includes `Pi_Node_Diagnostic_PRO.ps1`. Natural-language diagnostic requests can invoke it, and Gemini can analyze `diagnostic_latest.json`. The diagnostic is read-only.
