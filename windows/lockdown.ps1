#requires -Version 5.1
<#
ai-browser-lockdown — lock AI browser-control extensions out of your critical sites.

Writes the ExtensionSettings enterprise policy (runtime_blocked_hosts) for
Microsoft Edge / Google Chrome on Windows. This is the ONLY per-host control
that actually stops chrome.debugger-based automation extensions — the per-site
"site access" whitelist in the extensions UI does NOT apply to the debugger API.

Usage (run in an elevated PowerShell):
  .\lockdown.ps1              # interactive: lock / status / restore menu
  .\lockdown.ps1 -Action status
  .\lockdown.ps1 -Action lock
  .\lockdown.ps1 -Action restore

Every write is preceded by a timestamped backup under ~\.ai-browser-lockdown\backups.
#>
[CmdletBinding()]
param(
    [ValidateSet('lock', 'status', 'restore')]
    [string]$Action
)

$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = [Text.Encoding]::UTF8 } catch { }

$Script:Browsers = [ordered]@{
    edge = @{
        Label     = 'Microsoft Edge'
        PolicyKey = 'HKLM:\SOFTWARE\Policies\Microsoft\Edge'
        UserData  = Join-Path $env:LOCALAPPDATA 'Microsoft\Edge\User Data'
    }
    chrome = @{
        Label     = 'Google Chrome'
        PolicyKey = 'HKLM:\SOFTWARE\Policies\Google\Chrome'
        UserData  = Join-Path $env:LOCALAPPDATA 'Google\Chrome\User Data'
    }
}
$Script:BackupDir   = Join-Path $env:USERPROFILE '.ai-browser-lockdown\backups'
$Script:CatalogPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'catalog\hosts.json'

# ---------------------------------------------------------------- pure helpers

function Test-IsAdmin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    ([Security.Principal.WindowsPrincipal]$id).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function ConvertTo-DeepHashtable {
    # PS 5.1 ConvertFrom-Json has no -AsHashtable; normalize PSCustomObject trees.
    param($InputObject)
    if ($null -eq $InputObject) { return $null }
    if ($InputObject -is [System.Collections.IDictionary]) {
        $h = [ordered]@{}
        foreach ($k in $InputObject.Keys) { $h[$k] = ConvertTo-DeepHashtable $InputObject[$k] }
        return $h
    }
    if ($InputObject -is [System.Management.Automation.PSCustomObject]) {
        $h = [ordered]@{}
        foreach ($p in $InputObject.PSObject.Properties) { $h[$p.Name] = ConvertTo-DeepHashtable $p.Value }
        return $h
    }
    if (($InputObject -is [System.Collections.IEnumerable]) -and ($InputObject -isnot [string])) {
        return @($InputObject | ForEach-Object { ConvertTo-DeepHashtable $_ })
    }
    return $InputObject
}

function Format-HostPattern {
    # Accepts "host", "*://host", or a pasted URL; returns "*://host" (lowercased) or $null.
    param([string]$InputHost)
    $h = ($InputHost | ForEach-Object { $_.Trim() }) -replace '^\*://', ''
    if ([string]::IsNullOrWhiteSpace($h)) { return $null }
    if ($h -match '://') {
        try { $h = ([Uri]$h).Host } catch { return $null }
    } else {
        $h = ($h -split '[/?#]')[0]
    }
    $h = $h.Trim().TrimEnd('.').ToLowerInvariant()
    if ([string]::IsNullOrWhiteSpace($h) -or $h -match '\s') { return $null }
    return "*://$h"
}

function Merge-BlockedHosts {
    <#
    Merge new blocked hosts into an existing ExtensionSettings JSON string.
    - Preserves unrelated extensions and any other per-extension settings.
    - Union + sort of runtime_blocked_hosts (idempotent).
    Returns a compressed JSON string.
    #>
    param(
        [AllowNull()][AllowEmptyString()][string]$ExistingJson,
        [Parameter(Mandatory)][string[]]$ExtensionIds,
        [Parameter(Mandatory)][string[]]$Hosts
    )
    $settings = [ordered]@{}
    if (-not [string]::IsNullOrWhiteSpace($ExistingJson)) {
        $settings = ConvertTo-DeepHashtable (ConvertFrom-Json $ExistingJson)
    }
    $patterns = @($Hosts | ForEach-Object { Format-HostPattern $_ } | Where-Object { $_ })
    foreach ($extId in $ExtensionIds) {
        if (-not $settings.Contains($extId)) { $settings[$extId] = [ordered]@{} }
        $existing = @()
        if ($settings[$extId].Contains('runtime_blocked_hosts')) {
            $existing = @($settings[$extId]['runtime_blocked_hosts'])
        }
        $merged = @($existing + $patterns | Where-Object { $_ } | Sort-Object -Unique)
        $settings[$extId]['runtime_blocked_hosts'] = $merged
    }
    # -Depth default (2) silently truncates nested structures — always set it.
    return (ConvertTo-Json $settings -Depth 10 -Compress)
}

function Test-HostsBlocked {
    # Verify (from a policy JSON string) that every host pattern is present for every extension id.
    param(
        [AllowNull()][AllowEmptyString()][string]$PolicyJson,
        [Parameter(Mandatory)][string[]]$ExtensionIds,
        [Parameter(Mandatory)][string[]]$Hosts
    )
    if ([string]::IsNullOrWhiteSpace($PolicyJson)) { return $false }
    $settings = ConvertTo-DeepHashtable (ConvertFrom-Json $PolicyJson)
    foreach ($extId in $ExtensionIds) {
        if (-not $settings.Contains($extId)) { return $false }
        $blocked = @($settings[$extId]['runtime_blocked_hosts'])
        foreach ($h in $Hosts) {
            $p = Format-HostPattern $h
            if ($blocked -notcontains $p) { return $false }
        }
    }
    return $true
}

# ------------------------------------------------------------ registry access

function Get-PolicyJson {
    param([Parameter(Mandatory)][hashtable]$Browser)
    $item = Get-ItemProperty -Path $Browser.PolicyKey -Name 'ExtensionSettings' -ErrorAction SilentlyContinue
    if ($null -eq $item) { return $null }
    return [string]$item.ExtensionSettings
}

function Set-PolicyJson {
    param(
        [Parameter(Mandatory)][hashtable]$Browser,
        [Parameter(Mandatory)][string]$Json
    )
    if (-not (Test-Path $Browser.PolicyKey)) {
        New-Item -Path $Browser.PolicyKey -Force | Out-Null
    }
    Set-ItemProperty -Path $Browser.PolicyKey -Name 'ExtensionSettings' -Value $Json -Type String
}

function Backup-Policy {
    # Snapshot the current value (or its absence) before any write. Returns backup file path.
    param(
        [Parameter(Mandatory)][string]$BrowserId,
        [Parameter(Mandatory)][hashtable]$Browser
    )
    if (-not (Test-Path $Script:BackupDir)) { New-Item -ItemType Directory -Path $Script:BackupDir -Force | Out-Null }
    $current = Get-PolicyJson -Browser $Browser
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $file = Join-Path $Script:BackupDir "$BrowserId-ExtensionSettings-$stamp.json"
    $payload = [ordered]@{
        browser   = $BrowserId
        policyKey = $Browser.PolicyKey
        timestamp = (Get-Date -Format 'o')
        existed   = ($null -ne $current)
        value     = $current
    }
    ConvertTo-Json $payload -Depth 5 | Set-Content -Path $file -Encoding UTF8
    return $file
}

# --------------------------------------------------------- extension detection

function Get-ExtensionDisplayName {
    # Resolve manifest "name"; follow __MSG_key__ into _locales/<default_locale>/messages.json.
    param(
        [Parameter(Mandatory)]$Manifest,
        [Parameter(Mandatory)][string]$VersionDir
    )
    $name = [string]$Manifest.name
    if ($name -notmatch '^__MSG_(.+)__$') { return $name }
    $key = $Matches[1]
    $locale = [string]$Manifest.default_locale
    if (-not $locale) { return $name }
    $msgFile = Join-Path $VersionDir "_locales\$locale\messages.json"
    if (-not (Test-Path $msgFile -ErrorAction SilentlyContinue)) { return $name }
    try {
        $messages = ConvertFrom-Json (Get-Content $msgFile -Raw -Encoding UTF8)
        foreach ($p in $messages.PSObject.Properties) {
            if ($p.Name -ieq $key) { return [string]$p.Value.message }
        }
    } catch { }
    return $name
}

function Get-DebuggerExtensions {
    # Scan all profiles of a browser for installed extensions holding the "debugger"
    # API permission — the class of extensions this tool exists to fence in.
    param([Parameter(Mandatory)][hashtable]$Browser)
    $found = @{}
    if (-not (Test-Path $Browser.UserData)) { return @() }
    $profiles = Get-ChildItem $Browser.UserData -Directory -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -eq 'Default' -or $_.Name -like 'Profile *' }
    foreach ($prof in $profiles) {
        $extRoot = Join-Path $prof.FullName 'Extensions'
        if (-not (Test-Path $extRoot)) { continue }
        foreach ($extDir in (Get-ChildItem $extRoot -Directory -ErrorAction SilentlyContinue)) {
            # Whole per-extension body is best-effort: ACL-denied manifests (seen in the
            # wild under Chrome User Data) must skip the extension, not kill the scan.
            try {
                $verDir = Get-ChildItem $extDir.FullName -Directory -ErrorAction SilentlyContinue |
                    Sort-Object Name -Descending | Select-Object -First 1
                if (-not $verDir) { continue }
                $manifestPath = Join-Path $verDir.FullName 'manifest.json'
                if (-not (Test-Path $manifestPath -ErrorAction SilentlyContinue)) { continue }
                $manifest = ConvertFrom-Json (Get-Content $manifestPath -Raw -Encoding UTF8)
                if (@($manifest.permissions) -notcontains 'debugger') { continue }
                $extName = Get-ExtensionDisplayName -Manifest $manifest -VersionDir $verDir.FullName
            } catch { continue }
            if (-not $found.ContainsKey($extDir.Name)) {
                $found[$extDir.Name] = [pscustomobject]@{
                    Id       = $extDir.Name
                    Name     = $extName
                    Profiles = @($prof.Name)
                }
            } elseif ($found[$extDir.Name].Profiles -notcontains $prof.Name) {
                $found[$extDir.Name].Profiles += $prof.Name
            }
        }
    }
    return @($found.Values | Sort-Object Id)
}

# ------------------------------------------------------------------ catalog/UI

function Get-Catalog {
    if (-not (Test-Path $Script:CatalogPath)) {
        Write-Warning "找不到 host 目錄 $Script:CatalogPath — 只能手動輸入 host。"
        return @()
    }
    $catalog = ConvertFrom-Json (Get-Content $Script:CatalogPath -Raw -Encoding UTF8)
    return @($catalog.groups)
}

function Select-Multi {
    # Numbered multi-select. Returns selected items (subset of $Items).
    param(
        [Parameter(Mandatory)][string]$Title,
        [Parameter(Mandatory)][object[]]$Items,
        [Parameter(Mandatory)][scriptblock]$LabelOf,
        [switch]$AllowAll
    )
    Write-Host ""
    Write-Host $Title -ForegroundColor Cyan
    for ($i = 0; $i -lt $Items.Count; $i++) {
        Write-Host ("  [{0}] {1}" -f ($i + 1), (& $LabelOf $Items[$i]))
    }
    $hint = "輸入編號（逗號分隔，例如 1,3,4"
    if ($AllowAll) { $hint += "；輸入 all 全選" }
    $hint += "；直接 Enter 跳過）"
    while ($true) {
        $raw = Read-Host $hint
        if ([string]::IsNullOrWhiteSpace($raw)) { return @() }
        if ($AllowAll -and $raw.Trim() -ieq 'all') { return @($Items) }
        $picked = @()
        $ok = $true
        foreach ($tok in ($raw -split ',')) {
            $n = 0
            if ([int]::TryParse($tok.Trim(), [ref]$n) -and $n -ge 1 -and $n -le $Items.Count) {
                $picked += $Items[$n - 1]
            } else { $ok = $false; break }
        }
        if ($ok -and $picked.Count -gt 0) { return @($picked | Select-Object -Unique) }
        Write-Host "  無效輸入，請重試。" -ForegroundColor Yellow
    }
}

# ----------------------------------------------------------------- top actions

function Show-Status {
    foreach ($id in $Script:Browsers.Keys) {
        $b = $Script:Browsers[$id]
        Write-Host ""
        Write-Host ("=== {0} ===" -f $b.Label) -ForegroundColor Cyan
        if (-not (Test-Path $b.UserData)) {
            Write-Host "  （未偵測到安裝）"
            continue
        }
        # Subkey-style ExtensionSettings (GPO per-extension subkeys) would shadow our JSON value.
        if (Test-Path (Join-Path $b.PolicyKey 'ExtensionSettings')) {
            Write-Warning "  發現 subkey 形式的 ExtensionSettings（可能來自 GPO）——本工具使用 JSON 字串值，兩者並存時請先釐清，避免互相覆蓋。"
        }
        $json = Get-PolicyJson -Browser $b
        $blockedByExt = [ordered]@{}
        if ($json) {
            $settings = ConvertTo-DeepHashtable (ConvertFrom-Json $json)
            foreach ($extId in $settings.Keys) {
                if ($settings[$extId].Contains('runtime_blocked_hosts')) {
                    $blockedByExt[$extId] = @($settings[$extId]['runtime_blocked_hosts'])
                }
            }
        }
        $debuggerExts = Get-DebuggerExtensions -Browser $b
        if ($debuggerExts.Count -eq 0) {
            Write-Host "  未發現帶 debugger 權限的擴充。"
        }
        foreach ($ext in $debuggerExts) {
            Write-Host ("  擴充: {0}  ({1})" -f $ext.Name, $ext.Id)
            if ($blockedByExt.Contains($ext.Id)) {
                Write-Host ("    已封鎖 {0} 個 host:" -f $blockedByExt[$ext.Id].Count) -ForegroundColor Green
                foreach ($h in $blockedByExt[$ext.Id]) { Write-Host "      $h" }
            } else {
                Write-Host "    ⚠ 未設定任何封鎖 — 此擴充可以 attach 到任何分頁。" -ForegroundColor Yellow
            }
        }
        foreach ($extId in $blockedByExt.Keys) {
            if ($debuggerExts.Id -notcontains $extId) {
                Write-Host ("  （policy 另含未安裝/其他擴充 {0}：封鎖 {1} 個 host）" -f $extId, $blockedByExt[$extId].Count)
            }
        }
    }
}

function Invoke-Lock {
    if (-not (Test-IsAdmin)) {
        Write-Warning "寫入 HKLM policy 需要系統管理員權限。請用「以系統管理員身分執行」開 PowerShell 後重跑。"
        return
    }
    # 1. pick browsers (only installed ones)
    $installed = @($Script:Browsers.Keys | Where-Object { Test-Path $Script:Browsers[$_].UserData })
    if ($installed.Count -eq 0) { Write-Warning "未偵測到 Edge 或 Chrome。"; return }
    $browserPick = Select-Multi -Title "要設定哪些瀏覽器？" -Items $installed -AllowAll `
        -LabelOf { param($x) $Script:Browsers[$x].Label }
    if ($browserPick.Count -eq 0) { Write-Host "未選擇，結束。"; return }

    foreach ($browserId in $browserPick) {
        $b = $Script:Browsers[$browserId]
        Write-Host ""
        Write-Host ("--- {0} ---" -f $b.Label) -ForegroundColor Cyan

        # 2. pick extensions (auto-detected debugger extensions + manual entry)
        $exts = Get-DebuggerExtensions -Browser $b
        $extIds = @()
        if ($exts.Count -gt 0) {
            $picked = Select-Multi -Title "偵測到以下帶 debugger 權限的擴充（AI 瀏覽器控制工具屬於這類）：" `
                -Items $exts -AllowAll -LabelOf { param($x) "{0}  ({1})  [{2}]" -f $x.Name, $x.Id, ($x.Profiles -join ', ') }
            $extIds = @($picked | ForEach-Object { $_.Id })
        } else {
            Write-Host "  未自動偵測到帶 debugger 權限的擴充。"
        }
        $manualId = Read-Host "要手動加入其他擴充 ID 嗎？（32 碼小寫字母；直接 Enter 跳過）"
        if ($manualId -match '^[a-p]{32}$') { $extIds += $manualId }
        elseif (-not [string]::IsNullOrWhiteSpace($manualId)) { Write-Warning "「$manualId」不是合法擴充 ID（略過）。" }
        $extIds = @($extIds | Select-Object -Unique)
        if ($extIds.Count -eq 0) { Write-Host "沒有要設定的擴充，跳過 $($b.Label)。"; continue }

        # 3. pick hosts: catalog groups + custom
        $groups = Get-Catalog
        $hosts = @()
        if ($groups.Count -gt 0) {
            $pickedGroups = Select-Multi -Title "選擇要封鎖的網站群組（皆為實地驗證過的登入 host）：" `
                -Items $groups -AllowAll -LabelOf { param($g) "{0}  → {1}" -f $g.label, ($g.hosts -join ', ') }
            foreach ($g in $pickedGroups) { $hosts += @($g.hosts) }
        }
        $custom = Read-Host "自訂 host（逗號分隔；可直接貼上登入頁網址，會自動取出 host；直接 Enter 跳過）"
        if (-not [string]::IsNullOrWhiteSpace($custom)) {
            foreach ($tok in ($custom -split ',')) {
                $p = Format-HostPattern $tok
                if ($p) { $hosts += ($p -replace '^\*://', '') }
                else { Write-Warning "「$tok」無法解析成 host（略過）。" }
            }
        }
        $hosts = @($hosts | Select-Object -Unique)
        if ($hosts.Count -eq 0) { Write-Host "沒有選擇任何 host，跳過 $($b.Label)。"; continue }

        # 4. plan + confirm
        Write-Host ""
        Write-Host "即將寫入的封鎖規則：" -ForegroundColor Cyan
        Write-Host ("  瀏覽器: {0}" -f $b.Label)
        Write-Host ("  擴充:   {0}" -f ($extIds -join ', '))
        Write-Host ("  Host:   ({0} 個)" -f $hosts.Count)
        foreach ($h in $hosts) { Write-Host ("    *://{0}" -f ($h -replace '^\*://', '')) }
        Write-Host "  （既有設定會保留，只做合併；寫入前自動備份）"
        $go = Read-Host "確定寫入？ (y/N)"
        if ($go -notmatch '^[Yy]') { Write-Host "已取消。"; continue }

        # 5. backup → merge → write → verify
        $backupFile = Backup-Policy -BrowserId $browserId -Browser $b
        Write-Host ("已備份現況 → {0}" -f $backupFile)
        $newJson = Merge-BlockedHosts -ExistingJson (Get-PolicyJson -Browser $b) -ExtensionIds $extIds -Hosts $hosts
        Set-PolicyJson -Browser $b -Json $newJson
        $readback = Get-PolicyJson -Browser $b
        if (Test-HostsBlocked -PolicyJson $readback -ExtensionIds $extIds -Hosts $hosts) {
            Write-Host "✓ 寫入成功，讀回驗證通過。" -ForegroundColor Green
        } else {
            Write-Warning "✗ 讀回驗證失敗 — registry 內容與預期不符，請用 -Action status 檢查，或用 -Action restore 還原備份。"
            continue
        }
        Write-Host ""
        Write-Host "接下來（重要）：" -ForegroundColor Yellow
        Write-Host "  1. 完全關閉 $($b.Label)（含所有視窗與背景程序）再重開，policy 才會載入。"
        Write-Host "  2. 開 $(if ($browserId -eq 'edge') { 'edge://policy' } else { 'chrome://policy' }) 應看到 ExtensionSettings。"
        Write-Host "  3. 實測：叫你的 AI 工具開一個被封鎖的網站 — 應該得到 attach 失敗（例如 Cannot attach to this target）；"
        Write-Host "     再開一個未封鎖的網站 — 應該正常。兩個方向都要測。"
    }
}

function Invoke-Restore {
    if (-not (Test-IsAdmin)) {
        Write-Warning "還原 HKLM policy 需要系統管理員權限。請用「以系統管理員身分執行」開 PowerShell 後重跑。"
        return
    }
    if (-not (Test-Path $Script:BackupDir)) { Write-Host "沒有任何備份（$Script:BackupDir 不存在）。"; return }
    $backups = @(Get-ChildItem $Script:BackupDir -Filter '*-ExtensionSettings-*.json' | Sort-Object Name -Descending)
    if ($backups.Count -eq 0) { Write-Host "沒有任何備份。"; return }
    $picked = Select-Multi -Title "選擇要還原的備份（還原＝把該時間點的 ExtensionSettings 原樣寫回）：" `
        -Items $backups -LabelOf { param($f) $f.Name }
    foreach ($f in $picked) {
        $payload = ConvertFrom-Json (Get-Content $f.FullName -Raw -Encoding UTF8)
        $b = $Script:Browsers[[string]$payload.browser]
        if (-not $b) { Write-Warning "備份檔 $($f.Name) 的 browser 欄位無法辨識，略過。"; continue }
        $go = Read-Host "還原 $($b.Label) 到 $($payload.timestamp) 的狀態？ (y/N)"
        if ($go -notmatch '^[Yy]') { continue }
        if ($payload.existed) {
            Set-PolicyJson -Browser $b -Json ([string]$payload.value)
            Write-Host "✓ 已還原 ExtensionSettings。" -ForegroundColor Green
        } else {
            Remove-ItemProperty -Path $b.PolicyKey -Name 'ExtensionSettings' -ErrorAction SilentlyContinue
            Write-Host "✓ 備份時原本沒有這個 policy — 已刪除 ExtensionSettings 值。" -ForegroundColor Green
        }
        Write-Host "  記得完全重啟 $($b.Label) 才會生效。"
    }
}

function Main {
    if (-not $Action) {
        Write-Host ""
        Write-Host "ai-browser-lockdown — 把 AI 瀏覽器控制擴充擋在要害網站之外" -ForegroundColor Cyan
        Write-Host "  [1] 上鎖（選銀行 → 寫入 policy → 驗證）"
        Write-Host "  [2] 查看目前狀態"
        Write-Host "  [3] 還原備份"
        $choice = Read-Host "選擇動作 (1/2/3)"
        $Action = switch ($choice.Trim()) {
            '1' { 'lock' } '2' { 'status' } '3' { 'restore' }
            default { Write-Host "無效選擇，結束。"; return }
        }
    }
    switch ($Action) {
        'lock'    { Invoke-Lock }
        'status'  { Show-Status }
        'restore' { Invoke-Restore }
    }
}

# Dot-sourcing (e.g. from tests) defines the functions without running Main.
if ($MyInvocation.InvocationName -ne '.') { Main }
