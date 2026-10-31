<#
.SYNOPSIS
  Adds English UI support to the Chinese (CN) build of vivo Office Kit (vivo办公套件).

.DESCRIPTION
  The CN build is the same Electron app as the Global build, but its UI code forces
  the language to zh_CN whenever build-config.json says IS_EXPORT=false:

      renderer.js : if(!isExport) return "zh_CN";
      main/renderer: isExport || (setItem("currentLanguage","zh_CN"), ...)

  This script neutralises those locks, translates hard-coded Chinese labels listed in
  translations.json, rebuilds the asar (changed files appended, header and integrity
  hashes updated), then sets the saved language to en_US. Server / account / USB
  behaviour stays 100% Chinese, so a China-market phone (e.g. X200 Ultra) keeps connecting.

  Safe to run repeatedly. Originals are backed up once as *.en-kit.bak.

.PARAMETER Restore     Put the original (Chinese-only) files back.
.PARAMETER InstallDir  Override auto-detected install folder.
.PARAMETER ConfigDir   Override %APPDATA%\pcsuite (user settings folder).
.PARAMETER Force       Patch even if the install looks like the Global build.
.PARAMETER NoServiceControl  Don't stop/start vivo processes and services (testing).
.PARAMETER NoLaunch    Don't start vivo Office Kit afterwards.
.PARAMETER NoLabelTranslation  Only unlock English; leave hard-coded Chinese labels alone.
#>
[CmdletBinding()]
param(
    [switch]$Restore,
    [switch]$NoLabelTranslation,
    [string]$InstallDir,
    [string]$ConfigDir = (Join-Path $env:APPDATA 'pcsuite'),
    [switch]$Force,
    [switch]$NoServiceControl,
    [switch]$NoLaunch
)

$ErrorActionPreference = 'Stop'
$KitDir   = $PSScriptRoot
$LogFile  = Join-Path $KitDir 'patch-log.txt'
$BakExt   = '.en-kit.bak'
$Latin1   = [Text.Encoding]::GetEncoding(28591)   # 1 char == 1 byte, keeps offsets exact
$Services = 'vivoesService_x64', 'vivoesService', 'vivoSyncService'

function Log([string]$msg, [string]$color = 'Gray') {
    $line = '[{0:HH:mm:ss}] {1}' -f (Get-Date), $msg
    Write-Host $line -ForegroundColor $color
    Add-Content -Path $LogFile -Value $line -Encoding UTF8
}

function ConvertFrom-JsonHash([string]$json) {
    if ($PSVersionTable.PSVersion.Major -ge 6) { return $json | ConvertFrom-Json -AsHashtable }
    Add-Type -AssemblyName System.Web.Extensions
    $ser = New-Object System.Web.Script.Serialization.JavaScriptSerializer
    $ser.MaxJsonLength = [int]::MaxValue
    $ser.RecursionLimit = 1000
    return $ser.DeserializeObject($json)
}

function Find-InstallDir {
    $keys = 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*',
            'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
            'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*'
    foreach ($k in $keys) {
        $hit = Get-ItemProperty $k -ErrorAction SilentlyContinue |
            Where-Object { $_.PSChildName -eq 'pcsuite' -or $_.DisplayName -match 'vivo.*(Office Kit|办公套件)' } |
            Select-Object -First 1
        if ($hit) {
            $dir = $hit.InstallLocation
            if (-not $dir -and $hit.UninstallString) { $dir = Split-Path ($hit.UninstallString.Trim('"')) }
            if ($dir -and (Test-Path (Join-Path $dir 'resources\app.asar'))) { return $dir }
        }
    }
    foreach ($d in "${env:ProgramFiles(x86)}\pcsuite", "$env:ProgramFiles\pcsuite") {
        if (Test-Path (Join-Path $d 'resources\app.asar')) { return $d }
    }
    return $null
}

function Stop-Vivo([string]$dir) {
    Get-Process | Where-Object { $_.Path -and $_.Path.StartsWith($dir, [StringComparison]::OrdinalIgnoreCase) } |
        ForEach-Object { Log "Stopping process $($_.Name)"; Stop-Process -Id $_.Id -Force -ErrorAction SilentlyContinue }
    foreach ($s in $Services) {
        $svc = Get-Service $s -ErrorAction SilentlyContinue
        if ($svc -and $svc.Status -eq 'Running') { Log "Stopping service $s"; Stop-Service $s -Force -ErrorAction SilentlyContinue }
    }
    Start-Sleep -Seconds 2
}

function Start-VivoServices {
    foreach ($s in $Services) {
        $svc = Get-Service $s -ErrorAction SilentlyContinue
        if ($svc -and $svc.StartType -ne 'Disabled' -and $svc.Status -ne 'Running') {
            Log "Starting service $s"; Start-Service $s -ErrorAction SilentlyContinue
        }
    }
}

# --- asar helpers -----------------------------------------------------------------

function Read-AsarHeader([IO.FileStream]$fs) {
    $br = New-Object IO.BinaryReader($fs)
    $fs.Position = 0
    $null = $br.ReadUInt32(); $headerSize = $br.ReadUInt32()
    $null = $br.ReadUInt32(); $jsonLen = $br.ReadUInt32()
    $jsonBytes = $br.ReadBytes($jsonLen)
    if ($headerSize -ne 8 + (($jsonLen + 3) -band -4)) { throw 'Unexpected asar header layout; aborting' }
    [pscustomobject]@{
        DataBase  = 8 + [int64]$headerSize
        Json      = [Text.Encoding]::UTF8.GetString($jsonBytes)
    }
}

function Get-AsarFiles($node, [string]$prefix, [System.Collections.Generic.List[object]]$out) {
    foreach ($name in @($node['files'].Keys)) {
        $entry = $node['files'][$name]
        $path = if ($prefix) { "$prefix/$name" } else { $name }
        if ($entry.ContainsKey('files')) {
            if ($name -ne 'node_modules') { Get-AsarFiles $entry $path $out }
        } elseif (-not $entry['unpacked']) {
            $out.Add([pscustomobject]@{ Path = $path; Size = [int64]$entry['size']; Offset = [string]$entry['offset'] })
        }
    }
}

function Get-Sha256Hex([byte[]]$bytes, [int]$start, [int]$count) {
    $sha = [Security.Cryptography.SHA256]::Create()
    try { return (($sha.ComputeHash($bytes, $start, $count) | ForEach-Object { $_.ToString('x2') }) -join '') }
    finally { $sha.Dispose() }
}

# Points the header entry whose offset is $oldOffset at a new body: size, offset and
# integrity (whole-file hash + per-block hashes) are rewritten, key order is kept.
$EntryRegex = [regex]'^\{"size":\d+,(?:"integrity":(?<int>\{"algorithm":"SHA256","hash":"[0-9a-f]{64}","blockSize":(?<bs>\d+),"blocks":\[[^\]]*\]\}),)?"offset":"\d+"(?:,"integrity":(?<int2>\{"algorithm":"SHA256","hash":"[0-9a-f]{64}","blockSize":(?<bs2>\d+),"blocks":\[[^\]]*\]\}))?\}$'
function Set-AsarEntry([string]$json, [string]$oldOffset, [int64]$newOffset, [byte[]]$data) {
    $anchor = '"offset":"' + $oldOffset + '"'
    $a = $json.IndexOf($anchor)
    if ($a -lt 0 -or $json.IndexOf($anchor, $a + 1) -ge 0) { throw "asar entry at offset $oldOffset not found or not unique" }
    $start = $json.LastIndexOf('{"size":', $a)
    $depth = 0
    for ($end = $start; $end -lt $json.Length; $end++) {
        if ($json[$end] -eq '{') { $depth++ } elseif ($json[$end] -eq '}') { $depth--; if ($depth -eq 0) { break } }
    }
    $seg = $json.Substring($start, $end - $start + 1)
    $m = $EntryRegex.Match($seg)
    if (-not $m.Success) { throw "Unexpected asar entry layout at offset $oldOffset" }

    $integrity = ''
    $bsText = if ($m.Groups['bs'].Success) { $m.Groups['bs'].Value } else { $m.Groups['bs2'].Value }
    if ($bsText) {
        $bs = [int]$bsText
        $blocks = for ($p = 0; $p -lt $data.Length; $p += $bs) {
            '"' + (Get-Sha256Hex $data $p ([Math]::Min($bs, $data.Length - $p))) + '"'
        }
        $integrity = '"integrity":{"algorithm":"SHA256","hash":"' + (Get-Sha256Hex $data 0 $data.Length) +
                     '","blockSize":' + $bs + ',"blocks":[' + ($blocks -join ',') + ']}'
    }
    $size = '"size":' + $data.Length
    $off  = '"offset":"' + $newOffset + '"'
    $new = if ($m.Groups['int'].Success) { "{$size,$integrity,$off}" }
           elseif ($integrity) { "{$size,$off,$integrity}" }
           else { "{$size,$off}" }
    return $json.Substring(0, $start) + $new + $json.Substring($end + 1)
}

# Writes a new archive: new header + the original data block untouched + changed file
# bodies appended at the end (old bodies stay as unused bytes). Swapped in atomically.
function Write-Asar([string]$asar, [string]$json, [int64]$dataBase, [System.Collections.Generic.List[object]]$changes) {
    $jb = [Text.Encoding]::UTF8.GetBytes($json)
    $padded = ($jb.Length + 3) -band -4
    $tmp = "$asar.en-kit.tmp"
    $src = [IO.File]::Open($asar, 'Open', 'Read', 'Read')
    try {
        $dst = [IO.File]::Open($tmp, 'Create', 'Write', 'None')
        try {
            $bw = New-Object IO.BinaryWriter($dst)
            $bw.Write([uint32]4); $bw.Write([uint32](8 + $padded))
            $bw.Write([uint32](4 + $padded)); $bw.Write([uint32]$jb.Length)
            $bw.Write($jb); $bw.Write((New-Object byte[] ($padded - $jb.Length)))
            $bw.Flush()
            $src.Position = $dataBase
            $src.CopyTo($dst, 4MB)
            foreach ($c in $changes) { $dst.Write($c.Bytes, 0, $c.Bytes.Length) }
        } finally { $dst.Dispose() }
    } catch { Remove-Item -LiteralPath $tmp -ErrorAction SilentlyContinue; throw }
    finally { $src.Dispose() }
    try { [IO.File]::Replace($tmp, $asar, [NullString]::Value) }
    catch {
        # File.Replace fails through directory junctions; fall back to a plain overwrite.
        try { Copy-Item -LiteralPath $tmp -Destination $asar -Force }
        finally { Remove-Item -LiteralPath $tmp -ErrorAction SilentlyContinue }
    }
}

# Same-length replacements that unlock non-Chinese UI languages on the CN build.
$Patches = @(
    @{  # function o(){ if(!isExport) return "zh_CN"; ... }  -> fall through to saved language
        Name  = 'renderer zh_CN lock'
        Regex = [regex]'(?<![\w$])if\(![\w$]{1,6}\)return"zh_CN";'
        Make  = { param($m) ' ' * $m.Length }
    },
    @{  # isExport || (store.setItem("currentLanguage","zh_CN"), ...)  -> never runs
        Name  = 'force zh_CN on mode switch'
        Regex = [regex]'(?<![\w$.])(?!1 *\|\|)(?<v>[\w$]{1,6})\|\|\((?=[\w$]{1,6}\.default\.setItem\("currentLanguage","zh_CN"\))'
        Make  = { param($m) '1' + (' ' * ($m.Groups['v'].Length - 1)) + '||(' }
    },
    @{  # const locale = isExport ? getDefaultLanguage() : "zh_CN", i18n = new VueI18n({locale ...})
        Name  = 'vue-i18n startup locale'
        Regex = [regex]'(?<![\w$])[\w$]{1,6}\?(?<f>[\w$]{1,6})\(\):"zh_CN"(?=,[\w$]{1,6}=new [\w$]{1,6}\.default\(\{locale:)'
        Make  = { param($m) $call = $m.Groups['f'].Value + '()'; $call + (' ' * ($m.Length - $call.Length)) }
    }
)

# Hard-coded Chinese labels (China-only features have no translation in the app).
# Keys/values are Latin1 views of UTF-8 bytes, matching how Patch-Asar reads files.
function Get-LabelTranslator {
    $file = Join-Path $KitDir 'translations.json'
    if ($NoLabelTranslation -or -not (Test-Path $file)) { return $null }
    $table = ConvertFrom-JsonHash ([IO.File]::ReadAllText($file, [Text.Encoding]::UTF8))
    $toLatin1 = { param($s) $Latin1.GetString([Text.Encoding]::UTF8.GetBytes($s)) }
    $map = @{}
    foreach ($zh in @($table.Keys)) {
        if ($zh.StartsWith('_')) { continue }
        $en = ([string]$table[$zh]).Replace('\', '\\').Replace('"', '\"')
        $map['"' + (& $toLatin1 $zh) + '"'] = '"' + (& $toLatin1 $en) + '"'
    }
    # "_code": exact code snippets, for labels that are also used as data elsewhere.
    $code = $table['_code']
    if ($code) {
        foreach ($snip in @($code.Keys)) {
            if (-not $snip.StartsWith('_')) { $map[(& $toLatin1 $snip)] = & $toLatin1 ([string]$code[$snip]) }
        }
    }
    if ($map.Count -eq 0) { return $null }
    $alts = $map.Keys | Sort-Object Length -Descending | ForEach-Object { [regex]::Escape($_) }
    [pscustomobject]@{ Map = $map; Regex = [regex]($alts -join '|') }
}

function Patch-Asar([string]$asar, [string]$bak) {
    Log "Scanning $asar"
    $changes = New-Object System.Collections.Generic.List[object]
    $fs = [IO.File]::Open($asar, 'Open', 'Read', 'Read')
    try {
        $hdr  = Read-AsarHeader $fs
        $tree = ConvertFrom-JsonHash $hdr.Json
        $files = New-Object System.Collections.Generic.List[object]
        Get-AsarFiles $tree '' $files

        $json = $hdr.Json
        $nextOffset = $fs.Length - $hdr.DataBase
        $total = 0
        $hasEnglish = $false
        foreach ($f in $files) {
            if ($f.Path -match '(^|/)locales?[-/]en_US') { $hasEnglish = $true }
            if ($f.Path -notmatch '\.js$' -or $f.Size -gt 64MB -or $f.Size -eq 0) { continue }
            $fs.Position = $hdr.DataBase + [int64]$f.Offset
            $buf = New-Object byte[] $f.Size
            $null = $fs.Read($buf, 0, $buf.Length)
            $text = $Latin1.GetString($buf)
            $doLocks = $text.IndexOf('zh_CN') -ge 0
            # App code only: not translation bundles or third-party static files (TinyMCE langs).
            $doLabels = $Labels -and $f.Path -notmatch '(^|/)(locales|static|langs)([-/_]|$)' -and $Labels.Regex.IsMatch($text)
            if (-not ($doLocks -or $doLabels)) { continue }

            $counter = @{ n = 0; labels = 0 }
            if ($doLocks) {
                foreach ($p in $Patches) {
                    $make = $p.Make
                    $text = $p.Regex.Replace($text, [Text.RegularExpressions.MatchEvaluator]{
                        param($m) $counter.n++; & $make $m
                    })
                }
            }
            if ($doLabels) {
                $map = $Labels.Map
                $text = $Labels.Regex.Replace($text, [Text.RegularExpressions.MatchEvaluator]{
                    param($m) $counter.labels++; $map[$m.Value]
                })
            }
            $hits = $counter.n
            $script:LabelCount += $counter.labels
            if ($hits -eq 0 -and $counter.labels -eq 0) { continue }

            $newBytes = $Latin1.GetBytes($text)
            $json = Set-AsarEntry $json $f.Offset $nextOffset $newBytes
            $changes.Add([pscustomobject]@{ Bytes = $newBytes })
            $nextOffset += $newBytes.Length
            Log "  patched $($f.Path) ($hits lock(s), $($counter.labels) label(s))" 'Green'
            $total += $hits
        }
    }
    finally { $fs.Dispose() }

    if ($changes.Count -gt 0) {
        # Unpatched locks mean this archive is fresh from vivo (first run or an app update),
        # so it is the right thing to keep as the Chinese original.
        if (-not (Test-Path $bak)) { Copy-Item $asar $bak; Log "Backup: $bak" }
        elseif ($total -gt 0) { Copy-Item $asar $bak -Force; Log "Backup refreshed (app was updated): $bak" }
        Write-Asar $asar $json $hdr.DataBase $changes
    }
    return [pscustomobject]@{ Sites = $total; HasEnglish = $hasEnglish }
}

function Set-EnglishSettings([string]$cfgDir) {
    $ini = Join-Path $cfgDir 'config.ini'
    if (Test-Path $ini) {
        $lines = Get-Content $ini -Encoding UTF8
        $lines = $lines -replace '^LanguageTag=.*', 'LanguageTag=en_US' -replace '^LanguageID=.*', 'LanguageID=1033'
        if (-not ($lines -match '^LanguageTag=')) { $lines += 'LanguageTag=en_US' }
        Set-Content $ini $lines -Encoding UTF8
        Log 'config.ini -> LanguageTag=en_US, LanguageID=1033'
    }
    $cfg = Join-Path $cfgDir 'config.json'
    if (Test-Path $cfg) {
        $raw = [IO.File]::ReadAllText($cfg)
        $orig = $raw
        foreach ($kv in @(@('currentLanguage', '"en_US"'), @('vLang', '"vus"'), @('isRtl', 'false'))) {
            $pat = '("' + $kv[0] + '"\s*:\s*)("[^"]*"|true|false)'
            if ($raw -match $pat) { $raw = [regex]::Replace($raw, $pat, ('${1}' + $kv[1])) }
            else { $raw = [regex]::Replace($raw, '^\s*\{', ('{"' + $kv[0] + '":' + $kv[1] + ',')) }
        }
        if ($raw -ne $orig) {
            [IO.File]::WriteAllText($cfg, $raw, (New-Object Text.UTF8Encoding($false)))
            Log 'config.json -> currentLanguage=en_US'
        }
    } else {
        Log 'config.json not found yet (app never started). English will come from config.ini / Windows language.' 'Yellow'
    }
}

# --- main ---------------------------------------------------------------------------

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $InstallDir) { $InstallDir = Find-InstallDir }
if (-not $InstallDir) { Write-Host 'vivo Office Kit installation not found.' -ForegroundColor Red; exit 1 }
$needsAdmin = $InstallDir.StartsWith($env:ProgramFiles, 'OrdinalIgnoreCase') -or
              $InstallDir.StartsWith(${env:ProgramFiles(x86)}, 'OrdinalIgnoreCase')
if ($needsAdmin -and -not $isAdmin) {
    $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`"", '-InstallDir', "`"$InstallDir`"", '-ConfigDir', "`"$ConfigDir`"")
    foreach ($s in 'Restore', 'NoLabelTranslation', 'Force', 'NoServiceControl', 'NoLaunch') { if ((Get-Variable $s).Value) { $argList += "-$s" } }
    $exe = (Get-Process -Id $PID).Path
    Start-Process $exe -Verb RunAs -ArgumentList $argList
    exit 0
}

Log "=== vivo English kit: $(if ($Restore) {'RESTORE'} else {'PATCH'}) ===" 'Cyan'
Log "Install folder: $InstallDir"

$buildCfg = Join-Path $InstallDir 'resources\build-config.json'
$isExport = $false
if (Test-Path $buildCfg) { $isExport = [IO.File]::ReadAllText($buildCfg) -match '"IS_EXPORT"\s*:\s*true' }
$exePath = Join-Path $InstallDir 'pcsuite.exe'
$ver = if (Test-Path $exePath) { (Get-Item $exePath).VersionInfo.FileVersion } else { '?' }
Log ("Detected: vivo Office Kit {0} ({1} build)" -f $ver, $(if ($isExport) {'Global'} else {'Chinese'}))
if ($isExport -and -not $Force -and -not $Restore) {
    Log 'This is the GLOBAL build, which is already English. This kit is for the Chinese build. Use -Force to override.' 'Yellow'
    exit 2
}

$asars = Get-ChildItem $InstallDir -Recurse -Filter 'app.asar' -File -ErrorAction SilentlyContinue |
    Where-Object { $_.FullName -notmatch '\.unpacked' }

if (-not $NoServiceControl) { Stop-Vivo $InstallDir }

try {
    if ($Restore) {
        foreach ($a in $asars) {
            $bak = $a.FullName + $BakExt
            if (Test-Path $bak) { Copy-Item $bak $a.FullName -Force; Remove-Item $bak; Log "Restored $($a.FullName)" 'Green' }
        }
        Log 'Restore complete. The app will show Chinese again.' 'Cyan'
    } else {
        $sum = 0; $english = $false
        $script:LabelCount = 0
        $Labels = Get-LabelTranslator
        foreach ($a in $asars) {
            $r = Patch-Asar $a.FullName ($a.FullName + $BakExt)
            $sum += $r.Sites
            if ($r.HasEnglish) { $english = $true }
        }

        # Chromium UI strings (context menus etc.). Copy from kit if missing.
        foreach ($pair in @(@('locales', 'pcsuite'), @('vivoControl\locales', 'vivoControl'))) {
            $dst = Join-Path $InstallDir "$($pair[0])\en-US.pak"
            $src = Join-Path $KitDir "assets\global-7.0.6\$($pair[1])\chromium-locales\en-US.pak"
            if ((Test-Path (Split-Path $dst)) -and -not (Test-Path $dst) -and (Test-Path $src)) {
                Copy-Item $src $dst; Log "Added $dst"
            }
        }

        Set-EnglishSettings $ConfigDir

        if ($sum -gt 0) { Log "Patched $sum language-lock site(s)." 'Green' }
        else { Log 'No language locks found (already patched, or a newer build changed the code).' 'Yellow' }
        if ($script:LabelCount -gt 0) { Log "Translated $($script:LabelCount) hard-coded Chinese label(s)." 'Green' }
        if (-not $english) {
            Log 'WARNING: this build has no en_US translation bundle. UI may stay Chinese - send patch-log.txt to Claude.' 'Red'
        }
        Log 'Done. To undo, run Restore-Chinese.cmd.' 'Cyan'
    }
} finally {
    if (-not $NoServiceControl) {
        Start-VivoServices
        # Launch through Explorer so the app runs un-elevated (an admin window blocks drag & drop from Explorer).
        if (-not $NoLaunch) { Start-Process explorer.exe -ArgumentList ('"' + (Join-Path $InstallDir 'pcsuite.exe') + '"') }
    }
}
