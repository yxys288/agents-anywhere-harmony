param(
  [Parameter(Mandatory=$true)][string]$Tag
)
# glass-ball R59 真机采集助手：install -r → 冷启动 → 进会话 → 截图 → dumpLayout → 输出几何
# 只读红线：install -r（不 uninstall）、不改服务器、不登出、不发消息。
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
$hap = $env:AA_HAP
if (-not $hap) { $hap = Join-Path $proj 'entry/build/default/outputs/default/entry-default-signed.hap' }
if (-not (Test-Path $hap)) {
  Write-Error "未找到签名 HAP：$hap —— 请先构建（node tools/build-locked.mjs），或用 AA_HAP=<hap 路径> 指定"
  exit 1
}

& $hdc -t $sn install -r $hap | Out-Null
Start-Sleep -Seconds 2
# 应用内切深色后直接截图可能仍是浅色（系统主题同步延迟）⇒ 先 force-stop 再 start
& $hdc -t $sn shell 'aa force-stop aa234.luyaowen.23' | Out-Null
Start-Sleep -Seconds 1
& $hdc -t $sn shell 'aa start -a EntryAbility -b aa234.luyaowen.23' | Out-Null
Start-Sleep -Seconds 5
# 首页（顶栏两个玻璃钮：账户 / 搜索）
& $hdc -t $sn shell 'snapshot_display -f /data/local/tmp/gb.jpeg' | Out-Null
& $hdc -t $sn file recv /data/local/tmp/gb.jpeg (Join-Path $dir ($Tag + '-home.jpeg')) | Out-Null
# 进会话详情页（顶栏齿轮钮 + 返回钮）
& $hdc -t $sn shell 'uitest uiInput click 587 869' | Out-Null
Start-Sleep -Seconds 3
& $hdc -t $sn shell 'snapshot_display -f /data/local/tmp/gb.jpeg' | Out-Null
& $hdc -t $sn file recv /data/local/tmp/gb.jpeg (Join-Path $dir ($Tag + '-session.jpeg')) | Out-Null
& $hdc -t $sn shell 'uitest dumpLayout -p /data/local/tmp/gb.json' | Out-Null
& $hdc -t $sn file recv /data/local/tmp/gb.json (Join-Path $tmp 'gb-layout.json') | Out-Null
Write-Output "collected $Tag -> $dir"
