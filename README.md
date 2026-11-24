# Snipe-IT inventory agent (Windows and macOS)

A small PowerShell sensor that runs on each Windows laptop/PC and writes its hardware
and installed software into the matching asset in Snipe-IT
(`https://hrms.wisilica.com/itasset`). No server-side software to install; it only
uses the Snipe-IT REST API.

## What it reports

Written into custom fields on the asset, matched by BIOS serial (Dell service tag /
Lenovo serial):

| Field | Example |
|---|---|
| Hostname | WIS-LAP-014 |
| CPU | 11th Gen Intel(R) Core(TM) i5-1135G7 @ 2.40GHz |
| RAM (GB) | 16 |
| Storage | NVMe SSD 512 GB (PC SN530 NVMe WDC 512GB) |
| Disk Free C: (GB) | 212 |
| Volumes | C: 212 GB free of 476 GB |
| Operating System | Windows 11 Pro 23H2 |
| OS Build | 22631.4460 |
| IP Address / MAC Address (Agent) | 192.168.1.54 / 3C:52:82:... |
| Last Logged-in User | WISILICA\abhiram |
| Software Count | 87 |
| Installed Software | one app per line, `Name (version)` |
| Last Inventory | 2026-11-24 11:42 |

Only fields that changed are sent, so the Recent Activity feed is not flooded.
Hardware, OS and software changes are pushed on the next run. Fast-changing values
(free space, IP, logged-in user) are refreshed together with those, or with the weekly
heartbeat. `Last Inventory` is refreshed at least every 7 days (`HeartbeatDays`), so you
can sort by it to find machines whose agent has stopped reporting.

## Files

| File | Where it runs | Purpose |
|---|---|---|
| `Setup-SnipeITFields.ps1` | Once, by an admin, any PC | Creates the custom fields and adds them to the laptop/desktop model fieldsets. Dry run by default. |
| `SnipeIT-Agent.ps1` | Every laptop (as SYSTEM) | Collects and pushes the inventory. `-DryRun` to just look. |
| `Install-Agent.ps1` | Every laptop (as admin) | Copies the agent to `C:\ProgramData\SnipeITAgent`, writes config, locks the folder, registers the scheduled task. |
| `Uninstall-Agent.ps1` | Laptop | Removes the task and folder. |
| `Sync-SnipeITModels.ps1` | Admin, after rollout | Moves assets to correct models based on the reported hardware model. Dry run by default. |
| `macos/` | Macs | macOS agent, installer, uninstaller. |
| `config.example.json` | | Template for mass rollout. |

## Test on the dev clone first

Everything below should be done first against the dev clone (Proxmox CT 110
`snipeitdev`, reachable at `http://192.168.1.35`), then repeated on production once it
looks right. Wherever the steps say `https://hrms.wisilica.com/itasset`, use
`http://192.168.1.35` instead. On dev, Apache serves Snipe-IT from the web root
(`/var/www/snipe-it/public`), so there is no `/itasset` path.

Before using the clone, on `snipeitdev`:

1. **Point it at itself.** The clone still has `APP_URL=https://hrms.wisilica.com/itasset`
   in `/var/www/snipe-it/.env`. Change it to `http://192.168.1.35`, then
   `sudo -u www-data php artisan config:clear`. Otherwise the web UI redirects you to
   production.
   Production runs on https, so also set `APP_FORCE_TLS=false` (and `SECURE_COOKIES=false`).
   Otherwise every page redirects to `https://192.168.1.35/...`, which the dev Apache
   doesn't serve, and the browser shows "refused to connect".
2. **Stop it emailing real people.** Set `MAIL_MAILER=log` (older versions:
   `MAIL_DRIVER=log`) in `.env`, so checkout/expiry alerts from the copy don't reach staff.
3. **Disable its scheduled jobs** if the clone has the Snipe-IT cron entry
   (`crontab -l` for the web user), or alerts and backups will run twice.
4. API tokens are copied with the database, so production tokens also work on dev.
   Make the agent user and token on dev; recreate them on production later.

For testing on dev, install on one laptop with `-SnipeUrl http://192.168.1.35`.
When you move to production, rerun `Install-Agent.ps1` with the production URL (it
overwrites the config in place).

## Setup, step by step

### 1. Create a low-privilege API user for the agents

The token sits on every laptop, so it must not be your admin token.

1. In Snipe-IT: **People → Create New**, e.g. `inventory-agent`, no login needed
   beyond API use. Give it a strong random password.
2. Permissions: **Assets → View** and **Assets → Edit** only. Everything else *Deny*.
3. Log in as that user once (or impersonate) → **profile menu → Manage API Keys →
   Create New Token**. Keep it in your password manager.

Snipe-IT tokens can't be limited to "only custom fields", so a local admin on a laptop
who digs out the token could edit asset records. The folder is restricted to
SYSTEM/Administrators to keep normal users out. If a token leaks, revoke it and push a
new `config.json`.

### 2. Create the custom fields (one time)

From any PC with PowerShell, using an **admin** token (prompted, not echoed):

```powershell
.\Setup-SnipeITFields.ps1 -SnipeUrl https://hrms.wisilica.com/itasset            # dry run: shows the plan
.\Setup-SnipeITFields.ps1 -SnipeUrl https://hrms.wisilica.com/itasset -Apply     # makes the changes
```

It targets models whose **category** matches `Laptop|Desktop|PC|Computer|Workstation`
(change with `-CategoryPattern`). Models that already have a fieldset get the new fields
added to it; models without one get a new `Inventory Agent` fieldset. Nothing is
deleted. Snipe-IT only stores custom fields that are in the asset model's fieldset, so
this step is required.

Take a database backup first (`php artisan snipeit:backup` on the server) since it changes
fieldsets.

### 3. Try it on one laptop

```powershell
# collection only, no API call, no install
powershell -ExecutionPolicy Bypass -File .\SnipeIT-Agent.ps1 -DryRun
```

Then install it on that one laptop from an elevated PowerShell:

```powershell
.\Install-Agent.ps1 -SnipeUrl https://hrms.wisilica.com/itasset   # prompts for the agent token
Get-Content C:\ProgramData\SnipeITAgent\agent.log -Tail 20
```

Open the asset in Snipe-IT and check the new fields.

### 4. Roll out to everyone

Prepare `config.json` from `config.example.json` with the agent token and put it, with
the scripts, on a share only Domain Computers / admins can read. Then pick one:

- **GPO** (domain-joined): Computer Configuration → Policies → Windows Settings →
  Scripts → Startup → PowerShell: `Install-Agent.ps1 -ConfigFile \\server\share\config.json`.
- **Intune**: package the folder as a Win32 app, install command
  `powershell -ExecutionPolicy Bypass -File Install-Agent.ps1 -ConfigFile .\config.json`,
  detection rule: file `C:\ProgramData\SnipeITAgent\SnipeIT-Agent.ps1` exists.
- **Manually / RMM**: run the install command above on each machine.

The task runs as SYSTEM 10 minutes after boot and daily at 11:00 (+ up to 2 hours random
delay, catches up if the laptop was off).

## macOS agent

`macos/snipeit-agent.js` fills the same fields on Macs (MacBook, Mac mini), matched by
the Mac's serial number (Apple menu → About This Mac). It's written in JavaScript for
Automation, which is built into macOS, so nothing else needs installing. It runs as a
root launchd daemon at boot and daily at 11:00, with up to 2 hours of random delay.

```bash
# copy the macos folder to the Mac, then in Terminal:
cd ~/Downloads/snipeit-agent-main/macos
sudo osascript -l JavaScript snipeit-agent.js --dry-run --config /tmp/none.json   # collect only, shows the data
sudo ./install-mac.sh --url http://192.168.1.35                                     # asks for the agent token
sudo tail -20 "/Library/Application Support/SnipeITAgent/agent.log"
```

On Macs the fields hold:
- **CPU**: the chip, for example "Apple M1 Pro".
- **Storage**: the internal SSD in decimal GB, as Apple reports it.
- **Disk Free C: (GB)**: free space on the startup disk. The field name is shared with
  Windows.
- **Installed Software**: everything in `/Applications` and `~/Applications`.

To remove it, run `sudo ./uninstall-mac.sh`.

## Clean up asset models (after the agents have reported)

Each agent writes the device's real make and model into the **Hardware Model** field,
for example "Dell Inspiron 15 3567", "Lenovo ideapad 330-15IKB" or "Apple Mac mini M4".
Custom-built PCs report their motherboard, for example "ASUS H170M-PLUS".
`Sync-SnipeITModels.ps1` uses that field to fix models like "Insprion" (83 assets),
"IDEAPAD 330" / "IDEAIPAD 330", or "x":

```powershell
.\Sync-SnipeITModels.ps1 -SnipeUrl http://192.168.1.35                       # plan only, writes model-cleanup-plan.csv
.\Sync-SnipeITModels.ps1 -SnipeUrl http://192.168.1.35 -Apply -DeleteEmpty   # move assets, delete emptied models
```

What it does:
- **Moves each asset to the right model.** It reuses an existing model with the same
  name, ignoring case and spaces. If none exists, it creates one with the right
  manufacturer and the Inventory Agent fieldset.
- **Leaves assets without agent data alone.** You can run it again as more machines
  report.
- **Deletes models this run emptied,** but only with `-DeleteEmpty`. Snipe-IT refuses to
  delete a model that still has assets, so nothing in use is lost.
- **Writes a CSV.** It lists every planned move, and after `-Apply` the result of each
  one.

Rerun `Setup-SnipeITFields.ps1 -Apply` once first, so the new Hardware Model field is
created. Try it on dev, check the result, then run it on production.

## Machines that don't match

The agent matches on serial. If it logs `No Snipe-IT asset found for serial ...`:

- Make sure the asset's **Serial** in Snipe-IT equals the BIOS serial
  (`(Get-CimInstance Win32_BIOS).SerialNumber`).
- For white-box PCs with a junk BIOS serial, install with `-AssetTag WICDC/LAP/014` to
  match by asset tag instead.

To list the laptops that never reported: in Snipe-IT's asset list, show the
`Last Inventory` column and sort, or use the custom report.

## Troubleshooting

- Log: `C:\ProgramData\SnipeITAgent\agent.log`; last collected data:
  `C:\ProgramData\SnipeITAgent\inventory.json`.
- `Snipe-IT returned an error ... required`: some other custom field in that model's
  fieldset is marked *required* and empty on that asset; Snipe-IT refuses to save until
  it is filled or made optional.
- `fields are not in this asset model's fieldset`: rerun step 2 (new model added since).
- `401 Unauthorized`: token wrong or revoked. `403`: the agent user lacks Assets View/Edit.
- Software list: comes from the Windows "Apps & features" registry entries (machine-wide
  plus currently logged-in users). Microsoft Store apps and portable apps are not listed.
  Windows updates and runtime noise are filtered out (edit `SoftwareExclude` in
  `config.json` to tune).

## Why this approach

| Option | Pros | Cons |
|---|---|---|
| **This script** (chosen) | Nothing new to host, uses Snipe-IT directly, easy to read and change, data shows on the asset page | Software list is text, not a searchable license table |
| GLPI Agent / OCS Inventory + sync to Snipe-IT | Rich inventory (software as records, Linux/macOS agents, monitors, peripherals) | Needs a second server (GLPI/OCS) plus a sync job to maintain |
| Intune / RMM inventory + sync | Already collected if you use Intune | Needs Graph API sync script; only for Intune-enrolled devices |

If you later need per-software reporting (e.g. "which laptops have AutoCAD"), the next
step would be mapping selected apps to Snipe-IT **Licenses** and checking out seats
automatically from the same agent data.
