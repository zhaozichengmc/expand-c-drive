# check-partitions.ps1 - 只读诊断：C 盘能否扩容、从 D 盘能划多少
# 用法： powershell -NoProfile -ExecutionPolicy Bypass -File check-partitions.ps1 -TakeGB 10
param(
    [int]$TakeGB = 10
)

$ErrorActionPreference = "Continue"

function GB([double]$bytes) {
    if ($bytes -le 0) { return "0 GB" }
    return "{0:N1} GB" -f ($bytes / 1GB)
}

function Line { param($t) Write-Host $t -ForegroundColor Cyan }

Line "================ C 盘扩容诊断（只读） ================"
Write-Host ("目标：从 D 盘划 {0} GB 给 C 盘" -f $TakeGB)
Write-Host ""

# ---------- 物理磁盘 ----------
Line "[1] 物理磁盘"
try {
    Get-Disk | Select-Object Number, FriendlyName, @{n="容量";e={ GB($_.Size) }}, PartitionStyle |
        Format-Table -AutoSize | Out-String | Write-Host
} catch {
    Get-CimInstance Win32_DiskDrive | Select-Object Index, Model, @{n="容量";e={ GB($_.Size) }} |
        Format-Table -AutoSize | Out-String | Write-Host
}

# ---------- C 盘位置 ----------
Line "[2] C 盘在哪个盘、右边是什么"
$cVol = $null
try { $cVol = Get-Volume -DriveLetter C } catch { }
if ($cVol -eq $null) {
    $ld = Get-CimInstance Win32_LogicalDisk | Where-Object { $_.DeviceID -eq "C:" }
    if ($ld -ne $null) {
        $cVol = [pscustomobject]@{ DriveLetter="C"; Size=$ld.Size; SizeRemaining=$ld.FreeSpace }
    }
}
if ($cVol -eq $null) {
    Write-Host "拿不到 C 盘容量信息，可能权限不足。请用管理员身份重跑。" -ForegroundColor Yellow
    return
}
Write-Host ("C 盘：总 {0}，剩余 {1}" -f (GB $cVol.Size), (GB $cVol.SizeRemaining))

$cPart = $null
try { $cPart = Get-Partition -DriveLetter C } catch { }
if ($cPart -eq $null) {
    Write-Host "拿不到分区表（需要管理员权限？），请用管理员身份重跑本脚本。" -ForegroundColor Yellow
    return
}

$diskNo = $cPart.DiskNumber
$parts = $null
try { $parts = Get-Partition -DiskNumber $diskNo | Sort-Object Offset } catch { }

Line ("磁盘 {0} 的分区顺序：" -f $diskNo)
$parts | ForEach-Object {
    $letter = if ($_.DriveLetter) { $_.DriveLetter + ":" } else { "（无盘符）" }
    $tag = if ($_.Offset -eq $cPart.Offset) { "<== C 盘" } else { "" }
    Write-Host ("  #{0,-2} {1,-8} 类型={2,-30} 起始={3,10:N0} 大小={4,10}  {5}" -f `
        $_.PartitionNumber, $letter, $_.Type, $_.Offset, (GB $_.Size), $tag)
}

$rightEdge = $cPart.Offset + $cPart.Size
$right = $parts | Where-Object { $_.Offset -eq $rightEdge } | Select-Object -First 1
$diskEnd = 0
try {
    $disk = Get-Disk -Number $diskNo
    $diskEnd = $disk.Size
} catch {
    if ($parts -ne $null) { $diskEnd = ($parts | Measure-Object -Property Offset -Maximum).Maximum + ($parts | Where-Object { $_.Offset -eq ($parts | Measure-Object -Property Offset -Maximum).Maximum }).Size }
}

Write-Host ""
Line "[3] 结论"

if ($right -eq $null) {
    $rest = $diskEnd - $rightEdge
    if ($rest -gt 1GB) {
        Write-Host "C 盘右侧紧邻的是 空闲空间（约 $(GB $rest)），自带磁盘管理可以直接扩：" -ForegroundColor Green
        Write-Host "  右键开始菜单 → 磁盘管理 → 右键 C → 扩展卷 → 填入不大于 $(GB $rest) 的数量"
    } else {
        Write-Host "C 盘右侧紧邻空闲很少（$(GB $rest)），需要先用分区软件从 D 划。" -ForegroundColor Yellow
    }
}
elseif ($right.DriveLetter -ne "D") {
    $rl = if ($right.DriveLetter) { $right.DriveLetter + ":" } else { "无盘符" }
    Write-Host ("C 盘右侧紧邻 #{0}（类型 {1}，盘符 {2}）" -f $right.PartitionNumber, $right.Type, $rl) -ForegroundColor Yellow
    Write-Host "这不是 D 盘，多半是厂家的恢复分区或 OEM 分区。它挡着 C 扩容，需要先用 DiskGenius 把它往后挪（或删掉）。"
}
else {
    Write-Host "C 盘右侧紧邻的就是 D 盘 —— 自带磁盘管理扩展不了（压缩 D 只会在 D 尾部产生空闲，贴不到 C）。" -ForegroundColor Yellow
    Write-Host "要用分区软件把 D 的数据整体后移：傲梅分区助手 → 右键 D → 「分配空闲空间」→ 填 $TakeGB GB 给 C。"
}

# ---------- D 盘能划多少 ----------
Write-Host ""
Line "[4] D 盘可划出的空间"
$dVol = $null
try { $dVol = Get-Volume -DriveLetter D } catch { }
if ($dVol -eq $null) {
    Write-Host "没找到 D 盘。" -ForegroundColor Yellow
}
else {
    Write-Host ("D 盘：总 {0}，剩余 {1}" -f (GB $dVol.Size), (GB $dVol.SizeRemaining))
    $dPart = $null
    try { $dPart = Get-Partition -DriveLetter D } catch { }
    if ($dPart -ne $null) {
        try {
            $min = Get-PartitionSupportedSize -DriveLetter D -ErrorAction Stop
            $canShrink = $dPart.Size - $min.SizeMin
            Write-Host ("理论可压缩：约 {0}（受文件碎片限制，实际略少）" -f (GB $canShrink))
        } catch { }
    }
    $needMB = $TakeGB * 1024
    if ($dVol.SizeRemaining -lt ($TakeGB * 1GB)) {
        Write-Host ("不够：要划 {0} GB，D 只剩 {1}，先把 D 里的东西清一清。" -f $TakeGB, (GB $dVol.SizeRemaining)) -ForegroundColor Red
    } else {
        Write-Host ("够用：软件里填 {0} GB（= {1} MB）。" -f $TakeGB, $needMB) -ForegroundColor Green
    }
}

Write-Host ""
Line "[5] 动手前清单"
Write-Host "  1) 备份 D 盘和桌面里的重要文件"
Write-Host "  2) 笔记本插电源，关闭睡眠 / 合盖休眠"
Write-Host "  3) BitLocker 加密的分区先暂停保护"
Write-Host "  4) PE 执行期间别强制关机；断电后重新进 PE 可继续或回滚"
Write-Host "  5) 完成后跑一次：chkdsk C: /f"
Write-Host ""
Write-Host "本脚本只读取分区信息，不修改任何分区。" -ForegroundColor DarkGray
