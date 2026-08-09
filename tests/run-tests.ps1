#requires -Version 5.1
# Plain-PowerShell test runner (no Pester dependency) for the pure logic in lockdown.ps1.
# Registry / filesystem functions are NOT exercised here — only merge/format/verify logic.
$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = [Text.Encoding]::UTF8 } catch { }

. (Join-Path (Split-Path -Parent $PSScriptRoot) 'windows\lockdown.ps1')

$Script:Failed = 0
$Script:Passed = 0
function Assert {
    param([Parameter(Mandatory)][bool]$Condition, [Parameter(Mandatory)][string]$Name)
    if ($Condition) { $Script:Passed++; Write-Host "  PASS  $Name" }
    else { $Script:Failed++; Write-Host "  FAIL  $Name" -ForegroundColor Red }
}

Write-Host "== Format-HostPattern =="
Assert ((Format-HostPattern 'mma.sinopac.com') -eq '*://mma.sinopac.com') 'bare host'
Assert ((Format-HostPattern '*://mma.sinopac.com') -eq '*://mma.sinopac.com') 'already a pattern (idempotent)'
Assert ((Format-HostPattern 'https://ebank.esunbank.com.tw/login?a=1') -eq '*://ebank.esunbank.com.tw') 'pasted URL extracts host'
Assert ((Format-HostPattern 'MAIL.Google.com/') -eq '*://mail.google.com') 'lowercase + trailing slash'
Assert ((Format-HostPattern '  richart.tw  ') -eq '*://richart.tw') 'whitespace trimmed'
Assert ($null -eq (Format-HostPattern '')) 'empty rejected'
Assert ($null -eq (Format-HostPattern '   ')) 'blank rejected'
Assert ($null -eq (Format-HostPattern 'not a host')) 'embedded space rejected'

Write-Host "== Merge-BlockedHosts =="
$extA = 'bnlffdbcfnanfbknnlaflhlhkocccckg'
$extB = 'aaaabbbbccccddddeeeeffffgggghhhh'

# 1. merge into empty policy
$j1 = Merge-BlockedHosts -ExistingJson $null -ExtensionIds @($extA) -Hosts @('mma.sinopac.com', 'richart.tw')
$o1 = ConvertFrom-Json $j1
Assert (@($o1.$extA.runtime_blocked_hosts).Count -eq 2) 'empty→2 hosts'
Assert (@($o1.$extA.runtime_blocked_hosts) -contains '*://mma.sinopac.com') 'pattern form stored'

# 2. idempotent: merging same hosts again changes nothing
$j2 = Merge-BlockedHosts -ExistingJson $j1 -ExtensionIds @($extA) -Hosts @('mma.sinopac.com', 'richart.tw')
Assert ($j2 -eq $j1) 'idempotent re-merge'

# 3. union: add one new host, existing kept
$j3 = Merge-BlockedHosts -ExistingJson $j1 -ExtensionIds @($extA) -Hosts @('mail.google.com')
$o3 = ConvertFrom-Json $j3
Assert (@($o3.$extA.runtime_blocked_hosts).Count -eq 3) 'union adds without dropping'

# 4. preserves unrelated extension entries and their other settings — including a
#    depth-3 nested structure (catches ConvertTo-Json default -Depth 2 truncation)
$existing = '{"' + $extB + '":{"installation_mode":"blocked","runtime_blocked_hosts":["*://x.example"],"nested":{"deep":["keep-me","and-me"]}}}'
$j4 = Merge-BlockedHosts -ExistingJson $existing -ExtensionIds @($extA) -Hosts @('richart.tw')
$o4 = ConvertFrom-Json $j4
Assert ($o4.$extB.installation_mode -eq 'blocked') 'unrelated extension settings preserved'
Assert (@($o4.$extB.runtime_blocked_hosts) -contains '*://x.example') 'unrelated blocked hosts preserved'
Assert ((@($o4.$extB.nested.deep) -contains 'keep-me') -and (@($o4.$extB.nested.deep) -contains 'and-me')) 'depth-3 nested structure survives roundtrip'
Assert (@($o4.$extA.runtime_blocked_hosts) -contains '*://richart.tw') 'new extension entry added'

# 5. preserves other settings on the SAME extension while extending its hosts
$existing5 = '{"' + $extA + '":{"toolbar_pin":"force_pinned","runtime_blocked_hosts":["*://a.example"]}}'
$j5 = Merge-BlockedHosts -ExistingJson $existing5 -ExtensionIds @($extA) -Hosts @('b.example')
$o5 = ConvertFrom-Json $j5
Assert ($o5.$extA.toolbar_pin -eq 'force_pinned') 'same-extension other settings preserved'
Assert ((@($o5.$extA.runtime_blocked_hosts) -join ',') -eq '*://a.example,*://b.example') 'hosts unioned + sorted'

# 6. multiple extension ids get the same hosts
$j6 = Merge-BlockedHosts -ExistingJson $null -ExtensionIds @($extA, $extB) -Hosts @('mail.google.com')
$o6 = ConvertFrom-Json $j6
Assert ((@($o6.$extA.runtime_blocked_hosts) -contains '*://mail.google.com') -and
        (@($o6.$extB.runtime_blocked_hosts) -contains '*://mail.google.com')) 'multi-extension write'

# 7. mixed/dirty host input is normalized inside merge
$j7 = Merge-BlockedHosts -ExistingJson $null -ExtensionIds @($extA) -Hosts @('https://my.taishinbank.com.tw/login', '*://richart.tw', 'AC.taishinbank.com.tw')
$o7 = ConvertFrom-Json $j7
$hosts7 = @($o7.$extA.runtime_blocked_hosts)
Assert (($hosts7 -contains '*://my.taishinbank.com.tw') -and ($hosts7 -contains '*://richart.tw') -and ($hosts7 -contains '*://ac.taishinbank.com.tw')) 'dirty inputs normalized'

Write-Host "== Test-HostsBlocked =="
Assert ((Test-HostsBlocked -PolicyJson $j1 -ExtensionIds @($extA) -Hosts @('mma.sinopac.com', 'richart.tw')) -eq $true) 'verify passes when all present'
Assert ((Test-HostsBlocked -PolicyJson $j1 -ExtensionIds @($extA) -Hosts @('mail.google.com')) -eq $false) 'verify fails on missing host'
Assert ((Test-HostsBlocked -PolicyJson $j1 -ExtensionIds @($extB) -Hosts @('mma.sinopac.com')) -eq $false) 'verify fails on missing extension'
Assert ((Test-HostsBlocked -PolicyJson $null -ExtensionIds @($extA) -Hosts @('mma.sinopac.com')) -eq $false) 'verify fails on empty policy'

Write-Host "== catalog sanity =="
$catalogPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'catalog\hosts.json'
$catalog = ConvertFrom-Json (Get-Content $catalogPath -Raw -Encoding UTF8)
Assert (@($catalog.groups).Count -ge 8) 'catalog has groups'
$allOk = $true
foreach ($g in $catalog.groups) {
    foreach ($h in $g.hosts) {
        if ($h -match '\*|://|\s' -or $h -ne $h.ToLowerInvariant()) { $allOk = $false }
        if ((Format-HostPattern $h) -ne "*://$h") { $allOk = $false }
    }
    if (-not $g.verified) { $allOk = $false }
}
Assert $allOk 'every catalog host is a bare lowercase host with a verified date'

Write-Host ""
Write-Host ("{0} passed, {1} failed" -f $Script:Passed, $Script:Failed)
if ($Script:Failed -gt 0) { exit 1 }
exit 0
