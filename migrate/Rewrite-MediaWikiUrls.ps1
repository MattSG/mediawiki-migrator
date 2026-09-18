[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Manifest,
    [string]$TargetWikiUrl = 'http://localhost:8090',
    [string]$SourceWikiUrl = 'http://enr-hvh-dwdb-10:81/wiki',
    [string]$OutputManifest
)
$ErrorActionPreference='Stop'
$m=Get-Content -LiteralPath $Manifest -Raw|ConvertFrom-Json
$target=$TargetWikiUrl.TrimEnd('/')
$source=$SourceWikiUrl.TrimEnd('/')
$pages=0;$replacements=0
foreach($p in @($m.pages)){
    $old=[string]$p.source
$pattern=[regex]::Escape($source) -replace '/wiki$','/+wiki'
$new=[regex]::Replace($old,$pattern,$target,[Text.RegularExpressions.RegexOptions]::IgnoreCase)
    $new=[regex]::Replace($new,'(?<!\[)(https?://[^\s<>\]]+)',{param($m)$url=$m.Value.TrimEnd('.,;');try{$u=[uri]$url;$label=($u.Segments|Select-Object -Last 1).Trim('/');if(-not $label){$label=$u.Host};$label=($label -replace '[_-]+',' ' -replace '\.[a-z0-9]+$','');$label=(Get-Culture).TextInfo.ToTitleCase($label.ToLowerInvariant());"[$url $label]"}catch{$m.Value}})
    if($new -ne $old){$p.source=$new;$pages++;$replacements += ([regex]::Matches($old,$pattern,'IgnoreCase')).Count}
}
$m.api_url="$target/api.php"
$out=if($OutputManifest){$OutputManifest}else{Join-Path (Split-Path $Manifest) 'manifest-target-url.json'}
$m|ConvertTo-Json -Depth 30|Set-Content -LiteralPath $out -Encoding utf8
Write-Host "Rewrote $replacements URL occurrences across $pages pages."
Write-Host "Wrote $out"
