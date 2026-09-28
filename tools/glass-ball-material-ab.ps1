param(
  [Parameter(Mandatory=$true)][string]$Tag
)
# R59 material A/B 采集器：冷启动 → 设置抽屉 → 打开「外观」bindPopup → 截图。
# 目的：在 state=0 / state=1 两态下对**同一组件、同一位置**取静止帧，做逐像素 MAE。
# 依赖 tools/ui-probe.mjs 解析 dumpLayout（避免 PowerShell 内联 node 的路径转义坑）。
# ---- 可移植化：环境变量优先，其次常见安装位置（不用改脚本就能换机器）----
$hdc = $env:HDC
if (-not $hdc) {
  $deveco = $env:DEVECO_HOME
  if (-not $deveco) {
    foreach ($c in @('D:/DevEco Studio', 'C:/Program Files/Huawei/DevEco Studio', 'C:/Program Files/DevEco Studio')) {
      if (Test-Path $c) { $deveco = $c; break }
    }
    if (-not $deveco) { $deveco = 'D:/DevEco Studio' }
  }
  $hdc = ($deveco.TrimEnd('/') + '/sdk/default/openharmony/toolchains/hdc.exe')
}
if (-not (Test-Path $hdc)) {
  Write-Error "未找到 hdc：$hdc —— 请设置环境变量 HDC=<hdc 完整路径>，或设置 DEVECO_HOME=<DevEco Studio 安装目录>"
  exit 1
}
$sn = $env:AA_DEVICE_SN
if (-not $sn) { $sn = $env:AA_DEVICE }
if (-not $sn) {
  Write-Error '未指定目标设备序列号 —— 请设置环境变量 AA_DEVICE_SN=<设备序列号>（多设备在线时不带 -t 可能打到另一台）'
  exit 1
}
# 工程根与临时目录：AA_PROJECT_ROOT / AA_TMP 可覆盖
$proj = $env:AA_PROJECT_ROOT
if (-not $proj) { $proj = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path }
$tmp = $env:AA_TMP
if (-not $tmp) { $tmp = [System.IO.Path]::GetTempPath() }
# 截图落盘目录：AA_EVIDENCE_DIR 可覆盖；默认落系统临时目录下的 aa-hm-glass-ball（不写进工程目录）
$dir = $env:AA_EVIDENCE_DIR
if (-not $dir) { $dir = Join-Path $tmp 'aa-hm-glass-ball' }
New-Item -ItemType Directory -Force -Path $dir | Out-Null
$probe = Join-Path $proj 'tools/ui-probe.mjs'

function Dump([string]$file) {
  & $hdc -t $sn shell 'uitest dumpLayout -p /data/local/tmp/gb.json' | Out-Null
  & $hdc -t $sn file recv /data/local/tmp/gb.json (Join-Path $tmp $file) | Out-Null
}
function Shot([string]$name) {
  & $hdc -t $sn shell 'snapshot_display -f /data/local/tmp/gb.jpeg' | Out-Null
  & $hdc -t $sn file recv /data/local/tmp/gb.jpeg (Join-Path $dir ($name + '.jpeg')) | Out-Null
}
function TapXY([int]$x, [int]$y) {
  & $hdc -t $sn shell "uinput -T -d $x $y" | Out-Null
  Start-Sleep -Milliseconds 120
  & $hdc -t $sn shell "uinput -T -u $x $y" | Out-Null
}
function ProbeHas([string]$json, [string]$text) {
  return ((node $probe has $json $text) -eq '1')
}
function ProbeCenter([string]$json, [string]$text) {
  return (node $probe center $json $text)
}

$ja = Join-Path $tmp 'gb-a.json'
$jb = Join-Path $tmp 'gb-b.json'

# ---- 冷启动 ----
& $hdc -t $sn shell 'aa force-stop aa234.luyaowen.23' | Out-Null
Start-Sleep -Seconds 1
& $hdc -t $sn shell 'aa start -a EntryAbility -b aa234.luyaowen.23' | Out-Null
Start-Sleep -Seconds 6

# ---- 打开设置抽屉（账户钮中心 112,204）----
Dump 'gb-a.json'
if (-not (ProbeHas $ja '外观')) {
  TapXY 112 204
  Start-Sleep -Seconds 3
  Dump 'gb-a.json'
}
if (-not (ProbeHas $ja '外观')) {
  Write-Output 'FAIL: 设置抽屉未打开'
  exit 1
}
Shot ($Tag + '-01-drawer')
Write-Output 'drawer OK'

# ---- 打开「外观」bindPopup（官方 ENABLE 默认名单内的 Popup/菜单）----
$c = ProbeCenter $ja '外观'
if ($c -eq '' -or $null -eq $c) { Write-Output 'FAIL: 找不到外观行'; exit 1 }
$parts = $c.Trim().Split(' ')
TapXY ([int]$parts[0]) ([int]$parts[1])
Start-Sleep -Seconds 2
Dump 'gb-b.json'
if (ProbeHas $jb '浅色') {
  Shot ($Tag + '-02-popup')
  Write-Output 'popup OK'
} else {
  Shot ($Tag + '-02-nopopup')
  Write-Output 'popup NOT open'
}
Write-Output ('done ' + $Tag + ' -> ' + $dir)
