# Geräte-Test wie bei einem Freund: Installer still installieren, die INSTALLIERTE App starten,
# rechte Strg halten (echter Tastatur-Hook), Sprache über ein virtuelles Mikrofon einspielen
# (Chromium-Fake-Gerät mit einer WAV-Datei), Text landet per Strg+V in Notepad, Zwischenablage
# wird danach wiederhergestellt. Läuft in der CI auf Windows x64 und Windows 11 ARM (Snapdragon).
param(
  [Parameter(Mandatory = $true)][string]$Installer,
  [string]$Wav = "$PSScriptRoot\..\test\fixtures\asr\de_meeting.wav",
  [string[]]$Expect = @('Meeting', 'morgen', 'Uhr'),
  [int]$ModelTimeoutSec = 900
)
$ErrorActionPreference = 'Stop'
$Wav = (Resolve-Path $Wav).Path

Add-Type @'
using System;
using System.Runtime.InteropServices;
public static class K {
  [StructLayout(LayoutKind.Sequential)] public struct KI { public ushort vk; public ushort scan; public uint flags; public uint time; public IntPtr extra; }
  [StructLayout(LayoutKind.Explicit, Size = 40)] public struct IN { [FieldOffset(0)] public uint type; [FieldOffset(8)] public KI ki; }
  [DllImport("user32.dll", SetLastError = true)] public static extern uint SendInput(uint n, IN[] inputs, int size);
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
  [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
  [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int cmd);
  [DllImport("user32.dll")] public static extern bool BringWindowToTop(IntPtr h);
  [DllImport("user32.dll")] public static extern bool AttachThreadInput(uint a, uint b, bool attach);
  [DllImport("kernel32.dll")] public static extern uint GetCurrentThreadId();
  public static bool Focus(IntPtr h) {
    uint p; uint fg = GetWindowThreadProcessId(GetForegroundWindow(), out p);
    uint me = GetCurrentThreadId(); uint target = GetWindowThreadProcessId(h, out p);
    AttachThreadInput(me, fg, true); AttachThreadInput(target, fg, true);
    ShowWindow(h, 9); BringWindowToTop(h); bool ok = SetForegroundWindow(h);
    AttachThreadInput(target, fg, false); AttachThreadInput(me, fg, false);
    return ok;
  }
  [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
  public static uint Key(ushort vk, ushort scan, bool ext, bool up) {
    var i = new IN[1]; i[0].type = 1; i[0].ki.vk = vk; i[0].ki.scan = scan;
    i[0].ki.flags = (ext ? 1u : 0u) | (up ? 2u : 0u);
    return SendInput(1, i, Marshal.SizeOf(typeof(IN)));
  }
  public static uint ForegroundPid() { uint p; GetWindowThreadProcessId(GetForegroundWindow(), out p); return p; }
}
'@

function Step($m) { Write-Host "» $m" }
function Fail($m) { Write-Host "✗ GERÄTE-TEST FEHLGESCHLAGEN: $m"; if ($log -and (Test-Path $log)) { Write-Host '--- flow.log ---'; Get-Content $log -Tail 60 }; exit 1 }
# Windows 11 sperrt SetForegroundWindow für Hintergrund-Prozesse → kurz an den Eingabe-Thread des
# aktuellen Vordergrundfensters hängen (übliches Verfahren, kein Tastendruck)
function Focus-Window([IntPtr]$h) { [void][K]::Focus($h) }
function Ok($m) { Write-Host "✓ $m" }

Write-Host "Windows: $([Environment]::OSVersion.VersionString) · CPU: $env:PROCESSOR_ARCHITECTURE ($env:PROCESSOR_IDENTIFIER)"

# ── 1. Installation (pro Benutzer, ohne Adminrechte) ──
Step 'Installiere still …'
$p = Start-Process -FilePath $Installer -ArgumentList '/S' -Wait -PassThru
if ($p.ExitCode -ne 0) { Fail "Installer Exit-Code $($p.ExitCode)" }
$exe = Join-Path $env:LOCALAPPDATA 'Programs\Flow\Flow.exe'
if (-not (Test-Path $exe)) { Fail "Flow.exe nicht installiert ($exe)" }
$lnk = Join-Path ([Environment]::GetFolderPath('Programs')) 'Flow.lnk'
if (-not (Test-Path $lnk)) { Fail "Startmenü-Verknüpfung fehlt ($lnk)" }
Ok "installiert: $exe"
Start-Sleep 3
Get-Process Flow -ErrorAction SilentlyContinue | Stop-Process -Force   # runAfterFinish → eigene Instanz starten
Start-Sleep 1

# ── 2. Start der installierten App (frisches Profil, Modell-Download wie beim Freund) ──
$data = Join-Path $env:RUNNER_TEMP 'flow-device-profile'
Remove-Item $data -Recurse -Force -ErrorAction SilentlyContinue
$env:FLOW_USER_DATA = $data
$log = Join-Path $data 'logs\flow.log'
$script:flow = $null

function Start-Flow {
  $script:flow = Start-Process -FilePath $exe -PassThru -ArgumentList @(
    '--hidden', '--use-fake-ui-for-media-stream', '--use-fake-device-for-media-stream', "--use-file-for-fake-audio-capture=$Wav")
  $skip = if (Test-Path $log) { (Get-Content $log).Count } else { 0 }
  $t0 = Get-Date
  while ($true) {
    if ($script:flow.HasExited) { Fail "App beendet sich beim Start (Exit $($script:flow.ExitCode))" }
    $new = if (Test-Path $log) { Get-Content $log | Select-Object -Skip $skip } else { @() }
    if ($new -match 'asr error') { Fail 'Spracherkennung lädt nicht' }
    if (($new -match 'asr: .* loaded in') -and ($new -match 'hotkey: hook started')) { break }
    if (((Get-Date) - $t0).TotalSeconds -gt $ModelTimeoutSec) { Fail 'Sprachmodell/Tastatur-Hook nicht rechtzeitig bereit' }
    Start-Sleep 2
  }
  Ok ("Sprachmodell geladen + Tastatur-Hook läuft nach {0:N0} s" -f ((Get-Date) - $t0).TotalSeconds)
  Start-Sleep 6   # Aufwärm-Durchlauf
}

function Stop-Flow { if ($script:flow -and -not $script:flow.HasExited) { Stop-Process -Id $script:flow.Id -Force; Start-Sleep 2 } }

# Diktat-Taste halten → Text muss in Notepad stehen, Zwischenablage danach wie vorher
function Test-Dictation([string]$name, [scriptblock]$down, [scriptblock]$up) {
  Set-Clipboard -Value 'VORHER-1234'
  Get-Process -Name notepad -ErrorAction SilentlyContinue | Stop-Process -Force; Start-Sleep 1
  Start-Process notepad | Out-Null
  $deadline = (Get-Date).AddSeconds(30); $npPid = 0
  while ((Get-Date) -lt $deadline) {
    $w = Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.MainWindowHandle -ne 0 -and ($_.ProcessName -match '^notepad$' -or $_.MainWindowTitle -match 'Notepad|Editor') } | Select-Object -First 1
    if ($w) { Focus-Window $w.MainWindowHandle; Start-Sleep -Milliseconds 400; if ([K]::GetForegroundWindow() -eq $w.MainWindowHandle -or [K]::ForegroundPid() -eq $w.Id) { $npPid = $w.Id; break } }
    Start-Sleep -Milliseconds 300
  }
  if (-not $npPid) { Get-Process | Where-Object { $_.MainWindowHandle -ne 0 } | ForEach-Object { Write-Host "  Fenster: $($_.ProcessName) '$($_.MainWindowTitle)'" }; Fail 'Notepad kommt nicht in den Vordergrund' }
  $before = @(Select-String -Path $log -Pattern 'dictation: ').Count
  $dur = [Math]::Ceiling((Get-Item $Wav).Length / 32000.0) + 1
  Step "[$name] halten $dur s und sprechen …"
  & $down; Start-Sleep -Seconds $dur; & $up
  $deadline = (Get-Date).AddSeconds(40)
  while ((Get-Date) -lt $deadline -and @(Select-String -Path $log -Pattern 'dictation: ').Count -le $before) { Start-Sleep -Milliseconds 500 }
  $line = Select-String -Path $log -Pattern 'dictation: ' | Select-Object -Last 1
  if (@(Select-String -Path $log -Pattern 'dictation: ').Count -le $before) { Fail "[$name] kein Diktat verarbeitet (Taste oder Mikrofon kam nicht an)" }
  Ok "[$name] Diktat verarbeitet: $($line.Line -replace '^.*dictation: ','')"
  Start-Sleep 2
  $clipAfter = Get-Clipboard -Raw
  if (($clipAfter -replace '\s+$','') -ne 'VORHER-1234') { Fail "[$name] Zwischenablage nicht wiederhergestellt (steht: '$clipAfter')" }
  Ok "[$name] Zwischenablage danach wiederhergestellt"
  Focus-Window (Get-Process -Id $npPid).MainWindowHandle; Start-Sleep -Milliseconds 300
  [void][K]::Key(0x11, 0x1D, $false, $false); [void][K]::Key(0x41, 0x1E, $false, $false); [void][K]::Key(0x41, 0x1E, $false, $true)
  [void][K]::Key(0x43, 0x2E, $false, $false); [void][K]::Key(0x43, 0x2E, $false, $true); [void][K]::Key(0x11, 0x1D, $false, $true)
  Start-Sleep -Milliseconds 600
  $text = Get-Clipboard -Raw
  Write-Host "[$name] Text in Notepad: $text"
  if (-not $text -or $text -eq 'VORHER-1234') { Fail "[$name] kein Text in Notepad eingefügt" }
  $miss = $Expect | Where-Object { $text -notmatch [regex]::Escape($_) }
  if ($miss) { Fail "[$name] Text unvollständig, fehlt: $($miss -join ', ')" }
  Ok "[$name] Text steht in Notepad"
  Stop-Process -Id $npPid -Force -ErrorAction SilentlyContinue
}

Step 'Starte die installierte App (virtuelles Mikrofon) …'
Start-Flow
$arch = (Select-String -Path $log -Pattern 'starting \((win32-[a-z0-9]+)' | Select-Object -First 1).Matches.Groups[1].Value
Ok "App läuft als $arch"

# ── 3a. Standard: rechte Strg ──
Test-Dictation 'rechte Strg' { [void][K]::Key(0xA3, 0x1D, $true, $false) } { [void][K]::Key(0xA3, 0x1D, $true, $true) }

# ── 3b. Alt Gr (Laptops mit Copilot- statt rechter Strg-Taste, z. B. Samsung Galaxy Book4/5) ──
# Windows schickt bei Alt Gr erst ein unechtes linkes Strg (Scancode 0x21D), dann rechtes Alt.
Stop-Flow
$sf = Join-Path $data 'settings.json'
$st = Get-Content $sf -Raw | ConvertFrom-Json
$st.hotkey = 'RightAlt'
$st | ConvertTo-Json -Depth 20 | Set-Content $sf -Encoding utf8
Start-Flow
Test-Dictation 'Alt Gr' {
  [void][K]::Key(0xA2, 0x21D, $false, $false); [void][K]::Key(0xA5, 0x38, $true, $false)
} {
  [void][K]::Key(0xA2, 0x21D, $false, $true); [void][K]::Key(0xA5, 0x38, $true, $true)
}

# ── 4. Aufräumen + Deinstallation ──
Stop-Flow
$un = Join-Path $env:LOCALAPPDATA 'Programs\Flow\Uninstall Flow.exe'
if (Test-Path $un) { $u = Start-Process -FilePath $un -ArgumentList '/S' -Wait -PassThru; Start-Sleep 3; if (Test-Path $exe) { Fail 'Deinstallation lässt Flow.exe zurück' }; Ok 'Deinstallation sauber' }
Write-Host '✓ GERÄTE-TEST BESTANDEN'
