<#
.SYNOPSIS
    Google Chrome Portable (PortableApps.com版) を最新版に自動アップデートします。

.DESCRIPTION
    ユーザーデータ (Data フォルダ) には一切触れず、プログラム本体
    (App\Chrome-bin) だけを Google 公式の最新版に入れ替えるため、
    ブックマーク・履歴・パスワード・拡張機能などのデータはそのまま引き継がれます。

    処理の流れ:
      1. 現在のバージョンを確認
      2. Google の Version History API で最新の安定版を確認 (新しければ続行)
      3. Google 公式のスタンドアロンインストーラ (ChromeStandaloneSetup) を
         ダウンロードし、電子署名が Google のものであることを検証
      4. インストーラを実行せず、7-Zip で中身を多段展開して
         Chrome 本体 (Chrome-bin フォルダ) を取り出す
      5. 旧 App\Chrome-bin を Backup フォルダへ退避してから、新版に入れ替え
         (失敗したら自動で旧版に戻します)
      6. Data フォルダは最初から最後まで読み書きしません

    Google Chrome Portable が見つからない場合は、インストールは行わず、
    先に手動でインストールするよう案内を表示して終了します。
    (このスクリプトはアップデート専用です)

    展開の多段構造 (2026-11 時点のインストーラで実地に確認済み):
      ChromeStandaloneSetup64.exe
        └ updater.7z
            └ <バージョン>_chrome_installer.exe
                └ chrome.7z
                    └ Chrome-bin\ (chrome.exe + <バージョン> フォルダ)

.PARAMETER PortableDir
    GoogleChromePortable.exe のあるフォルダ。
    省略時は、このスクリプトのあるフォルダとその親フォルダ、
    およびその直下の GoogleChromePortable フォルダから自動検出します。

.PARAMETER Architecture
    x64 (既定) / x86 / ARM64。既存の Chrome のアーキテクチャに合わせてください。

.PARAMETER Force
    バージョンが同じでも入れ替えを実行します。

.PARAMETER CloseChrome
    対象フォルダの Chrome が起動中だった場合、自動で終了してから更新します。
    指定しない場合は、終了してよいか確認します (応答できない環境では中断します)。

.PARAMETER BackupProfile
    ついでに Data\profile を ZIP にして Backup フォルダへ保存します。
    プロファイルが大きいと時間と容量を使います。通常は不要です
    (Data フォルダ自体は更新で触らないため)。

.PARAMETER BackupKeep
    残しておく旧プログラム本体のバックアップ世代数 (既定: 1)。

.PARAMETER KeepWorkFiles
    ダウンロード・展開した作業ファイルを指定フォルダに残します (デバッグ用)。

.PARAMETER Launch
    更新後に Google Chrome Portable を起動します。

.EXAMPLE
    .\Update-ChromePortable.ps1
    スクリプトを GoogleChromePortable フォルダに置いて実行 (自動検出)。

.EXAMPLE
    .\Update-ChromePortable.ps1 -PortableDir "D:\PortableApps\GoogleChromePortable" -CloseChrome
    フォルダを指定し、起動中なら自動で閉じて更新。

.NOTES
    対象: PortableApps.com 版 Google Chrome Portable
          (App\Chrome-bin と Data\profile という構成のもの)
    要件: Windows 10/11, Windows PowerShell 5.1 以降, インターネット接続
          作業用に一時フォルダへ約 2 GB の空き容量が必要です。
          管理者権限は不要です (インストールは行いません)。
          7-Zip は、インストール済みのものがあればそれを使い、
          なければ公式の単体版コンソール (7-Zip Extra) を作業フォルダへ
          自動でダウンロードして使います。
    Version: 1.2.0
#>
[CmdletBinding()]
param(
    [string]$PortableDir,
    [ValidateSet('x64', 'x86', 'ARM64')]
    [string]$Architecture = 'x64',
    [switch]$Force,
    [switch]$CloseChrome,
    [switch]$BackupProfile,
    [int]$BackupKeep = 1,
    [switch]$KeepWorkFiles,
    [switch]$Launch
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

function Write-Step {
    param([string]$Message)
    Write-Host ""
    Write-Host "== $Message" -ForegroundColor Cyan
}

function Get-ChromeVersion {
    param([string]$ChromeExePath)
    if (-not (Test-Path -LiteralPath $ChromeExePath)) { return $null }
    $ver = (Get-Item -LiteralPath $ChromeExePath).VersionInfo.ProductVersion
    if ($ver) { return $ver.Trim() }
    # ファイルバージョンが取れない場合は、バージョン名のサブフォルダから推定
    $dir = Split-Path -Parent $ChromeExePath
    $sub = Get-ChildItem -LiteralPath $dir -Directory -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match '^\d+\.\d+\.\d+\.\d+$' } |
        Select-Object -First 1
    if ($sub) { return $sub.Name }
    return $null
}

function Get-LatestStableVersion {
    param([string]$Arch)
    $platformMap = @{ 'x64' = 'win64'; 'x86' = 'win' }
    if (-not $platformMap.ContainsKey($Arch)) { return $null }  # ARM64 は API の対象外
    $uri = "https://versionhistory.googleapis.com/v1/chrome/platforms/$($platformMap[$Arch])/channels/stable/versions"
    try {
        $resp = Invoke-RestMethod -Uri $uri -UseBasicParsing -TimeoutSec 30
        $versions = @($resp.versions | ForEach-Object { [version]$_.version })
        if ($versions.Count -eq 0) { return $null }
        return ($versions | Sort-Object -Descending | Select-Object -First 1).ToString()
    } catch {
        Write-Warning "最新バージョンの確認に失敗しました (そのままダウンロードして確認します): $($_.Exception.Message)"
        return $null
    }
}

function Find-SevenZip {
    # インストール済みの 7-Zip (7z.exe / 7za.exe) を探す
    $candidates = @()
    $cmd = Get-Command '7z.exe' -ErrorAction SilentlyContinue
    if ($cmd) { $candidates += $cmd.Source }
    $cmdA = Get-Command '7za.exe' -ErrorAction SilentlyContinue
    if ($cmdA) { $candidates += $cmdA.Source }
    foreach ($pf in @($env:ProgramFiles, ${env:ProgramFiles(x86)})) {
        if ($pf) {
            $candidates += (Join-Path $pf '7-Zip\7z.exe')
            $candidates += (Join-Path $pf '7-Zip\7za.exe')
        }
    }
    foreach ($c in $candidates) {
        if ($c -and (Test-Path -LiteralPath $c)) { return $c }
    }
    return $null
}

function Get-SevenZipBootstrap {
    param([string]$ToolsDir)
    # 7zr.exe (公式・単体) で 7-Zip Extra を展開し、7za.exe を得る
    New-Item -ItemType Directory -Path $ToolsDir -Force | Out-Null
    $zr = Join-Path $ToolsDir '7zr.exe'
    Write-Host "7-Zip が見つからないため、公式の単体版をダウンロードします"
    Invoke-WebRequest -Uri 'https://www.7-zip.org/a/7zr.exe' -OutFile $zr -UseBasicParsing

    $page = Invoke-WebRequest -Uri 'https://www.7-zip.org/download.html' -UseBasicParsing
    $m = [regex]::Match($page.Content, 'a/(7z\d+-extra\.7z)')
    if (-not $m.Success) {
        throw "7-Zip Extra のダウンロード先を特定できませんでした。https://www.7-zip.org/ から 7-Zip をインストールしてから再実行してください。"
    }
    $extraPath = Join-Path $ToolsDir $m.Groups[1].Value
    Invoke-WebRequest -Uri "https://www.7-zip.org/a/$($m.Groups[1].Value)" -OutFile $extraPath -UseBasicParsing
    $extraDir = Join-Path $ToolsDir 'extra'
    & $zr 'x' "-o$extraDir" '-y' $extraPath | Out-Null
    if ($LASTEXITCODE -gt 1) {
        throw "7-Zip Extra の展開に失敗しました (終了コード: $LASTEXITCODE)。"
    }
    $sub = switch ($env:PROCESSOR_ARCHITECTURE) {
        'AMD64' { 'x64' }
        'ARM64' { 'arm64' }
        default { '' }
    }
    $zaDir = if ($sub) { Join-Path $extraDir $sub } else { $extraDir }
    $za = Join-Path $zaDir '7za.exe'
    if (-not (Test-Path -LiteralPath $za)) {
        throw "7za.exe の取得に失敗しました。7-Zip をインストールしてから再実行してください。"
    }
    return $za
}

function Expand-With7z {
    param(
        [string]$SevenZip,
        [string]$Archive,
        [string]$OutDir,
        [switch]$FullPaths,
        [string]$LogFile
    )
    New-Item -ItemType Directory -Path $OutDir -Force | Out-Null
    $mode = if ($FullPaths) { 'x' } else { 'e' }
    $output = & $SevenZip $mode "-o$OutDir" '-y' $Archive 2>&1
    if ($LogFile) { $output | Add-Content -LiteralPath $LogFile -Encoding UTF8 }
    if ($LASTEXITCODE -gt 1) {
        throw "7-Zip での展開に失敗しました (終了コード: $LASTEXITCODE / 対象: $Archive)。詳細は作業フォルダのログを確認してください。"
    }
}

# ---------------------------------------------------------------------------
# 1. Portable フォルダの決定と検証
# ---------------------------------------------------------------------------
Write-Step "Google Chrome Portable の場所を確認しています"

$searched = @()
if (-not $PortableDir) {
    $candidates = @(
        $PSScriptRoot,
        (Split-Path -Parent $PSScriptRoot),
        (Join-Path $PSScriptRoot 'GoogleChromePortable')
    )
    foreach ($c in $candidates) {
        if (-not $c) { continue }
        $searched += $c
        if (Test-Path -LiteralPath (Join-Path $c 'App\Chrome-bin\chrome.exe')) {
            $PortableDir = $c
            break
        }
    }
}

if (-not $PortableDir -or -not (Test-Path -LiteralPath (Join-Path $PortableDir 'App\Chrome-bin\chrome.exe'))) {
    Write-Host ""
    Write-Host "Google Chrome Portable が見つかりませんでした。" -ForegroundColor Yellow
    Write-Host "このスクリプトはアップデート専用です。先に手動でインストールしてから、もう一度実行してください。"
    Write-Host ""
    Write-Host "  1. PortableApps.com から Google Chrome Portable をインストールする"
    Write-Host "     https://portableapps.com/apps/internet/google_chrome_portable"
    Write-Host "  2. インストール先フォルダにこのスクリプトを置くか、-PortableDir でそのフォルダを指定して再実行する"
    Write-Host ""
    if ($PortableDir) {
        Write-Host "指定されたフォルダに App\Chrome-bin\chrome.exe がありません: $PortableDir"
    } elseif ($searched.Count -gt 0) {
        Write-Host "探した場所: $($searched -join ' / ')"
    }
    return
}
$PortableDir = (Resolve-Path -LiteralPath $PortableDir).Path

$chromeBin = Join-Path $PortableDir 'App\Chrome-bin'
$chromeExe = Join-Path $chromeBin 'chrome.exe'
$dataDir   = Join-Path $PortableDir 'Data'

if (-not (Test-Path -LiteralPath $dataDir)) {
    Write-Warning "Data フォルダが見つかりません ($dataDir)。まだ一度も起動していない可能性があります。このままプログラム本体だけ更新します。"
}
Write-Host "対象フォルダ: $PortableDir"

$currentVersion = Get-ChromeVersion -ChromeExePath $chromeExe
if (-not $currentVersion) { throw "現在の Chrome のバージョンを取得できませんでした。" }
Write-Host "現在のバージョン: $currentVersion"

# ---------------------------------------------------------------------------
# 2. 起動中チェック
# ---------------------------------------------------------------------------
$running = @(Get-Process -Name 'chrome', 'GoogleChromePortable' -ErrorAction SilentlyContinue |
    Where-Object {
        try { $_.Path -and $_.Path.StartsWith($PortableDir, [System.StringComparison]::OrdinalIgnoreCase) }
        catch { $false }
    })
if ($running.Count -gt 0) {
    Write-Step "このフォルダの Chrome が起動中です"
    $doClose = $CloseChrome.IsPresent
    if (-not $doClose) {
        try {
            $ans = Read-Host "終了して更新を続けますか? [y/N]"
            $doClose = ($ans -match '^(y|yes)$')
        } catch {
            $doClose = $false
        }
    }
    if (-not $doClose) {
        throw "更新を中断しました。Chrome をすべて閉じてから再実行してください (自動で閉じる場合は -CloseChrome を指定)。"
    }
    $running | ForEach-Object { [void]$_.CloseMainWindow() }
    $deadline = (Get-Date).AddSeconds(15)
    while ((Get-Date) -lt $deadline) {
        $still = @(Get-Process -Name 'chrome' -ErrorAction SilentlyContinue |
            Where-Object { try { $_.Path -and $_.Path.StartsWith($PortableDir, [System.StringComparison]::OrdinalIgnoreCase) } catch { $false } })
        if ($still.Count -eq 0) { break }
        Start-Sleep -Seconds 1
    }
    $still = @(Get-Process -Name 'chrome' -ErrorAction SilentlyContinue |
        Where-Object { try { $_.Path -and $_.Path.StartsWith($PortableDir, [System.StringComparison]::OrdinalIgnoreCase) } catch { $false } })
    if ($still.Count -gt 0) {
        $still | Stop-Process -Force
        Start-Sleep -Seconds 1
    }
    Write-Host "Chrome を終了しました。"
}

# ---------------------------------------------------------------------------
# 3. 最新バージョンの確認
# ---------------------------------------------------------------------------
Write-Step "最新の安定版を確認しています"
$latestVersion = Get-LatestStableVersion -Arch $Architecture
if ($latestVersion) {
    Write-Host "最新の安定版: $latestVersion"
    if (([version]$latestVersion -le [version]$currentVersion) -and (-not $Force)) {
        Write-Host ""
        Write-Host "すでに最新版です ($currentVersion)。更新は不要でした。" -ForegroundColor Green
        return
    }
} else {
    Write-Host "最新版の事前確認はスキップし、ダウンロードした本体のバージョンで判定します。"
}

# ---------------------------------------------------------------------------
# 4. 作業フォルダの準備と 7-Zip の用意
# ---------------------------------------------------------------------------
$stamp   = Get-Date -Format 'yyyyMMdd_HHmmss'
$workDir = Join-Path ([System.IO.Path]::GetTempPath()) "ChromePortableUpdate_$stamp"
if ($KeepWorkFiles) {
    $workDir = Join-Path $PortableDir "Backup\work_$stamp"
}
New-Item -ItemType Directory -Path $workDir -Force | Out-Null
$sevenZipLog = Join-Path $workDir '7zip.log'

$tempDrive = Get-PSDrive -Name ([System.IO.Path]::GetPathRoot($workDir).TrimEnd(':\')) -ErrorAction SilentlyContinue
if ($tempDrive -and $tempDrive.Free -lt 2GB) {
    Write-Warning "作業フォルダのあるドライブの空き容量が 2 GB 未満です。展開に失敗する可能性があります。"
}

Write-Step "展開ツール (7-Zip) を用意しています"
$sevenZip = Find-SevenZip
if ($sevenZip) {
    Write-Host "7-Zip: $sevenZip"
} else {
    $sevenZip = Get-SevenZipBootstrap -ToolsDir (Join-Path $workDir 'tools')
    Write-Host "7-Zip (単体版): $sevenZip"
}

# ---------------------------------------------------------------------------
# 5. Google 公式インストーラのダウンロードと署名検証
# ---------------------------------------------------------------------------
$installerNames = @{
    'x64'   = 'ChromeStandaloneSetup64.exe'
    'x86'   = 'ChromeStandaloneSetup.exe'
    'ARM64' = 'ChromeStandaloneSetupArm64.exe'
}
$installerUrl  = "https://dl.google.com/chrome/install/$($installerNames[$Architecture])"
$installerPath = Join-Path $workDir $installerNames[$Architecture]

Write-Step "Google 公式サイトから最新版をダウンロードしています"
Write-Host "URL: $installerUrl"
Invoke-WebRequest -Uri $installerUrl -OutFile $installerPath -UseBasicParsing
$sizeMB = [math]::Round((Get-Item -LiteralPath $installerPath).Length / 1MB, 1)
Write-Host "ダウンロード完了 ($sizeMB MB)"

Write-Step "ダウンロードしたファイルの署名を確認しています"
$sig = Get-AuthenticodeSignature -LiteralPath $installerPath
if ($sig.Status -ne 'Valid' -or $sig.SignerCertificate.Subject -notmatch 'Google') {
    throw "署名の検証に失敗しました (状態: $($sig.Status))。ダウンロードしたファイルを信用できないため、中断します。"
}
Write-Host "署名 OK: $($sig.SignerCertificate.Subject)"

# ---------------------------------------------------------------------------
# 6. インストーラを実行せずに多段展開し、Chrome 本体を取り出す
# ---------------------------------------------------------------------------
Write-Step "インストーラを展開して Chrome 本体を取り出しています (実行はしません)"

$step1 = Join-Path $workDir 'step1'
Expand-With7z -SevenZip $sevenZip -Archive $installerPath -OutDir $step1 -LogFile $sevenZipLog
$updaterArc = Get-ChildItem -LiteralPath $step1 -Recurse -Filter 'updater.7z' -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not $updaterArc) { throw "インストーラの中に updater.7z が見つかりませんでした。インストーラの形式が変わった可能性があります。" }

$step2 = Join-Path $workDir 'step2'
Expand-With7z -SevenZip $sevenZip -Archive $updaterArc.FullName -OutDir $step2 -LogFile $sevenZipLog
$innerInstaller = Get-ChildItem -LiteralPath $step2 -Recurse -Filter '*_chrome_installer.exe' -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not $innerInstaller) { throw "updater.7z の中に chrome_installer.exe が見つかりませんでした。インストーラの形式が変わった可能性があります。" }

$step3 = Join-Path $workDir 'step3'
Expand-With7z -SevenZip $sevenZip -Archive $innerInstaller.FullName -OutDir $step3 -LogFile $sevenZipLog
$chromeArc = Get-ChildItem -LiteralPath $step3 -Recurse -Filter 'chrome.7z' -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not $chromeArc) { throw "chrome_installer.exe の中に chrome.7z が見つかりませんでした。インストーラの形式が変わった可能性があります。" }

$step4 = Join-Path $workDir 'step4'
Expand-With7z -SevenZip $sevenZip -Archive $chromeArc.FullName -OutDir $step4 -FullPaths -LogFile $sevenZipLog
$newBinDir = Join-Path $step4 'Chrome-bin'
$newChromeExe = Join-Path $newBinDir 'chrome.exe'
if (-not (Test-Path -LiteralPath $newChromeExe)) {
    throw "展開したファイルの中に Chrome 本体 (Chrome-bin\chrome.exe) が見つかりませんでした。"
}
$newVersion = Get-ChromeVersion -ChromeExePath $newChromeExe
Write-Host "新しいバージョン: $newVersion"

if (([version]$newVersion -le [version]$currentVersion) -and (-not $Force)) {
    Write-Host ""
    Write-Host "ダウンロードした本体は現在のバージョン以下でした ($currentVersion)。入れ替えは行いません。" -ForegroundColor Green
    if (-not $KeepWorkFiles) { Remove-Item -LiteralPath $workDir -Recurse -Force -ErrorAction SilentlyContinue }
    return
}

# ---------------------------------------------------------------------------
# 7. 本体の入れ替え (Data フォルダには触りません)
# ---------------------------------------------------------------------------
$backupRoot = Join-Path $PortableDir 'Backup'
Write-Step "プログラム本体を入れ替えています (ユーザーデータはそのまま残ります)"
New-Item -ItemType Directory -Path $backupRoot -Force | Out-Null
$oldBinBackup = Join-Path $backupRoot ("Chrome-bin_{0}_{1}" -f $currentVersion, $stamp)

Move-Item -LiteralPath $chromeBin -Destination $oldBinBackup
Write-Host "旧本体の退避先: $oldBinBackup"
try {
    Copy-Item -LiteralPath $newBinDir -Destination $chromeBin -Recurse -Force
    $copiedVersion = Get-ChromeVersion -ChromeExePath $chromeExe
    if (-not $copiedVersion -or ([version]$copiedVersion -ne [version]$newVersion)) {
        throw "コピー後のバージョン確認に失敗しました (期待: $newVersion / 実際: $copiedVersion)。"
    }
} catch {
    Write-Warning "入れ替えに失敗したため、旧本体に戻します: $($_.Exception.Message)"
    if (Test-Path -LiteralPath $chromeBin) { Remove-Item -LiteralPath $chromeBin -Recurse -Force }
    Move-Item -LiteralPath $oldBinBackup -Destination $chromeBin
    throw "更新に失敗しました。旧バージョン ($currentVersion) のまま元に戻してあります。"
}

# プロファイルの任意バックアップ
if ($BackupProfile -and (Test-Path -LiteralPath (Join-Path $dataDir 'profile'))) {
    Write-Step "プロファイルを ZIP にバックアップしています"
    $profileZip = Join-Path $backupRoot ("profile_{0}.zip" -f $stamp)
    Compress-Archive -Path (Join-Path $dataDir 'profile') -DestinationPath $profileZip
    Write-Host "プロファイルのバックアップ: $profileZip"
}

# 古いバックアップの世代管理
if ($BackupKeep -ge 0) {
    $oldBackups = @(Get-ChildItem -LiteralPath $backupRoot -Directory -Filter 'Chrome-bin_*' -ErrorAction SilentlyContinue |
        Sort-Object CreationTime -Descending)
    if ($oldBackups.Count -gt $BackupKeep) {
        $oldBackups | Select-Object -Skip $BackupKeep | ForEach-Object {
            Write-Host "古いバックアップを削除します: $($_.FullName)"
            Remove-Item -LiteralPath $_.FullName -Recurse -Force
        }
    }
}

# 履歴
$historyFile = Join-Path $backupRoot 'update-history.txt'
"{0}  {1} -> {2}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $currentVersion, $newVersion |
    Add-Content -LiteralPath $historyFile -Encoding UTF8

# 後片付け
if (-not $KeepWorkFiles) {
    Remove-Item -LiteralPath $workDir -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ""
Write-Host "更新が完了しました: $currentVersion -> $newVersion" -ForegroundColor Green
Write-Host "ユーザーデータ (Data フォルダ) は変更していないため、ブックマークや設定はそのまま使えます。"
Write-Host "問題があれば、Backup フォルダ内の旧本体 ($oldBinBackup) を App\Chrome-bin に戻すと元に戻せます。"

if ($Launch) {
    $launcher = Join-Path $PortableDir 'GoogleChromePortable.exe'
    if (Test-Path -LiteralPath $launcher) {
        Start-Process -FilePath $launcher
    } else {
        Start-Process -FilePath $chromeExe -ArgumentList "--user-data-dir=`"$(Join-Path $dataDir 'profile')`""
    }
}
