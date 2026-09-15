# MediaWiki Migrator

PowerShell 7 tools for exporting a MediaWiki into an editable manifest and importing it into a blank wiki. No revision history is copied, and imports refuse non-empty targets.

```powershell
$env:MEDIAWIKI_USERNAME = 'BotName@label'
$env:MEDIAWIKI_PASSWORD = 'bot-password'
.\MediaWikiMigrator.ps1 -ApiUrl https://wiki.example/w/api.php -Output .\export
.\Import-MediaWikiManifest.ps1 -ApiUrl https://new-wiki.example/w/api.php -Manifest .\export\manifest.json -WhatIf
```

Credentials are optional for anonymously readable wikis. Use `namespace-mapper.html` to edit the exported mapping before import. Uploads are preserved under `assets/`; office files are listed for review.
