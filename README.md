# MediaWiki Toolkit

PowerShell 7 tools to stand up a MediaWiki instance and move content into it: `provision/` builds a self-hosted MediaWiki server on Windows from scratch (Apache, PHP, MySQL, the wiki itself); `migrate/` exports pages/files from one MediaWiki and imports them into another. Kept as two separate tools, run in sequence, rather than one entangled script.

```powershell
# 1. Provision a wiki server (see provision/README.md for full options)
.\provision\provision-mediawiki.ps1 -Action Up

# 2. Migrate content into it (see migrate/README.md for full options)
.\migrate\MediaWikiMigrator.ps1 -ApiUrl https://old-wiki.example/w/api.php -Output .\export
.\migrate\Import-MediaWikiManifest.ps1 -ApiUrl http://localhost:8080/api.php -Manifest .\export\manifest.json
```

See [`provision/README.md`](provision/README.md) and [`migrate/README.md`](migrate/README.md) for details.
