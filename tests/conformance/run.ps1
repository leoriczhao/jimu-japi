# tests\conformance\run.ps1 - 一条命令跑一致性测试台
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File tests\conformance\run.ps1
#   ... -Timeout 300           # 慢机器
#   ... -NoKill                # 你自己管 war3 进程
#
# 输出末尾两行由 war3map.lua 打印：
#   " Conformance: N passed, M failed, K skipped"
#   " Results: N passed, M failed, T total"     <- deploy.ps1 用这一行判定成败
param(
    [int]$Timeout = 200,
    [switch]$NoKill
)

$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)

# 1) 先做语法校验：打包器原样拼接，语法错误在游戏里只能看到一行 FATAL
$lua = Join-Path $Root "tools\w3x2lni\bin\w3x2lni-lua.exe"
$chk = Join-Path $PSScriptRoot "check-syntax.lua"
$map = Join-Path $PSScriptRoot "war3map.lua"
& $lua $chk $map
if ($LASTEXITCODE -ne 0) { throw "tests\conformance\war3map.lua 语法校验失败" }

# 2) 独占 war3 再部署
if (-not $NoKill) {
    & (Join-Path $Root "tools\kill-war3.ps1") *> $null
    Start-Sleep -Seconds 3
}

$deployArgs = @("-NoProfile","-ExecutionPolicy","Bypass","-File", (Join-Path $Root "tools\deploy.ps1"),
                "-MapDir", $PSScriptRoot, "-MapName", "conformance.w3x", "-Timeout", "$Timeout")
$logPath = Join-Path $Root 'build\conformance-run.log'
New-Item -ItemType Directory -Force -Path (Split-Path -Parent $logPath) | Out-Null
$out = & powershell.exe @deployArgs 2>&1 | ForEach-Object { "$_" }
$out | Set-Content -Encoding UTF8 $logPath
$code = $LASTEXITCODE

$out | Where-Object { $_ -match "^\s*\[(PASS|FAIL|SKIP)\]" } | ForEach-Object { Write-Host $_ }

$conformance = ($out | Select-String -Pattern "Conformance:\s*\d+ passed").Line
$results     = ($out | Select-String -Pattern "Results:\s*\d+ passed").Line

Write-Host ''
Write-Host ("deploy exit: " + $code)
if ($conformance) { Write-Host $conformance } else { Write-Host "Conformance 行缺失（游戏没跑到收尾？看 C:\ProgramData\japi_debug.txt）" }
if ($results)     { Write-Host $results }     else { Write-Host "Results 行缺失" }
Write-Host ''
Write-Host "完整日志: C:\ProgramData\japi_debug.txt"
if (-not $conformance) { exit 1 }
