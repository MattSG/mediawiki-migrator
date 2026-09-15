[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string]$ApiUrl,
    [Parameter(Mandatory)] [string]$Output,
    [string]$Username = $env:MEDIAWIKI_USERNAME,
    [string]$Password = $env:MEDIAWIKI_PASSWORD
)

$ErrorActionPreference = 'Stop'
$OfficeExtensions = @('.doc','.docx','.docm','.dot','.dotx','.dotm','.xls','.xlsx','.xlsm','.xlt','.xltx','.xltm','.ppt','.pptx','.pptm','.pot','.potx','.potm','.pps','.ppsx','.ppsm')
$IgnoredNamespaceIds = @(1,2,3,4,5,7,8,9,10,11,12,13,14,15) # keep File namespace (6) so asset descriptions migrate; skip talk/system noise
$Failures = [System.Collections.Generic.List[object]]::new()
$Pages = [System.Collections.Generic.List[object]]::new()
$Files = [System.Collections.Generic.List[object]]::new()
$Office = [System.Collections.Generic.List[object]]::new()
$FileRefs = @{}

function Invoke-MwApi([hashtable]$Params, [switch]$Post) {
    $Params.format = 'json'; $Params.formatversion = 2
    if ($Post) { $data = Invoke-RestMethod -Uri $ApiUrl -Method Post -Body $Params -TimeoutSec 60 }
    else {
        $query = ($Params.GetEnumerator() | ForEach-Object { '{0}={1}' -f [uri]::EscapeDataString([string]$_.Key), [uri]::EscapeDataString([string]$_.Value) }) -join '&'
        $data = Invoke-RestMethod -Uri "$ApiUrl`?$query" -Method Get -TimeoutSec 60
    }
    if ($data.error) { throw ($data.error | ConvertTo-Json -Compress) }
    $data
}

function Convert-HtmlToMarkdown([string]$Html) {
    $text = $Html -replace '(?is)<script.*?</script>|<style.*?</style>', ''
    $text = $text -replace '(?i)<br\s*/?>', "`n" -replace '(?i)</p>|</div>|</li>|</h[1-6]>', "`n"
    $text = $text -replace '(?i)<li[^>]*>', '- ' -replace '<[^>]+>', ''
    [System.Net.WebUtility]::HtmlDecode($text).Trim()
}

function Add-Failure($Kind, $Name, $Error) { $Failures.Add([pscustomobject]@{ kind=$Kind; title=$Name; error=[string]$Error }) }

try {
    $root = [IO.Path]::GetFullPath($Output)
    if (Test-Path -LiteralPath $root) { throw "Output directory already exists: $root" }
    New-Item -ItemType Directory -Path $root, "$root\pages", "$root\rendered", "$root\assets" | Out-Null

    if ($Username -or $Password) {
        if (-not ($Username -and $Password)) { throw 'MEDIAWIKI_USERNAME and MEDIAWIKI_PASSWORD must both be set' }
        $token = (Invoke-MwApi @{ action='query'; meta='tokens'; type='login' }).query.tokens.logintoken
        $login = Invoke-MwApi @{ action='login'; lgname=$Username; lgpassword=$Password; lgtoken=$token } -Post
        if ($login.login.result -ne 'Success') { throw 'MediaWiki login failed' }
    }

    $site = Invoke-MwApi @{ action='query'; meta='siteinfo'; siprop='general|namespaces|namespacealiases' }
    $namespaceInfo = @($site.query.namespaces.psobject.Properties | Where-Object { [int]$_.Name -ge 0 -and $IgnoredNamespaceIds -notcontains [int]$_.Name } | ForEach-Object { $n=$_.Value; $label=$n.PSObject.Properties['*'].Value; [ordered]@{ id=[int]$_.Name; name=if($label){$label}elseif($n.canonical){$n.canonical}else{'Main'}; canonical=$n.canonical } })
    $namespaces = @($namespaceInfo.id)

    foreach ($ns in $namespaces) {
        $continue = @{}
        do {
            $p = @{ action='query'; list='allpages'; apnamespace=$ns; aplimit='max' } + $continue
            $batch = Invoke-MwApi $p
            foreach ($item in @($batch.query.allpages)) {
                try {
                    $page = (Invoke-MwApi @{ action='query'; pageids=$item.pageid; prop='revisions|info'; rvprop='ids|timestamp|sha1|content|contentmodel'; rvslots='main'; inprop='url' }).query.pages[0]
                    $rev = $page.revisions[0]; $slot = $rev.slots.main
                    $parsed = (Invoke-MwApi @{ action='parse'; oldid=$rev.revid; prop='text|links|images|categories' }).parse
                    $refs = @($parsed.images) + @($parsed.links | Where-Object { $_.ns -eq 6 } | ForEach-Object title) | Sort-Object -Unique
                    foreach ($ref in $refs) { $fileTitle = if ($ref -like 'File:*') { $ref } else { "File:$ref" }; if (-not $FileRefs.ContainsKey($fileTitle)) { $FileRefs[$fileTitle] = [Collections.Generic.HashSet[string]]::new() }; [void]$FileRefs[$fileTitle].Add($page.title) }
                    $renderedHtml = if ($parsed.text -is [string]) { [string]$parsed.text } else { [string]$parsed.text.'*' }
                    $record = [ordered]@{ pageid=$page.pageid; title=$page.title; ns=$page.ns; redirect=[bool]$page.redirect; url=$page.fullurl; revision=[ordered]@{ revid=$rev.revid; parentid=$rev.parentid; timestamp=$rev.timestamp; sha1=$rev.sha1; contentmodel=$slot.contentmodel }; source=$slot.content; rendered_html=$renderedHtml; categories=@($parsed.categories | ForEach-Object category); file_references=$refs }
                    $record | ConvertTo-Json -Depth 20 | Set-Content "$root\pages\$($page.pageid).json" -Encoding utf8
                    Convert-HtmlToMarkdown ([string]$parsed.text) | Set-Content "$root\rendered\$($page.pageid).md" -Encoding utf8
                    $Pages.Add([pscustomobject]$record)
                } catch { Add-Failure 'page' $item.title $_ }
            }
            if ($batch.continue) { $continue = @{}; foreach ($property in $batch.continue.psobject.Properties) { $continue[$property.Name] = $property.Value } } else { $continue = $null }
        } while ($continue)
    }

    $continue = @{}
    do {
        $p = @{ action='query'; list='allimages'; ailimit='max'; aiprop='timestamp|url|size|mime|sha1' } + $continue
        $batch = Invoke-MwApi $p
        foreach ($item in @($batch.query.allimages)) {
            try {
                $tmp = "$root\assets\.$($Files.Count).part"; Invoke-WebRequest -Uri $item.url -OutFile $tmp -TimeoutSec 120
                $hash = (Get-FileHash $tmp -Algorithm SHA1).Hash.ToLowerInvariant(); if ($item.sha1 -and $item.sha1 -ne $hash) { throw 'checksum mismatch' }
                $suffix = [IO.Path]::GetExtension($item.title).ToLowerInvariant(); $target = "$root\assets\$hash$suffix"; Move-Item $tmp $target -Force
                $isOffice = $OfficeExtensions -contains $suffix -or $item.mime -like 'application/msword*' -or $item.mime -like 'application/vnd.ms-*'
                $record = [pscustomobject]@{ title=$item.title; path=[IO.Path]::GetRelativePath($root,$target); url=$item.url; mime=$item.mime; size=$item.size; sha1=$hash; timestamp=$item.timestamp; referenced_by=@($FileRefs[$item.title]); needs_adjustment=$isOffice }
                $Files.Add($record)
                if ($isOffice) { $Office.Add($record) }
            } catch { Add-Failure 'file' $item.title $_ }
        }
        if ($batch.continue) { $continue = @{}; foreach ($property in $batch.continue.psobject.Properties) { $continue[$property.Name] = $property.Value } } else { $continue = $null }
    } while ($continue)

    $officeLines = @('# Office files requiring adjustment','') + @($Office | ForEach-Object { $refs = @($_.referenced_by) -join ', '; if (-not $refs) { $refs = 'none' }; '- **{0}** ({1}): `{2}`; referenced by: {3}' -f $_.title,$_.mime,$_.path,$refs })
    $officeLines | Set-Content "$root\office-adjustments.md" -Encoding utf8
    $manifest = [ordered]@{ version=1; api_url=$ApiUrl; namespaces=$namespaceInfo; namespace_mapping=@(); pages=$Pages; files=$Files; office_adjustments=$Office; counts=[ordered]@{ pages=$Pages.Count; files=$Files.Count; office=$Office.Count }; failures=$Failures; complete=($Failures.Count -eq 0) }
    $manifest | ConvertTo-Json -Depth 30 | Set-Content "$root\manifest.json" -Encoding utf8
    if ($Failures.Count) { exit 1 }; exit 0
} catch {
    Add-Failure 'export' '' $_
    if (Test-Path "$root") { @{ complete=$false; failures=$Failures } | ConvertTo-Json -Depth 10 | Set-Content "$root\manifest.json" -Encoding utf8 }
    exit 1
}

