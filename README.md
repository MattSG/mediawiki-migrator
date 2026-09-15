# MediaWiki Migrator

PowerShell 7 tools for exporting a MediaWiki into an editable manifest and importing it into a blank wiki. No revision history is copied, and imports refuse non-empty targets.

```powershell
$env:MEDIAWIKI_USERNAME = 'BotName@label'
$env:MEDIAWIKI_PASSWORD = 'bot-password'
.\MediaWikiMigrator.ps1 -ApiUrl https://wiki.example/w/api.php -Output .\export
.\Import-MediaWikiManifest.ps1 -ApiUrl https://new-wiki.example/w/api.php -Manifest .\export\manifest.json -WhatIf
```

Credentials are optional for anonymously readable wikis. Use `namespace-mapper.html` to edit the exported mapping before import. Uploads are preserved under `assets/`; office files are listed for review.

Post-migration, upload the assets after importing the pages. `Upload-MediaWikiAssets.ps1` purges every imported page after the upload so cached broken-file links are reparsed. Then refresh the local links table:

```powershell
& $php maintenance/refreshLinks.php
```

To organise an already-imported local wiki under the knowledge namespace:

```powershell
.Post-Migrate-WholesaleSupport.ps1 -ApiUrl http://localhost:8090/api.php `
  -Username LocalAdmin -Password $password `
  -LocalSettingsPath C:\wiki\stack\www\LocalSettings.php
```

This moves namespace-0 pages only, keeps files/templates/system namespaces unchanged, removes old-title redirects, rewrites known internal links, and makes the root Main Page link to `Wholesale Support:Main Page`.
