# Baut und testet den Swift-Kern unter Windows, ohne den geteilten OneDrive-Ordner zu verschmutzen.
# Aufruf im Projektordner:  powershell -ExecutionPolicy Bypass -File tools\build_windows.ps1 [-Release] [-NoTest]
# -App baut zusaetzlich die Windows-App nach dist\windows\Klimacontrol (dort nur Klimacontrol.exe, alles andere in
# res\), -Zip legt daneben Klimacontrol-Windows-<Version>.zip ab, -Install kopiert die App nach -Dest (Standard
# %USERPROFILE%\Klimacontrol - nicht aus OneDrive starten), -Shortcut legt einen Startmenue-Eintrag an.
# -Setup (auch mit -Zip) baut zusaetzlich dist\windows\Klimacontrol-Windows-<Version>-Setup.exe mit Inno Setup 6
# (winget install JRSoftware.InnoSetup); nur so installiert bekommt die App automatische Updates (WinSparkle).
# Braucht Swift 6.4+ (winget install Swift.Toolchain), die Visual Studio Build Tools mit C++-Werkzeugen und
# Windows-SDK sowie das .NET 10 SDK (winget install Microsoft.DotNet.SDK.10); Anleitung im README.
# Nur ASCII: Windows PowerShell 5.1 liest die Datei (UTF-8 ohne BOM) als ANSI, ein Gedankenstrich bricht das Skript.
param([switch]$Release, [switch]$NoTest, [switch]$App, [switch]$Zip, [switch]$Install, [switch]$Shortcut,
      [switch]$Setup, [string]$Dest)
$ErrorActionPreference = "Stop"
Set-Location (Split-Path -Parent $PSScriptRoot)

if ($Install -or $Shortcut) { $App = $true; $Install = $true }
if ($Zip) { $Setup = $true }
if ($Setup) { $App = $true }
if (-not $Dest) { $Dest = Join-Path $env:USERPROFILE "Klimacontrol" }

# Build-Ordner immer ausserhalb von OneDrive. Ein .build im Projektordner gehoert dem Mac (Symlink) - nie benutzen.
$scratch = Join-Path $env:LOCALAPPDATA "Klimacontrol-build"

# OneDrive-Konfliktkopien ("Datei-PCNAME.swift", "Datei 2.swift") wuerden mitkompiliert.
$conflicts = Get-ChildItem -Recurse -File Sources, Tests | Where-Object { $_.Name -match '[- ]' -and $_.Extension -eq '.swift' }
if ($conflicts) {
    Write-Host "Abbruch: moegliche OneDrive-Konfliktkopien:"
    $conflicts | ForEach-Object { Write-Host "  $($_.FullName)" }
    exit 1
}
# Katalog und Versionshinweise muessen zu den eingebetteten Swift-Dateien passen (der Mac erzeugt sie). Python:
# "python3" ist unter Windows oft nur ein Store-Verweis ohne Python, darum jeden Kandidaten kurz probieren.
$py = $null
foreach ($cand in @(@("python"), @("py", "-3"), @("python3"))) {
    try {
        $cmd = $cand[0]; $pre = @($cand | Select-Object -Skip 1)
        if (-not (Get-Command $cmd -ErrorAction SilentlyContinue)) { continue }
        $v = & $cmd @pre --version
        if ($LASTEXITCODE -eq 0 -and "$v" -match '^Python 3') { $py = $cand; break }
    } catch { }
}
if (-not $py) {
    Write-Host "Hinweis: Python 3 nicht gefunden - sync_strings.py/sync_release_notes.py --check uebersprungen."
} else {
    $pyCmd = $py[0]; $pyPre = @($py | Select-Object -Skip 1)
    foreach ($script in @("tools\sync_strings.py", "tools\sync_release_notes.py")) {
        & $pyCmd @pyPre $script --check
        if ($LASTEXITCODE -ne 0) {
            Write-Host "Abbruch: $script --check meldet Abweichungen. Der Mac muss die Dateien neu erzeugen (python3 $script), bevor hier gebaut wird."
            exit 1
        }
    }
}
if ((Test-Path .agent-lock) -and -not (Select-String -Quiet -Pattern "plattform=windows" .agent-lock)) {
    Write-Host "Hinweis: .agent-lock vom Mac vorhanden - dort wird gerade gearbeitet:"
    Get-Content .agent-lock
}

# Bauordner von SwiftPM; Exit-Code und Ergebnis pruefen, sonst wird aus einem leeren Pfad kopiert.
function Get-BinPath([string[]]$buildArgs) {
    $out = & swift build @buildArgs --show-bin-path
    if ($LASTEXITCODE -ne 0) { Write-Host "Abbruch: swift build --show-bin-path endet mit Fehler $LASTEXITCODE"; exit 1 }
    $path = "$($out | Select-Object -Last 1)".Trim()
    if (-not $path -or -not (Test-Path $path -PathType Container)) { Write-Host "Abbruch: Bauordner nicht gefunden: '$path'"; exit 1 }
    return $path
}

# Ordner der Swift-Laufzeit: erster runtimeLibraryPaths-Eintrag mit swiftCore.dll (der Toolchain-Ordner usr\bin
# enthaelt nur den Compiler), Rueckfall erster PATH-Treffer.
function Get-SwiftRuntimeDir {
    $dirs = @()
    try {
        $json = (& swift -print-target-info) | Out-String
        if ($LASTEXITCODE -eq 0) { $dirs += @(($json | ConvertFrom-Json).paths.runtimeLibraryPaths) }
    } catch { Write-Host "Hinweis: swift -print-target-info nicht lesbar ($($_.Exception.Message))" }
    $onPath = Get-Command swiftCore.dll -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($onPath) { $dirs += (Split-Path $onPath.Source) }
    foreach ($d in $dirs) { if ($d -and (Test-Path (Join-Path $d "swiftCore.dll"))) { return $d } }
    return $null
}

# Die App bekommt immer die Release-DLL: Debug (-Onone) macht den Kern 5-20x langsamer.
if ($App) { $Release = $true }
$config = if ($Release) { "release" } else { "debug" }

# Ohne .NET SDK gaebe es weder App noch Oberflaechen-Tests: lieber abbrechen als still ueberspringen.
if (($App -or $Release) -and -not (Get-Command dotnet -ErrorAction SilentlyContinue)) {
    Write-Host "Abbruch: .NET SDK fehlt (winget install Microsoft.DotNet.SDK.10, danach neues Terminal)"; exit 1
}

# Vor dem langen Bauen pruefen, ob die Laufzeit vollstaendig ist: ohne eine dieser DLLs startet die App auf einem
# frischen Windows nicht. Die VC++-Laufzeit liefert der Swift-Installer mit.
if ($App) {
    $runtime = Get-SwiftRuntimeDir
    if (-not $runtime) { Write-Host "Abbruch: Swift-Laufzeit (swiftCore.dll) nicht gefunden - Swift-Toolchain installiert? (winget install Swift.Toolchain, danach neues Terminal)"; exit 1 }
    $required = "swiftCore", "swift_Concurrency", "Foundation", "FoundationEssentials", "FoundationInternationalization",
                "FoundationNetworking", "_FoundationICU", "dispatch", "BlocksRuntime", "vcruntime140", "vcruntime140_1", "msvcp140"
    $missing = @($required | Where-Object { -not (Test-Path (Join-Path $runtime "$_.dll")) })
    if ($missing) {
        Write-Host "Abbruch: In der Swift-Laufzeit $runtime fehlen:"
        $missing | ForEach-Object { Write-Host "  $_.dll" }
        Write-Host "Swift-Toolchain neu installieren (winget install --id Swift.Toolchain -e)."
        exit 1
    }
    Write-Host "Swift-Laufzeit: $runtime"
}

# Warnungen brechen den Bau: Package.swift setzt .treatAllWarnings(as: .error) je eigenem Swift-Ziel. Ein globales
# -warnaserror liesse auch die Warnungen von swift-crypto/swift-asn1 durch und wuerde Sources/CSQLite (dessen
# Warnungen hingenommen werden) treffen; darum bewusst nicht hier.
# Gebaut wird nur, wo es sonst niemand tut: "swift test" uebersetzt den Kern ohnehin (debug), und mit -App entsteht
# die ausgelieferte DLL im -Osize-Bau weiter unten.
if (-not $App -and ($NoTest -or $Release)) {
    swift build -c $config --scratch-path $scratch
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
}
if (-not $NoTest) {
    # Tests nie gegen echte Daten: Schluesselbund im Speicher, Protokoll im Temp-Ordner (auch falls der Kern den
    # Windows-Namen <Ziel>-test-runner.exe nicht als Testprozess erkennt).
    $env:KLIMACONTROL_KEYCHAIN = "memory"
    $env:KLIMACONTROL_LOG_DIR = Join-Path ([IO.Path]::GetTempPath()) "klimacontrol-testlog"
    New-Item -ItemType Directory -Force $env:KLIMACONTROL_LOG_DIR | Out-Null
    swift test --scratch-path $scratch
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
    if (Get-Command dotnet -ErrorAction SilentlyContinue) {
        dotnet test windows\KlimacontrolTray.Tests\KlimacontrolTray.Tests.csproj --nologo
        if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
    } else {
        Write-Host "Hinweis: kein .NET SDK gefunden - Tests der Windows-Oberflaeche uebersprungen."
    }
}
Write-Host "Swift-Kern geprueft ($config)"
if (-not $App) { exit 0 }

# Programmordner enthaelt nur Klimacontrol.exe; Kern, Swift- und VC++-Laufzeit und Lizenzdateien liegen in res
# (die App laedt den Kern von dort).

# Laeuft die App aus $dir, wird sie vor dem Ersetzen beendet (sonst sind exe und DLLs gesperrt): zuerst geordnet
# ueber das benannte Ereignis "KlimacontrolTray.Quit" (sichert Verlauf, sendet gesammelte Befehle), nach 10 s hart.
# Die App laeuft nur einmal je Anmeldung (Mutex), das Ereignis trifft also genau diese Instanz.
function Stop-AppIn($dir) {
    $prefix = $dir.TrimEnd('\') + '\'
    $procs = @(Get-Process -Name Klimacontrol -ErrorAction SilentlyContinue |
        Where-Object { $_.Path -and $_.Path.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase) })
    if (-not $procs) { return }
    Write-Host "Beende laufende App (PID $(($procs | ForEach-Object { $_.Id }) -join ', '))"
    $signaled = $false
    try {
        $quit = [System.Threading.EventWaitHandle]::OpenExisting("KlimacontrolTray.Quit")
        [void]$quit.Set()
        $quit.Dispose()
        $signaled = $true
    } catch { }
    if (-not $signaled) { Write-Host "Hinweis: App kennt das Beenden-Signal nicht (aeltere Version) - wird hart beendet." }
    $deadline = (Get-Date).AddSeconds(10)
    foreach ($p in $procs) {
        if ($signaled) {
            $left = [int][Math]::Max(0, ($deadline - (Get-Date)).TotalMilliseconds)
            if ($p.WaitForExit($left)) { Write-Host "App geordnet beendet (PID $($p.Id))"; continue }
            Write-Host "App reagiert nach 10 s nicht - wird hart beendet (PID $($p.Id))"
        }
        if (-not $p.HasExited) { $p.Kill(); [void]$p.WaitForExit(5000) }
    }
}
# Installierte Ordner gehen in den Papierkorb, nie endgueltig loeschen.
function Remove-ToRecycleBin($path) {
    Add-Type -AssemblyName Microsoft.VisualBasic
    if (Test-Path $path -PathType Container) {
        [Microsoft.VisualBasic.FileIO.FileSystem]::DeleteDirectory($path, 'OnlyErrorDialogs', 'SendToRecycleBin')
    } else {
        [Microsoft.VisualBasic.FileIO.FileSystem]::DeleteFile($path, 'OnlyErrorDialogs', 'SendToRecycleBin')
    }
}
# Direkt nach dem Beenden oder waehrend des Virenscans kann der Ordner noch kurz gesperrt sein: bis 15 s wiederholen.
function Move-DirWithRetry($from, $to) {
    for ($try = 1; ; $try++) {
        try { [IO.Directory]::Move($from, $to); return }
        catch { if ($try -ge 15) { throw }; Start-Sleep -Seconds 1 }
    }
}

$distWin = [IO.Path]::GetFullPath("dist\windows")
$appDir = Join-Path $distWin "Klimacontrol"
$res = Join-Path $appDir "res"
Stop-AppIn $appDir
# dist\windows ist reproduzierbare Bauausgabe: hart loeschen statt ~100 MB je Bau in den Papierkorb (OneDrive hat
# ohnehin einen eigenen). Nur einen frueheren App-Ordner (mit Klimacontrol.exe) leeren, nie einen fremden.
if (Test-Path (Join-Path $appDir "Klimacontrol.exe")) { Get-ChildItem $appDir -Force | Remove-Item -Recurse -Force }
New-Item -ItemType Directory -Force $appDir, $res | Out-Null
# Eigenstaendig: .NET steckt in Klimacontrol.exe, keine Installation noetig.
dotnet publish windows\KlimacontrolTray\KlimacontrolTray.csproj -c Release -o $appDir --nologo
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
# Was publish ausser der exe ablegt (z. B. Symbole), gehoert nicht in den Programmordner.
Get-ChildItem $appDir -File | Where-Object { $_.Name -ne "Klimacontrol.exe" } |
    ForEach-Object { Write-Host "Entferne $($_.Name)"; Remove-Item $_.FullName -Force }
# Kern fuer die App kleiner bauen (-Osize); eigener Scratch-Ordner, damit der -O-Build der Tests nicht jedes Mal
# neu uebersetzt wird. Ausgeliefert wird er ohne Debug-Infos (siehe llvm-strip unten), Pfade dieses Rechners werden
# zusaetzlich umgeschrieben. swiftc nimmt die erste passende Zuordnung, clang die letzte - darum zwei Reihenfolgen.
$scratchSize = Join-Path $env:LOCALAPPDATA "Klimacontrol-build-size"
$sizeArgs = @("-c", "release", "--product", "KlimacontrolBridge", "--scratch-path", $scratchSize,
              "-Xswiftc", "-Osize", "-Xswiftc", "-gnone", "-Xlinker", "/DEBUG:NONE")
$prefixMaps = @(@($scratchSize, "/_/build"), @((Get-Location).Path, "/_/src"),
                @((Join-Path $env:LOCALAPPDATA "Programs\Swift"), "/_/swift"), @($env:LOCALAPPDATA, "/_/local"),
                @($env:USERPROFILE, "/_/home"))
foreach ($m in $prefixMaps) { $sizeArgs += @("-Xswiftc", "-file-prefix-map", "-Xswiftc", "$($m[0])=$($m[1])") }
for ($i = $prefixMaps.Count - 1; $i -ge 0; $i--) { $sizeArgs += "-Xcc", "-ffile-prefix-map=$($prefixMaps[$i][0])=$($prefixMaps[$i][1])" }
swift build @sizeArgs
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
$binSize = Get-BinPath $sizeArgs
Copy-Item (Join-Path $binSize "KlimacontrolBridge.dll") $res -Force
# Der Linker behaelt die DWARF-Abschnitte der C-Teile (swift-crypto) trotz -gnone und /DEBUG:NONE in der DLL - mit
# allen Quell-, Bau- und SDK-Pfaden. llvm-strip aus der Swift-Toolchain entfernt sie (DLL ~25 MB -> ~7 MB).
$strip = Join-Path (Split-Path (Get-Command swift).Source) "llvm-strip.exe"
if (-not (Test-Path $strip)) { Write-Host "Abbruch: llvm-strip.exe fehlt neben swift.exe"; exit 1 }
& $strip --strip-debug (Join-Path $res "KlimacontrolBridge.dll")
if ($LASTEXITCODE -ne 0) { Write-Host "Abbruch: llvm-strip endet mit Fehler $LASTEXITCODE"; exit 1 }
Write-Host "Kern (-Osize): $([int]((Get-Item (Join-Path $res 'KlimacontrolBridge.dll')).Length / 1KB)) KB"
# Swift- und VC++-Laufzeit nach res, damit die App ohne Toolchain startet (swiftRemoteMirror nur zum Debuggen).
Get-ChildItem $runtime -Filter *.dll | Where-Object { $_.Name -ne "swiftRemoteMirror.dll" } | Copy-Item -Destination $res -Force
# Keine Debug-Dateien in App-Ordner und ZIP (die App wird im Release ohne Symbole gebaut, siehe csproj).
Get-ChildItem $res -File | Where-Object { $_.Extension -in ".pdb", ".ilk", ".lib", ".exp" } |
    ForEach-Object { Write-Host "Entferne Debug-Datei $($_.Name)"; Remove-Item $_.FullName -Force }
# Lizenzhinweise: MIT/Apache verlangen Vermerk und Lizenztext beim Weitergeben.
Copy-Item docs\THIRD_PARTY_NOTICES.md $res -Force
# Die mitgelieferte .NET-Laufzeit braucht ihre eigene Hinweisdatei (aus dem Laufzeitpaket, das publish benutzt hat).
$nugetRoot = if ($env:NUGET_PACKAGES) { $env:NUGET_PACKAGES } else { Join-Path $env:USERPROFILE ".nuget\packages" }
$runtimePack = Join-Path $nugetRoot "microsoft.netcore.app.runtime.win-x64"
$dotnetNotice = Get-ChildItem $runtimePack -Directory -ErrorAction SilentlyContinue |
    Sort-Object { try { [version]($_.Name -replace '-.*$', '') } catch { [version]"0.0" } } -Descending |
    ForEach-Object { Join-Path $_.FullName "THIRD-PARTY-NOTICES.TXT" } | Where-Object { Test-Path $_ } | Select-Object -First 1
if ($dotnetNotice) { Copy-Item $dotnetNotice (Join-Path $res "DOTNET-THIRD-PARTY-NOTICES.TXT") -Force }
else { Write-Host "Warnung: THIRD-PARTY-NOTICES.TXT der .NET-Laufzeit nicht gefunden ($runtimePack)" }
# WinSparkle (Updates): festes Release, Pruefsumme fest im Skript; das ZIP wird einmal ausserhalb von OneDrive
# zwischengespeichert.
$winSparkleVersion = "0.9.4"
$winSparkleSha256 = "6037DF37FC263BD1650A1C4949681A9D40FFE991D01F35892A406CB5D103C976"
$deps = Join-Path $env:LOCALAPPDATA "Klimacontrol-deps"
$wsZip = Join-Path $deps "WinSparkle-$winSparkleVersion.zip"
if (-not $winSparkleSha256) { Write-Host "Abbruch: Pruefsumme fuer WinSparkle $winSparkleVersion fehlt im Skript"; exit 1 }
if (-not (Test-Path $wsZip)) {
    New-Item -ItemType Directory -Force $deps | Out-Null
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $wsUrl = "https://github.com/vslavik/winsparkle/releases/download/v$winSparkleVersion/WinSparkle-$winSparkleVersion.zip"
    Write-Host "Lade $wsUrl"
    Invoke-WebRequest -UseBasicParsing -Uri $wsUrl -OutFile "$wsZip.neu"
    Move-Item "$wsZip.neu" $wsZip -Force
}
$wsHash = [BitConverter]::ToString([Security.Cryptography.SHA256]::Create().ComputeHash([IO.File]::ReadAllBytes($wsZip))) -replace "-", ""
if ($wsHash -ne $winSparkleSha256) {
    Write-Host "Abbruch: Pruefsumme von $wsZip stimmt nicht"; exit 1
}
$wsDir = Join-Path $deps "WinSparkle-$winSparkleVersion"
if (-not (Test-Path $wsDir)) {
    & (Join-Path $env:SystemRoot "System32\tar.exe") -x -f $wsZip -C $deps
    if ($LASTEXITCODE -ne 0) { Write-Host "Abbruch: WinSparkle-ZIP nicht entpackt"; exit 1 }
}
Copy-Item (Join-Path $wsDir "x64\Release\WinSparkle.dll") $res -Force
foreach ($f in @("KlimacontrolBridge.dll", "WinSparkle.dll")) {
    if (-not (Test-Path (Join-Path $res $f))) { Write-Host "Abbruch: res\$f fehlt"; exit 1 }
}
Write-Host "App fertig: $appDir\Klimacontrol.exe (+ res, $((Get-ChildItem $res -File).Count) Dateien)"

# Pruefung 1: alles im App-Ordner ist x64 (eine DLL anderer Architektur faellt sonst erst beim Start auf).
function Get-PeMachine($path) {
    $fs = [IO.File]::OpenRead($path)
    try {
        $br = New-Object IO.BinaryReader($fs)
        $fs.Position = 0x3C; $pe = $br.ReadInt32()
        $fs.Position = $pe + 4; return $br.ReadUInt16()
    } finally { $fs.Dispose() }
}
$wrongArch = @(Get-ChildItem $appDir -Recurse -File | Where-Object { $_.Extension -in ".exe", ".dll" } |
    Where-Object { (Get-PeMachine $_.FullName) -ne 0x8664 })
if ($wrongArch) {
    Write-Host "Abbruch: nicht x64:"
    $wrongArch | ForEach-Object { Write-Host "  $($_.Name) (0x$('{0:X4}' -f (Get-PeMachine $_.FullName)))" }
    exit 1
}

# Pruefung 2: nichts im Paket verraet den Bauenden oder diesen Rechner (wie tools/check_traces.py am Mac). Gesucht
# wird in allen Dateien des Ordners und in allen Datei- und Ordnernamen, ohne Gross-/Kleinschreibung, als Latin-1,
# UTF-8, UTF-16 LE und UTF-16 BE (UTF-16 auch um ein Byte versetzt); ausgegeben werden nur Pfad, Art und Anzahl, nie
# der Fundtext (Fundstellen im Pfad sind durch [...] ersetzt). Fremde Build-Server-Pfade (swift-ci, D:\a\...) treffen
# diese Muster nicht. "OneDrive" allein ist kein Fund (der Kern nennt Cloud-Ordner beim Namen), nur Konto-Ordner wie
# "OneDrive-<Name>"; der Pfad dieses Rechners samt OneDrive-Ordner ist ueber Benutzer- und Projektordner abgedeckt.
function New-LeakRegex {
    $bs = [string][char]92; $cls = "[$bs$bs/]"
    $anySlash = { param($s) ([regex]::Escape($s)).Replace("$bs$bs", $cls) }
    $parts = @(
        "(?<Projektordner>$(& $anySlash (Get-Location).Path))",
        "(?<Benutzerordner>$(& $anySlash $env:USERPROFILE))",
        "(?<Benutzername>${cls}Users${cls}$([regex]::Escape($env:USERNAME))(?![A-Za-z0-9_.-]))",
        "(?<Rechnername>(?<![\w-])$([regex]::Escape($env:COMPUTERNAME))(?![\w-]))",
        "(?<OneDrive>OneDrive(?: - |-)[A-Za-z0-9])",
        "(?<ClaudeContainer>Packages${cls}Claude_)",
        "(?<Bauordner>Klimacontrol-(?:build|tray-build|deps))",
        "(?<SID>S-1-5-21-\d+-\d+-\d+)")
    return New-Object regex (($parts -join '|'), 'IgnoreCase')
}
function Find-Leaks($entries, $base, $rx) {
    $views = @(
        @{ Label = "Latin-1"; Enc = [Text.Encoding]::GetEncoding(28591); Shift = $false },
        @{ Label = "UTF-8"; Enc = New-Object Text.UTF8Encoding($false); Shift = $false },
        @{ Label = "UTF-16 LE"; Enc = [Text.Encoding]::Unicode; Shift = $true },
        @{ Label = "UTF-16 BE"; Enc = [Text.Encoding]::BigEndianUnicode; Shift = $true })
    $names = @($rx.GetGroupNames() | Where-Object { $_ -notmatch '^\d+$' })
    $total = 0
    foreach ($f in $entries) {
        $rel = $f.FullName.Substring($base.Length).TrimStart('\')
        $counts = [ordered]@{}
        foreach ($m in $rx.Matches($rel)) {
            foreach ($n in $names) { if ($m.Groups[$n].Success) { $counts["$n im Namen"] = 1 + [int]$counts["$n im Namen"] } }
        }
        if (-not $f.PSIsContainer) {
            $b = [IO.File]::ReadAllBytes($f.FullName)
            foreach ($v in $views) {
                $texts = @($v.Enc.GetString($b))
                if ($v.Shift -and $b.Length -gt 1) { $texts += $v.Enc.GetString($b, 1, $b.Length - 1) }
                foreach ($t in $texts) {
                    foreach ($m in $rx.Matches($t)) {
                        foreach ($n in $names) { if ($m.Groups[$n].Success) { $k = "$n ($($v.Label))"; $counts[$k] = 1 + [int]$counts[$k] } }
                    }
                }
            }
        }
        if ($counts.Count) {
            Write-Host "  $($rx.Replace($rel, '[...]')) : $(($counts.GetEnumerator() | ForEach-Object { "$($_.Key) $($_.Value)" }) -join ', ')"
            foreach ($v in $counts.Values) { $total += $v }
        }
    }
    return $total
}
$leakRx = New-LeakRegex
# Die exe ist komprimiert; darum zusaetzlich derselbe Bau unkomprimiert als Probe (wird nicht ausgeliefert).
$probe = Join-Path $env:LOCALAPPDATA "Klimacontrol-tray-build\probe"
if (Test-Path $probe) { Remove-Item $probe -Recurse -Force }
dotnet publish windows\KlimacontrolTray\KlimacontrolTray.csproj -c Release -p:PublishSingleFile=false -o $probe --nologo | Out-Null
if ($LASTEXITCODE -ne 0) { Write-Host "Abbruch: unkomprimierte Probe liess sich nicht bauen"; exit 1 }
Write-Host "Pruefe Metadaten: App-Ordner und unkomprimierte Probe"
$leaks = (Find-Leaks (Get-ChildItem $appDir -Recurse -Force) $appDir $leakRx) + (Find-Leaks (Get-ChildItem $probe -Recurse -Force) $probe $leakRx)
if ($leaks -gt 0) { Write-Host "Abbruch: $leaks Funde mit Daten dieses Rechners im Paket (Liste oben)"; exit 1 }
Write-Host "Metadaten: keine Funde"
if ($Zip) {
    # tar.exe aus System32 (bsdtar) schreibt "/" in die ZIP-Pfade wie vorgeschrieben; Compress-Archive unter
    # PowerShell 5.1 schreibt "\". Nicht "tar" aus PATH: Git bringt ein GNU-tar ohne ZIP mit.
    $tar = Join-Path $env:SystemRoot "System32\tar.exe"
    if (-not (Test-Path $tar)) { Write-Host "Abbruch: $tar fehlt (ab Windows 10 1803 eingebaut)"; exit 1 }
    $version = (Get-Content tools\VERSION -Raw).Trim()
    $zipFile = Join-Path $distWin "Klimacontrol-Windows-$version.zip"
    $zipTmp = "$zipFile.neu"
    if (Test-Path $zipTmp) { Remove-Item $zipTmp -Force }
    & $tar -c --format zip --options zip:compression=deflate -f $zipTmp -C $appDir Klimacontrol.exe res
    if ($LASTEXITCODE -ne 0) { Write-Host "Abbruch: tar.exe endet mit Fehler $LASTEXITCODE"; exit 1 }
    # Nur ein ZIP derselben Version beiseitelegen; andere Versionen (z. B. ein veroeffentlichtes Original) bleiben.
    if (Test-Path $zipFile) {
        $alt = Join-Path $distWin "Klimacontrol-Windows-$version-alt-$(Get-Date -Format yyyyMMddHHmmss).zip"
        Write-Host "Lege $([IO.Path]::GetFileName($zipFile)) beiseite: $([IO.Path]::GetFileName($alt))"
        Move-Item $zipFile $alt
    }
    Move-Item $zipTmp $zipFile -Force
    Write-Host "ZIP: $zipFile ($([int]((Get-Item $zipFile).Length / 1MB)) MB)"
}
if ($Setup) {
    $iscc = @((Join-Path $env:LOCALAPPDATA "Programs\Inno Setup 6\ISCC.exe"),
              (Join-Path ${env:ProgramFiles(x86)} "Inno Setup 6\ISCC.exe"),
              (Join-Path $env:ProgramFiles "Inno Setup 6\ISCC.exe")) | Where-Object { Test-Path $_ } | Select-Object -First 1
    if (-not $iscc) { Write-Host "Abbruch: Inno Setup 6 fehlt (winget install JRSoftware.InnoSetup)"; exit 1 }
    $version = (Get-Content tools\VERSION -Raw).Trim()
    $setupFile = Join-Path $distWin "Klimacontrol-Windows-$version-Setup.exe"
    # Nur ein Setup derselben Version beiseitelegen; andere Versionen (z. B. das veroeffentlichte Original) bleiben.
    if (Test-Path $setupFile) {
        $alt = Join-Path $distWin "Klimacontrol-Windows-$version-Setup-alt-$(Get-Date -Format yyyyMMddHHmmss).exe"
        Write-Host "Lege $([IO.Path]::GetFileName($setupFile)) beiseite: $([IO.Path]::GetFileName($alt))"
        Move-Item $setupFile $alt
    }
    & $iscc /Q "/DAppVersion=$version" "/DSourceDir=$appDir" "/DOutputDir=$distWin" windows\installer\Klimacontrol.iss
    if ($LASTEXITCODE -ne 0) { Write-Host "Abbruch: Inno Setup endet mit Fehler $LASTEXITCODE"; exit 1 }
    # Das Setup ist LZMA-komprimiert: darin findet die Suche kaum etwas; geprueft wurde der Inhalt vorher im App-Ordner
    # und in der unkomprimierten Probe. Hier bleiben Metadaten (Dateiname, Inno-Kopfdaten).
    if ((Find-Leaks @(Get-Item $setupFile) $distWin $leakRx) -gt 0) {
        # Nicht nach dist\windows: dort wird alles ausgeliefert; verworfenes Setup (mit Rechnerdaten) bleibt im Bauordner.
        New-Item -ItemType Directory -Force $scratch | Out-Null
        $rejected = Join-Path $scratch "Klimacontrol-Windows-$version-Setup-verworfen-$(Get-Date -Format yyyyMMddHHmmss).exe"
        Move-Item $setupFile $rejected
        Write-Host "Abbruch: Setup enthaelt Daten dieses Rechners (Liste oben) - Setup beiseitegelegt: $rejected"; exit 1
    }
    Write-Host "Setup: $setupFile ($([int]((Get-Item $setupFile).Length / 1MB)) MB)"
}
if ($Install) {
    # Ausserhalb von OneDrive ausfuehren (Dateien nur online, Sperren beim Synchronisieren). Nur in einen frueheren
    # App-Ordner (mit Klimacontrol.exe) oder einen leeren Ordner installieren, nie in einen fremden.
    $inst = [IO.Path]::GetFullPath($Dest).TrimEnd('\')
    if ($inst.StartsWith($distWin, [StringComparison]::OrdinalIgnoreCase)) { Write-Host "Abbruch: -Dest liegt in dist\windows"; exit 1 }
    if ($inst -eq [IO.Path]::GetPathRoot($inst).TrimEnd('\')) { Write-Host "Abbruch: -Dest ist ein Laufwerk"; exit 1 }
    if (-not (Test-Path (Join-Path $inst "Klimacontrol.exe")) -and (Test-Path $inst) -and (Get-ChildItem $inst -Force | Select-Object -First 1)) {
        Write-Host "Abbruch: $inst ist kein frueherer Klimacontrol-Ordner und nicht leer"; exit 1
    }
    # Atomar: neue Fassung vollstaendig in <Dest>.neu, dann alte nach <Dest>.alt und .neu umbenennen - nie neue exe
    # mit altem res. Autostart und Startmenue zeigen weiter auf <Dest>\Klimacontrol.exe.
    $neu = "$inst.neu"
    $alt = "$inst.alt"
    $parent = Split-Path -Parent $inst
    if (-not (Test-Path $parent)) { New-Item -ItemType Directory -Force $parent | Out-Null }
    Stop-AppIn $alt
    Stop-AppIn $neu
    foreach ($old in @($neu, $alt)) {
        if (Test-Path $old) { Write-Host "In den Papierkorb (Rest eines frueheren Laufs): $old"; Remove-ToRecycleBin $old }
    }
    Copy-Item $appDir $neu -Recurse -Force
    if (-not (Test-Path (Join-Path $neu "Klimacontrol.exe")) -or -not (Test-Path (Join-Path $neu "res\KlimacontrolBridge.dll"))) {
        Write-Host "Abbruch: $neu unvollstaendig - $inst bleibt unveraendert"; exit 1
    }
    Stop-AppIn $inst
    if (Test-Path $inst) { Move-DirWithRetry $inst $alt }
    try { Move-DirWithRetry $neu $inst }
    catch {
        Write-Host "Abbruch: $neu liess sich nicht nach $inst umbenennen - alte Fassung wird zurueckgelegt"
        if ((Test-Path $alt) -and -not (Test-Path $inst)) { Move-DirWithRetry $alt $inst }
        throw
    }
    if (Test-Path $alt) { Write-Host "In den Papierkorb: vorherige Fassung"; Remove-ToRecycleBin $alt }
    Write-Host "Installiert: $inst\Klimacontrol.exe (+ res)"
    if ($Shortcut) {
        $lnk = Join-Path ([Environment]::GetFolderPath("Programs")) "Klimacontrol.lnk"
        $s = (New-Object -ComObject WScript.Shell).CreateShortcut($lnk)
        $s.TargetPath = Join-Path $inst "Klimacontrol.exe"
        $s.WorkingDirectory = $inst
        $s.Save()
        Write-Host "Startmenue: $lnk"
    }
}
