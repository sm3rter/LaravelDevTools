# dev

A console tool for local Laravel work on Windows with Laragon. It runs project services, handles git (offline too), makes backups, and zips projects.

## Requirements

- Windows with PowerShell 5.1 (built in)
- Laragon
- git
- Optional: GitHub CLI (`gh`), 7-Zip, cloudflared, ngrok, Stripe CLI

## Install

1. Copy this folder to `C:\dev`.
2. Add `C:\dev` to your `PATH`.
3. Open a new terminal and run `dev`.

On first run `config.json` is created from `config.example.json`. Set your paths there or in **Settings**.

## Keys

| key | action |
| --- | --- |
| Up / Down, PgUp / PgDn, Home / End | move |
| Enter | select |
| Backspace or Left | back |
| Right | forward |
| Esc | exit |

## Menus

**Projects** lists every folder in your Laragon `www`. Open one to:

- Start everything the project needs, open the site, open the editor
- Start, restart, or stop queue workers
- Start or stop a Cloudflare tunnel, Reverb, the scheduler, the Stripe webhook, ngrok
- Run commands: artisan, composer, npm build
- Use Git, Backup, Zip project, Apply patches

Sites are served by Laragon at `<folder>.test`. Nothing runs `php -S` or `artisan serve`.

**Git** works on any project. Main actions: Changes, Commit, Push, Pull, Experiments, Versions, History tree, Branches, Stash, Tags. Everything else is under **More**.

- **Experiments**: try something on a restore point, then merge it back or discard it.
- **Versions**: independent lines of work (branches). Create one from now, a commit, a tag, or another version. Switch between them or open one in a separate folder to work on two at once.
- **History tree**: all branches and merges drawn as a graph.

**Backup** zips a project (and its database) into `backupDir`. You pick the project each time. Restore and clean up old backups from the same menu.

**Zip project** writes a zip of the project to your desktop folder. **Apply patches** unpacks patch zips over a project.

**Snapshots** keeps a local version history for any folder, separate from the project's own git.

**Sync** appears when git work is waiting for internet.

**Tools**: local IP, backup name, folder tree, Laragon, log.

## Offline git

Commits, branches, and merges work without internet. Pushes and new repositories are queued and sent the next time `dev` starts with internet. Turn this off with `autoSyncOnStart`.

## Queue workers

Queue names are read from `app/Jobs`: every `->onQueue('name')` or `public $queue = 'name'`. A job with no queue runs on `default`. One worker runs per queue.

**Restart workers** runs `php artisan queue:restart`. Workers finish their current job and reload.

When the queue driver is `database`, a stuck worker is restarted automatically: a job running longer than `workerStuckMinutes` (default 15), or jobs waiting more than 3 minutes with none running.

## Commands

    dev                    main menu
    dev start [project]    project menu
    dev stop [project|all]
    dev git [project]
    dev backup [project]
    dev restore
    dev cleanup
    dev zip [project]
    dev patches [project]
    dev snaps
    dev sync
    dev clone
    dev ip
    dev settings
    dev tray

`Tray.vbs` starts a tray icon with shortcuts to the same actions.

## Config

`config.json` keys:

| key | meaning |
| --- | --- |
| laragonDir | Laragon folder |
| wwwDir | projects folder (empty: `laragonDir\www`) |
| backupDir | backups folder |
| githubBackupDir | repository bundle backups (empty: `backupDir\GitHub`) |
| snapshotsDir, restoredDir | snapshots and exported versions (empty: inside `backupDir`) |
| desktopDir | where project zips are written and patches are read (empty: Desktop) |
| dataDir | state and log folder (empty: `%LOCALAPPDATA%\Dev`) |
| githubUser | your GitHub user name |
| editor | editor command, for example `code` |
| domainSuffix, webPort, mysqlPort, mysqlUser, mysqlPassword | Laragon settings |
| autoSyncOnStart | send queued git work at start |
| backupExcludeNames, backupExcludePaths | skipped when backing up |

Per-project options go in `projects\<folder name>.json`. See `projects\example.json`:

| key | meaning |
| --- | --- |
| tunnel | start a Cloudflare tunnel with the project |
| reverb, reverbTunnel | start Reverb, and a tunnel for it |
| schedule | start the scheduler |
| stripe | webhook path for `stripe listen` |
| ngrok | `{ "domain": "name.ngrok-free.dev" }` |
| build | run `npm run build` first |
| openEditor, stopWithEditor | open the editor, and stop everything when it closes |
| workerStuckMinutes | how long a job may run before its worker is restarted |
| host, url, https | override the site address |

## Backup files

- Project: `yyyy-MM-dd_HH-mm-ss_<project>.zip`
- Database: `<db>_backup_yyyy-MM-dd_HH-mm-ss.sql`

## Extras

`github.bat` and `password.bat` are standalone and not part of the dev menus.

- `github` opens the GitHub repository manager in `tools\github`.
- `password` generates a 32 character password and copies it to the clipboard.

## Tunnels

The tunnel sends requests to Laragon with the site's own host name. While a tunnel is on, `APP_URL` is set to the tunnel address and restored when it stops. If generated links still show `.test`, add this to `AppServiceProvider::boot()`:

    URL::forceRootUrl(config('app.url'));
