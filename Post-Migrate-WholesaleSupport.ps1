[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)][string]$ApiUrl,
    [Parameter(Mandatory)][string]$Username,
    [Parameter(Mandatory)][string]$Password,
    [Parameter(Mandatory)][string]$LocalSettingsPath,
    [string]$PhpPath = 'php.exe',
    [switch]$WhatIf
)

$ErrorActionPreference = 'Stop'
if ($PSVersionTable.PSVersion.Major -lt 7) { throw 'Run Post-Migrate-WholesaleSupport.ps1 with PowerShell 7.' }
if (-not (Test-Path -LiteralPath $LocalSettingsPath)) { throw "LocalSettings.php not found: $LocalSettingsPath" }

$marker = '// --- Wholesale Support namespace (managed by migrator) ---'
$settings = Get-Content -LiteralPath $LocalSettingsPath -Raw
if (-not $WhatIf -and $settings -notmatch [regex]::Escape($marker)) {
    Add-Content -LiteralPath $LocalSettingsPath -Value @"

$marker
`$wgExtraNamespaces[100] = 'Wholesale Support';
`$wgExtraNamespaces[101] = 'Wholesale Support_talk';
`$wgNamespaceProtection[101] = [ 'edit' => [ 'sysop' ] ];
"@ -Encoding utf8
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

$all = @(); $continue = @{}
do {
    $q = @{ action='query'; list='allpages'; apnamespace=0; aplimit='max' }
    foreach ($k in $continue.Keys) { $q[$k] = $continue[$k] }
    $r = Invoke-WikiApi $q
    $all += @($r.query.allpages)
    $continue = if ($r.continue) { @{} + $r.continue } else { @{} }
} while ($continue.Count)

$map = @{}
foreach ($p in $all) { $map[$p.title] = "Wholesale Support:$($p.title)" }
function Rewrite-Links([string]$Text) {
    [regex]::Replace($Text, '\[\[([^\[\]|#]+)(#[^\]|]*)?(\|[^\]]*)?\]', {
        param($m)
        $target = $m.Groups[1].Value.Trim()
        if ($map.ContainsKey($target)) { "[[$($map[$target])$($m.Groups[2].Value)$($m.Groups[3].Value)]]" }
        else { $m.Value }
    })
}

$moveToken = $csrf
foreach ($p in $all) {
    $destination = $map[$p.title]
    if ($PSCmdlet.ShouldProcess($p.title, "Move to $destination")) {
        $r = Invoke-WikiApi @{ action='move'; from=$p.title; to=$destination; reason='Organise knowledge pages under Wholesale Support'; token=$moveToken; noredirect='1'; movetalk='0' } -Post
        if ($r.move.result -ne 'Success') { throw "Move failed for '$($p.title)'." }
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

$rootText = "== Wholesale Support ==`n`n[[Wholesale Support:Main Page|Wholesale Support knowledge base]]`n"
if ($PSCmdlet.ShouldProcess('Main Page', 'Create namespace index')) {
    Invoke-WikiApi @{ action='edit'; title='Main Page'; text=$rootText; token=$csrf; summary='Create knowledge namespace index' } -Post | Out-Null
}
Write-Host "Moved and processed $($all.Count) namespace-0 pages."

if (-not $WhatIf) {
    & $PhpPath (Join-Path (Split-Path $LocalSettingsPath) 'maintenance\refreshLinks.php')
    if ($LASTEXITCODE -ne 0) { throw 'refreshLinks.php failed.' }
}
Write-Host 'Wholesale Support post-migration complete.'
