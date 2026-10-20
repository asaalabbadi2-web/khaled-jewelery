"""Statement Verification — QR signing, token generation, and payload building for account statements."""
from __future__ import annotations

import base64
import hashlib
import hmac
import json
import os
from typing import TYPE_CHECKING
from urllib.parse import quote

if TYPE_CHECKING:
    from models import Account

from core.settings import _get_settings_singleton


def _qr_hmac_secret() -> str | None:
    """Return HMAC secret used to sign statement QR payloads (server-side only)."""
    try:
        secret = (os.environ.get('QR_HMAC_SECRET') or '').strip()
        if secret:
            return secret
    except Exception:
        return None
    return None


def _qr_canonical_json(payload: dict) -> str:
    return json.dumps(
        payload,
        ensure_ascii=False,
        sort_keys=True,
        separators=(',', ':'),
    )


def _sign_qr_payload(payload: dict) -> str | None:
    secret = _qr_hmac_secret()
    if not secret:
        return None

    msg = _qr_canonical_json(payload).encode('utf-8')
    digest = hmac.new(secret.encode('utf-8'), msg, hashlib.sha256).digest()
    return base64.urlsafe_b64encode(digest).decode('ascii').rstrip('=')


def _public_base_url() -> str | None:
    """Base URL to embed in QR codes.

    IMPORTANT: `request.host_url` becomes `http://localhost:...` when the Flutter app
    runs on the same machine — won't work when scanning from a phone. Use explicit
    PUBLIC_BASE_URL (e.g. http://192.168.1.10:8001).
    """
    try:
        raw = (os.environ.get('PUBLIC_BASE_URL') or '').strip()
    except Exception:
        raw = ''

    if not raw:
        return None

    raw = raw.rstrip('/')
    if raw.startswith('http://') or raw.startswith('https://'):
        return raw
    return f'http://{raw}'


def _b64url_encode_utf8(value: str) -> str:
    return base64.urlsafe_b64encode((value or '').encode('utf-8')).decode('ascii').rstrip('=')


def _b64url_decode_utf8(value: str) -> str:
    raw = (value or '').strip()
    if not raw:
        return ''
    pad = '=' * ((4 - (len(raw) % 4)) % 4)
    return base64.urlsafe_b64decode((raw + pad).encode('ascii')).decode('utf-8')


def _build_qr_verify_token(*, signed_payload: dict | None, signature: str | None) -> str | None:
    if not isinstance(signed_payload, dict) or not signed_payload:
        return None
    sig = (signature or '').strip()
    if not sig:
        return None
    blob = _b64url_encode_utf8(_qr_canonical_json(signed_payload))
    return f'{blob}.{sig}'


def _build_statement_verify_url(token: str | None) -> str | None:
    base_url = _public_base_url()
    tok = (token or '').strip()
    if not base_url or not tok:
        return None
    return f'{base_url}/api/verify/statement?t={quote(tok)}'


def _verify_statement_token(token: str) -> dict | None:
    """Return signed payload if token is valid, otherwise None."""
    tok = (token or '').strip()
    if not tok or '.' not in tok:
        return None

    try:
        blob, sig = tok.rsplit('.', 1)
    except Exception:
        return None

    blob = (blob or '').strip()
    sig = (sig or '').strip()
    if not blob or not sig:
        return None

    try:
        payload_json = _b64url_decode_utf8(blob)
        payload = json.loads(payload_json)
    except Exception:
        return None

    if not isinstance(payload, dict) or not payload:
        return None

    expected = _sign_qr_payload(payload)
    if not expected:
        return None
    try:
        if not hmac.compare_digest(expected, sig):
            return None
    except Exception:
        return None

    return payload


def _build_statement_qr_signed_payload(
    *,
    account: 'Account',
    main_karat: int,
    closing_gold_g: float,
    closing_cash: float,
    issued_at: str,
    is_merged: bool,
) -> dict:
    settings = None
    try:
        settings = _get_settings_singleton(create_if_missing=False)
    except Exception:
        settings = None

    company_name = (getattr(settings, 'company_name', None) or '').strip() if settings else ''
    vat = (getattr(settings, 'company_tax_number', None) or '').strip() if settings else ''
    cr = (getattr(settings, 'company_cr_number', None) or '').strip() if settings else ''

    return {
        'org': company_name,
        'vat': vat,
        'cr': cr,
        'issued_at': issued_at,
        'account_id': int(getattr(account, 'id', 0) or 0),
        'account_number': str(getattr(account, 'account_number', '') or ''),
        'account_name': str(getattr(account, 'name', '') or ''),
        'main_karat': int(main_karat),
        'closing_gold_g': float(round(float(closing_gold_g or 0.0), 3)),
        'closing_cash': float(round(float(closing_cash or 0.0), 2)),
        'is_merged': bool(is_merged),
    }
