param(
  [ValidateSet('Blocked','Allowed','Status','Reset')][string]$State = 'Status',
  [string]$Group = 'Codex Egress Guard'
)
$ErrorActionPreference = 'Stop'
$scriptRoot = $PSScriptRoot
$statusJson = Join-Path $scriptRoot 'codex-egress-status.json'
$lastAction = Join-Path $scriptRoot 'last-action.txt'

# MSIX/Store-packaged apps must be blocked by package identity: path-based rules
# do not reliably match packaged-app traffic, and their versioned install paths
# change on every update. Package-family-scoped rules survive updates.
$pkgRulePrefix = 'CodexEgressGuard.Outbound.Pkg.'

function Test-Administrator {
  $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
  $principal = [Security.Principal.WindowsPrincipal]$identity
  return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Invoke-ElevatedSelf {
  $argumentList = @(
    '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`"", '-State', $State
  )
  Start-Process -FilePath 'powershell.exe' -ArgumentList $argumentList -Verb RunAs -WindowStyle Hidden -Wait
}

function Get-PathKey([string]$Value) {
  $sha = [Security.Cryptography.SHA256]::Create()
  try {
    $bytes = [Text.Encoding]::UTF8.GetBytes($Value.ToLowerInvariant())
    return ([BitConverter]::ToString($sha.ComputeHash($bytes)).Replace('-','')).Substring(0,12)
  } finally {
    $sha.Dispose()
  }
}

function Get-TargetPrograms {
  # Non-packaged codex.exe copies (local CLI install, VS Code extension).
  # Exact-path rules work for ordinary Win32 binaries like these.
  $paths = [System.Collections.Generic.List[string]]::new()

  $patterns = @(
    (Join-Path $env:LOCALAPPDATA 'OpenAI\Codex\bin\*\codex.exe'),
    (Join-Path $env:USERPROFILE '.vscode\extensions\openai.chatgpt-*\bin\windows-x86_64\codex.exe')
  )
  foreach ($pattern in $patterns) {
    foreach ($item in (Get-Item -Path $pattern -ErrorAction SilentlyContinue)) {
      if ($item -and $item.PSIsContainer -eq $false) { $paths.Add($item.FullName) }
    }
  }

  foreach ($process in (Get-CimInstance Win32_Process -ErrorAction SilentlyContinue)) {
    if ($process.Name -in @('codex.exe','ChatGPT.exe') -and $process.ExecutablePath) {
      # Packaged copies live under WindowsApps and are covered by package rules.
      if ($process.ExecutablePath -notlike '*\WindowsApps\*') {
        $paths.Add([string]$process.ExecutablePath)
      }
    }
  }

  return @($paths | Sort-Object -Unique)
}

function Get-TargetPackages {
  # Any MSIX package that ships ChatGPT.exe or codex.exe gets one rule scoped to
  # its package family name, which stays valid across app version updates.
  $families = @{}
  foreach ($pkg in (Get-AppxPackage -ErrorAction SilentlyContinue)) {
    $loc = $pkg.InstallLocation
    if (-not $loc) { continue }
    if ((Test-Path (Join-Path $loc 'app\ChatGPT.exe')) -or
        (Test-Path (Join-Path $loc 'app\resources\codex.exe'))) {
      $families[[string]$pkg.PackageFamilyName] = $true
    }
  }
  return @($families.Keys)
}

function Get-GuardRules {
  @(Get-NetFirewallRule -ErrorAction SilentlyContinue | Where-Object { $_.Group -eq $Group })
}

function Get-RuleProgram([string]$RuleName) {
  $rule = Get-NetFirewallRule -Name $RuleName -ErrorAction SilentlyContinue
  if (-not $rule) { return $null }
  $filter = Get-NetFirewallApplicationFilter -AssociatedNetFirewallRule $rule -ErrorAction SilentlyContinue
  return [string]$filter.Program
}

function New-GuardPackageRule([string]$PackageFamilyName) {
  $key = Get-PathKey $PackageFamilyName
  $name = "$pkgRulePrefix$key"
  $display = "Codex Egress Guard - package $PackageFamilyName"
  $existing = Get-NetFirewallRule -Name $name -ErrorAction SilentlyContinue
  if ($existing) {
    Set-NetFirewallRule -Name $name -Enabled True -Action Block -Direction Outbound | Out-Null
    return $existing.Name
  }
  New-NetFirewallRule `
    -Name $name `
    -DisplayName $display `
    -Group $Group `
    -Direction Outbound `
    -Action Block `
    -PackageFamilyName $PackageFamilyName `
    -RemoteAddress Internet `
    -Profile Any `
    -Enabled True `
    -Description 'Blocks every app in this package family (ChatGPT.exe / codex.exe shipped inside the MSIX package) from direct Internet egress. Loopback and local/private traffic remain outside the Internet scope. Package scoping keeps the rule valid across app version updates.' | Out-Null
  return $name
}

function New-GuardRule([string]$Program) {
  $key = Get-PathKey $Program
  $name = "CodexEgressGuard.Outbound.$key"
  $display = "Codex Egress Guard - $(Split-Path $Program -Leaf) [$key]"
  $existing = Get-NetFirewallRule -Name $name -ErrorAction SilentlyContinue
  if ($existing) {
    Set-NetFirewallRule -Name $name -Enabled True -Action Block -Direction Outbound | Out-Null
    return $existing.Name
  }
  New-NetFirewallRule `
    -Name $name `
    -DisplayName $display `
    -Group $Group `
    -Direction Outbound `
    -Action Block `
    -Program $Program `
    -RemoteAddress Internet `
    -Profile Any `
    -Enabled True `
    -Description 'Blocks Codex/ChatGPT direct Internet egress. Loopback and local/private traffic remain outside the Internet scope.' | Out-Null
  return $name
}

function Remove-StaleRules([string[]]$TargetPrograms, [string[]]$TargetPackages) {
  $targetSet = @($TargetPrograms | ForEach-Object { $_.ToLowerInvariant() })
  $expectedPkgNames = @($TargetPackages | ForEach-Object { "$pkgRulePrefix$(Get-PathKey $_)" })
  foreach ($rule in (Get-GuardRules)) {
    if ($rule.Name -like "$pkgRulePrefix*") {
      if (-not ($expectedPkgNames -contains $rule.Name)) {
        Remove-NetFirewallRule -Name $rule.Name -ErrorAction SilentlyContinue
      }
    } else {
      $program = Get-RuleProgram $rule.Name
      if (-not $program -or -not ($targetSet -contains $program.ToLowerInvariant())) {
        Remove-NetFirewallRule -Name $rule.Name -ErrorAction SilentlyContinue
      }
    }
  }
}

function Write-Status([string]$Action) {
  $rules = Get-GuardRules
  $targetPrograms = Get-TargetPrograms
  $targetPackages = Get-TargetPackages
  $ruleRows = foreach ($rule in $rules) {
    $filter = Get-NetFirewallApplicationFilter -AssociatedNetFirewallRule $rule -ErrorAction SilentlyContinue
    [PSCustomObject]@{
      name = $rule.Name
      display_name = $rule.DisplayName
      enabled = [string]$rule.Enabled
      action = [string]$rule.Action
      direction = [string]$rule.Direction
      scope = if ($rule.Name -like "$pkgRulePrefix*") { 'package' } else { 'program' }
      remote_address = (Get-NetFirewallAddressFilter -AssociatedNetFirewallRule $rule -ErrorAction SilentlyContinue).RemoteAddress -join ','
      program = [string]$filter.Program
      package = [string]$filter.Package
    }
  }
  $status = [PSCustomObject]@{
    generated_at = (Get-Date).ToString('o')
    action = $Action
    group = $Group
    target_programs = $targetPrograms
    target_packages = $targetPackages
    rules = $ruleRows
    enabled_rule_count = @($rules | Where-Object Enabled -eq 'True').Count
  }
  $status | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $statusJson -Encoding UTF8
  Set-Content -LiteralPath $lastAction -Value ("{0} {1}" -f (Get-Date).ToString('o'), $Action) -Encoding UTF8
  $status | ConvertTo-Json -Depth 8
}

if (-not (Test-Administrator) -and $State -ne 'Status') {
  Invoke-ElevatedSelf
  exit 0
}

$targetPrograms = Get-TargetPrograms
$targetPackages = Get-TargetPackages
if ($State -eq 'Blocked' -and $targetPrograms.Count -eq 0 -and $targetPackages.Count -eq 0) {
  throw 'No codex.exe/ChatGPT.exe program paths or MSIX package shipping them was found.'
}

switch ($State) {
  'Blocked' {
    Remove-StaleRules $targetPrograms $targetPackages
    foreach ($family in $targetPackages) { New-GuardPackageRule $family | Out-Null }
    foreach ($program in $targetPrograms) { New-GuardRule $program | Out-Null }
    foreach ($rule in (Get-GuardRules)) { Set-NetFirewallRule -Name $rule.Name -Enabled True | Out-Null }
    Write-Status 'Blocked'
  }
  'Allowed' {
    foreach ($rule in (Get-GuardRules)) { Set-NetFirewallRule -Name $rule.Name -Enabled False | Out-Null }
    Write-Status 'Allowed'
  }
  'Reset' {
    foreach ($rule in (Get-GuardRules)) { Remove-NetFirewallRule -Name $rule.Name -ErrorAction SilentlyContinue }
    Write-Status 'Reset'
  }
  'Status' {
    Write-Status 'Status'
  }
}
