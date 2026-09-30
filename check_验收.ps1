<#
  MoonProbe - official acceptance check (Windows)

  Runs, in order, the checks the project has to pass to be accepted:

    1. core code size   non-test .mbt lines, required to exceed 1500
    2. compile check    moon check --target wasm-gc / js, 0 error 0 warning
    3. build check      moon build --target js
    4. unit tests       moon test --target wasm-gc, every test green
    5. formatting       moon fmt --check
    6. commit history   commits reachable from HEAD

  Every check prints one [OK] / [FAIL] line, a failing check prints the tail of
  the command output, and the exit code is 0 only when all of them passed.

  Usage: powershell -ExecutionPolicy Bypass -File .\check_验收.ps1
#>

Set-Location -LiteralPath $PSScriptRoot

$script:passed = 0
$script:failed = 0
$log = Join-Path ([System.IO.Path]::GetTempPath()) 'moonprobe_check.log'

function Write-Heading {
  param([string]$Text)
  Write-Host ""
  Write-Host "== $Text"
}

function Write-Ok {
  param([string]$Text)
  Write-Host "   [OK]   $Text"
  $script:passed++
}

function Write-No {
  param([string]$Text)
  Write-Host "   [FAIL] $Text"
  $script:failed++
}

function Show-Log {
  param([int]$Lines = 30)
  Get-Content -LiteralPath $log -Tail $Lines -ErrorAction SilentlyContinue |
    ForEach-Object { Write-Host "          $_" }
}

# ---------------------------------------------------------------------------
# 1. Core code size
# ---------------------------------------------------------------------------

Write-Heading "1/6  Core code size (non-test .mbt)"

$coreFiles = Get-ChildItem -LiteralPath $PSScriptRoot -Recurse -File -Filter '*.mbt' -ErrorAction SilentlyContinue |
  Where-Object {
    $_.Name -notlike '*_test.mbt' -and
    $_.FullName -notlike '*\_build\*' -and
    $_.FullName -notlike '*\.git\*'
  }
$coreLines = 0
foreach ($file in $coreFiles) {
  $coreLines += (Get-Content -LiteralPath $file.FullName | Measure-Object -Line).Lines
}

Write-Host "   non-test .mbt lines: $coreLines (required > 1500)"
if ($coreLines -gt 1500) {
  Write-Ok "code size $coreLines lines"
} else {
  Write-No "code size $coreLines lines is not above 1500"
}

# ---------------------------------------------------------------------------
# 2. Compile check
# ---------------------------------------------------------------------------

Write-Heading "2/6  Compile check (0 error / 0 warning)"

foreach ($target in @('wasm-gc', 'js')) {
  & moon check --target $target --deny-warn *> $log
  if ($LASTEXITCODE -eq 0) {
    Write-Ok "moon check --target $target --deny-warn"
  } else {
    Write-No "moon check --target $target --deny-warn"
    Show-Log 40
  }
}

# ---------------------------------------------------------------------------
# 3. Build check
# ---------------------------------------------------------------------------

Write-Heading "3/6  Build check (js)"

& moon build --target js *> $log
if ($LASTEXITCODE -eq 0) {
  Write-Ok "moon build --target js"
} else {
  Write-No "moon build --target js"
  Show-Log 40
}

# ---------------------------------------------------------------------------
# 4. Unit tests
# ---------------------------------------------------------------------------

Write-Heading "4/6  Unit tests (wasm-gc)"

& moon test --target wasm-gc *> $log
$total = Select-String -LiteralPath $log -Pattern 'Total tests:' -ErrorAction SilentlyContinue |
  Select-Object -Last 1
if ($LASTEXITCODE -eq 0) {
  $summary = if ($total) { " - " + $total.Line.Trim() } else { "" }
  Write-Ok ("moon test --target wasm-gc" + $summary)
} else {
  Write-No "moon test --target wasm-gc"
  Show-Log 60
}

# ---------------------------------------------------------------------------
# 5. Formatting
# ---------------------------------------------------------------------------

Write-Heading "5/6  Formatting (moon fmt --check)"

& moon fmt --check *> $log
if ($LASTEXITCODE -eq 0) {
  Write-Ok "moon fmt --check"
} else {
  Write-No "moon fmt --check"
  Show-Log 40
}

# ---------------------------------------------------------------------------
# 6. Commit history
# ---------------------------------------------------------------------------

Write-Heading "6/6  Commit history"

$commits = 0
$countText = & git rev-list --count HEAD 2>$null
if ($LASTEXITCODE -eq 0 -and $countText) {
  $commits = [int]$countText.Trim()
}

Write-Host "   commits reachable from HEAD: $commits"
if ($commits -gt 0) {
  Write-Ok "git history present"
} else {
  Write-No "no commits found"
}

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------

Write-Heading "Summary"

Write-Host "   $script:passed passed, $script:failed failed"
if ($script:failed -eq 0) {
  Write-Host "   Result: PASSED - MoonProbe meets the acceptance criteria"
  exit 0
}
Write-Host "   Result: FAILED"
exit 1