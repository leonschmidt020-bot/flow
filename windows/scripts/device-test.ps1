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

# ── 2. Erster Start der installierten App (frisches Profil, Modell-Download wie beim Freund) ──
$data = Join-Path $env:RUNNER_TEMP 'flow-device-profile'
Remove-Item $data -Recurse -Force -ErrorAction SilentlyContinue
$env:FLOW_USER_DATA = $data
$log = Join-Path $data 'logs\flow.log'
Step 'Starte die installierte App (virtuelles Mikrofon) …'
$flow = Start-Process -FilePath $exe -PassThru -ArgumentList @(
  '--hidden', '--use-fake-ui-for-media-stream', '--use-fake-device-for-media-stream', "--use-file-for-fake-audio-capture=$Wav")
$t0 = Get-Date
while ($true) {
  if ($flow.HasExited) { Fail "App beendet sich beim Start (Exit $($flow.ExitCode))" }
  if ((Test-Path $log) -and (Select-String -Path $log -Pattern 'asr: .* loaded in' -Quiet)) { break }
  if ((Test-Path $log) -and (Select-String -Path $log -Pattern 'asr error' -Quiet)) { Fail 'Spracherkennung lädt nicht' }
  if (((Get-Date) - $t0).TotalSeconds -gt $ModelTimeoutSec) { Fail 'Sprachmodell nicht rechtzeitig geladen' }
  Start-Sleep 2
}
Ok ("Sprachmodell geladen nach {0:N0} s" -f ((Get-Date) - $t0).TotalSeconds)
Start-Sleep 6   # Aufwärm-Durchlauf + Tastatur-Hook
if (-not (Select-String -Path $log -Pattern 'hotkey: hook started' -Quiet)) { Fail 'Tastatur-Hook nicht gestartet' }
Ok 'Tastatur-Hook läuft'
$arch = (Select-String -Path $log -Pattern 'starting \((win32-[a-z0-9]+)' | Select-Object -First 1).Matches.Groups[1].Value
Ok "App läuft als $arch"

# ── 3. Diktat in Notepad ──
Set-Clipboard -Value 'VORHER-1234'
$np = Start-Process notepad -PassThru
$deadline = (Get-Date).AddSeconds(30)
$npPid = 0
while ((Get-Date) -lt $deadline) {
  $w = Get-Process -Name notepad -ErrorAction SilentlyContinue | Where-Object { $_.MainWindowHandle -ne 0 } | Select-Object -First 1
  if ($w) { [void][K]::SetForegroundWindow($w.MainWindowHandle); Start-Sleep -Milliseconds 400; if ([K]::ForegroundPid() -eq $w.Id) { $npPid = $w.Id; break } }
  Start-Sleep -Milliseconds 300
}
if (-not $npPid) { Fail 'Notepad kommt nicht in den Vordergrund' }
Ok 'Notepad im Vordergrund'

$dur = [Math]::Ceiling((Get-Item $Wav).Length / 32000.0) + 1
Step "Halte rechte Strg $dur s und spreche …"
[void][K]::Key(0xA3, 0x1D, $true, $false)
Start-Sleep -Seconds $dur
[void][K]::Key(0xA3, 0x1D, $true, $true)

$deadline = (Get-Date).AddSeconds(40)
while ((Get-Date) -lt $deadline -and -not (Select-String -Path $log -Pattern 'dictation: ' -Quiet)) { Start-Sleep -Milliseconds 500 }
$line = Select-String -Path $log -Pattern 'dictation: ' | Select-Object -Last 1
if (-not $line) { Fail 'kein Diktat verarbeitet (Taste oder Mikrofon kam nicht an)' }
Ok "Diktat verarbeitet: $($line.Line -replace '^.*dictation: ','')"
Start-Sleep 2

$clipAfter = Get-Clipboard -Raw
if (($clipAfter -replace '\s+$','') -ne 'VORHER-1234') { Fail "Zwischenablage nicht wiederhergestellt (steht: '$clipAfter')" }
Ok 'Zwischenablage danach wiederhergestellt'

[void][K]::SetForegroundWindow((Get-Process -Id $npPid).MainWindowHandle); Start-Sleep -Milliseconds 300
[void][K]::Key(0x11, 0x1D, $false, $false); [void][K]::Key(0x41, 0x1E, $false, $false); [void][K]::Key(0x41, 0x1E, $false, $true)
[void][K]::Key(0x43, 0x2E, $false, $false); [void][K]::Key(0x43, 0x2E, $false, $true); [void][K]::Key(0x11, 0x1D, $false, $true)
Start-Sleep -Milliseconds 600
$text = Get-Clipboard -Raw
Write-Host "Text in Notepad: $text"
if (-not $text -or $text -eq 'VORHER-1234') { Fail 'kein Text in Notepad eingefügt' }
$miss = $Expect | Where-Object { $text -notmatch [regex]::Escape($_) }
if ($miss) { Fail "Text unvollständig, fehlt: $($miss -join ', ')" }
Ok 'Text steht in Notepad'

# ── 4. Aufräumen + Deinstallation ──
Stop-Process -Id $npPid -Force -ErrorAction SilentlyContinue
Stop-Process -Id $flow.Id -Force -ErrorAction SilentlyContinue
$un = Join-Path $env:LOCALAPPDATA 'Programs\Flow\Uninstall Flow.exe'
if (Test-Path $un) { $u = Start-Process -FilePath $un -ArgumentList '/S' -Wait -PassThru; Start-Sleep 3; if (Test-Path $exe) { Fail 'Deinstallation lässt Flow.exe zurück' }; Ok 'Deinstallation sauber' }
Write-Host '✓ GERÄTE-TEST BESTANDEN'
