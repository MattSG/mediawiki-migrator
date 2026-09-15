$ErrorActionPreference = 'Stop'
$script = Get-Content (Join-Path $PSScriptRoot '..\MediaWikiMigrator.ps1') -Raw
if ($script -notmatch 'Invoke-MwApi') { throw 'API client missing' }
if ($script -notmatch 'office-adjustments') { throw 'Office report missing' }
if ($script -notmatch 'allimages') { throw 'Upload enumeration missing' }
'PowerShell checks passed.'
