# Prueft eine Setup-Installation von Klimacontrol vor und nach einem Update (D3/2). Nur lesend: schreibt nichts
# ausser der Ergebnisdatei %LOCALAPPDATA%\Klimacontrol-D3\<Name>.json. Fasst %LOCALAPPDATA%\Klimacontrol (Daten,
# Zugangsdaten) nicht an und liest keine Geheimnisse.
#   -Snapshot <Name>        Zustand festhalten (Uninstall-Eintrag, Autostart, WinSparkle-Werte, Programmordner, Verknuepfungen)
#   -Compare <A> <B>        zwei Zustaende vergleichen und die Bedingungen von D3/2 pruefen
# Nur ASCII (Windows PowerShell 5.1).
param([string]$Snapshot, [string[]]$Compare)

$ErrorActionPreference = "Stop"
$appId = "{1EAA2BD1-F86E-420F-A62C-4057C87B34F8}_is1"
$dir = Join-Path $env:LOCALAPPDATA "Klimacontrol-D3"
$progDir = Join-Path $env:LOCALAPPDATA "Programs\Klimacontrol"

function Read-Values($path) {
    $o = [ordered]@{}
    if (-not (Test-Path $path)) { return $o }
    $k = Get-Item $path
    foreach ($n in $k.GetValueNames()) { $o[$n] = [string]$k.GetValue($n) }
    return $o
}

function Get-State {
    $uninstallRoot = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall"
    $entries = @()
    if (Test-Path $uninstallRoot) {
        foreach ($k in Get-ChildItem $uninstallRoot) {
            $name = [string]$k.GetValue("DisplayName")
            if ($k.PSChildName -eq $appId -or $name -eq "Klimacontrol") {
                $entries += [ordered]@{
                    Key = $k.PSChildName
                    DisplayName = $name
                    DisplayVersion = [string]$k.GetValue("DisplayVersion")
                    InstallLocation = [string]$k.GetValue("InstallLocation")
                    Language = [string]$k.GetValue("Inno Setup: Language")
                    SelectedTasks = [string]$k.GetValue("Inno Setup: Selected Tasks")
                }
            }
        }
    }
    $run = Read-Values "HKCU:\Software\Microsoft\Windows\CurrentVersion\Run"
    $runValue = $null
    if ($run.Contains("Klimacontrol")) { $runValue = $run["Klimacontrol"] }
    $files = @()
    if (Test-Path $progDir) {
        foreach ($f in Get-ChildItem $progDir -Recurse -File -Force) {
            $files += [ordered]@{
                Path = $f.FullName.Substring($progDir.Length).TrimStart('\')
                Size = $f.Length
                Version = [string]$f.VersionInfo.FileVersion
            }
        }
    }
    $startMenu = Join-Path $env:APPDATA "Microsoft\Windows\Start Menu\Programs\Klimacontrol.lnk"
    $desktop = Join-Path ([Environment]::GetFolderPath("DesktopDirectory")) "Klimacontrol.lnk"
    return [ordered]@{
        Created = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
        UninstallEntryCount = $entries.Count
        UninstallEntries = $entries
        AutostartValue = $runValue
        WinSparkle = Read-Values "HKCU:\Software\Klimacontrol\WinSparkle"
        ProgramDir = $progDir
        Files = $files
        StartMenuShortcut = (Test-Path $startMenu)
        DesktopShortcut = (Test-Path $desktop)
    }
}

function Read-Snapshot($name) {
    $p = Join-Path $dir "$name.json"
    if (-not (Test-Path $p)) { Write-Host "Abbruch: $p fehlt"; exit 1 }
    return Get-Content $p -Raw | ConvertFrom-Json
}

if ($Snapshot) {
    if ($Snapshot -notmatch '^[A-Za-z0-9._-]+$') { Write-Host "Abbruch: Name nur aus Buchstaben, Ziffern, . _ -"; exit 1 }
    New-Item -ItemType Directory -Force $dir | Out-Null
    $out = Join-Path $dir "$Snapshot.json"
    if (Test-Path $out) { Write-Host "Abbruch: $out gibt es schon (anderen Namen waehlen)"; exit 1 }
    $json = (Get-State) | ConvertTo-Json -Depth 6
    [IO.File]::WriteAllText($out, $json, (New-Object Text.UTF8Encoding $false))
    Write-Host "Zustand gespeichert: $out"
    Write-Host "Uninstall-Eintraege: $((Get-State).UninstallEntryCount)"
    exit 0
}

if ($Compare -and $Compare.Count -eq 2) {
    $a = Read-Snapshot $Compare[0]
    $b = Read-Snapshot $Compare[1]
    $bad = 0
    function Check($ok, $text) {
        if ($ok) { Write-Host "OK      $text" } else { Write-Host "FEHLER  $text"; $script:bad++ }
    }
    $ea = @($a.UninstallEntries); $eb = @($b.UninstallEntries)
    Check ($a.UninstallEntryCount -eq 1 -and $b.UninstallEntryCount -eq 1) "genau ein Uninstall-Eintrag vorher ($($a.UninstallEntryCount)) und nachher ($($b.UninstallEntryCount))"
    if ($ea.Count -ge 1 -and $eb.Count -ge 1) {
        Check ($ea[0].InstallLocation -eq $eb[0].InstallLocation) "gleicher Programmordner ($($ea[0].InstallLocation) -> $($eb[0].InstallLocation))"
        Check ($ea[0].DisplayVersion -ne $eb[0].DisplayVersion) "Version neu ($($ea[0].DisplayVersion) -> $($eb[0].DisplayVersion))"
        Write-Host "INFO    Setup-Sprache: $($ea[0].Language) -> $($eb[0].Language)"
        Write-Host "INFO    Gewaehlte Aufgaben: '$($ea[0].SelectedTasks)' -> '$($eb[0].SelectedTasks)'"
    }
    Check ($a.AutostartValue -eq $b.AutostartValue) "Autostart-Wert gleich ('$($a.AutostartValue)' -> '$($b.AutostartValue)')"
    Check ($a.StartMenuShortcut -eq $b.StartMenuShortcut) "Startmenue-Verknuepfung gleich ($($a.StartMenuShortcut) -> $($b.StartMenuShortcut))"
    Check ($a.DesktopShortcut -eq $b.DesktopShortcut) "Desktop-Verknuepfung gleich ($($a.DesktopShortcut) -> $($b.DesktopShortcut))"

    $wa = @{}; if ($a.WinSparkle) { $a.WinSparkle.PSObject.Properties | ForEach-Object { $wa[$_.Name] = $_.Value } }
    $wb = @{}; if ($b.WinSparkle) { $b.WinSparkle.PSObject.Properties | ForEach-Object { $wb[$_.Name] = $_.Value } }
    foreach ($n in (@($wa.Keys) + @($wb.Keys) | Sort-Object -Unique)) {
        if ($wa[$n] -ne $wb[$n]) { Write-Host "INFO    WinSparkle $n : '$($wa[$n])' -> '$($wb[$n])'" }
    }

    $fa = @{}; foreach ($f in @($a.Files)) { $fa[$f.Path] = $f }
    $fb = @{}; foreach ($f in @($b.Files)) { $fb[$f.Path] = $f }
    foreach ($p in ($fb.Keys | Sort-Object)) {
        if (-not $fa.ContainsKey($p)) { Write-Host "NEU     $p" }
        elseif ($fa[$p].Size -ne $fb[$p].Size -or $fa[$p].Version -ne $fb[$p].Version) { Write-Host "GEAENDERT $p ($($fa[$p].Version) -> $($fb[$p].Version))" }
    }
    foreach ($p in ($fa.Keys | Sort-Object)) {
        if (-not $fb.ContainsKey($p)) { Write-Host "ENTFALLEN $p" }
    }
    Check (@($b.Files).Count -gt 0) "Programmordner nachher nicht leer ($(@($b.Files).Count) Dateien)"
    if ($bad -gt 0) { Write-Host "$bad Bedingung(en) verletzt"; exit 1 }
    Write-Host "Alle Bedingungen erfuellt"
    exit 0
}

Write-Host "Aufruf: check_windows_upgrade.ps1 -Snapshot <Name>   bzw.   -Compare <A> <B>"
exit 1
