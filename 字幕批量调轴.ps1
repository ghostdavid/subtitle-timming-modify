Add-Type -AssemblyName System.Windows.Forms

# 1. 弹出可视化文件选择框 (增加对所有主流字幕格式的支持)
$dialog = New-Object System.Windows.Forms.OpenFileDialog
$dialog.Filter = "支持的字幕文件 (*.srt;*.ass;*.ssa;*.vtt)|*.srt;*.ass;*.ssa;*.vtt|所有文件 (*.*)|*.*"
$dialog.Multiselect = $true
$dialog.Title = "请选择需要调轴的字幕文件 (支持按住Ctrl或Shift多选)"

if ($dialog.ShowDialog() -ne [System.Windows.Forms.DialogResult]::OK) {
    Write-Host "未选择任何文件，程序即将退出。" -ForegroundColor Yellow
    Start-Sleep -Seconds 2
    exit
}

$files = $dialog.FileNames
Write-Host "已选择 $($files.Count) 个文件。" -ForegroundColor Cyan

# 2. 输入时间偏移量
Write-Host "`n请输入时间偏移量（单位：毫秒，1秒=1000毫秒）。"
Write-Host " -> 【正数】表示字幕延后显示（例如输入 500 表示延后0.5秒）"
Write-Host " -> 【负数】表示字幕提前显示（例如输入 -1500 表示提前1.5秒）"
$offsetStr = Read-Host "请输入偏移量"

$offsetMs = 0
if (-not [int]::TryParse($offsetStr, [ref]$offsetMs)) {
    Write-Host "输入错误：请输入有效的整数！" -ForegroundColor Red
    Start-Sleep -Seconds 3
    exit
}

if ($offsetMs -eq 0) {
    Write-Host "偏移量为 0，不需要进行任何调整。" -ForegroundColor Yellow
    Start-Sleep -Seconds 2
    exit
}

# 3. 核心：自适应时间轴处理逻辑
function Adjust-TimeCode {
    param([string]$tc, [int]$offset, [string]$format)
    
    # 统一将逗号替换为句点，方便 TimeSpan 解析
    $tcNorm = $tc -replace ',', '.'
    
    # VTT 格式有时会省略小时 (例如 05:23.456)，需补全为 00:05:23.456 才能正确解析
    if (($tcNorm.Split(':')).Count -eq 2) {
        $tcNorm = "00:" + $tcNorm
    }
    
    $ts = [timespan]::Parse($tcNorm)
    $ts = $ts.Add([timespan]::FromMilliseconds($offset))
    
    # 防止因提前太多导致时间变成负数
    if ($ts.TotalMilliseconds -lt 0) {
        $ts = [timespan]::Zero
    }
    
    # 根据不同的字幕规范输出对应的时间格式
    if ($format -eq "SRT") {
        return $ts.ToString("hh\:mm\:ss\,fff")
    } elseif ($format -eq "VTT") {
        # VTT 标准为 HH:mm:ss.fff
        return $ts.ToString("hh\:mm\:ss\.fff")
    } elseif ($format -eq "ASS") {
        # ASS/SSA 标准为 H:mm:ss.cc (单小时，百分秒)
        return $ts.ToString("h\:mm\:ss\.ff")
    }
    return $tc
}

# 4. 遍历处理所有选择的文件
foreach ($file in $files) {
    Write-Host "`n正在处理: $($file)"
    
    $dir = Split-Path $file -Parent
    $filename = Split-Path $file -Leaf
    $ext = [System.IO.Path]::GetExtension($filename).ToLower()
    $backupDir = Join-Path $dir "backup"
    
    # 检查并创建 backup 文件夹
    if (-not (Test-Path $backupDir)) {
        New-Item -ItemType Directory -Path $backupDir -Force | Out-Null
    }
    
    # 将原始文件拷贝至 backup 文件夹
    $backupFile = Join-Path $backupDir $filename
    Copy-Item -Path $file -Destination $backupFile -Force
    Write-Host "  -> 原文件已安全备份"
    
    # 读取字幕内容 (使用 File 类避免 Get-Content 潜在的编码破坏)
    $lines = [System.IO.File]::ReadAllLines($file)
    $newLines = New-Object System.Collections.Generic.List[string]
    $matchCount = 0
    
    foreach ($line in $lines) {
        if ($ext -eq ".srt") {
            # 解析 SRT: 00:00:00,000 --> 00:00:00,000
            if ($line -match "^(\d{2}:\d{2}:\d{2},\d{3})\s*-->\s*(\d{2}:\d{2}:\d{2},\d{3})(.*)$") {
                $newStart = Adjust-TimeCode -tc $matches[1] -offset $offsetMs -format "SRT"
                $newEnd   = Adjust-TimeCode -tc $matches[2] -offset $offsetMs -format "SRT"
                $newLines.Add("$newStart --> $newEnd$($matches[3])")
                $matchCount++
            } else { $newLines.Add($line) }
            
        } elseif ($ext -eq ".vtt") {
            # 解析 VTT: 00:00:00.000 --> 00:00:00.000 (可能没有小时部分)
            if ($line -match "^((?:\d{2,}:)?\d{2}:\d{2}\.\d{3})\s*-->\s*((?:\d{2,}:)?\d{2}:\d{2}\.\d{3})(.*)$") {
                $newStart = Adjust-TimeCode -tc $matches[1] -offset $offsetMs -format "VTT"
                $newEnd   = Adjust-TimeCode -tc $matches[2] -offset $offsetMs -format "VTT"
                $newLines.Add("$newStart --> $newEnd$($matches[3])")
                $matchCount++
            } else { $newLines.Add($line) }
            
        } elseif ($ext -match "\.ass|\.ssa") {
            # 解析 ASS/SSA: Dialogue: 0,0:00:00.00,0:00:00.00,Default...
            if ($line -match "^(Dialogue:\s*[^,]+,)(\d{1,2}:\d{2}:\d{2}\.\d{2,3}),(\d{1,2}:\d{2}:\d{2}\.\d{2,3})(,.*)$") {
                $newStart = Adjust-TimeCode -tc $matches[2] -offset $offsetMs -format "ASS"
                $newEnd   = Adjust-TimeCode -tc $matches[3] -offset $offsetMs -format "ASS"
                $newLines.Add("$($matches[1])$newStart,$newEnd$($matches[4])")
                $matchCount++
            } else { $newLines.Add($line) }
            
        } else {
            # 其他未知格式不处理，原样保留
            $newLines.Add($line)
        }
    }
    
    # 覆盖保存文件 (统一以无 BOM 的 UTF8 编码保存，避免播放器乱码)
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllLines($file, $newLines, $utf8NoBom)
    Write-Host "  -> 调轴完成，共调整 $matchCount 处时间轴" -ForegroundColor Green
}

Write-Host "`n所有字幕文件处理完毕！" -ForegroundColor Cyan
Read-Host "请按回车键退出"