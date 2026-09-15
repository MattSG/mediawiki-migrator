[CmdletBinding()]param([Parameter(Mandatory)][string]$ApiUrl,[Parameter(Mandatory)][string]$Manifest,[Parameter(Mandatory)][string]$Username,[Parameter(Mandatory)][string]$Password)
$ErrorActionPreference='Stop';$m=Get-Content $Manifest -Raw|ConvertFrom-Json;$s=New-Object Microsoft.PowerShell.Commands.WebRequestSession
function Api([hashtable]$p){$p.format='json';Invoke-RestMethod "${ApiUrl}?$(( $p.GetEnumerator()|%{'{0}={1}'-f $_.Key,[uri]::EscapeDataString([string]$_.Value)})-join'&')" -WebSession $s}
$lt=(Api @{action='query';meta='tokens';type='login'}).query.tokens.logintoken;$login=Invoke-RestMethod $ApiUrl -Method Post -Body @{action='login';lgname=$Username;lgpassword=$Password;lgtoken=$lt;format='json'} -WebSession $s;if($login.login.result -ne 'Success'){throw 'MediaWiki login failed'}
$token=(Api @{action='query';meta='tokens';type='csrf'}).query.tokens.csrftoken;$root=Split-Path $Manifest -Parent;$i=0
foreach($f in @($m.files)){$path=Join-Path $root $f.path;if(-not(Test-Path $path)){throw "Missing asset: $path"};$form=@{action='upload';filename=($f.title -replace '^File:','');token=$token;format='json';ignorewarnings='1';comment='Migrated from read-only source export'};$r=Invoke-RestMethod $ApiUrl -Method Post -Form ($form+@{file=Get-Item $path}) -WebSession $s;if($r.upload.result -notin 'Success','Warning' -and $r.error.code -ne 'fileexists-no-change'){throw "Upload failed for $($f.title): $($r|ConvertTo-Json -Compress)"};$i++;if(($i%25)-eq 0){Write-Host "Uploaded $i/$($m.files.Count)"}}
Write-Host "Uploaded $i/$($m.files.Count) assets."
# Files arrive after page parsing; purge those pages so MediaWiki resolves the
# newly available files instead of serving cached broken-media HTML.
$i=0;foreach($p in @($m.pages)){Api @{action='purge';titles=$p.title;token=$token};$i++;if(($i%100)-eq 0){Write-Host "Purged $i/$($m.pages.Count) pages"}}
Write-Host "Purged $i/$($m.pages.Count) pages."
