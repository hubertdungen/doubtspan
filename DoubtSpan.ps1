param(
    [string]$Config = "",
    [switch]$DryRun,
    [switch]$NoLaunch,
    [switch]$Attach,
    [switch]$RestorePreferences,
    [switch]$RestoreDisplay,
    [switch]$LibraryOnly
)

$ErrorActionPreference = "Stop"

$isWindowsVariable = Get-Variable -Name IsWindows -ErrorAction SilentlyContinue
$runningOnWindows = if ($isWindowsVariable) { [bool]$isWindowsVariable.Value } else { [Environment]::OSVersion.Platform -eq [System.PlatformID]::Win32NT }
if (-not $runningOnWindows) { throw "DoubtSpan.ps1 must run on Windows." }

if ([string]::IsNullOrWhiteSpace($Config)) { $Config = Join-Path $PSScriptRoot "DoubtSpan.ini" }
$LogRoot = Join-Path $PSScriptRoot "logs"
New-Item -ItemType Directory -Force -Path $LogRoot | Out-Null
$LogPath = Join-Path $LogRoot ("DoubtSpan-{0}.log" -f (Get-Date -Format "yyyyMMdd-HHmmss"))
$DisplayStatePath = Join-Path $LogRoot "display-restore-state.json"
$PreferenceStatePath = Join-Path $LogRoot "preferences-restore-state.json"

function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $line = "[{0}] [{1}] {2}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $Level, $Message
    Write-Host $line
    Add-Content -LiteralPath $LogPath -Value $line
}

function Read-IniFile {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { throw "Configuration file not found: $Path" }
    $data = @{ default = @{} }; $section = "default"
    foreach ($raw in Get-Content -LiteralPath $Path) {
        $line = $raw.Trim()
        if (-not $line -or $line.StartsWith(";") -or $line.StartsWith("#")) { continue }
        if ($line -match '^\[(.+)\]$') { $section = $matches[1].Trim(); if (-not $data.ContainsKey($section)) { $data[$section] = @{} }; continue }
        $index = $line.IndexOf("="); if ($index -lt 1) { continue }
        $data[$section][$line.Substring(0, $index).Trim()] = $line.Substring($index + 1).Trim()
    }
    return $data
}

function Get-IniValue {
    param([hashtable]$Ini, [string]$Section, [string]$Key, [string]$Default)
    if ($Ini.ContainsKey($Section) -and $Ini[$Section].ContainsKey($Key)) { return [string]$Ini[$Section][$Key] }
    return $Default
}

function Get-IniInt {
    param([hashtable]$Ini, [string]$Section, [string]$Key, [int]$Default)
    $parsed = 0; $value = Get-IniValue $Ini $Section $Key ([string]$Default)
    if ([int]::TryParse($value, [ref]$parsed)) { return $parsed }
    return $Default
}

function Get-IniBool {
    param([hashtable]$Ini, [string]$Section, [string]$Key, [bool]$Default)
    switch ((Get-IniValue $Ini $Section $Key ([string]$Default)).Trim().ToLowerInvariant()) {
        { $_ -in @("1", "true", "yes", "on") } { return $true }
        { $_ -in @("0", "false", "no", "off") } { return $false }
        default { return $Default }
    }
}

if (-not ("DoubtSpan.Native" -as [type])) {
    Add-Type -TypeDefinition @"
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;

namespace DoubtSpan {
    public class DisplayModeInfo {
        public string Device; public int X; public int Y; public int Width; public int Height;
        public int Frequency; public int BitsPerPixel; public int Orientation;
    }
    public class MonitorScaleInfo {
        public int X; public int Y; public int Width; public int Height; public int Scale;
    }
    public static class Native {
        [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
        [StructLayout(LayoutKind.Sequential, CharSet=CharSet.Unicode)] public struct DEVMODE {
            [MarshalAs(UnmanagedType.ByValTStr, SizeConst=32)] public string dmDeviceName;
            public short dmSpecVersion, dmDriverVersion, dmSize, dmDriverExtra; public int dmFields;
            public int dmPositionX, dmPositionY, dmDisplayOrientation, dmDisplayFixedOutput;
            public short dmColor, dmDuplex, dmYResolution, dmTTOption, dmCollate;
            [MarshalAs(UnmanagedType.ByValTStr, SizeConst=32)] public string dmFormName;
            public short dmLogPixels; public int dmBitsPerPel, dmPelsWidth, dmPelsHeight;
            public int dmDisplayFlags, dmDisplayFrequency, dmICMMethod, dmICMIntent, dmMediaType;
            public int dmDitherType, dmReserved1, dmReserved2, dmPanningWidth, dmPanningHeight;
        }
        private delegate bool MonitorEnumProc(IntPtr monitor, IntPtr hdc, ref RECT rect, IntPtr data);
        [DllImport("user32.dll")] private static extern bool EnumDisplayMonitors(IntPtr hdc, IntPtr clip, MonitorEnumProc callback, IntPtr data);
        [DllImport("shcore.dll")] private static extern int GetScaleFactorForMonitor(IntPtr monitor, out int scale);
        [DllImport("user32.dll", CharSet=CharSet.Unicode)] private static extern bool EnumDisplaySettingsEx(string device, int mode, ref DEVMODE dm, int flags);
        [DllImport("user32.dll", CharSet=CharSet.Unicode)] private static extern int ChangeDisplaySettingsEx(string device, ref DEVMODE dm, IntPtr hwnd, int flags, IntPtr param);
        [DllImport("user32.dll", CharSet=CharSet.Unicode)] private static extern int ChangeDisplaySettingsEx(string device, IntPtr dm, IntPtr hwnd, int flags, IntPtr param);
        [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
        [DllImport("user32.dll", SetLastError=true)] public static extern bool SetProcessDpiAwarenessContext(IntPtr value);
        [DllImport("user32.dll")] public static extern bool IsWindow(IntPtr hwnd);
        [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hwnd, int command);
        [DllImport("user32.dll", SetLastError=true)] public static extern bool GetWindowRect(IntPtr hwnd, out RECT rect);
        [DllImport("user32.dll", SetLastError=true)] public static extern bool SetWindowPos(IntPtr hwnd, IntPtr after, int x, int y, int width, int height, uint flags);
        [DllImport("user32.dll", SetLastError=true)] public static extern int GetWindowLong(IntPtr hwnd, int index);
        [DllImport("user32.dll", SetLastError=true)] public static extern int SetWindowLong(IntPtr hwnd, int index, int value);
        [DllImport("user32.dll", SetLastError=true)] public static extern bool GetClipCursor(out RECT rect);
        [DllImport("user32.dll", SetLastError=true)] public static extern bool ClipCursor(ref RECT rect);
        [DllImport("user32.dll", EntryPoint="ClipCursor", SetLastError=true)] public static extern bool ReleaseCursor(IntPtr rect);

        private static DEVMODE EmptyMode() { DEVMODE d = new DEVMODE(); d.dmSize = (short)Marshal.SizeOf(typeof(DEVMODE)); return d; }
        private static DisplayModeInfo Info(string device, DEVMODE d) { return new DisplayModeInfo { Device=device, X=d.dmPositionX, Y=d.dmPositionY, Width=d.dmPelsWidth, Height=d.dmPelsHeight, Frequency=d.dmDisplayFrequency, BitsPerPixel=d.dmBitsPerPel, Orientation=d.dmDisplayOrientation }; }
        public static DisplayModeInfo CurrentMode(string device) { DEVMODE d=EmptyMode(); if(!EnumDisplaySettingsEx(device,-1,ref d,0)) throw new InvalidOperationException("Cannot read display mode for " + device); return Info(device,d); }
        public static DisplayModeInfo[] Modes(string device) { var list=new List<DisplayModeInfo>(); for(int i=0;;i++){ DEVMODE d=EmptyMode(); if(!EnumDisplaySettingsEx(device,i,ref d,0)) break; list.Add(Info(device,d)); } return list.ToArray(); }
        public static int StageMode(string device, int width, int height, int frequency, int x, int y) {
            DEVMODE chosen=EmptyMode(); bool found=false;
            for(int i=0;;i++){ DEVMODE d=EmptyMode(); if(!EnumDisplaySettingsEx(device,i,ref d,0)) break; if(d.dmPelsWidth==width && d.dmPelsHeight==height && (frequency<=0 || d.dmDisplayFrequency==frequency)){ chosen=d; found=true; break; } }
            if(!found) return -2;
            chosen.dmPositionX=x; chosen.dmPositionY=y; chosen.dmFields |= 0x00000020 | 0x00080000 | 0x00100000 | 0x00400000;
            return ChangeDisplaySettingsEx(device,ref chosen,IntPtr.Zero,0x10000001,IntPtr.Zero);
        }
        public static int CommitModes() { return ChangeDisplaySettingsEx(null,IntPtr.Zero,IntPtr.Zero,0,IntPtr.Zero); }
        public static MonitorScaleInfo[] MonitorScales() {
            var list=new List<MonitorScaleInfo>(); MonitorEnumProc cb=delegate(IntPtr m,IntPtr h,ref RECT r,IntPtr d){int scale=100; try{GetScaleFactorForMonitor(m,out scale);}catch{} list.Add(new MonitorScaleInfo{X=r.Left,Y=r.Top,Width=r.Right-r.Left,Height=r.Bottom-r.Top,Scale=scale}); return true;};
            EnumDisplayMonitors(IntPtr.Zero,IntPtr.Zero,cb,IntPtr.Zero); return list.ToArray();
        }
    }
}
"@
}

Add-Type -AssemblyName System.Windows.Forms
if (-not [DoubtSpan.Native]::SetProcessDpiAwarenessContext([IntPtr](-4))) {
    [void][DoubtSpan.Native]::SetProcessDPIAware()
}

function Get-ScreenSnapshot {
    $screens = foreach ($screen in [System.Windows.Forms.Screen]::AllScreens) {
        $mode = [DoubtSpan.Native]::CurrentMode($screen.DeviceName)
        [pscustomobject]@{ Device=$screen.DeviceName; Primary=$screen.Primary; X=$screen.Bounds.X; Y=$screen.Bounds.Y; Width=$screen.Bounds.Width; Height=$screen.Bounds.Height; Frequency=$mode.Frequency; BitsPerPixel=$mode.BitsPerPixel; Orientation=$mode.Orientation }
    }
    return @($screens)
}

function Get-PrimaryRow {
    param([object[]]$Screens, [hashtable]$Ini)
    $primary = $Screens | Where-Object Primary | Select-Object -First 1
    if (-not $primary) { throw "Windows did not report a primary monitor." }
    $row = @($Screens | Where-Object { $_.Y -lt ($primary.Y + $primary.Height) -and ($_.Y + $_.Height) -gt $primary.Y } | Sort-Object X)
    $required = Get-IniInt $Ini "Layout" "RequiredMonitors" 3
    if ($required -gt 0 -and $row.Count -ne $required) { throw "Expected $required monitors in the primary row, detected $($row.Count)." }
    if ((Get-IniBool $Ini "Layout" "RequirePrimaryInMiddle" $true) -and $row.Count -eq 3 -and -not $row[1].Primary) { throw "The primary monitor must be the centre display in the three-monitor row." }
    return $row
}

function Write-ScreenLog {
    param([object[]]$Screens)
    Write-Log ("Detected {0} active screen(s)." -f $Screens.Count)
    foreach ($s in $Screens) { Write-Log ("Screen {0}: primary={1} x={2} y={3} {4}x{5} {6}Hz" -f $s.Device,$s.Primary,$s.X,$s.Y,$s.Width,$s.Height,$s.Frequency) }
}

function Test-MonitorScale {
    param([object[]]$Row, [hashtable]$Ini)
    if (-not (Get-IniBool $Ini "Display" "Require100PercentScale" $true)) { return }
    foreach ($scale in [DoubtSpan.Native]::MonitorScales()) {
        foreach ($s in $Row) {
            if ($scale.X -eq $s.X -and $scale.Y -eq $s.Y -and $scale.Width -eq $s.Width -and $scale.Height -eq $s.Height -and $scale.Scale -ne 100) {
                throw "Display $($s.Device) uses $($scale.Scale)% Windows scaling. Set every target display to 100% to avoid an enlarged or cropped game window."
            }
        }
    }
}

function Get-DisplayPlan {
    param([object[]]$Row, [hashtable]$Ini)
    $primary = $Row | Where-Object Primary | Select-Object -First 1
    $autoPromote = Get-IniBool $Ini "Display" "AutoPromoteToPrimary" $true
    $plans = @()
    foreach ($s in $Row) {
        $width=$s.Width; $height=$s.Height; $frequency=$s.Frequency
        if (($s.Width -ne $primary.Width -or $s.Height -ne $primary.Height) -and $autoPromote) {
            $matches = @([DoubtSpan.Native]::Modes($s.Device) | Where-Object { $_.Width -eq $primary.Width -and $_.Height -eq $primary.Height })
            if ($matches.Count -eq 0) {
                throw ("{0} is {1}x{2} and does not expose {3}x{4}. Enable the NVIDIA DSR/DLDSR mode for this side display first; this wrapper does not invent unsupported driver modes." -f $s.Device,$s.Width,$s.Height,$primary.Width,$primary.Height)
            }
            $preferred = $matches | Where-Object Frequency -eq $s.Frequency | Select-Object -First 1
            if (-not $preferred) { $preferred = $matches | Sort-Object Frequency -Descending | Select-Object -First 1 }
            $width=$preferred.Width; $height=$preferred.Height; $frequency=$preferred.Frequency
        }
        $plans += [pscustomobject]@{ Device=$s.Device; Primary=$s.Primary; OldX=$s.X; OldY=$s.Y; OldWidth=$s.Width; OldHeight=$s.Height; OldFrequency=$s.Frequency; X=0; Y=$primary.Y; Width=$width; Height=$height; Frequency=$frequency }
    }
    $primaryIndex = 0; for ($i=0; $i -lt $plans.Count; $i++) { if ($plans[$i].Primary) { $primaryIndex=$i; break } }
    $plans[$primaryIndex].X = $primary.X
    $cursor = $primary.X
    for ($i=$primaryIndex-1; $i -ge 0; $i--) { $cursor -= $plans[$i].Width; $plans[$i].X=$cursor }
    $cursor = $primary.X + $plans[$primaryIndex].Width
    for ($i=$primaryIndex+1; $i -lt $plans.Count; $i++) { $plans[$i].X=$cursor; $cursor += $plans[$i].Width }
    if (Get-IniBool $Ini "Layout" "RequireEqualHeight" $true) {
        foreach ($p in $plans) { if ($p.Height -ne $primary.Height) { throw "Target display heights are not equal." } }
    }
    return $plans
}

function Get-TargetFromPlan {
    param([object[]]$Plan)
    $left=($Plan|Measure-Object X -Minimum).Minimum; $top=($Plan|Measure-Object Y -Minimum).Minimum
    $right=($Plan|ForEach-Object {$_.X+$_.Width}|Measure-Object -Maximum).Maximum; $bottom=($Plan|ForEach-Object {$_.Y+$_.Height}|Measure-Object -Maximum).Maximum
    return [pscustomobject]@{ X=[int]$left; Y=[int]$top; Width=[int]($right-$left); Height=[int]($bottom-$top) }
}

function Save-DisplayState {
    param([object[]]$Plan)
    $state = @($Plan | ForEach-Object { [pscustomobject]@{Device=$_.Device;X=$_.OldX;Y=$_.OldY;Width=$_.OldWidth;Height=$_.OldHeight;Frequency=$_.OldFrequency} })
    $temp="$DisplayStatePath.tmp"; $state | ConvertTo-Json | Set-Content -LiteralPath $temp -Encoding UTF8; Move-Item -LiteralPath $temp -Destination $DisplayStatePath -Force
}

function Apply-DisplayPlan {
    param([object[]]$Plan)
    foreach ($p in $Plan) {
        $result=[DoubtSpan.Native]::StageMode($p.Device,$p.Width,$p.Height,$p.Frequency,$p.X,$p.Y)
        if ($result -ne 0) { throw "Windows rejected the staged mode for $($p.Device) with result $result." }
    }
    $result=[DoubtSpan.Native]::CommitModes(); if ($result -ne 0) { throw "Windows rejected the display layout with result $result." }
}

function Restore-DisplayState {
    if (-not (Test-Path -LiteralPath $DisplayStatePath)) { throw "No saved display state was found at $DisplayStatePath" }
    $parsed=Get-Content -Raw -LiteralPath $DisplayStatePath | ConvertFrom-Json
    $state=@($parsed | ForEach-Object { $_ })
    foreach ($s in $state) {
        $result=[DoubtSpan.Native]::StageMode([string]$s.Device,[int]$s.Width,[int]$s.Height,[int]$s.Frequency,[int]$s.X,[int]$s.Y)
        if ($result -ne 0) { throw "Windows rejected the restore mode for $($s.Device) with result $result." }
    }
    $result=[DoubtSpan.Native]::CommitModes(); if ($result -ne 0) { throw "Windows rejected the restored display layout with result $result." }
    Remove-Item -LiteralPath $DisplayStatePath -Force
    Write-Log "Restored the saved Windows display layout."
}

function Find-GameRoot {
    param([hashtable]$Ini)
    $configured=Get-IniValue $Ini "Game" "InstallRoot" ""
    $executable=Get-IniValue $Ini "Game" "Executable" "Shadows of Doubt.exe"
    $programFilesX86=[Environment]::GetEnvironmentVariable("ProgramFiles(x86)")
    $candidates=@(
        $configured,
        $(if ($programFilesX86) { Join-Path $programFilesX86 "Steam\steamapps\common\Shadows of Doubt" }),
        $(if ($env:ProgramFiles) { Join-Path $env:ProgramFiles "Steam\steamapps\common\Shadows of Doubt" }),
        "D:\SteamLibrary\steamapps\common\Shadows of Doubt",
        "E:\SteamLibrary\steamapps\common\Shadows of Doubt",
        "F:\SteamLibrary\steamapps\common\Shadows of Doubt"
    ) | Where-Object { $_ }
    foreach ($candidate in $candidates) { if (Test-Path -LiteralPath (Join-Path $candidate $executable)) { return (Resolve-Path -LiteralPath $candidate).Path } }
    throw "Shadows of Doubt was not found. Set Game.InstallRoot in DoubtSpan.ini."
}

function Find-SteamExecutable {
    $programFilesX86=[Environment]::GetEnvironmentVariable("ProgramFiles(x86)")
    $registryPaths=@(
        "HKCU:\Software\Valve\Steam",
        "HKLM:\Software\WOW6432Node\Valve\Steam",
        "HKLM:\Software\Valve\Steam"
    )
    $candidates=New-Object "System.Collections.Generic.List[String]"
    foreach ($registryPath in $registryPaths) {
        if (Test-Path $registryPath) {
            $properties=Get-ItemProperty $registryPath
            foreach ($propertyName in @("SteamExe","InstallPath")) {
                $value=[string]$properties.$propertyName
                if ($value) {
                    if ([IO.Path]::GetExtension($value) -ieq ".exe") { $candidates.Add($value.Replace("/","\")) }
                    else { $candidates.Add((Join-Path $value "steam.exe")) }
                }
            }
        }
    }
    if ($programFilesX86) { $candidates.Add((Join-Path $programFilesX86 "Steam\steam.exe")) }
    if ($env:ProgramFiles) { $candidates.Add((Join-Path $env:ProgramFiles "Steam\steam.exe")) }
    foreach ($candidate in $candidates) { if (Test-Path -LiteralPath $candidate) { return (Resolve-Path -LiteralPath $candidate).Path } }
    throw "Steam.exe was not found. Start the game manually with -NoLaunch, or repair the Steam installation."
}

function Get-PreferenceDefinitions {
    param([object]$Target, [hashtable]$Ini)
    $mode=Get-IniInt $Ini "Preferences" "WindowedMode" 3
    $useNative=if (Get-IniBool $Ini "Preferences" "UseNativeResolution" $false) { 1 } else { 0 }
    return @(
        [pscustomobject]@{Name="width_h191264035";Value=[int]$Target.Width},
        [pscustomobject]@{Name="height_h1581003770";Value=[int]$Target.Height},
        [pscustomobject]@{Name="fullscreen_h1476830426";Value=[int]$mode},
        [pscustomobject]@{Name="Screenmanager Fullscreen mode_h3630240806";Value=[int]$mode},
        [pscustomobject]@{Name="Screenmanager Resolution Width_h182942802";Value=[int]$Target.Width},
        [pscustomobject]@{Name="Screenmanager Resolution Height_h2627697771";Value=[int]$Target.Height},
        [pscustomobject]@{Name="Screenmanager Resolution Window Width_h2524650974";Value=[int]$Target.Width},
        [pscustomobject]@{Name="Screenmanager Resolution Window Height_h1684712807";Value=[int]$Target.Height},
        [pscustomobject]@{Name="Screenmanager Resolution Use Native_h1405027254";Value=[int]$useNative},
        [pscustomobject]@{Name="Screenmanager Window Position X_h4088080503";Value=[int]$Target.X},
        [pscustomobject]@{Name="Screenmanager Window Position Y_h4088080502";Value=[int]$Target.Y}
    )
}

function Open-PreferenceKey {
    param([hashtable]$Ini, [bool]$Writable)
    $path=Get-IniValue $Ini "Preferences" "RegistryPath" "Software\ColePowered Games\Shadows of Doubt"
    $key=[Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($path,$Writable)
    if (-not $key) { throw "Shadows of Doubt preferences were not found at HKCU\$path. Run the game once normally first." }
    return $key
}

function Save-PreferenceState {
    param([object[]]$Definitions, [hashtable]$Ini)
    $key=Open-PreferenceKey $Ini $false
    try {
        $names=@($key.GetValueNames())
        $state=@($Definitions | ForEach-Object {
            $exists=$names -contains $_.Name
            [pscustomobject]@{Name=$_.Name;Exists=$exists;Value=$(if($exists){[int]$key.GetValue($_.Name)}else{0})}
        })
    } finally { $key.Dispose() }
    $temp="$PreferenceStatePath.tmp"; $state | ConvertTo-Json | Set-Content -LiteralPath $temp -Encoding UTF8; Move-Item -LiteralPath $temp -Destination $PreferenceStatePath -Force
}

function Set-GamePreferences {
    param([object]$Target, [hashtable]$Ini)
    $definitions=Get-PreferenceDefinitions $Target $Ini
    if ((Get-IniBool $Ini "Preferences" "Backup" $true) -and -not (Test-Path -LiteralPath $PreferenceStatePath)) { Save-PreferenceState $definitions $Ini }
    $key=Open-PreferenceKey $Ini $true
    try {
        foreach ($item in $definitions) { $key.SetValue($item.Name,[int]$item.Value,[Microsoft.Win32.RegistryValueKind]::DWord) }
    } finally { $key.Dispose() }
    Write-Log ("Prepared Shadows of Doubt PlayerPrefs for Windowed {0}x{1} at x={2}, y={3}." -f $Target.Width,$Target.Height,$Target.X,$Target.Y)
}

function Restore-PreferenceState {
    param([hashtable]$Ini)
    if (-not (Test-Path -LiteralPath $PreferenceStatePath)) { throw "No saved preference state was found at $PreferenceStatePath" }
    $parsed=Get-Content -Raw -LiteralPath $PreferenceStatePath | ConvertFrom-Json
    $state=@($parsed | ForEach-Object { $_ })
    $key=Open-PreferenceKey $Ini $true
    try {
        foreach ($item in $state) {
            if ([bool]$item.Exists) { $key.SetValue([string]$item.Name,[int]$item.Value,[Microsoft.Win32.RegistryValueKind]::DWord) }
            else { $key.DeleteValue([string]$item.Name,$false) }
        }
    } finally { $key.Dispose() }
    Remove-Item -LiteralPath $PreferenceStatePath -Force
    Write-Log "Restored the saved Shadows of Doubt display preferences."
}

function Get-GameWindow {
    param([string]$Name,[int]$WaitSeconds)
    if ($Name.EndsWith(".exe",[StringComparison]::OrdinalIgnoreCase)) { $Name=$Name.Substring(0,$Name.Length-4) }
    $deadline=(Get-Date).AddSeconds($WaitSeconds)
    while ((Get-Date) -lt $deadline) {
        foreach ($process in [Diagnostics.Process]::GetProcessesByName($Name)) { try { $process.Refresh(); if ($process.MainWindowHandle -ne [IntPtr]::Zero) { return $process } } catch {} }
        Start-Sleep -Milliseconds 500
    }
    throw "No visible $Name window appeared within $WaitSeconds seconds."
}

function Get-WindowRectangle {
    param([IntPtr]$Handle)
    if ($Handle -eq [IntPtr]::Zero -or -not [DoubtSpan.Native]::IsWindow($Handle)) { return $null }
    $rect=New-Object DoubtSpan.Native+RECT
    if (-not [DoubtSpan.Native]::GetWindowRect($Handle,[ref]$rect)) { return $null }
    return [pscustomobject]@{X=$rect.Left;Y=$rect.Top;Width=$rect.Right-$rect.Left;Height=$rect.Bottom-$rect.Top}
}

function Test-RectangleClose {
    param([object]$Actual,[object]$Target,[int]$Tolerance)
    return $Actual -and [Math]::Abs($Actual.X-$Target.X) -le $Tolerance -and [Math]::Abs($Actual.Y-$Target.Y) -le $Tolerance -and [Math]::Abs($Actual.Width-$Target.Width) -le $Tolerance -and [Math]::Abs($Actual.Height-$Target.Height) -le $Tolerance
}

function Get-CursorClipRectangle {
    $rect=New-Object DoubtSpan.Native+RECT
    if (-not [DoubtSpan.Native]::GetClipCursor([ref]$rect)) { return $null }
    return [pscustomobject]@{X=$rect.Left;Y=$rect.Top;Width=$rect.Right-$rect.Left;Height=$rect.Bottom-$rect.Top}
}

function Set-CursorClipRectangle {
    param([object]$Target)
    $rect=New-Object DoubtSpan.Native+RECT
    $rect.Left=[int]$Target.X; $rect.Top=[int]$Target.Y; $rect.Right=[int]($Target.X+$Target.Width); $rect.Bottom=[int]($Target.Y+$Target.Height)
    if (-not [DoubtSpan.Native]::ClipCursor([ref]$rect)) { throw "ClipCursor failed while applying the target rectangle." }
}

function Set-GameWindow {
    param([IntPtr]$Handle,[object]$Target,[bool]$RemoveBorders)
    if ($RemoveBorders) {
        $style=[DoubtSpan.Native]::GetWindowLong($Handle,-16)
        $removeStyle=0x00C00000 -bor 0x00040000 -bor 0x00020000 -bor 0x00010000 -bor 0x00080000
        [void][DoubtSpan.Native]::SetWindowLong($Handle,-16,($style -band (-bnot $removeStyle)))
        $exStyle=[DoubtSpan.Native]::GetWindowLong($Handle,-20)
        $removeExStyle=0x00000001 -bor 0x00000200 -bor 0x00020000
        [void][DoubtSpan.Native]::SetWindowLong($Handle,-20,($exStyle -band (-bnot $removeExStyle)))
    }
    [void][DoubtSpan.Native]::ShowWindow($Handle,9)
    $flags=0x0004 -bor 0x0010 -bor 0x0020 -bor 0x0040 -bor 0x0200
    if (-not [DoubtSpan.Native]::SetWindowPos($Handle,[IntPtr]::Zero,$Target.X,$Target.Y,$Target.Width,$Target.Height,[uint32]$flags)) { throw "SetWindowPos failed with Win32 error $([Runtime.InteropServices.Marshal]::GetLastWin32Error())." }
}

function Maintain-GameWindow {
    param([Diagnostics.Process]$Process,[object]$Target,[hashtable]$Ini)
    $interval=Get-IniInt $Ini "Window" "IntervalMilliseconds" 750
    $tolerance=Get-IniInt $Ini "Window" "TolerancePixels" 2
    $maxConsecutive=Get-IniInt $Ini "Window" "MaxConsecutiveCorrections" 12
    $remove=Get-IniBool $Ini "Window" "RemoveBorders" $true
    $repairCursor=Get-IniBool $Ini "Window" "RepairCursorClip" $true
    $handle=[IntPtr]::Zero; $consecutive=0; $corrections=0; $missingLogged=$false
    while ($true) {
        try { $Process.Refresh(); if ($Process.HasExited) { break } } catch { break }
        $current=$Process.MainWindowHandle
        if ($current -eq [IntPtr]::Zero -or -not [DoubtSpan.Native]::IsWindow($current)) {
            if (-not $missingLogged) { Write-Log "The game temporarily has no visible main window; waiting for recreation." "WARN"; $missingLogged=$true }
            Start-Sleep -Milliseconds $interval; continue
        }
        if ($current -ne $handle) {
            if ($handle -ne [IntPtr]::Zero) { Write-Log ("The game recreated its window: old handle={0}, new handle={1}." -f $handle,$current) "WARN" }
            $handle=$current; $missingLogged=$false; $consecutive=0
        }
        $actual=Get-WindowRectangle $handle
        if (-not (Test-RectangleClose $actual $Target $tolerance)) {
            $consecutive++; $corrections++
            if ($consecutive -gt $maxConsecutive) { throw "Shadows of Doubt kept changing its window after $maxConsecutive consecutive corrections." }
            Set-GameWindow $handle $Target $remove
            Write-Log ("Applied x={0} y={1} {2}x{3}; previous x={4} y={5} {6}x{7}; correction {8}." -f $Target.X,$Target.Y,$Target.Width,$Target.Height,$actual.X,$actual.Y,$actual.Width,$actual.Height,$corrections)
        } else { $consecutive=0 }
        if ($repairCursor) {
            $clip=Get-CursorClipRectangle
            if ($clip -and -not (Test-RectangleClose $clip $Target $tolerance)) { Set-CursorClipRectangle $Target }
        }
        Start-Sleep -Milliseconds $interval
    }
    Write-Log ("Shadows of Doubt exited after {0} window correction(s)." -f $corrections)
}

if ($LibraryOnly) { return }

$ini=Read-IniFile $Config
Write-Log "DoubtSpan started."
Write-Log "Safety boundary: external PlayerPrefs, display modes, and top-level window APIs only; no DLL injection, game-memory access, renderer hook, or executable modification."

if ($RestoreDisplay) { Restore-DisplayState; exit 0 }
if ($RestorePreferences) { Restore-PreferenceState $ini; exit 0 }

$gameRoot=Find-GameRoot $ini
$screens=Get-ScreenSnapshot; Write-ScreenLog $screens; $row=Get-PrimaryRow $screens $ini; Test-MonitorScale $row $ini
$plan=Get-DisplayPlan $row $ini; $target=Get-TargetFromPlan $plan
foreach ($p in $plan) { Write-Log ("Plan {0}: {1}x{2}@{3} -> x={4} y={5} {6}x{7}@{8}" -f $p.Device,$p.OldWidth,$p.OldHeight,$p.OldFrequency,$p.X,$p.Y,$p.Width,$p.Height,$p.Frequency) }
Write-Log ("Target: x={0} y={1} width={2} height={3}." -f $target.X,$target.Y,$target.Width,$target.Height)

$needsDisplayChange=@($plan | Where-Object { $_.OldX-ne$_.X -or $_.OldY-ne$_.Y -or $_.OldWidth-ne$_.Width -or $_.OldHeight-ne$_.Height -or $_.OldFrequency-ne$_.Frequency }).Count -gt 0
if ($DryRun) { Write-Log "Dry run complete: no display, preferences, process, cursor, or window changes were made."; exit 0 }

$processName=Get-IniValue $ini "Game" "ProcessName" "Shadows of Doubt"
$existing=@([Diagnostics.Process]::GetProcessesByName($processName))
if ($Attach) {
    if ($needsDisplayChange) { throw "Attach mode will not change display modes while the game is running. Put all three displays at the same effective resolution first." }
    Write-Log "Attach mode: preferences, display modes, and launcher will not be changed."
    $game=Get-GameWindow $processName (Get-IniInt $ini "Window" "WaitSeconds" 240)
    Write-Log ("Found existing {0}.exe pid={1}." -f $game.ProcessName,$game.Id)
    Maintain-GameWindow $game $target $ini
    [void][DoubtSpan.Native]::ReleaseCursor([IntPtr]::Zero)
    exit 0
}

if ($existing.Count -gt 0 -and (Get-IniBool $ini "Game" "RequireClosedBeforePrepare" $true)) { throw "Close Shadows of Doubt before running the wrapper so the wide render resolution is applied at startup." }
if ($needsDisplayChange -and (Test-Path -LiteralPath $DisplayStatePath)) { throw "A previous display restore state already exists. Run with -RestoreDisplay before continuing." }
if (Test-Path -LiteralPath $PreferenceStatePath) { throw "A previous preference restore state already exists. Run with -RestorePreferences before continuing." }

$displayChanged=$false; $preferencesChanged=$false; $game=$null
try {
    if ($needsDisplayChange) { Save-DisplayState $plan; Apply-DisplayPlan $plan; $displayChanged=$true; Write-Log "Applied the temporary equal-resolution display row." }
    Set-GamePreferences $target $ini; $preferencesChanged=$true
    if (-not $NoLaunch -and (Get-IniBool $ini "Game" "AutoLaunch" $true)) {
        $executable=Join-Path $gameRoot (Get-IniValue $ini "Game" "Executable" "Shadows of Doubt.exe")
        $arguments=(Get-IniValue $ini "Launch" "Arguments" "-screen-fullscreen 0 -window-mode borderless -popupwindow") + (" -screen-width {0} -screen-height {1}" -f $target.Width,$target.Height)
        $appId=Get-IniInt $ini "Game" "SteamAppId" 986130
        if (Get-IniBool $ini "Game" "LaunchViaSteam" $false) {
            $steam=Find-SteamExecutable
            Start-Process -FilePath $steam -ArgumentList ("-applaunch {0} {1}" -f $appId,$arguments) | Out-Null
            Write-Log ("Asked the installed Steam client to launch app {0} with the Unity window arguments." -f $appId)
        } else {
            $oldSteamAppId=$env:SteamAppId; $oldSteamGameId=$env:SteamGameId
            try {
                $env:SteamAppId=[string]$appId; $env:SteamGameId=[string]$appId
                Start-Process -FilePath $executable -WorkingDirectory $gameRoot -ArgumentList $arguments | Out-Null
            } finally {
                if ($null -eq $oldSteamAppId) { Remove-Item Env:\SteamAppId -ErrorAction SilentlyContinue } else { $env:SteamAppId=$oldSteamAppId }
                if ($null -eq $oldSteamGameId) { Remove-Item Env:\SteamGameId -ErrorAction SilentlyContinue } else { $env:SteamGameId=$oldSteamGameId }
            }
            Write-Log ("Started the installed executable with Steam app identity {0} and Unity window arguments." -f $appId)
        }
    } else { Write-Log "Launch Shadows of Doubt now; waiting for its window." }
    $game=Get-GameWindow $processName (Get-IniInt $ini "Window" "WaitSeconds" 240)
    Write-Log ("Found {0}.exe pid={1}." -f $game.ProcessName,$game.Id)
    Maintain-GameWindow $game $target $ini
} finally {
    [void][DoubtSpan.Native]::ReleaseCursor([IntPtr]::Zero)
    if ($game) { try { $game.Refresh(); if (-not $game.HasExited) { Write-Log "Waiting for Shadows of Doubt to close before restoring the desktop." "WARN"; $game.WaitForExit() } } catch {} }
    if ($preferencesChanged -and (Get-IniBool $ini "Preferences" "RestoreAfterGame" $true)) {
        try { Restore-PreferenceState $ini } catch { Write-Log ("Automatic preference restore failed: {0}. Run with -RestorePreferences." -f $_.Exception.Message) "ERROR" }
    }
    if ($displayChanged -and (Get-IniBool $ini "Display" "RestoreAfterGame" $true)) {
        try { Restore-DisplayState } catch { Write-Log ("Automatic display restore failed: {0}. Run with -RestoreDisplay." -f $_.Exception.Message) "ERROR" }
    }
}
Write-Log "Done. Log: $LogPath"
