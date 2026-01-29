from __future__ import annotations

import io
import json
import os
from dataclasses import dataclass
from typing import Any

from google.oauth2 import service_account
from googleapiclient.discovery import build
from googleapiclient.http import MediaIoBaseDownload, MediaInMemoryUpload


_DRIVE_SCOPES = ["https://www.googleapis.com/auth/drive.file"]


def _impersonate_user() -> str | None:
    """Optional Google Workspace domain-wide delegation.

    If set, Drive calls will be made on behalf of this user (uses their Drive quota).
    Requires the service account to have Domain-wide Delegation enabled and authorized.
    """

    subject = (os.getenv("GOOGLE_DRIVE_IMPERSONATE_USER") or "").strip()
    return subject or None


def _shared_drive_id() -> str | None:
    """Optional Google Workspace Shared Drive id.

    When set, list queries will use corpora=drive and includeItemsFromAllDrives.
    """

    drive_id = (os.getenv("GOOGLE_DRIVE_SHARED_DRIVE_ID") or "").strip()
    return drive_id or None


@dataclass(frozen=True)
class DriveFileInfo:
    id: str
    name: str | None = None
    mimeType: str | None = None
    createdTime: str | None = None
    size: int | None = None


class DriveServiceAccountError(RuntimeError):
    pass


def _load_sa_info() -> dict[str, Any]:
    raw = (os.getenv("GOOGLE_DRIVE_SERVICE_ACCOUNT_JSON") or "").strip()
    if raw:
        try:
            return json.loads(raw)
        except Exception as exc:
            raise DriveServiceAccountError(
                "Invalid GOOGLE_DRIVE_SERVICE_ACCOUNT_JSON"
            ) from exc

    path = (os.getenv("GOOGLE_DRIVE_SERVICE_ACCOUNT_FILE") or "").strip()
    if path:
        path = os.path.abspath(os.path.expanduser(path))
        if not os.path.exists(path):
            raise DriveServiceAccountError(
                f"GOOGLE_DRIVE_SERVICE_ACCOUNT_FILE not found: {path}"
            )
        try:
            with open(path, "r", encoding="utf-8") as f:
                return json.load(f)
        except Exception as exc:
            raise DriveServiceAccountError(
                f"Failed reading service account JSON: {path}"
            ) from exc

    raise DriveServiceAccountError(
        "Missing service account credentials. Set GOOGLE_DRIVE_SERVICE_ACCOUNT_FILE or GOOGLE_DRIVE_SERVICE_ACCOUNT_JSON."
    )


def _folder_id() -> str:
    folder_id = (os.getenv("GOOGLE_DRIVE_BACKUP_FOLDER_ID") or "").strip()
    if not folder_id:
        raise DriveServiceAccountError(
            "Missing GOOGLE_DRIVE_BACKUP_FOLDER_ID. Create a folder in Drive, share it with the service account email, and set this ID."
        )
    return folder_id


def _drive_client():
    info = _load_sa_info()
    creds = service_account.Credentials.from_service_account_info(
        info, scopes=_DRIVE_SCOPES
    )

    subject = _impersonate_user()
    if subject:
        # Note: this only works for Google Workspace with domain-wide delegation.
        creds = creds.with_subject(subject)

    # cache_discovery=False avoids writing to disk and speeds startup.
    return build("drive", "v3", credentials=creds, cache_discovery=False)


def list_backups(page_size: int = 20) -> list[DriveFileInfo]:
    folder = _folder_id()
    svc = _drive_client()

    shared_drive = _shared_drive_id()

    q = f"'{folder}' in parents and trashed=false"
    list_kwargs: dict[str, Any] = {
        "q": q,
        "pageSize": max(1, min(int(page_size), 100)),
        "orderBy": "createdTime desc",
        "fields": "files(id,name,mimeType,createdTime,size)",
        "supportsAllDrives": True,
        "includeItemsFromAllDrives": True,
    }
    if shared_drive:
        list_kwargs.update({
            "corpora": "drive",
            "driveId": shared_drive,
        })

    res = svc.files().list(**list_kwargs).execute()

    files = res.get("files") or []
    out: list[DriveFileInfo] = []
    for f in files:
        out.append(
            DriveFileInfo(
                id=str(f.get("id")),
                name=f.get("name"),
                mimeType=f.get("mimeType"),
                createdTime=f.get("createdTime"),
                size=int(f["size"]) if f.get("size") is not None else None,
            )
        )
    return out


def upload_bytes(
    *, filename: str, content: bytes, mime_type: str = "application/octet-stream"
) -> DriveFileInfo:
    folder = _folder_id()
    svc = _drive_client()

    media = MediaInMemoryUpload(content, mimetype=mime_type, resumable=False)
    meta = {"name": filename, "parents": [folder], "mimeType": mime_type}

    created = (
        svc.files()
        .create(
            body=meta,
            media_body=media,
            fields="id,name,mimeType,createdTime,size",
            supportsAllDrives=True,
        )
        .execute()
    )

    return DriveFileInfo(
        id=str(created.get("id")),
        name=created.get("name"),
        mimeType=created.get("mimeType"),
        createdTime=created.get("createdTime"),
        size=int(created["size"]) if created.get("size") is not None else None,
    )


def download_bytes(file_id: str) -> tuple[bytes, DriveFileInfo]:
    svc = _drive_client()

    meta = (
        svc.files()
        .get(
            fileId=file_id,
            fields="id,name,mimeType,createdTime,size",
            supportsAllDrives=True,
        )
        .execute()
    )
    info = DriveFileInfo(
        id=str(meta.get("id")),
        name=meta.get("name"),
        mimeType=meta.get("mimeType"),
        createdTime=meta.get("createdTime"),
        size=int(meta["size"]) if meta.get("size") is not None else None,
    )

    request = svc.files().get_media(fileId=file_id, supportsAllDrives=True)
    buf = io.BytesIO()
    downloader = MediaIoBaseDownload(buf, request)
    done = False
    while not done:
        _, done = downloader.next_chunk()

    return buf.getvalue(), info
