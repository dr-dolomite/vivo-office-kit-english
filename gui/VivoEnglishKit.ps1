<#
.SYNOPSIS
  Windows 11 (Fluent) front-end for Add-VivoEnglish.ps1.

.DESCRIPTION
  Shows what is installed, then runs the patcher hidden (elevated through UAC when the
  install lives under Program Files), follows patch-log.txt for progress and reports
  the outcome as a success / warning / error InfoBar.

  The Fluent look needs PowerShell 7.5+ (.NET 9+). Windows PowerShell 5.1 still works,
  with the classic WPF look.

.PARAMETER InstallDir        Use this vivo Office Kit folder instead of auto-detecting (testing).
.PARAMETER ConfigDir         Override %APPDATA%\pcsuite (testing).
.PARAMETER NoServiceControl  Passed to the patcher: don't stop/start vivo (testing).
.PARAMETER NoLaunch          Passed to the patcher: don't start vivo Office Kit afterwards.
#>
[CmdletBinding()]
param(
    [string]$InstallDir,
    [string]$ConfigDir = (Join-Path $env:APPDATA 'pcsuite'),
    [switch]$NoServiceControl,
    [switch]$NoLaunch
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase

$KitDir     = Split-Path $PSScriptRoot
$Patcher    = Join-Path $KitDir 'Add-VivoEnglish.ps1'
$LogFile    = Join-Path $KitDir 'patch-log.txt'
$BakExt     = '.en-kit.bak'
$TestedVer  = [version]'7.0.6'
$TestedText = 'vivo Office Kit (vivo办公套件) 7.0.6, Chinese build'
$TimeoutMin = 10

# Hide the console window this script may have been started from.
Add-Type -Namespace VivoKit -Name Native -MemberDefinition @'
[DllImport("kernel32.dll")] public static extern System.IntPtr GetConsoleWindow();
[DllImport("user32.dll")] public static extern bool ShowWindow(System.IntPtr h, int cmd);
'@
$console = [VivoKit.Native]::GetConsoleWindow()
if ($console -ne [IntPtr]::Zero) { $null = [VivoKit.Native]::ShowWindow($console, 0) }

# --- window ----------------------------------------------------------------------------

$app = [System.Windows.Application]::Current
if (-not $app) { $app = New-Object System.Windows.Application }
$fluent = $null -ne $app.GetType().GetProperty('ThemeMode')
if ($fluent) { $app.ThemeMode = [System.Windows.ThemeMode]::System }

# One InfoBar markup, stamped out under two names.
$infoBar = @'
<Border x:Name="{P}Bar" Visibility="Collapsed" CornerRadius="4" BorderThickness="1" Padding="14,10,8,10" Margin="0,0,0,12">
  <Grid>
    <Grid.ColumnDefinitions>
      <ColumnDefinition Width="Auto"/><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/>
    </Grid.ColumnDefinitions>
    <TextBlock x:Name="{P}Icon" FontFamily="{StaticResource IconFont}" FontSize="16" Margin="0,2,12,0" VerticalAlignment="Top"/>
    <StackPanel Grid.Column="1" VerticalAlignment="Center" Margin="0,0,8,0">
      <TextBlock x:Name="{P}Title" FontWeight="SemiBold" TextWrapping="Wrap" Foreground="{DynamicResource TextFillColorPrimaryBrush}"/>
      <TextBlock x:Name="{P}Message" TextWrapping="Wrap" Margin="0,2,0,0" Foreground="{DynamicResource TextFillColorPrimaryBrush}"/>
    </StackPanel>
    <Button x:Name="{P}Close" Grid.Column="2" VerticalAlignment="Top" Padding="6" Background="Transparent" BorderThickness="0"
            ToolTip="Close" AutomationProperties.Name="Close">
      <TextBlock Text="&#xE711;" FontFamily="{StaticResource IconFont}" FontSize="12"/>
    </Button>
  </Grid>
</Border>
'@
$xaml = [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'MainWindow.xaml'))
foreach ($p in 'Compat', 'Result') { $xaml = $xaml.Replace("<!--INFOBAR:$p-->", $infoBar.Replace('{P}', $p)) }
$win = [Windows.Markup.XamlReader]::Parse($xaml)

$ui = @{}
foreach ($n in 'PathText', 'BuildIcon', 'BuildText', 'VersionIcon', 'VersionText', 'PatchIcon', 'PatchText', 'TestedText',
               'LabelsCheck', 'InstallButton', 'InstallButtonText', 'RestoreButton', 'RefreshButton', 'LogButton',
               'FolderButton', 'HeaderGlyph', 'BusyPanel', 'BusyTitle', 'BusyDetail', 'NoteText', 'AdminText', 'HeaderTile',
               'RecommendedBadge', 'CompatBar', 'CompatIcon', 'CompatTitle', 'CompatMessage', 'CompatClose',
               'ResultBar', 'ResultIcon', 'ResultTitle', 'ResultMessage', 'ResultClose') {
    $ui[$n] = $win.FindName($n)
}
$ui.TestedText.Text = $TestedText
# Windows 10 has Segoe MDL2 Assets only, which lacks the Fluent "language" glyph.
if (-not ([System.Windows.Media.Fonts]::SystemFontFamilies | Where-Object Source -eq 'Segoe Fluent Icons')) {
    $ui.HeaderGlyph.Text = [char]0xE8C1
}

# --- theme -----------------------------------------------------------------------------

function Get-IsDark {
    try { (Get-ItemPropertyValue 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize' AppsUseLightTheme) -eq 0 }
    catch { $false }
}

function New-Brush([string]$hex) {
    # BrushConverter, not New-Object SolidColorBrush: 5.1 passes the boxed Color through as a string.
    $b = [System.Windows.Media.Brush](New-Object System.Windows.Media.BrushConverter).ConvertFromString($hex)
    $b.Freeze(); $b
}

# InfoBar palette from the Windows UI kit (background, icon) per theme.
$SeverityStyle = @{
    Success = @{ Glyph = [char]0xE930; Light = '#DFF6DD', '#0F7B0F'; Dark = '#393D1B', '#6CCB5F' }
    Warning = @{ Glyph = [char]0xE7BA; Light = '#FFF4CE', '#9D5D00'; Dark = '#433519', '#FCE100' }
    Error   = @{ Glyph = [char]0xEA39; Light = '#FDE7E9', '#C42B1C'; Dark = '#442726', '#FF99A4' }
    Info    = @{ Glyph = [char]0xE946; Light = '#F6F6F6', '#005FB8'; Dark = '#2B2B2B', '#60CDFF' }
}

function Set-Theme {
    $dark = $fluent -and (Get-IsDark)   # the classic fallback below is light-only
    $r = $win.Resources
    foreach ($k in $SeverityStyle.Keys) {
        $c = if ($dark) { $SeverityStyle[$k].Dark } else { $SeverityStyle[$k].Light }
        $r["Info${k}Background"] = New-Brush $c[0]
        $r["Info${k}Icon"]       = New-Brush $c[1]
    }
    $r['InfoBorder'] = New-Brush $(if ($dark) { '#19000000' } else { '#0F000000' })
    if (-not $fluent) {
        # Classic WPF has none of the Fluent resources; supply close equivalents.
        $glass = [System.Windows.SystemParameters]::WindowGlassColor
        $accent = New-Brush ('#FF{0:X2}{1:X2}{2:X2}' -f $glass.R, $glass.G, $glass.B)
        $r['AccentFillColorDefaultBrush']          = $accent
        $r['TextOnAccentFillColorPrimaryBrush']    = New-Brush '#FFFFFF'
        $r['CardBackgroundFillColorDefaultBrush']  = New-Brush '#FBFBFB'
        $r['CardStrokeColorDefaultBrush']          = New-Brush '#E5E5E5'
        $r['TextFillColorPrimaryBrush']            = New-Brush '#1A1A1A'
        $r['TextFillColorSecondaryBrush']          = New-Brush '#5F5F5F'
        $r['TextFillColorTertiaryBrush']           = New-Brush '#8A8A8A'
        $r['ControlStrongStrokeColorDefaultBrush'] = New-Brush '#8A8A8A'
        $win.Background = New-Brush '#F3F3F3'
        $ui.InstallButton.Background = $accent
        $ui.InstallButton.Foreground = $r['TextOnAccentFillColorPrimaryBrush']
    }
    foreach ($b in 'Compat', 'Result') {
        if ($ui["${b}Bar"].Tag) { Set-InfoBarColors $b $ui["${b}Bar"].Tag }
    }
}

function Set-InfoBarColors([string]$bar, [string]$severity) {
    $ui["${bar}Bar"].Background  = $win.Resources["Info${severity}Background"]
    $ui["${bar}Bar"].BorderBrush = $win.Resources['InfoBorder']
    $ui["${bar}Icon"].Foreground = $win.Resources["Info${severity}Icon"]
}

function Show-InfoBar([string]$bar, [string]$severity, [string]$title, [string]$message) {
    $ui["${bar}Bar"].Tag = $severity
    $ui["${bar}Icon"].Text = $SeverityStyle[$severity].Glyph
    $ui["${bar}Title"].Text = $title
    $ui["${bar}Message"].Text = $message
    $ui["${bar}Message"].Visibility = if ($message) { 'Visible' } else { 'Collapsed' }
    Set-InfoBarColors $bar $severity
    $ui["${bar}Bar"].Visibility = 'Visible'
}

function Hide-InfoBar([string]$bar) { $ui["${bar}Bar"].Visibility = 'Collapsed' }

function Set-StatusIcon($el, [string]$severity) {
    $el.Text = $SeverityStyle[$severity].Glyph
    $el.Foreground = $win.Resources["Info${severity}Icon"]
}

# --- detection (read-only) -------------------------------------------------------------

function Find-Install {
    if ($InstallDir) { return [pscustomobject]@{ Dir = $InstallDir; DisplayName = $null; DisplayVersion = $null } }
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
            if ($dir -and (Test-Path (Join-Path $dir 'resources\app.asar'))) {
                return [pscustomobject]@{ Dir = $dir; DisplayName = $hit.DisplayName; DisplayVersion = $hit.DisplayVersion }
            }
        }
    }
    foreach ($d in "${env:ProgramFiles(x86)}\pcsuite", "$env:ProgramFiles\pcsuite") {
        if (Test-Path (Join-Path $d 'resources\app.asar')) {
            return [pscustomobject]@{ Dir = $d; DisplayName = $null; DisplayVersion = $null }
        }
    }
    $null
}

function Get-KitStatus {
    $s = [ordered]@{ Found = $false; Dir = $null; Build = 'Unknown'; Version = $null; Patch = 'None'; Running = $false }
    $hit = Find-Install
    if (-not $hit -or -not (Test-Path (Join-Path $hit.Dir 'resources\app.asar'))) { return [pscustomobject]$s }
    $s.Found = $true
    $s.Dir = $hit.Dir

    $cfg = Join-Path $hit.Dir 'resources\build-config.json'
    if (Test-Path $cfg) {
        $s.Build = if ([IO.File]::ReadAllText($cfg) -match '"IS_EXPORT"\s*:\s*true') { 'Global' } else { 'Chinese' }
    } elseif ($hit.DisplayName -match '办公套件') { $s.Build = 'Chinese' }
    elseif ($hit.DisplayName -match 'Office Kit') { $s.Build = 'Global' }

    $exe = Join-Path $hit.Dir 'pcsuite.exe'
    if (Test-Path $exe) { $s.Version = (Get-Item $exe).VersionInfo.FileVersion }
    if (-not $s.Version) { $s.Version = $hit.DisplayVersion }

    if (Test-Path (Join-Path $hit.Dir "resources\app.asar$BakExt")) { $s.Patch = 'Installed' }

    $s.Running = [bool](Get-Process -Name pcsuite -ErrorAction SilentlyContinue |
        Where-Object { $_.Path -and $_.Path.StartsWith($hit.Dir, [StringComparison]::OrdinalIgnoreCase) })
    [pscustomobject]$s
}

function Test-TestedVersion([string]$v) {
    $m = [regex]::Match([string]$v, '^\d+(\.\d+){1,3}')
    if (-not $m.Success) { return $false }
    $p = ([version]$m.Value)
    $p.Major -eq $TestedVer.Major -and $p.Minor -eq $TestedVer.Minor -and $p.Build -eq $TestedVer.Build
}

$script:Status = $null
$script:Busy = $false

function Update-Status {
    $s = Get-KitStatus
    $script:Status = $s
    Hide-InfoBar 'Compat'

    if (-not $s.Found) {
        $ui.PathText.Text = 'Not found'
        Set-StatusIcon $ui.BuildIcon 'Error'; $ui.BuildText.Text = 'Not installed'
        $ui.VersionIcon.Text = ''; $ui.VersionText.Text = '-'
        $ui.PatchIcon.Text = ''; $ui.PatchText.Text = '-'
        Show-InfoBar 'Compat' 'Error' 'vivo Office Kit is not installed' `
            'Install the Chinese vivo Office Kit (vivo办公套件) 7.0.6 from vivo.com.cn, open it once, then click Refresh.'
    } else {
        $ui.PathText.Text = $s.Dir
        switch ($s.Build) {
            'Chinese' { Set-StatusIcon $ui.BuildIcon 'Success'; $ui.BuildText.Text = 'Chinese (vivo办公套件)' }
            'Global'  { Set-StatusIcon $ui.BuildIcon 'Error';   $ui.BuildText.Text = 'Global (vivo Office Kit)' }
            default   { Set-StatusIcon $ui.BuildIcon 'Warning'; $ui.BuildText.Text = 'Unknown (build-config.json missing)' }
        }
        $tested = Test-TestedVersion $s.Version
        $ui.VersionText.Text = if ($s.Version) { $s.Version } else { 'Unknown' }
        Set-StatusIcon $ui.VersionIcon $(if ($tested) { 'Success' } else { 'Warning' })
        switch ($s.Patch) {
            'Installed' { Set-StatusIcon $ui.PatchIcon 'Success'; $ui.PatchText.Text = 'Installed' }
            default     { Set-StatusIcon $ui.PatchIcon 'Info';    $ui.PatchText.Text = 'Not installed' }
        }

        if ($s.Build -eq 'Global') {
            Show-InfoBar 'Compat' 'Error' 'This is the Global vivo Office Kit' `
                'It already supports English, but China-market phones cannot connect to it. Install the Chinese build (vivo办公套件) instead.'
        } elseif (-not $s.Version) {
            Show-InfoBar 'Compat' 'Warning' 'The version could not be read' `
                "This kit was tested with version $TestedVer. It will probably work, and Restore Chinese undoes it if it doesn't."
        } elseif (-not $tested) {
            Show-InfoBar 'Compat' 'Warning' "Version $($s.Version) has not been tested" `
                "This kit was tested with version $TestedVer. It will probably work, and Restore Chinese undoes it if it doesn't."
        } elseif ($s.Build -eq 'Unknown') {
            Show-InfoBar 'Compat' 'Warning' 'Build type could not be read' `
                'resources\build-config.json is missing, so the kit cannot tell whether this is the Chinese build.'
        }
    }
    Update-Buttons
}

function Update-Buttons {
    $s = $script:Status
    $canInstall = $s.Found -and $s.Build -ne 'Global' -and -not $script:Busy
    $canRestore = $s.Found -and $s.Patch -eq 'Installed' -and -not $script:Busy
    $ui.InstallButton.IsEnabled = $canInstall
    $ui.RestoreButton.IsEnabled = $canRestore
    # The Fluent standard button barely dims its content when disabled.
    foreach ($b in $ui.InstallButton, $ui.RestoreButton) { $b.Content.Opacity = if ($b.IsEnabled) { 1 } else { 0.45 } }
    $ui.RefreshButton.IsEnabled = -not $script:Busy
    $ui.LabelsCheck.IsEnabled   = $canInstall
    $ui.FolderButton.IsEnabled  = [bool]$s.Found
    $ui.InstallButtonText.Text  = if ($s.Patch -eq 'Installed') { 'Reinstall English Language Support' } else { 'Install English Language Support' }

    $note = @()
    if ($s.Found -and (Test-NeedsAdmin $s.Dir)) { $note += 'Windows will ask for administrator permission.' }
    if ($s.Running) { $note += 'vivo Office Kit is open: it will close while it is being changed and reopen afterwards.' }
    else { $note += 'vivo Office Kit opens automatically when it is done.' }
    $note += 'Run Install again after every vivo Office Kit update.'
    $ui.NoteText.Text = $note -join ' '
}

# --- running the patcher ---------------------------------------------------------------

$IsAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator)
$ui.AdminText.Text = if ($IsAdmin) { 'Running as administrator' } else { '' }

function Test-NeedsAdmin([string]$dir) {
    -not $IsAdmin -and ($dir.StartsWith($env:ProgramFiles, 'OrdinalIgnoreCase') -or
                        $dir.StartsWith(${env:ProgramFiles(x86)}, 'OrdinalIgnoreCase'))
}

function Get-PatcherParams {
    try { (Get-Command $Patcher -ErrorAction Stop).Parameters.Keys } catch { @() }
}

function Quote([string]$s) { "'" + $s.Replace("'", "''") + "'" }

# Builds the hidden command: runs the patcher in-process (already elevated, so it won't
# self-elevate again) and turns any exception into a log line plus exit code 3.
function New-PatcherCommand([bool]$restore) {
    $known = Get-PatcherParams
    $p = @("InstallDir=$(Quote $script:Status.Dir)", "ConfigDir=$(Quote $ConfigDir)")
    if ($restore) { $p += 'Restore=$true' }
    if (-not $restore -and -not $ui.LabelsCheck.IsChecked -and $known -contains 'NoLabelTranslation') { $p += 'NoLabelTranslation=$true' }
    if ($NoServiceControl) { $p += 'NoServiceControl=$true' }
    if ($NoLaunch) { $p += 'NoLaunch=$true' }
    $cmd = @"
`$p = @{ $($p -join '; ') }
try { & $(Quote $Patcher) @p; exit `$LASTEXITCODE }
catch {
    Add-Content -LiteralPath $(Quote $LogFile) -Encoding UTF8 -Value ('[{0:HH:mm:ss}] ERROR: {1}' -f (Get-Date), `$_.Exception.Message)
    exit 3
}
"@
    [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($cmd))
}

function Start-Patcher([bool]$restore) {
    if ($script:Busy) { return }
    Update-Status
    if (-not $script:Status.Found) { return }
    Hide-InfoBar 'Result'

    $exe = (Get-Process -Id $PID).Path
    $psi = New-Object System.Diagnostics.ProcessStartInfo $exe
    $psi.Arguments = '-NoProfile -NonInteractive -ExecutionPolicy Bypass -EncodedCommand ' + (New-PatcherCommand $restore)
    $needsAdmin = Test-NeedsAdmin $script:Status.Dir
    if ($needsAdmin) {
        $psi.UseShellExecute = $true
        $psi.Verb = 'runas'
        $psi.WindowStyle = 'Hidden'
    } else {
        $psi.UseShellExecute = $false
        $psi.CreateNoWindow = $true
    }

    $script:Run = @{
        Restore = $restore; Lines = New-Object System.Collections.Generic.List[string]
        LogPos = $(if (Test-Path $LogFile) { (Get-Item $LogFile).Length } else { 0 }); Partial = ''
        Started = Get-Date; Proc = $null
    }
    Set-Busy $true $(if ($needsAdmin) { 'Waiting for administrator permission...' } else { 'Starting...' }) `
        $(if ($needsAdmin) { 'Choose Yes in the Windows prompt to continue.' } else { '' })

    try {
        $script:Run.Proc = [System.Diagnostics.Process]::Start($psi)
    } catch {
        Set-Busy $false
        $code = $_.Exception.InnerException.NativeErrorCode
        if (-not $code) { $code = $_.Exception.NativeErrorCode }
        if ($code -eq 1223) {
            Show-InfoBar 'Result' 'Warning' 'Administrator permission was declined' 'Nothing was changed. Try again and choose Yes in the Windows prompt.'
        } else {
            Show-InfoBar 'Result' 'Error' 'Could not start the patcher' $_.Exception.Message
        }
        return
    }
    $ui.BusyTitle.Text = if ($restore) { 'Restoring Chinese...' } else { 'Installing English language support...' }
    $ui.BusyDetail.Text = 'Closing vivo Office Kit'
    $script:Timer.Start()
}

function Set-Busy([bool]$on, [string]$title, [string]$detail) {
    $script:Busy = $on
    $ui.BusyPanel.Visibility = if ($on) { 'Visible' } else { 'Collapsed' }
    if ($on) { $ui.BusyTitle.Text = $title; $ui.BusyDetail.Text = $detail }
    $win.Cursor = if ($on) { [System.Windows.Input.Cursors]::AppStarting } else { $null }
    Update-Buttons
}

function Read-NewLogLines {
    if (-not (Test-Path $LogFile)) { return }
    $fs = [IO.File]::Open($LogFile, 'Open', 'Read', 'ReadWrite')
    try {
        if ($fs.Length -lt $script:Run.LogPos) { $script:Run.LogPos = 0 }   # log was trimmed
        if ($fs.Length -eq $script:Run.LogPos) { return }
        $fs.Position = $script:Run.LogPos
        $buf = New-Object byte[] ($fs.Length - $script:Run.LogPos)
        $n = $fs.Read($buf, 0, $buf.Length)
        $script:Run.LogPos += $n
    } finally { $fs.Dispose() }
    $text = $script:Run.Partial + [Text.Encoding]::UTF8.GetString($buf, 0, $n).TrimStart([char]0xFEFF)
    $parts = $text -split "`r?`n"
    $script:Run.Partial = $parts[-1]
    if ($parts.Count -lt 2) { return }   # no complete line yet (0..-1 would count backwards)
    foreach ($l in $parts[0..($parts.Count - 2)]) {
        if ($l.Trim()) {
            $script:Run.Lines.Add($l)
            $ui.BusyDetail.Text = ($l -replace '^\[\d\d:\d\d:\d\d\]\s*', '').Trim()
        }
    }
}

function On-Tick {
    $run = $script:Run
    Read-NewLogLines
    $proc = $run.Proc
    $exited = $proc.HasExited
    if (-not $exited -and ((Get-Date) - $run.Started).TotalMinutes -lt $TimeoutMin) { return }

    $script:Timer.Stop()
    if (-not $exited) {
        Set-Busy $false
        Show-InfoBar 'Result' 'Warning' "Still running after $TimeoutMin minutes" `
            'The patcher has not finished. Check the log, and close vivo Office Kit if it is stuck.'
        Update-Status
        return
    }
    Start-Sleep -Milliseconds 150
    if ($run.Partial) { $run.Lines.Add($run.Partial); $run.Partial = '' }
    Read-NewLogLines
    Set-Busy $false
    Show-Result $proc.ExitCode
    $proc.Dispose()
    Update-Status
}

function Show-Result([int]$code) {
    $lines = $script:Run.Lines
    $has = { param($pat) [bool]($lines | Where-Object { $_ -match $pat }) }
    $msgOf = { param($pat) (($lines | Where-Object { $_ -match $pat } | Select-Object -First 1) -replace '^\[\d\d:\d\d:\d\d\]\s*', '') }

    switch ($code) {
        1 { Show-InfoBar 'Result' 'Error' 'vivo Office Kit was not found' 'Nothing was changed. Check that it is installed, then click Refresh.'; return }
        2 { Show-InfoBar 'Result' 'Error' 'Global build detected, nothing changed' 'This kit is for the Chinese vivo Office Kit (vivo办公套件). The Global build already has English.'; return }
        3 {
            $err = & $msgOf 'ERROR:'
            $err = ($err -replace '^ERROR:\s*', '')
            Show-InfoBar 'Result' 'Error' 'Something went wrong' "$err  Your original files are kept as a backup; Restore Chinese puts them back. Details are in the log."
            return
        }
        0 { }
        default { Show-InfoBar 'Result' 'Error' "The patcher stopped with code $code" 'See the log for details.'; return }
    }

    if ($script:Run.Restore) {
        if (-not (& $has 'Restore complete')) {
            Show-InfoBar 'Result' 'Error' 'Restore did not finish' 'See the log for details.'
        } elseif (& $has '^\[[\d:]+\]\s+Restored ') {
            Show-InfoBar 'Result' 'Success' 'Chinese restored' 'vivo Office Kit is back to its original files and will show Chinese again.'
        } else {
            Show-InfoBar 'Result' 'Warning' 'Nothing to restore' 'No backup from this kit was found, so no files were changed.'
        }
        return
    }

    if (-not (& $has 'Done\. To undo')) {
        Show-InfoBar 'Result' 'Error' 'Install did not finish' 'The patcher stopped early. See the log for details.'
    } elseif (& $has 'WARNING') {
        Show-InfoBar 'Result' 'Error' 'Installed, but English may not appear' ((& $msgOf 'WARNING') -replace '^WARNING:\s*', '')
    } elseif (& $has 'No language locks found') {
        Show-InfoBar 'Result' 'Warning' 'Nothing new to change' `
            'No Chinese language locks were found. English is probably installed already; if vivo Office Kit still shows Chinese, this version changed its code. Keep the log.'
    } else {
        $labels = & $msgOf 'Translated \d+ hard-coded'
        $msg = 'vivo Office Kit now shows English.'
        if ($labels) { $msg += " $labels" }
        Show-InfoBar 'Result' 'Success' 'English language support installed' $msg
    }
}

# --- wiring ----------------------------------------------------------------------------

$script:Timer = New-Object System.Windows.Threading.DispatcherTimer
$script:Timer.Interval = [TimeSpan]::FromMilliseconds(300)
$script:Timer.Add_Tick({ try { On-Tick } catch { $script:Timer.Stop(); Set-Busy $false; Show-InfoBar 'Result' 'Error' 'Lost track of the patcher' $_.Exception.Message } })

$ui.InstallButton.Add_Click({ Start-Patcher $false })
$ui.RestoreButton.Add_Click({ Start-Patcher $true })
$ui.RefreshButton.Add_Click({ Hide-InfoBar 'Result'; Update-Status })
$ui.CompatClose.Add_Click({ Hide-InfoBar 'Compat' })
$ui.ResultClose.Add_Click({ Hide-InfoBar 'Result' })
$ui.LogButton.Add_Click({
    if (Test-Path $LogFile) { Start-Process notepad.exe -ArgumentList ('"' + $LogFile + '"') }
    else { Show-InfoBar 'Result' 'Info' 'No log yet' 'The log is created the first time you install or restore.' }
})
$ui.FolderButton.Add_Click({ if ($script:Status.Dir) { Start-Process explorer.exe -ArgumentList ('"' + $script:Status.Dir + '"') } })
$win.Add_Activated({ if (-not $script:Busy) { Set-Theme; Update-Status } })
$win.Add_Closing({ param($s, $e)
    if ($script:Busy) {
        $r = [System.Windows.MessageBox]::Show($win, 'The patcher is still running. Close this window anyway? The patch keeps running in the background.',
            'vivo English Kit', 'YesNo', 'Warning')
        if ($r -ne 'Yes') { $e.Cancel = $true }
    }
})

if (-not (Test-Path $Patcher)) {
    [System.Windows.MessageBox]::Show("Add-VivoEnglish.ps1 was not found next to the gui folder:`n$KitDir", 'vivo English Kit', 'OK', 'Error') | Out-Null
    exit 1
}
if ((Get-PatcherParams) -notcontains 'NoLabelTranslation') { $ui.LabelsCheck.Visibility = 'Collapsed' }

Set-Theme
Update-Status
$null = $app.Run($win)
