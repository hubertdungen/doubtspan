$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
$script = Join-Path $root "DoubtSpan.ps1"
$source = Get-Content -Raw -LiteralPath $script

foreach ($required in @(
    "AutoPromoteToPrimary",
    "display-restore-state.json",
    "preferences-restore-state.json",
    "Get-PreferenceDefinitions",
    "MaxConsecutiveCorrections",
    "no DLL injection, game-memory access, renderer hook, or executable modification",
    "Attach mode: preferences, display modes, and launcher will not be changed",
    "Require100PercentScale"
)) {
    if (-not $source.Contains($required)) { throw "Missing safety or recovery feature: $required" }
}

$ini = Get-Content -Raw -LiteralPath (Join-Path $root "DoubtSpan.ini")
foreach ($required in @("RequiredMonitors=3", "RestoreAfterGame=true", "RequireClosedBeforePrepare=true", "LaunchViaSteam=false", "-popupwindow")) {
    if (-not $ini.Contains($required)) { throw "Missing safe default: $required" }
}

$tokens = $null; $parseErrors = $null
$null = [System.Management.Automation.Language.Parser]::ParseFile($script, [ref]$tokens, [ref]$parseErrors)
if ($parseErrors.Count -gt 0) { throw ($parseErrors | ForEach-Object Message | Out-String) }
Write-Output "PASS: PowerShell syntax and triple-screen safety/recovery guards"

. $script -LibraryOnly
$testIni=@{ Preferences=@{ WindowedMode="3"; UseNativeResolution="false" } }
$target=[pscustomobject]@{X=-2560;Y=0;Width=7680;Height=1440}
$definitions=Get-PreferenceDefinitions $target $testIni
$expected=@{
    "width_h191264035"=7680
    "height_h1581003770"=1440
    "fullscreen_h1476830426"=3
    "Screenmanager Fullscreen mode_h3630240806"=3
    "Screenmanager Window Position X_h4088080503"=-2560
}
foreach ($entry in $expected.GetEnumerator()) {
    $actual=$definitions | Where-Object Name -eq $entry.Key | Select-Object -ExpandProperty Value
    if ($actual -ne $entry.Value) { throw "Preference definition failed for $($entry.Key): expected $($entry.Value), got $actual" }
}

$syntheticPlan = @(
    [pscustomobject]@{X=-2560;Y=0;Width=2560;Height=1440},
    [pscustomobject]@{X=0;Y=0;Width=2560;Height=1440},
    [pscustomobject]@{X=2560;Y=0;Width=2560;Height=1440}
)
$syntheticTarget=Get-TargetFromPlan $syntheticPlan
if ($syntheticTarget.X -ne -2560 -or $syntheticTarget.Width -ne 7680 -or $syntheticTarget.Height -ne 1440) { throw "Synthetic triple-monitor target calculation failed." }
Write-Output "PASS: Unity preference mapping and 7680x1440 target calculation"

$testRegistryPath="Software\DoubtSpan-Test-$([Guid]::NewGuid().ToString('N'))"
$testStatePath=Join-Path ([IO.Path]::GetTempPath()) ("DoubtSpan-pref-{0}.json" -f [Guid]::NewGuid().ToString("N"))
try {
    $created=[Microsoft.Win32.Registry]::CurrentUser.CreateSubKey($testRegistryPath)
    $created.Dispose()
    $testIni.Preferences.RegistryPath=$testRegistryPath
    $PreferenceStatePath=$testStatePath
    Set-GamePreferences $target $testIni
    $testKey=[Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($testRegistryPath,$false)
    try {
        if ([int]$testKey.GetValue("Screenmanager Resolution Width_h182942802") -ne 7680) { throw "Disposable registry write failed." }
    } finally { $testKey.Dispose() }
    Restore-PreferenceState $testIni
    $testKey=[Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($testRegistryPath,$false)
    try {
        if ($testKey.GetValueNames().Count -ne 0) { throw "Disposable registry restore did not remove newly created values." }
    } finally { $testKey.Dispose() }
    Write-Output "PASS: disposable Unity PlayerPrefs backup, write, and restore"
} finally {
    if (Test-Path -LiteralPath $testStatePath) { Remove-Item -LiteralPath $testStatePath -Force }
    [Microsoft.Win32.Registry]::CurrentUser.DeleteSubKeyTree($testRegistryPath,$false)
}
