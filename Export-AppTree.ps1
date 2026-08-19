.\Export-AppTree.ps1
$AppRootDir = Get-Location

$OutputFile = Join-Path$AppRootDir "PROJECT_TREE.md"



function Build-Tree {

    param([string]$Path, [string]$Prefix = "")

    $items = Get-ChildItem -LiteralPath $Path -ErrorAction SilentlyContinue \vert{} Where-Object {$_.Name -notlike ".*" -and $_.Extension -ne ".bak" } \vert{} Sort-Object { -not $_.PSIsContainer }, Name

    $count =$items.Count

    for ($i = 0; $i -lt $count; $i++) {

        $item =$items[$i]$isLast = ($i -eq$count - 1)

        $connector = if ($isLast) { "└── " } else { "├── " }

        if ($item.PSIsContainer) {

            $script:TreeLines.Add($Prefix + $connector +$item.Name + "/")

            $newPrefix = $Prefix + (if ($isLast) { "    " } else { "│   " })

            Build-Tree -Path $item.FullName -Prefix$newPrefix

        } else {

            $script:TreeLines.Add($Prefix + $connector +$item.Name)

        }

    }

}



$script:TreeLines = [System.Collections.Generic.List[string]]::new()

$script:TreeLines.Add((Split-Path$AppRootDir -Leaf) + "/")

Build-Tree -Path $AppRootDir



$TreeText = $script:TreeLines -join [Environment]::NewLine$DateStr = Get-Date -Format "yyyy-MM-dd HH:mm:ss"

$Header = "# SƠ ĐỒ CẤU TRÚC APP" + [Environment]::NewLine + "> Cập nhật: " + $DateStr + [Environment]::NewLine + [Environment]::NewLine$CodeBlockStart = "```text" + [Environment]::NewLine

$CodeBlockEnd = [Environment]::NewLine + "```"

$DocContent = $Header + $CodeBlockStart + $TreeText + $CodeBlockEnd



Set-Content -Path $OutputFile -Value $DocContent -Encoding UTF8

Write-Host "DA_TAO_FILE_PROJECT_TREE_THANH_CONG" -ForegroundColor Green

