param(
    [string]$ReleaseDirectory,
    [string]$XxhsumPath
)

# SYNC_Morphingの配布用AUF2と説明書・ライセンスをZIPへ梱包する。
# 入力AUF2は読取専用。出力ZIPとカタログJSONのXXH3_128だけを原子的に更新する。
# ビルド・ホスト起動・ネットワークへの公開は行わない。
# Copyright (c) 2026 VRAMの魔術師 / SPDX-License-Identifier: GPL-3.0-only
$ErrorActionPreference = 'Stop'
$packageName = 'SYNC_Morphing'
$releaseVersion = 'v1.0.0'
$projectDir = Split-Path -Parent $PSScriptRoot

function Get-FileSHA256([string]$Path) {
    $sha256 = [Security.Cryptography.SHA256]::Create()
    try {
        $stream = [IO.File]::OpenRead($Path)
        try { return [BitConverter]::ToString($sha256.ComputeHash($stream)).Replace('-', '') }
        finally { $stream.Dispose() }
    }
    finally { $sha256.Dispose() }
}

$pluginName = "$packageName.auf2"
if (-not $ReleaseDirectory) {
    $ReleaseDirectory = Join-Path $projectDir 'Win64\Release'
    if (-not (Test-Path -LiteralPath (Join-Path $ReleaseDirectory $pluginName) -PathType Leaf)) {
        $ReleaseDirectory = Join-Path $env:ProgramData "aviutl2\Plugin\$packageName"
    }
}
$pluginPath = Join-Path $ReleaseDirectory $pluginName
if (-not (Test-Path -LiteralPath $pluginPath -PathType Leaf)) {
    throw "Release plugin not found: $pluginPath. Build the Win64 Release configuration first."
}
$pluginPath = (Resolve-Path -LiteralPath $pluginPath).ProviderPath

if (-not $XxhsumPath) {
    $XxhsumPath = Join-Path $projectDir 'Win64\Dependencies\xxHash-0.8.4\xxhsum.exe'
    if (-not (Test-Path -LiteralPath $XxhsumPath -PathType Leaf)) {
        $xxhsum = Get-Command xxhsum.exe -CommandType Application -ErrorAction SilentlyContinue
        if (-not $xxhsum) { throw 'xxhsum.exe is required. See setup\README.md.' }
        $XxhsumPath = $xxhsum.Source
    }
}
$XxhsumPath = (Resolve-Path -LiteralPath $XxhsumPath).ProviderPath

$catalogPath = Join-Path $PSScriptRoot "$packageName.catalog.json"
$zipPath = Join-Path $PSScriptRoot "$packageName.zip"
$tempBase = Join-Path $PSScriptRoot ('.release-' + [guid]::NewGuid().ToString('N'))
$tempPlugin = "$tempBase-plugin.tmp"
$tempZip = "$tempBase-zip.tmp"
$tempCatalog = "$tempBase-catalog.tmp"
$tempNotices = "$tempBase-notices.tmp"
$tempReadme = "$tempBase-readme.tmp"
$catalogBackup = "$tempBase-previous-catalog.tmp"

Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem
$lock = [Threading.Mutex]::new($false, "Local\VRAMWIZ.$packageName.ReleaseZip")
$ownsLock = $false
try {
    try { $ownsLock = $lock.WaitOne(0) }
    catch [Threading.AbandonedMutexException] { $ownsLock = $true }
    if (-not $ownsLock) { throw 'Another release ZIP is being created. Run the batch again.' }

    $catalogSource = [IO.File]::ReadAllText($catalogPath)
    if ($catalogSource -notmatch '^\s*\[') { throw 'The catalog root must be a JSON array.' }
    $catalog = [object[]]($catalogSource | ConvertFrom-Json)
    if ($catalog.Count -ne 1 -or $catalog[0].id -cne "VRAMWIZ.$packageName") {
        throw "The catalog must contain only VRAMWIZ.$packageName."
    }
    $entry = $catalog[0]
    $github = $entry.installer.source.github
    if ($github.owner -cne 'vramwiz' -or $github.repo -cne $packageName -or
        [string]::IsNullOrWhiteSpace($github.pattern) -or
        "$packageName.zip" -cnotmatch $github.pattern) {
        throw 'The catalog GitHub source must match this repository and ZIP name.'
    }
    $copyEntry = @($entry.installer.install | Where-Object action -ceq 'copy')
    if ($copyEntry.Count -ne 1 -or $copyEntry[0].from -cne "{tmp}/$packageName" -or
        $copyEntry[0].to -cne "{pluginsDir}/$packageName") {
        throw 'The catalog install paths must match the ZIP root and plugin directory.'
    }
    if (@($entry.version).Count -ne 1 -or $entry.version[0].version -cne $releaseVersion) {
        throw 'The initial Morphing catalog must contain only v1.0.0.'
    }
    $version = $entry.version[0]
    $publicVersion = $releaseVersion.Substring(1)
    $releaseDate = [datetime]::MinValue
    if ([string]::IsNullOrWhiteSpace($version.version) -or
        @($entry.version | Where-Object version -ceq $version.version).Count -ne 1 -or
        -not [datetime]::TryParseExact($version.release_date, 'yyyy-MM-dd',
            [Globalization.CultureInfo]::InvariantCulture,
            [Globalization.DateTimeStyles]::None, [ref]$releaseDate)) {
        throw 'The last catalog version must have a unique name and a valid yyyy-MM-dd release date.'
    }
    if ($releaseDate.Year -lt 1980 -or $releaseDate.Year -gt 2107) {
        throw 'The release date must be within the ZIP timestamp range (1980-2107).'
    }
    $pluginEntry = @($version.file | Where-Object path -ceq "{pluginsDir}/$packageName/$pluginName")
    if (@($version.file).Count -ne 1 -or $pluginEntry.Count -ne 1) {
        throw 'The last catalog version must list only the production AUF2 once.'
    }
    if (-not $pluginEntry[0].PSObject.Properties['XXH3_128'] -or
        ($pluginEntry[0].XXH3_128 -ne '' -and $pluginEntry[0].XXH3_128 -cnotmatch '^[0-9a-fA-F]{32}$')) {
        throw 'The AUF2 XXH3_128 must be empty or contain exactly 32 hexadecimal digits.'
    }

    # Hash the same AUF2 bytes that will go into the ZIP.
    Copy-Item -LiteralPath $pluginPath -Destination $tempPlugin
    $pluginSHA256 = Get-FileSHA256 $tempPlugin
    $binaryInfo = [Diagnostics.FileVersionInfo]::GetVersionInfo($tempPlugin)
    $binaryVersion = '{0}.{1}.{2}' -f $binaryInfo.FileMajorPart, $binaryInfo.FileMinorPart, $binaryInfo.FileBuildPart
    if ($binaryInfo.ProductName -cne $packageName -or $binaryInfo.ProductVersion -cne $publicVersion -or
        $binaryVersion -cne $publicVersion -or $binaryInfo.FilePrivatePart -ne 0 -or $binaryInfo.IsDebug) {
        throw "Release AUF2 product/version must match $packageName v$publicVersion. Rebuild Win64 Release first."
    }
    $hashOutput = & $XxhsumPath -H128 --tag $tempPlugin
    if ($LASTEXITCODE -ne 0 -or ($hashOutput -join "`n") -notmatch ' = ([0-9a-f]{32})\s*\z') {
        throw 'Could not calculate the AUF2 XXH3-128 hash.'
    }
    $hash = $Matches[1].ToLowerInvariant()

    $packageFiles = [ordered]@{
        $pluginName = $tempPlugin
        'README.md' = $tempReadme
        'LICENSE' = Join-Path $projectDir 'LICENSE'
        'THIRD_PARTY_NOTICES.md' = $tempNotices
        'ThirdParty/LICENSE.AviUtl2-SDK.txt' = Join-Path $projectDir 'ThirdParty\LICENSE.AviUtl2-SDK.txt'
        'Sample/morphing-preview.png' = Join-Path $projectDir 'Sample\morphing-preview.png'
    }
    # 開発用と配布用で同じライセンス配置を使用する。
    $notices = [IO.File]::ReadAllText((Join-Path $projectDir 'THIRD_PARTY_NOTICES.md'))
    [IO.File]::WriteAllText($tempNotices, $notices, [Text.UTF8Encoding]::new($false))
    # 利用者向けREADMEと作例を同梱し、配布ZIP内でも相対リンクを維持する。
    $readme = [IO.File]::ReadAllText((Join-Path $projectDir 'README.md'))
    if ($readme -notmatch ('\*\*v' + [regex]::Escape($publicVersion) + '\*\*')) {
        throw 'README version must match the catalog and Release AUF2.'
    }
    [IO.File]::WriteAllText($tempReadme, $readme, [Text.UTF8Encoding]::new($false))
    foreach ($file in $packageFiles.Values) {
        if (-not (Test-Path -LiteralPath $file -PathType Leaf)) { throw "Package file not found: $file" }
    }
    # インストールした全ファイルをアンインストールでき、他の場所を消さないことを確認する。
    $expectedPaths = @($packageFiles.Keys | ForEach-Object { "{pluginsDir}/$packageName/$_" })
    $deleteEntries = @($entry.installer.uninstall)
    $deletePaths = @($deleteEntries | Where-Object action -ceq 'delete' | ForEach-Object path)
    if ($deleteEntries.Count -ne $expectedPaths.Count -or $deletePaths.Count -ne $expectedPaths.Count -or
        @($deletePaths | Select-Object -Unique).Count -ne $expectedPaths.Count -or
        @(Compare-Object $expectedPaths $deletePaths -CaseSensitive).Count -ne 0) {
        throw 'The catalog uninstall paths must list every packaged file exactly once.'
    }
    $zip = [IO.Compression.ZipFile]::Open($tempZip, [IO.Compression.ZipArchiveMode]::Create)
    try {
        # 公開日の固定時刻を使い、同じ入力から同じZIPを生成する。
        $zipTimestamp = [DateTimeOffset]::new($releaseDate.Year, $releaseDate.Month, $releaseDate.Day,
            0, 0, 0, [TimeSpan]::Zero)
        foreach ($file in $packageFiles.GetEnumerator()) {
            $archiveEntry = $zip.CreateEntry("$packageName/$($file.Key)", [IO.Compression.CompressionLevel]::Optimal)
            $archiveEntry.LastWriteTime = $zipTimestamp
            $sourceStream = [IO.File]::OpenRead($file.Value)
            try {
                $archiveStream = $archiveEntry.Open()
                try { $sourceStream.CopyTo($archiveStream) }
                finally { $archiveStream.Dispose() }
            }
            finally { $sourceStream.Dispose() }
        }
    }
    finally { $zip.Dispose() }

    # ZIPを読み戻し、格納名・件数・実際の全ファイルを確定前に照合する。
    $zip = [IO.Compression.ZipFile]::OpenRead($tempZip)
    try {
        if ($zip.Entries.Count -ne $packageFiles.Count) { throw 'ZIP file count mismatch.' }
        foreach ($file in $packageFiles.GetEnumerator()) {
            $packedEntries = @($zip.Entries | Where-Object FullName -ceq "$packageName/$($file.Key)")
            if ($packedEntries.Count -ne 1) { throw "ZIP entry is missing or duplicated: $($file.Key)" }
            $stream = $packedEntries[0].Open()
            $sha256 = [Security.Cryptography.SHA256]::Create()
            try {
                $packedHash = [BitConverter]::ToString($sha256.ComputeHash($stream)).Replace('-', '')
            }
            finally { $sha256.Dispose(); $stream.Dispose() }
            if ($packedHash -cne (Get-FileSHA256 $file.Value)) {
                throw "ZIP content mismatch: $($file.Key)"
            }
        }
    }
    finally { $zip.Dispose() }

    if ((Get-FileSHA256 $pluginPath) -cne $pluginSHA256) {
        throw 'Release AUF2 changed during packaging. Run the batch again.'
    }
    if ([IO.File]::ReadAllText($catalogPath) -cne $catalogSource) {
        throw 'Catalog changed during packaging. Run the batch again.'
    }
    if ($pluginEntry[0].XXH3_128 -cne $hash) {
        $pluginEntry[0].XXH3_128 = $hash
        $json = ConvertTo-Json -InputObject $catalog -Depth 12
        [IO.File]::WriteAllText($tempCatalog, $json + [Environment]::NewLine, [Text.UTF8Encoding]::new($false))
        [IO.File]::Replace($tempCatalog, $catalogPath, $catalogBackup)
    }
    try {
        if ([IO.File]::Exists($zipPath)) { [IO.File]::Replace($tempZip, $zipPath, [NullString]::Value) }
        else { [IO.File]::Move($tempZip, $zipPath) }
    }
    catch {
        if ([IO.File]::Exists($catalogBackup)) {
            [IO.File]::Replace($catalogBackup, $catalogPath, [NullString]::Value)
        }
        throw
    }
    if ([IO.File]::Exists($catalogBackup)) { [IO.File]::Delete($catalogBackup) }
}
finally {
    if ($ownsLock) { $lock.ReleaseMutex() }
    $lock.Dispose()
    foreach ($tempPath in @($tempPlugin, $tempZip, $tempCatalog, $tempNotices, $tempReadme)) {
        [IO.File]::Delete($tempPath)
    }
}

Write-Output "Created $zipPath"
Write-Output "Catalog $catalogPath ($($version.version), XXH3_128=$hash)"
Write-Output "Release AUF2 SHA256=$pluginSHA256"
Write-Output "ZIP SHA256=$(Get-FileSHA256 $zipPath)"
