# dev

One console tool for local Laravel work on Windows with Laragon: run project services, git and GitHub (works offline), backups, project zips and patches.

Requires Windows PowerShell 5.1, Laragon, and git. Optional: gh (GitHub CLI), 7-Zip, cloudflared, ngrok, stripe CLI.

## Run

    dev.bat

Tray icon: `Tray.vbs`. Commands: `dev.bat start|stop|git|github|backup|restore|cleanup|zip|patches|snaps|sync|clone|ip|settings|tray [project]`

Keys: arrows and Enter, Backspace or Left = back, Right = forward, Esc = exit.

## Config

On first run `config.json` is created from `config.example.json`. Edit it or use Settings.

| key | meaning |
| --- | --- |
| laragonDir | Laragon folder |
| wwwDir | projects folder (empty = `laragonDir\www`) |
| backupDir | backups folder |
| githubBackupDir | GitHub bundle backups (empty = `backupDir\GitHub`) |
| snapshotsDir, restoredDir | snapshots and exported versions (empty = inside `backupDir`) |
| desktopDir | where project zips and patches are read and written (empty = Desktop) |
| dataDir | state and log (empty = `%LOCALAPPDATA%\Dev`) |
| githubUser, editor, domainSuffix, ports, mysql* | as named |

Per project options go in `projects\<folder name>.json` (see `projects\example.json`).

## Notes

- Sites are served by Laragon (`<folder>.test`). Nothing runs `php -S` or `artisan serve`.
- Queue names are read from `app/Jobs` (`onQueue`). A worker runs for each queue; stuck workers are restarted when the queue driver is `database`.
- Git works offline. Pushes and new repositories are queued and sent the next time the tool starts with internet.
- Backup file names: `yyyy-MM-dd_HH-mm-ss_<project>.zip` and `<db>_backup_yyyy-MM-dd_HH-mm-ss.sql`.
