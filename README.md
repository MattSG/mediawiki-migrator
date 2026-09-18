# MediaWiki Toolkit

PowerShell 7 tools to stand up a MediaWiki instance and move content into it. Two independent tools, run in sequence rather than combined into one script, because provisioning a server and migrating wiki content are different jobs with different failure modes:

- **[`provision/`](provision/README.md)** — provisions a complete, self-hosted MediaWiki instance on a vanilla Windows machine (Apache, PHP, MySQL, MediaWiki itself, no Docker/IIS/Chocolatey). Can also tear itself down.
- **[`migrate/`](migrate/README.md)** — exports pages/files from an existing MediaWiki into an editable manifest, then imports that manifest into a blank wiki. No revision history is copied, and imports refuse non-empty targets.

## Requirements

- Windows with PowerShell 7+, run as Administrator (for `provision/`)
- Internet access to download Apache/PHP/MySQL/MediaWiki (or see `provision/README.md` for proxy/offline-mirror options)
- A `MEDIAWIKI_USERNAME`/`MEDIAWIKI_PASSWORD` bot password for `migrate/`, if the source/target wikis aren't anonymously readable/writable

## 1. Provision a wiki server

```powershell
cd provision
.\provision-mediawiki.ps1 -Action Up
```

Run with no other parameters, this is a one-shot interactive setup: it asks about internet access/proxy, install folder, ports, an existing-vs-new MySQL instance, site name, admin user, logo, Dev/Prod, HTTPS, and SSO, then shows a summary before touching anything. Two other ways to run it:

```powershell
# Unattended - pass every option you want via parameters, no prompts
.\provision-mediawiki.ps1 -Action Up -NonInteractive

# Config-driven - copy the example config, edit it, run without the wizard
Copy-Item .\provision.config.example.psd1 .\provision.config.psd1
notepad .\provision.config.psd1   # fill in site name, ports, SSO secrets, etc.
.\provision-mediawiki.ps1 -ConfigPath .\provision.config.psd1
```

`provision.config.psd1` holds every option the wizard would otherwise ask for (site name, admin user, ports, `-UseExternalDb` credentials, Entra SSO client secret, backup/log-rotation/job-runner schedules, proxy settings for offline installs). It's your own copy of the example file, gitignored so secrets never get committed. Anything passed explicitly on the command line overrides the same setting in the config file, so e.g. `-Action Status` still works against a config-driven install.

Other actions: `-Action Status` (health check), `-Action Down` (tear down; `-KeepData` to just stop services), `-Action Backup` (on-demand DB + files backup, if `-EnableBackups` was configured). See **[`provision/README.md`](provision/README.md)** for the full parameter reference, what gets installed, HTTPS/SSO/external-DB setup, and restore steps.

## 2. Migrate content into it

```powershell
cd migrate
$env:MEDIAWIKI_USERNAME = 'BotName@label'
$env:MEDIAWIKI_PASSWORD = 'bot-password'

# Export the old wiki to a manifest
.\MediaWikiMigrator.ps1 -ApiUrl https://old-wiki.example/w/api.php -Output .\export

# If exported pages link back to the old wiki, rewrite those URLs first
.\Rewrite-MediaWikiUrls.ps1 -Manifest .\export\manifest.json -TargetWikiUrl http://localhost:8080

# Edit .\export\manifest.json namespace mapping in namespace-mapper.html if needed,
# then dry-run and import into the new (empty) wiki
.\Import-MediaWikiManifest.ps1 -ApiUrl http://localhost:8080/api.php -Manifest .\export\manifest.json -WhatIf
.\Import-MediaWikiManifest.ps1 -ApiUrl http://localhost:8080/api.php -Manifest .\export\manifest.json

# Upload the file assets, then refresh MediaWiki's link cache
.\Upload-MediaWikiAssets.ps1 -ApiUrl http://localhost:8080/api.php -Manifest .\export\manifest.json
& $php maintenance/refreshLinks.php
```

Uploads are preserved under `export\assets\`; office files (`.doc`/`.docx`/etc.) are listed for manual review rather than converted. `Post-Migrate-WholesaleSupport.ps1` is an optional last step that reorganises an already-imported wiki's main-namespace pages under a target namespace. See **[`migrate/README.md`](migrate/README.md)** for what each script does and why the order matters.
