[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)][string]$ApiUrl,
    [Parameter(Mandatory)][string]$Username,
    [Parameter(Mandatory)][string]$Password,
    [Parameter(Mandatory)][string]$LocalSettingsPath,
    [string]$PhpPath = 'php.exe',
    [string]$ApacheServiceName = 'MediaWikiApache',
    [string]$TargetWikiUrl = 'http://localhost:8090'
)

$ErrorActionPreference = 'Stop'
if ($PSVersionTable.PSVersion.Major -lt 7) { throw 'Run Post-Migrate-WholesaleSupport.ps1 with PowerShell 7.' }
if (-not (Test-Path -LiteralPath $LocalSettingsPath)) { throw "LocalSettings.php not found: $LocalSettingsPath" }

$marker = '// --- Wholesale Support namespace (managed by migrator) ---'
$settings = Get-Content -LiteralPath $LocalSettingsPath -Raw
if (-not $WhatIfPreference -and $settings -notmatch [regex]::Escape($marker)) {
    Add-Content -LiteralPath $LocalSettingsPath -Value @"

$marker
`$wgExtraNamespaces[100] = 'Wholesale_Support';
"@ -Encoding utf8
    $service = Get-Service -Name $ApacheServiceName -ErrorAction SilentlyContinue
    if ($service) { Restart-Service -Name $ApacheServiceName -Force; Start-Sleep -Seconds 2 }
}

$session = New-Object Microsoft.PowerShell.Commands.WebRequestSession
function Invoke-WikiApi([hashtable]$Body, [switch]$Post) {
    $Body['format'] = 'json'
    $r = if ($Post) { Invoke-RestMethod $ApiUrl -Method Post -Body $Body -WebSession $session }
        else { Invoke-RestMethod "${ApiUrl}?$(( $Body.GetEnumerator() | ForEach-Object { '{0}={1}' -f $_.Key,[uri]::EscapeDataString([string]$_.Value) }) -join '&')" -WebSession $session }
    if ($r.error) { throw "MediaWiki API error: $($r.error.code) $($r.error.info)" }
    return $r
}

$loginToken = (Invoke-WikiApi @{ action='query'; meta='tokens'; type='login' }).query.tokens.logintoken
$login = Invoke-WikiApi @{ action='login'; lgname=$Username; lgpassword=$Password; lgtoken=$loginToken } -Post
if ($login.login.result -ne 'Success') { throw 'MediaWiki login failed.' }
$csrf = (Invoke-WikiApi @{ action='query'; meta='tokens'; type='csrf' }).query.tokens.csrftoken
$registered = Invoke-WikiApi @{ action='query'; meta='siteinfo'; siprop='namespaces' }
if (-not $registered.query.namespaces.'100') { throw 'Wholesale Support namespace is not registered by the target wiki.' }

$all = @(); $continue = @{}
do {
    $q = @{ action='query'; list='allpages'; apnamespace=0; aplimit='max' }
    foreach ($k in $continue.Keys) { $q[$k] = $continue[$k] }
    $r = Invoke-WikiApi $q
    $all += @($r.query.allpages)
    $continue = if ($r.continue) { @{} + $r.continue } else { @{} }
} while ($continue.Count)

$map = @{}
$used = @{}
foreach ($p in $all) {
    $parent = if ($p.title -match '/') { $p.title.Substring(0, $p.title.LastIndexOf('/')) } else { 'Main Page' }
    $leaf = if ($p.title -match '/') { $p.title.Substring($p.title.LastIndexOf('/') + 1) } else { $p.title }
    $base = if ($p.title -eq 'Main Page') { 'Wholesale_Support:Main Page' } else { "Wholesale_Support:$parent/$leaf" }
    $key = ($base -replace '_',' ').ToLowerInvariant()
    $used[$key] = 1 + ($used[$key] ?? 0)
    $map[$p.title] = if ($used[$key] -eq 1) { $base } else { "$base ($($used[$key]))" }
}
function Rewrite-Links([string]$Text) {
    [regex]::Replace($Text, '\[\[\s*([^\[\]|#]+?)\s*(#[^\]|]*)?(?:\|([^\]]*))?\s*\]\]', {
        param($m)
        $target = $m.Groups[1].Value.Trim()
        if ($map.ContainsKey($target)) { $label=$m.Groups[3].Value.Trim(); if (-not $label) { $label=$target }; "[[$($map[$target])$($m.Groups[2].Value)|$label]]" }
        else { $m.Value }
    })
}
$oldMain = $all | Where-Object { $_.title -eq 'Main Page' } | Select-Object -First 1

$moveToken = $csrf
foreach ($p in $all) {
    $destination = $map[$p.title]
    if ($PSCmdlet.ShouldProcess($p.title, "Move to $destination")) {
        $r = Invoke-WikiApi @{ action='move'; from=$p.title; to=$destination; reason='Organise knowledge pages under Wholesale Support'; token=$moveToken; noredirect='1'; movetalk='0' } -Post
        if (-not $r.move) { throw "Move failed for '$($p.title)': $($r|ConvertTo-Json -Compress)" }
    }
}

# Re-read each moved page, rewrite only known namespace-0 links, and preserve its text.
foreach ($p in $all) {
    $destination = $map[$p.title]
    if ($PSCmdlet.ShouldProcess($destination, 'Rewrite internal links')) {
        $q = Invoke-WikiApi @{ action='query'; prop='revisions'; rvprop='content'; rvslots='main'; titles=$destination }
        $page = $q.query.pages.PSObject.Properties.Value
        $text = $page.revisions[0].slots.main.'*'
        $newText = Rewrite-Links $text
        if ($newText -ne $text) { Invoke-WikiApi @{ action='edit'; title=$destination; text=$newText; token=$csrf; summary='Update links after namespace migration' } -Post | Out-Null }
    }
}

$rootText = "== Wholesale Support ==`n`n[[Wholesale_Support:Main Page|Wholesale Support knowledge base]]`n"
if ($PSCmdlet.ShouldProcess('Main Page', 'Create namespace index')) {
    Invoke-WikiApi @{ action='edit'; title='Main Page'; text=$rootText; token=$csrf; summary='Create knowledge namespace index' } -Post | Out-Null
}
if ($oldMain -and $PSCmdlet.ShouldProcess('Wholesale Support:Main Page', 'Restore migrated main page')) {
    $namespaceMain = Rewrite-Links $oldMain.source
    Invoke-WikiApi @{ action='edit'; title='Wholesale Support:Main Page'; text=$namespaceMain; token=$csrf; summary='Restore migrated main page in Wholesale Support namespace' } -Post | Out-Null
}
if ($PSCmdlet.ShouldProcess('Main Page', 'Purge parser cache')) {
    Invoke-WikiApi @{ action='purge'; titles='Main Page' } -Post | Out-Null
}
Write-Host "Moved and processed $($all.Count) namespace-0 pages."

if (-not $WhatIfPreference) {
    $smwRebuild = Join-Path (Split-Path $LocalSettingsPath) 'extensions\SemanticMediaWiki\maintenance\rebuildData.php'
    if (Test-Path -LiteralPath $smwRebuild) {
        & $PhpPath $smwRebuild
        if ($LASTEXITCODE -ne 0) { throw 'SemanticMediaWiki rebuildData.php failed.' }
    }
    & $PhpPath (Join-Path (Split-Path $LocalSettingsPath) 'maintenance\refreshLinks.php')
    if ($LASTEXITCODE -ne 0) { throw 'refreshLinks.php failed.' }
    & $PhpPath (Join-Path (Split-Path $LocalSettingsPath) 'maintenance\rebuildFileCache.php') --all --overwrite --server $TargetWikiUrl
    if ($LASTEXITCODE -ne 0) { throw 'rebuildFileCache.php failed.' }
    & $PhpPath (Join-Path (Split-Path $LocalSettingsPath) 'maintenance\runJobs.php') --maxjobs 100
    if ($LASTEXITCODE -ne 0) { throw 'runJobs.php failed.' }
}
Write-Host 'Wholesale Support post-migration complete.'
