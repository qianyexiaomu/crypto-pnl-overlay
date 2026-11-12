# 把 OkxPnl.ps1 里的 C# 核心 + src/Program.cs 编译成单文件 exe
#   powershell -NoProfile -ExecutionPolicy Bypass -File build-exe.ps1
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$ps1 = Join-Path $root 'OkxPnl.ps1'
$srcDir = Join-Path $root 'src'
$coreFile = Join-Path $srcDir 'OkxPnl.Core.cs'
$progFile = Join-Path $srcDir 'Program.cs'
$outExe = Join-Path $root 'OkxPnl.exe'

# 1) 从 ps1 里抽出 C# 代码块
$raw = [System.IO.File]::ReadAllText($ps1, [System.Text.Encoding]::UTF8)
$mark = '$code' + " = @'"
$s = $raw.IndexOf($mark)
if ($s -lt 0) { throw 'OkxPnl.ps1 里没找到 C# 代码块' }
$lf = [string][char]10
$s = $raw.IndexOf($lf, $s) + 1
$e = $raw.IndexOf($lf + "'@", $s)
if ($e -lt 0) { throw 'C# 代码块没结束标记' }
$code = $raw.Substring($s, $e - $s).TrimEnd([char]13)
New-Item -ItemType Directory -Force -Path $srcDir | Out-Null
[System.IO.File]::WriteAllText($coreFile, $code, (New-Object System.Text.UTF8Encoding($true)))

# 2) 选 csc（.NET Framework 4.x，Win10/11 自带，不需要装任何东西）
$csc = @(
    'C:\Windows\Microsoft.NET\Framework64\v4.0.30319\csc.exe',
    'C:\Windows\Microsoft.NET\Framework\v4.0.30319\csc.exe'
) | Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $csc) { throw '找不到 csc.exe（需要 .NET Framework 4.x）' }

# 3) 编译
$args = @(
    '/nologo', '/target:winexe', '/optimize+', '/platform:anycpu',
    ('/out:"' + $outExe + '"'),
    '/r:System.dll', '/r:System.Core.dll', '/r:System.Drawing.dll',
    '/r:System.Windows.Forms.dll', '/r:System.Security.dll', '/r:System.Management.dll',
    ('"' + $coreFile + '"'), ('"' + $progFile + '"')
)
& $csc $args
if ($LASTEXITCODE -ne 0) { throw ('编译失败，exit=' + $LASTEXITCODE) }
if (-not (Test-Path $outExe)) { throw '没有生成 exe' }

$fi = Get-Item $outExe
Write-Output ('已生成 ' + $fi.Name + '  ' + [math]::Round($fi.Length / 1KB, 0) + ' KB  ' + $fi.LastWriteTime)
