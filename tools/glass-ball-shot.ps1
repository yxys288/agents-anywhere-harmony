param(
  [Parameter(Mandatory=$true)][string]$Out
)
# glass-ball R59 真机截图助手：snapshot_display 必须带 .jpeg 后缀，file recv 必须给 Windows 反斜杠绝对路径
# 设备序列号从 AA_DEVICE_SN 读（不再写死）；hdc 从 HDC / DEVECO_HOME 解析。
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
& $hdc -t $sn shell 'snapshot_display -f /data/local/tmp/gb.jpeg' | Out-Null
& $hdc -t $sn file recv /data/local/tmp/gb.jpeg $Out
if (Test-Path $Out) { Write-Output ("OK " + $Out + " " + (Get-Item $Out).Length) } else { Write-Output "FAIL $Out" }
