param(
  [string]$Tag = 'press'
)
# R59 深色档按压 + 连点回归（只读：不改服务器/不发消息/不点审批）
# 按压验证用 uinput -T -d/up（uitest uiInput down/up 不触发 clickEffect，Lead 已踩）
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

function Shot([string]$name) {
  & $hdc -t $sn shell 'snapshot_display -f /data/local/tmp/gb.jpeg' | Out-Null
  & $hdc -t $sn file recv /data/local/tmp/gb.jpeg (Join-Path $dir ($name + '.jpeg')) | Out-Null
  Write-Output "shot $name"
}

# 冷启动到首页
& $hdc -t $sn shell 'aa force-stop aa234.luyaowen.23' | Out-Null
Start-Sleep -Seconds 1
& $hdc -t $sn shell 'aa start -a EntryAbility -b aa234.luyaowen.23' | Out-Null
Start-Sleep -Seconds 5
Shot "$Tag-00-rest"

# 账户钮中心 (113,204)
& $hdc -t $sn shell 'uinput -T -d 113 204' | Out-Null
Start-Sleep -Milliseconds 400
Shot "$Tag-01-down"
& $hdc -t $sn shell 'uinput -T -u 113 204' | Out-Null
Start-Sleep -Milliseconds 600
Shot "$Tag-02-up"

# 连点 5 次（SDK NOTE：clickEffect 缩放后触点可能落到控件外）
for ($i = 1; $i -le 5; $i++) {
  & $hdc -t $sn shell 'uinput -T -d 113 204' | Out-Null
  Start-Sleep -Milliseconds 120
  & $hdc -t $sn shell 'uinput -T -u 113 204' | Out-Null
  Start-Sleep -Milliseconds 500
  Write-Output "tap $i done"
}
Start-Sleep -Seconds 1
Shot "$Tag-03-after5"
Write-Output "done $Tag -> $dir"
