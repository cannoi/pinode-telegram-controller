# ==============================================================================
# APPLY-UPDATES.PS1 (ANTI-PARSE ERROR - NO HERE-STRINGS)
# ==============================================================================
$ErrorActionPreference = "Stop"

# [ERR:01] Check Admin
if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host "[ERR:01] Yeu cau Run as Administrator!" -ForegroundColor Red; Pause; exit 1
}

# [ERR:02] Check Location
$AppRootDir = $PSScriptRoot
if (-not $AppRootDir) { $AppRootDir = Split-Path -Parent $MyInvocation.MyCommand.Definition }
if ($AppRootDir -like "*System32*") {
    Write-Host "[ERR:02] Luu file vao thu muc App Pi Node va chay lai!" -ForegroundColor Red; Pause; exit 2
}

Write-Host "[...] Dang cap nhat Pi Node Controller va tao PROJECT_DOCS.md..." -ForegroundColor Yellow

# 1. Create Core Module
try {
    $ModulesDir = Join-Path $AppRootDir "Modules"
    if (-not (Test-Path $ModulesDir)) { New-Item -ItemType Directory -Path $ModulesDir -Force | Out-Null }
    $PatchFilePath = Join-Path $ModulesDir "Updated_Core_Logic.ps1"

    $CoreLines = @(
        'function Read-NDJSONHistorySafe {',
        '    param([object]$InputPath)',
        '    $parsed = @()',
        '    if (-not $InputPath) { return $parsed }',
        '    $fp = [string]$InputPath',
        '    if (-not (Test-Path $fp -PathType Leaf)) { return $parsed }',
        '    try {',
        '        $lines = [System.IO.File]::ReadAllLines($fp)',
        '        foreach ($l in $lines) {',
        '            if (-not [string]::IsNullOrWhiteSpace($l)) {',
        '                try { $j = $l | ConvertFrom-Json -ErrorAction Stop; if ($j) { $parsed += $j } } catch {}',
        '            }',
        '        }',
        '    } catch {}',
        '    return $parsed',
        '}',
        'function Get-TargetPiContainers {',
        '    $map = @(',
        '        @{ Network = "Mainnet";  Keywords = @("mainnet", "pi-node", "--mainnet", "production network") },',
        '        @{ Network = "Testnet";  Keywords = @("testnet", "pi-node", "--testnet") },',
        '        @{ Network = "Testnet2"; Keywords = @("testnet2", "--testnet2", "testnet goc") }',
        '    )',
        '    $raw = docker ps -a --format "{{.ID}}|{{.Names}}|{{.Image}}|{{.Command}}|{{.Status}}" 2>$null',
        '    $res = @()',
        '    if ($raw) {',
        '        foreach ($line in $raw) {',
        '            $id, $name, $img, $cmd, $stat = $line.Split("|")',
        '            $net = "Unknown"',
        '            foreach ($m in $map) {',
        '                foreach ($kw in $m.Keywords) {',
        '                    if ($name -like "*$kw*" -or $cmd -like "*$kw*" -or $img -like "*$kw*") { $net = $m.Network; break }',
        '                }',
        '                if ($net -ne "Unknown") { break }',
        '            }',
        '            if ($net -ne "Unknown") {',
        '                $res += [PSCustomObject]@{ ContainerID = $id; Name = $name; Network = $net; Image = $img; Status = $stat }',
        '            }',
        '        }',
        '    }',
        '    return $res',
        '}',
        'function Generate-ActionReport {',
        '    param([array]$DoneActions, [array]$PendingActions)',
        '    $r = "=== BAO CAO HANH DONG ===" + [Environment]::NewLine',
        '    $r += "[OK] DA LAM:" + [Environment]::NewLine',
        '    if ($DoneActions.Count -eq 0) { $r += "- Khong co" + [Environment]::NewLine }',
        '    else { foreach ($i in $DoneActions) { $r += "- $($i.Action) | $($i.Timestamp)" + [Environment]::NewLine } }',
        '    $r += "[WAIT] SE LAM:" + [Environment]::NewLine',
        '    if ($PendingActions.Count -eq 0) { $r += "- Khong co" + [Environment]::NewLine }',
        '    else { foreach ($i in $PendingActions) { $r += "- $($i.Action) | UU TIEN: $($i.Priority)" + [Environment]::NewLine } }',
        '    return $r',
        '}'
    )
    Set-Content -Path $PatchFilePath -Value ($CoreLines -join "`r`n") -Encoding UTF8
} catch {
    Write-Host "[ERR:03] Loi ghi Module: $_" -ForegroundColor Red; Pause; exit 3
}

# 2. Patch Smart Import Header cho các file .ps1
try {
    $ImportHeader = 'if (Test-Path "$PSScriptRoot/Modules/Updated_Core_Logic.ps1") { . "$PSScriptRoot/Modules/Updated_Core_Logic.ps1" } elseif (Test-Path "$PSScriptRoot/../Modules/Updated_Core_Logic.ps1") { . "$PSScriptRoot/../Modules/Updated_Core_Logic.ps1" } elseif (Test-Path "$PSScriptRoot/../../Modules/Updated_Core_Logic.ps1") { . "$PSScriptRoot/../../Modules/Updated_Core_Logic.ps1" }'

    $TargetFiles = Get-ChildItem -Path $AppRootDir -Recurse -Filter "*.ps1" | Where-Object { 
        $_.FullName -ne $MyInvocation.MyCommand.Path -and $_.FullName -ne $PatchFilePath 
    }

    foreach ($file in $TargetFiles) {
        $bak = "$($file.FullName).bak"
        if (Test-Path $bak) { Copy-Item -Path $bak -Destination $file.FullName -Force }
        else { Copy-Item -Path $file.FullName -Destination $bak -Force }

        $raw = Get-Content -Path $file.FullName -Raw -Encoding UTF8
        if (-not $raw) { $raw = "" }
        $lines = $raw -split "`r?\n"
        $clean = $lines \vert{} Where-Object {$_ -notlike "*Updated_Core_Logic.ps1*" }
        $final =$ImportHeader + "`r`n" + ($clean -join "`r`n")
        Set-Content -Path $file.FullName -Value$final -Encoding UTF8
    }
} catch {
    Write-Host "[ERR:04] Loi cap nhat file .ps1: $_" -ForegroundColor Red; Pause; exit 4
}

# 3. Auto Generate / Update PROJECT_DOCS.md
try {
    $DocPath = Join-Path$AppRootDir "PROJECT_DOCS.md"
    $TimeStamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"

    $DirectoryStructure = Get-ChildItem -Path $AppRootDir -Recurse \vert{} Where-Object {$_.FullName -notlike "*\.git*" } | Select-Object -ExpandProperty FullName | ForEach-Object {
        $_ -replace [regex]::Escape($AppRootDir), ""
    } | Out-String

    $ExistingLog = ""
    if (Test-Path $DocPath) {
        $FullDoc = Get-Content$DocPath -Raw -Encoding UTF8
        if ($FullDoc -match "(?s)(## NHAT KY CAP NHAT.*)") {
            $ExistingLog =$Matches[1]
        }
    }

    if (-not $ExistingLog) {$ExistingLog = "## NHAT KY CAP NHAT TU DONG (CHANGELOG)`r`n| Thoi Gian | Hanh Dong | Trang Thai |`r`n|---|---|---|"
    }

    $NewLogEntry = "\vert{} $TimeStamp | Chay Apply-Updates: Fix NDJSON, Docker Scan, Smart Import | SUCCESS:00 |"
    $UpdatedLog =$ExistingLog.TrimEnd() + "`r`n" + $NewLogEntry

    $DocLines = @(
        "# TAI LIEU KIEN TRUC & SO DO UNG DUNG PI NODE CONTROLLER",
        "> File nay duoc tu dong tao va cap nhat boi Apply-Updates.ps1.",
        "",
        "---",
        "",
        "## 1. TONG QUAN HE THONG",
        "* Ten ung dung: Pi Node Controller PRO",
        "* Moi truong chay: Windows PowerShell 5.1+ / PowerShell Core (Admin)",
        "* Chuc nang chinh: Dieu khien Pi Node, Telegram Bot, kiem tra Docker Container, doc log NDJSON.",
        "",
        "---",
        "",
        "## 2. CAU TRUC THU MUC DU AN (PROJECT TREE)",
        "```text",
        $DirectoryStructure.TrimEnd(),
        "```",
        "",
        "---",
        "",
        "## 3. CAC PHAN HE VA MODULE CHINH",
        "* Apply-Updates.ps1: Bo cap nhat tu dong va tao tai lieu.",
        "* Modules/Updated_Core_Logic.ps1: Chua logic loi.",
        "* Controller/: Chua file giao dien dieu khien chinh.",
        "* Config/: Chua thiet lap tham so.",
        "",
        "---",
        "",
        $UpdatedLog
    )

    Set-Content -Path $DocPath -Value ($DocLines -join "`r`n") -Encoding UTF8
    Write-Host "[SUCCESS:00] CAP NHAT CODE VA FILE PROJECT_DOCS.MD THANH CONG!" -ForegroundColor Green
} catch {
    Write-Host "[ERR:05] Loi ghi file PROJECT_DOCS.md: $_" -ForegroundColor Red; Pause; exit 5
}

Pause
1" } elseif (Test-Path "$PSScriptRoot/../Modules/Updated_Core_Logic.ps1") { . "$PSScriptRoot/../Modules/Updated_Core_Logic.ps1" }'

foreach ($file in $TargetFiles) {
    Write-Host "[*] Đang tối ưu đường dẫn cho: $($file.Name)..." -ForegroundColor Yellow
    
    # Khôi phục file từ backup cũ nếu có để làm sạch mã cũ bị lỗi
    $backupPath = "$($file.FullName).bak"
    if (Test-Path -Path $backupPath) {
        Copy-Item -Path $backupPath -Destination $file.FullName -Force
    } else {
        Copy-Item -Path $file.FullName -Destination $backupPath -Force
    }
    
    # Lọc bỏ các dòng import cũ và chèn SmartImportLine
    $fileLines = Get-Content -Path $file.FullName -Encoding UTF8
    $cleanedLines = $fileLines | Where-Object { $_ -notlike "*Updated_Core_Logic.ps1*" }
    
    $newContent = @($SmartImportLine) + $cleanedLines
    Set-Content -Path $file.FullName -Value $newContent -Encoding UTF8
    Write-Host "    └--> [OK] Cập nhật Smart Import thành công." -ForegroundColor Green
}

Write-Host "==================================================" -ForegroundColor Cyan
Write-Host " 🎉 CẬP NHẬT HOÀN TẤT & ĐÃ SỬA LỖI ĐƯỜNG DẪN THƯ MỤC CON!" -ForegroundColor Green
Write-Host " Bạn có thể chạy lại file Controller ngay bây giờ." -ForegroundColor Green
Write-Host "==================================================" -ForegroundColor Cyan
Pause
e-Host "    └--> [OK] Cập nhật thành công." -ForegroundColor Green
    } else {
        Write-Host "    └--> [!] Đã liên kết trước đó." -ForegroundColor Gray
    }
}

Write-Host "==================================================" -ForegroundColor Cyan
Write-Host " 🎉 DỌN DẸP & CẬP NHẬT HOÀN TẤT THÀNH CÔNG!" -ForegroundColor Green
Write-Host " - Tự động xóa file rác trong System32: HOÀN TẤT." -ForegroundColor Green
Write-Host " - Khắc phục lỗi đọc log NDJSON History: HOÀN TẤT." -ForegroundColor Green
Write-Host "==================================================" -ForegroundColor Cyan
Pause
