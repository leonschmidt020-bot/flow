# Flow - UI Automation helper for Windows (started on demand by src/main/uia/uiaClient.ts, stopped after 5 idle minutes).
#
# Protocol: one JSON request per line on stdin -> one JSON reply per line on stdout ({"id":..,"ok":true,...}).
# First line written: {"ready":true,"v":1,"dpi":true|false}.
#
#   at {x,y}          element under a PHYSICAL screen point + ancestors (control type, class name, password?, editable?)
#   focused {value}   focused element + ancestors; with value=true also the field value (never for password fields)
#   setFocusAt {x,y}  focus the text field under the point (never a password field) -> {focused:true|false}
#   read              text of the focused element: field value / text around the caret, terminal rows (Windows Terminal,
#                     conhost: visible ranges), xterm.js rows (VS Code & co: "xterm-accessibility-tree"); remembers it
#   reread            the remembered element again (or the focused one of the same process)
#   quit
#
# No network, no files, no logging. Nothing is sent anywhere; the reply goes only to Flow's own process.
# ASCII only (the file is read by PowerShell 5.1).

$ErrorActionPreference = 'Stop'
$utf8 = [System.Text.UTF8Encoding]::new($false)
$stdin = [System.IO.StreamReader]::new([Console]::OpenStandardInput(), $utf8)
$stdout = [System.IO.StreamWriter]::new([Console]::OpenStandardOutput(), $utf8)
$stdout.AutoFlush = $true

Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes
Add-Type -AssemblyName WindowsBase

# Per-monitor DPI awareness: otherwise coordinates are scaled on 125 % / 150 % monitors and FromPoint hits the wrong
# element. Needs a tiny P/Invoke (compiled once by Add-Type); without it the coordinate commands are refused.
$native = $false
$dpi = $false
try {
  Add-Type -Namespace FlowUia -Name Native -MemberDefinition @'
[DllImport("user32.dll")] public static extern IntPtr SetThreadDpiAwarenessContext(IntPtr ctx);
[DllImport("user32.dll")] public static extern IntPtr GetAncestor(IntPtr hwnd, uint flags);
'@
  $native = $true
  $prev = [FlowUia.Native]::SetThreadDpiAwarenessContext([IntPtr](-4))
  $dpi = ($prev -ne [IntPtr]::Zero)
} catch { }

$AE = [System.Windows.Automation.AutomationElement]
$VP = [System.Windows.Automation.ValuePattern]
$TP = [System.Windows.Automation.TextPattern]
$walker = [System.Windows.Automation.TreeWalker]::ControlViewWalker
$rawWalker = [System.Windows.Automation.TreeWalker]::RawViewWalker
$desktop = $AE::RootElement
$script:last = $null
$script:lastKind = ''
$script:lastPid = 0
$procNames = @{}

function ProcName([int]$id) {
  if ($procNames.ContainsKey($id)) { return $procNames[$id] }
  $n = ''
  try { $n = (Get-Process -Id $id).ProcessName.ToLowerInvariant() } catch { }
  $procNames[$id] = $n
  return $n
}

function Tail([string]$s, [int]$max) {
  if ($null -eq $s) { return $null }
  if ($s.Length -gt $max) { return $s.Substring($s.Length - $max) }
  return $s
}

function IsEditable($el) {
  try {
    if ([bool]$el.GetCurrentPropertyValue($AE::IsValuePatternAvailableProperty)) {
      $vp = $el.GetCurrentPattern($VP::Pattern)
      return (-not $vp.Current.IsReadOnly)
    }
  } catch { }
  return $false
}

function Node($el, [bool]$full) {
  $c = $el.Current
  $ct = ''
  try { $ct = ($c.ControlType.ProgrammaticName -replace '^ControlType\.', '') } catch { }
  $cls = ''
  try { $cls = [string]$c.ClassName } catch { }
  if ($cls.Length -gt 200) { $cls = $cls.Substring(0, 200) }
  $n = @{ ct = $ct; cls = $cls }
  if ($full) {
    try { if ($c.IsPassword) { $n.pwd = $true } } catch { }
    if (IsEditable $el) { $n.ed = $true }
  }
  return $n
}

function RootOf($el) {
  $cur = $el
  $hwnd = [int64]0
  for ($i = 0; $i -lt 100 -and $null -ne $cur; $i++) {
    try { $hwnd = [int64]$cur.Current.NativeWindowHandle } catch { $hwnd = 0 }
    if ($hwnd -ne 0) {
      if ($native) { return [int64][FlowUia.Native]::GetAncestor([IntPtr]$hwnd, 2) }
      $p = $rawWalker.GetParent($cur)
      if ($null -eq $p -or [System.Windows.Automation.Automation]::Compare($p, $desktop)) { return $hwnd }
    }
    $cur = $rawWalker.GetParent($cur)
    if ($null -ne $cur -and [System.Windows.Automation.Automation]::Compare($cur, $desktop)) { break }
  }
  return $hwnd
}

function Info($el, [int]$depth, [bool]$withValue) {
  $chain = New-Object System.Collections.ArrayList
  $cur = $el
  for ($i = 0; $i -lt $depth -and $null -ne $cur; $i++) {
    [void]$chain.Add((Node $cur ($i -lt 6)))
    $p = $walker.GetParent($cur)
    if ($null -eq $p -or [System.Windows.Automation.Automation]::Compare($p, $desktop)) { break }
    $cur = $p
  }
  $first = $chain[0]
  $o = @{ chain = $chain; root = (RootOf $el); pid = [int]$el.Current.ProcessId; pwd = [bool]$first.pwd; ed = [bool]$first.ed }
  if ($withValue -and -not $o.pwd) {
    $v = FieldText $el 4000
    if ($null -ne $v) { $o.value = $v }
  }
  return $o
}

# text of a field: ValuePattern value (end of it), else TextPattern text around the caret
function FieldText($el, [int]$max) {
  try {
    if ([bool]$el.GetCurrentPropertyValue($AE::IsValuePatternAvailableProperty)) {
      $v = [string]$el.GetCurrentPattern($VP::Pattern).Current.Value
      if ($v.Length -gt 0 -or -not [bool]$el.GetCurrentPropertyValue($AE::IsTextPatternAvailableProperty)) { return (Tail $v $max) }
    }
  } catch { }
  try {
    if ([bool]$el.GetCurrentPropertyValue($AE::IsTextPatternAvailableProperty)) {
      $tp = $el.GetCurrentPattern($TP::Pattern)
      $sel = $tp.GetSelection()
      if ($sel.Length -gt 0) {
        $r = $sel[0].Clone()
        [void]$r.MoveEndpointByUnit([System.Windows.Automation.Text.TextPatternRangeEndpoint]::Start, [System.Windows.Automation.Text.TextUnit]::Character, -[Math]::Min(6000, $max))
        [void]$r.MoveEndpointByUnit([System.Windows.Automation.Text.TextPatternRangeEndpoint]::End, [System.Windows.Automation.Text.TextUnit]::Character, 1500)
        return [string]$r.GetText($max + 1500)
      }
      return (Tail ([string]$tp.DocumentRange.GetText(200000)) $max)
    }
  } catch { }
  return $null
}

# the nearest element (itself or up to 4 ancestors) that has a readable text
function TextHost($el) {
  $cur = $el
  for ($i = 0; $i -lt 5 -and $null -ne $cur; $i++) {
    try {
      if ([bool]$cur.GetCurrentPropertyValue($AE::IsValuePatternAvailableProperty) -or [bool]$cur.GetCurrentPropertyValue($AE::IsTextPatternAvailableProperty)) { return $cur }
    } catch { }
    $cur = $walker.GetParent($cur)
  }
  return $null
}

function ClassOf($el) { try { return [string]$el.Current.ClassName } catch { return '' } }
function HasWord([string]$cls, [string]$word) { return (' ' + $cls + ' ') -match ('\s' + [regex]::Escape($word) + '\s') }

# xterm.js: from an element inside the terminal up to the node with class "xterm", then down to the row list
function XtermTree($el) {
  $cur = $el
  $rootEl = $null
  for ($i = 0; $i -lt 16 -and $null -ne $cur; $i++) {
    $c = ClassOf $cur
    if ($c -match 'xterm-accessibility-tree') { return $cur }
    if (HasWord $c 'xterm') { $rootEl = $cur; break }
    $cur = $rawWalker.GetParent($cur)
  }
  if ($null -eq $rootEl) { return $null }
  $queue = New-Object System.Collections.Queue
  $queue.Enqueue(@($rootEl, 0))
  $seen = 0
  while ($queue.Count -gt 0 -and $seen -lt 120) {
    $item = $queue.Dequeue(); $e = $item[0]; $d = $item[1]; $seen++
    if ((ClassOf $e) -match 'xterm-accessibility-tree') { return $e }
    if ($d -lt 5) {
      $k = $rawWalker.GetFirstChild($e); $n = 0
      while ($null -ne $k -and $n -lt 16) { $queue.Enqueue(@($k, ($d + 1))); $k = $rawWalker.GetNextSibling($k); $n++ }
    }
  }
  return $null
}

function XtermRows($tree) {
  $rows = New-Object System.Collections.ArrayList
  $k = $rawWalker.GetFirstChild($tree); $n = 0
  while ($null -ne $k -and $n -lt 400) {
    $t = ''
    try { $t = [string]$k.Current.Name } catch { }
    if ($t.Length -eq 0) {
      $c = $rawWalker.GetFirstChild($k); $m = 0
      while ($null -ne $c -and $m -lt 20) { try { $t += [string]$c.Current.Name } catch { }; $c = $rawWalker.GetNextSibling($c); $m++ }
    }
    [void]$rows.Add($t)
    $k = $rawWalker.GetNextSibling($k); $n++
  }
  return ,$rows
}

function TerminalRows($el) {
  $tp = $el.GetCurrentPattern($TP::Pattern)
  $parts = New-Object System.Collections.ArrayList
  foreach ($r in $tp.GetVisibleRanges()) { [void]$parts.Add([string]$r.GetText(20000)) }
  $rows = New-Object System.Collections.ArrayList
  foreach ($line in ((($parts -join "`n") -replace "`r", '') -split "`n")) { [void]$rows.Add($line) }
  return ,$rows
}

$terminalProcs = @('windowsterminal', 'openconsole', 'conhost', 'cmd', 'powershell', 'pwsh', 'wezterm-gui', 'alacritty', 'mintty')

function ReadEl($el, [string]$want) {
  $c = $el.Current
  $procId = [int]$c.ProcessId
  $o = @{ pid = $procId; root = (RootOf $el); kind = 'none' }
  try { if ($c.IsPassword) { $o.pwd = $true; return $o } } catch { }
  $cls = ClassOf $el
  # xterm.js (VS Code, Cursor, ...): the focused element is the hidden helper textarea
  if ($want -eq 'xterm' -or ($want -eq '' -and ($cls -match 'xterm'))) {
    $tree = XtermTree $el
    if ($null -ne $tree -or $want -eq 'xterm') {
      $o.kind = 'xterm'
      if ($null -ne $tree) { $o.rows = (XtermRows $tree); $script:last = $tree } else { $o.rows = @() }
      return $o
    }
  }
  $pn = ProcName $procId
  $isTerm = ($cls -eq 'TermControl' -or $cls -eq 'ConsoleWindowClass' -or $terminalProcs -contains $pn)
  if (($want -eq 'terminal' -or ($want -eq '' -and $isTerm)) -and [bool]$el.GetCurrentPropertyValue($AE::IsTextPatternAvailableProperty)) {
    $o.kind = 'terminal'
    $o.rows = (TerminalRows $el)
    $script:last = $el
    return $o
  }
  $host_ = TextHost $el
  if ($null -eq $host_) { return $o }
  try { if ($host_.Current.IsPassword) { $o.pwd = $true; return $o } } catch { }
  $t = FieldText $host_ 20000
  if ($null -ne $t) { $o.kind = 'field'; $o.text = $t; $script:last = $host_ }
  return $o
}

function Point($req) { return [System.Windows.Point]::new([double]$req.x, [double]$req.y) }

$stdout.WriteLine((@{ ready = $true; v = 1; dpi = $dpi } | ConvertTo-Json -Compress))

while ($true) {
  $line = $stdin.ReadLine()
  if ($null -eq $line) { break }
  if ($line.Trim().Length -eq 0) { continue }
  $req = $null
  try { $req = $line | ConvertFrom-Json } catch { continue }
  $res = @{ id = $req.id; ok = $true }
  try {
    switch ([string]$req.cmd) {
      'quit' { exit 0 }
      'ping' { $res.dpi = $dpi }
      'at' {
        if (-not $dpi) { throw 'dpi' }
        $el = $AE::FromPoint((Point $req))
        $res.el = (Info $el 18 $false)
      }
      'focused' {
        $el = $AE::FocusedElement
        if ($null -eq $el) { $res.ok = $false } else { $res.el = (Info $el 30 ([bool]$req.value)) }
      }
      'setFocusAt' {
        if (-not $dpi) { throw 'dpi' }
        $el = $AE::FromPoint((Point $req))
        $target = $null
        $cur = $el
        for ($i = 0; $i -lt 5 -and $null -ne $cur; $i++) {
          try { if ($cur.Current.IsPassword) { break } } catch { }
          if (IsEditable $cur) { $target = $cur; break }
          $cur = $walker.GetParent($cur)
        }
        $res.focused = $false
        if ($null -ne $target) {
          $target.SetFocus()
          Start-Sleep -Milliseconds 30
          $f = $AE::FocusedElement
          $ok = $false
          if ($null -ne $f) {
            if ([System.Windows.Automation.Automation]::Compare($f, $target)) { $ok = $true }
            else {
              # Chromium focuses a child of the contenteditable root
              $fp = $walker.GetParent($f)
              if ($null -ne $fp -and [System.Windows.Automation.Automation]::Compare($fp, $target)) { $ok = $true }
            }
          }
          $res.focused = $ok
        }
      }
      'read' {
        $el = $AE::FocusedElement
        if ($null -eq $el) { $res.ok = $false } else {
          $r = ReadEl $el ''
          foreach ($k in $r.Keys) { $res[$k] = $r[$k] }
          $script:lastKind = [string]$r.kind
          $script:lastPid = [int]$r.pid
        }
      }
      'reread' {
        $r = $null
        if ($null -ne $script:last) {
          try {
            $alive = [int]$script:last.Current.ProcessId
            if ($script:lastKind -eq 'xterm') {
              $o = @{ pid = $alive; root = (RootOf $script:last); kind = 'xterm'; rows = (XtermRows $script:last) }
              $r = $o
            } else { $r = ReadEl $script:last $script:lastKind }
          } catch { $script:last = $null }
        }
        if ($null -eq $r) {
          # element gone (Chromium/React rebuilt the field): the focused element of the same process
          $el = $AE::FocusedElement
          if ($null -ne $el -and [int]$el.Current.ProcessId -eq $script:lastPid) { $r = ReadEl $el '' }
        }
        if ($null -eq $r) { $res.ok = $false } else { foreach ($k in $r.Keys) { $res[$k] = $r[$k] } }
      }
      default { $res.ok = $false; $res.err = 'unknown' }
    }
  } catch {
    $res.ok = $false
    $res.err = $_.Exception.GetType().Name
  }
  try { $stdout.WriteLine(($res | ConvertTo-Json -Compress -Depth 6)) } catch { $stdout.WriteLine('{"id":' + [int]$req.id + ',"ok":false,"err":"json"}') }
}
