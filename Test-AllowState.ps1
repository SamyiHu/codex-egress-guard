param([string]$LogFile)
$ErrorActionPreference = "Stop"
"start $(Get-Date -Format o)" | Set-Content -LiteralPath $LogFile -Encoding UTF8
$rules = @(Get-NetFirewallRule | Where-Object { $_.Group -eq "Codex Egress Guard" })
"rules=$($rules.Count)" | Add-Content -LiteralPath $LogFile -Encoding UTF8
foreach($rule in $rules){
  "disable=$($rule.Name)" | Add-Content -LiteralPath $LogFile -Encoding UTF8
  Set-NetFirewallRule -Name $rule.Name -Enabled False | Out-Null
}
$after = @(Get-NetFirewallRule | Where-Object { $_.Group -eq "Codex Egress Guard" })
"enabled_after=$(@($after | Where-Object Enabled -eq "True").Count)" | Add-Content -LiteralPath $LogFile -Encoding UTF8
"done $(Get-Date -Format o)" | Add-Content -LiteralPath $LogFile -Encoding UTF8
