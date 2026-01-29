# Backup & Restore (SQLite now, PostgreSQL in production)

This project supports SQLite (default dev) and PostgreSQL (recommended for production).
The backend reads `DATABASE_URL` and falls back to SQLite at `backend/app.db`.

## Recommended production direction
- Use **PostgreSQL** for production.
- Keep **logical dumps** (`pg_dump`) even if you also have managed snapshots.
- Apply **3-2-1** backups: 3 copies, 2 media types, 1 offsite.

## Quick start scripts
### PostgreSQL
- Backup: `backend/backup_postgres.sh`
- Restore: `backend/restore_postgres.sh`

Windows equivalents:
- Backup: `backend/backup_postgres.ps1`
- Restore: `backend/restore_postgres.ps1`

Example:
- `export DATABASE_URL='postgresql://USER:PASS@HOST:5432/DBNAME'`
- `./backend/backup_postgres.sh`
- Restore (DANGEROUS):
  - `CONFIRM_RESTORE=YES BACKUP_FILE=/path/to/file.dump ./backend/restore_postgres.sh`
  - then `alembic upgrade head`

### SQLite (dev/local)
- Backup: `backend/backup_sqlite.sh`
- Restore: `backend/restore_sqlite.sh`

Windows equivalents:
- Backup: `backend/backup_sqlite.ps1`
- Restore: `backend/restore_sqlite.ps1`

## Storage options (pick one or combine)
### Option A: Local disk + external drive/NAS
- Store backups on local disk.
- Sync to NAS using `rsync` or `scp`.
- Enable snapshots on NAS if available.

Example sync:
- `rsync -av --delete backups/ user@nas:/backups/yasargold/`

### Option B: S3-compatible object storage (AWS S3 / Backblaze B2 / Wasabi / MinIO)
- Enable bucket **versioning**.
- If available, enable **object lock / immutability** for ransomware resistance.
- Upload backups using `aws s3 cp` or `rclone`.

Example upload:
- `aws s3 cp backups/postgres/yasargold_pg_....dump s3://YOUR-BUCKET/yasargold/`

### Option C: Managed PostgreSQL backups (RDS/Cloud SQL/etc.)
- Enable automated backups + PITR (point-in-time restore) if you need low RPO.
- Still run `pg_dump` regularly for portability and faster partial restores.

### Option D: Google Drive (recommended for Hybrid on-prem) via rclone + encryption
Best-practice for Google Drive is to use `rclone` with a `crypt` remote so backups are encrypted end-to-end before leaving the server.

#### Step 0) إعداد Google Drive المشفّر (مرة واحدة)
على السيرفر/جهاز النسخ الاحتياطي:
- شغّل `rclone config`
- أنشئ remote:
  - `gdrive` (Google Drive)
  - ثم `gdrive-crypt` (نوع `crypt`) فوق `gdrive:yasargold`

1) Install `rclone` on the backup machine/server.

2) Configure a Google Drive remote (interactive):
- `rclone config`
- Create remote name: `gdrive`

3) Configure a crypt remote on top of Google Drive:
- `rclone config`
- Create remote name: `gdrive-crypt`
- Choose `crypt`
- Set remote to: `gdrive:yasargold`
- Set strong passwords (store them securely)

4) Use the provided script to create a Postgres dump and upload it:
- Script: `backend/backup_postgres_to_gdrive.sh`
- Example:
  - `export DATABASE_URL='postgresql://USER:PASS@HOST:5432/DBNAME'`
  - `export RCLONE_REMOTE='gdrive-crypt:yasargold/postgres'`
  - `./backend/backup_postgres_to_gdrive.sh`

Windows script:
- Script: `backend/backup_postgres_to_gdrive.ps1`
- Example:
  - `pwsh -NoProfile -ExecutionPolicy Bypass -File "C:\\path\\to\\yasargold\\backend\\backup_postgres_to_gdrive.ps1" -DatabaseUrl "postgresql://USER@HOST:5432/DBNAME" -RcloneRemote "gdrive-crypt:yasargold/postgres" -RetentionDays 14 -RemoteRetentionDays 90`

Windows + Docker Postgres (no pg_dump installation on Windows):
- If Postgres runs in Docker, you can run `pg_dump` inside the container and copy the dump to Windows.
- This repo's compose defaults to Postgres container name: `yasargold-db`.
- Example:
  - `pwsh -NoProfile -ExecutionPolicy Bypass -File "C:\\path\\to\\yasargold\\backend\\backup_postgres_to_gdrive.ps1" -UseDockerPgDump -DockerContainerName "yasargold-db" -DockerDatabase "yasargold" -DockerUser "yasargold" -DockerPassword "YOUR_PASSWORD" -RcloneRemote "gdrive-crypt:yasargold/postgres"`

Parameter aliases (same script):
- `-DbUser` is an alias for `-DockerUser`
- `-DbName` is an alias for `-DockerDatabase`
- `-DbPassword` is an alias for `-DockerPassword`

#### Step 11) اختبار النسخ الاحتياطي يدويًا (مرة واحدة)
شغّل أمر اختبار (Docker `pg_dump` بدون تثبيت PostgreSQL على Windows):
- `pwsh -NoProfile -ExecutionPolicy Bypass -File "C:\yasargold\backend\backup_postgres_to_gdrive.ps1" -UseDockerPgDump -DockerContainerName "yasargold-db" -DbUser "yasargold" -DbName "yasargold" -DbPassword "YOUR_PASSWORD" -RcloneRemote "gdrive-crypt:yasargold/postgres"`

تأكد أن الملفات على Google Drive تظهر بأسماء “غير مفهومة” (هذا دليل التشفير يعمل عبر `rclone crypt`).

Notes:
- If your Postgres runs in Docker, you can still use this script by pointing `DATABASE_URL` to the Postgres service (or install PostgreSQL client tools on the host).
- Keep `.env.production` and any rclone credentials on the server only.

### Option E: Google Drive (server-side) via Service Account (works on IP-only / HTTP deployments)
This repo also supports uploading/listing/downloading backups to Google Drive **from the backend** using a Google **Service Account**.

Why this exists:
- If you run the UI from a local IP (example: `http://192.168.x.x`), browser OAuth flows can be hard/impossible to use reliably.
- Service Account mode avoids browser sign-in completely; Google Drive is accessed server-to-server.

Security note:
- This mode is **not end-to-end encrypted** by default (unlike `rclone crypt`). If you require E2EE, keep using Option D (or add encryption before upload).

Important limitation (storage quota):
- On consumer Google accounts, a Service Account can fail with: "Service Accounts do not have storage quota".
- This mode is intended for **Google Workspace** deployments using **Shared Drives** (recommended), or using Workspace **Domain-wide Delegation** to impersonate a user.
- If you don't have Google Workspace, prefer Option D (`rclone` OAuth + `crypt`) for Google Drive uploads.

#### Setup (one-time)
1) In Google Cloud Console:
- Create a Service Account.
- Enable **Google Drive API** for the project.
- Create a JSON key and download it.

2) In Google Drive:
- Create a folder dedicated to backups.
- Share that folder with the Service Account email (Editor).
- Copy the folder id from the URL and set it as `GOOGLE_DRIVE_BACKUP_FOLDER_ID`.

3) On the server (Docker Compose production recommended):
- Put the JSON key at `./secrets/google_drive_sa.json` (or any secure path).
- Ensure the backend container can read it read-only.

Required environment variables for the backend:
- `GOOGLE_DRIVE_BACKUP_FOLDER_ID` (required)
- One of:
  - `GOOGLE_DRIVE_SERVICE_ACCOUNT_FILE=/run/secrets/google_drive_sa.json`
  - `GOOGLE_DRIVE_SERVICE_ACCOUNT_JSON={...raw json...}`

Optional (Google Workspace):
- `GOOGLE_DRIVE_SHARED_DRIVE_ID` (if the folder is in a Shared Drive)
- `GOOGLE_DRIVE_IMPERSONATE_USER=user@yourdomain.com` (Domain-wide Delegation)

#### How to use
- From the app UI: go to Backup/Restore screen → "Google Drive (على السيرفر - Service Account)".
- Or via API (requires an authenticated user with `system.backup` or `system.settings`):
  - `GET /api/system/backup/drive/status`
  - `POST /api/system/backup/drive/upload`
  - `GET /api/system/backup/drive/list`
  - `GET /api/system/backup/drive/download/<file_id>`

Restore safety:
- The existing restore endpoint is still protected in production (see `ALLOW_DANGEROUS_RESETS`).

## Suggested schedule (baseline)
- Hourly: PostgreSQL dump (or every 30–60 minutes depending on RPO)
- Daily: Full dump + offsite upload
- Retention: 14 daily, 8 weekly, 12 monthly (adjust)

## Scheduling on Linux (cron) (common for on-prem servers)
Example: run hourly, using a minimal environment.

1) Ensure scripts are executable:
- `chmod +x backend/backup_postgres_to_gdrive.sh`

2) Add a crontab entry (example):
- `crontab -e`
- Add:
  - `0 * * * * cd /var/www/yasargold && /bin/bash backend/backup_postgres_to_gdrive.sh >> /var/log/yasargold-backup.log 2>&1`

Environment handling:
- Prefer `~/.pgpass` for PostgreSQL password (recommended) instead of embedding it in `DATABASE_URL`.
- You can export `DATABASE_URL` and `RCLONE_REMOTE` in the crontab, or source them from a root-readable env file.

## Scheduling on macOS (launchd)
Templates:
- `backend/ops/macos/com.yasargold.backup-postgres.plist`
- `backend/ops/macos/com.yasargold.backup-sqlite.plist`

Steps:
1. Copy the plist to `~/Library/LaunchAgents/` and edit the project path if needed (the template assumes `~/yasargold`).
2. Ensure the scripts are executable (`chmod +x backend/backup_*.sh`).
3. Set environment variables for launchd (recommended for secrets):
   - `launchctl setenv DATABASE_URL 'postgresql://USER@HOST:5432/DBNAME'`
   - Use `.pgpass` for the password (recommended) instead of embedding it.
4. Load the job:
   - `launchctl load -w ~/Library/LaunchAgents/com.yasargold.backup-postgres.plist`

Logs:
- `/tmp/yasargold-backup-postgres.out.log`
- `/tmp/yasargold-backup-postgres.err.log`

## Scheduling on Windows (Task Scheduler)
Recommended: use PowerShell scripts.

#### Step 12) جدولة النسخ الاحتياطي كل ساعة (Task Scheduler)
Task Scheduler → Create Task
- General:
  - “Run whether user is logged on or not”
  - “Hidden”
- Triggers: كل ساعة
- Actions:
  - Program: `pwsh.exe`
  - Arguments: نفس أمر الخطوة 11 (مع مساراتك وكلمة المرور)

Example action (PostgreSQL hourly):
- Program/script: `pwsh.exe` (or `powershell.exe`)
- Add arguments:
  - `-NoProfile -ExecutionPolicy Bypass -File "C:\\path\\to\\yasargold\\backend\\backup_postgres.ps1" -DatabaseUrl "postgresql://USER@HOST:5432/DBNAME" -BackupDir "C:\\yasargold\\backups\\postgres" -RetentionDays 14`

Example action (PostgreSQL hourly + upload to Google Drive via rclone crypt):
- Program/script: `pwsh.exe`
- Add arguments:
  - `-NoProfile -ExecutionPolicy Bypass -File "C:\\path\\to\\yasargold\\backend\\backup_postgres_to_gdrive.ps1" -DatabaseUrl "postgresql://USER@HOST:5432/DBNAME" -BackupDir "C:\\yasargold\\backups\\postgres" -RetentionDays 14 -RcloneRemote "gdrive-crypt:yasargold/postgres" -RemoteRetentionDays 90`

Recommended Task Scheduler settings (to avoid popups):
- General: "Run whether user is logged on or not"
- General: check "Hidden"
- Conditions: (optional) "Wake the computer to run this task"

Example action (SQLite hourly):
- Program/script: `pwsh.exe`
- Add arguments:
  - `-NoProfile -ExecutionPolicy Bypass -File "C:\\path\\to\\yasargold\\backend\\backup_sqlite.ps1" -SqliteDbPath "C:\\path\\to\\yasargold\\backend\\app.db" -BackupDir "C:\\yasargold\\backups\\sqlite" -RetentionDays 14`

Password handling (PostgreSQL):
- Prefer `.pgpass` with `pg_dump/pg_restore` so your scheduled task does not contain passwords.
- Alternatively, use a secret manager and inject credentials at runtime.

## Restore runbook (minimum)
1. Stop backend server
2. Restore DB from last known-good backup
3. Run `alembic upgrade head`
4. Start backend server
5. Verify core flows: login, invoice create, journal entry post

## Notes on secrets
- Prefer `.pgpass` or secret manager instead of embedding DB password in `DATABASE_URL`.
- Encrypt offsite backups if your storage is not already encrypted end-to-end.
