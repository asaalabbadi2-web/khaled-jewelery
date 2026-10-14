"""خدمات مساندة لبروفايلات عمليات الوزن والتكاليف.

A profile's expense account is a role -- weight_profile_<support_account_key>
(cleaning, melting, logistics, valuation_diff) -- mapped by the owner in
«الربط المحاسبي»; its weight side is that account's linked twin. They were
account numbers in config (5110/7510, 5120/7520, 5130/7530, 3600/7600) that
production never had: every profile answered «الحساب المالي للبروفايل غير
متوفر». The owner, 14 Oct 2026: the screen stays, its accounts are roles
(CHART-002 step 4c2). Optional: a role left unmapped refuses only its profile.
"""

from typing import Dict, Optional

from accounting.mappings import DEFAULT_MAPPING_OPERATION_TYPE, get_account_id_for_mapping
from config import WEIGHT_EXECUTION_PROFILES
from models import Account, db


def profile_role(support_account_key: str) -> str:
    return f'weight_profile_{support_account_key}'


def _resolve_accounts(support_account_key: str):
    account_id = get_account_id_for_mapping(DEFAULT_MAPPING_OPERATION_TYPE, profile_role(support_account_key or ''))
    financial = db.session.get(Account, account_id) if account_id else None
    memo = db.session.get(Account, financial.memo_account_id) if financial and financial.memo_account_id else None
    return financial, memo


def list_weight_profiles():
    """إرجاع قائمة مبسطة للبروفايلات المتاحة مع معلومات العرض."""
    profiles = []
    for key, profile in WEIGHT_EXECUTION_PROFILES.items():
        profiles.append(
            {
                'key': key,
                'display_name': profile.get('display_name', key.title()),
                'requires_cash_amount': profile.get('requires_cash_amount', False),
                'requires_weight': profile.get('requires_weight', False),
                'price_strategy': profile.get('price_strategy', 'manual'),
                'execution_type': profile.get('execution_type', 'expense'),
            }
        )
    return profiles


def resolve_weight_profile(profile_key: str) -> Dict:
    profile = WEIGHT_EXECUTION_PROFILES.get(profile_key)
    if not profile:
        raise ValueError(f"Weight execution profile '{profile_key}' غير معرّف")

    financial_account, memo_account = _resolve_accounts(profile.get('support_account_key'))

    return {
        'key': profile_key,
        'role': profile_role(profile.get('support_account_key') or ''),
        'meta': profile,
        'financial_account': financial_account,
        'memo_account': memo_account,
    }


def ensure_profile_accounts_ready(profile_key: Optional[str] = None) -> bool:
    """تأكد من توفر الحسابات الخاصة ببروفايل معين أو بجميع البروفايلات."""
    if profile_key:
        profile = resolve_weight_profile(profile_key)
        return bool(profile['financial_account'] and profile['memo_account'])

    for key in WEIGHT_EXECUTION_PROFILES.keys():
        profile = resolve_weight_profile(key)
        if not profile['financial_account'] or not profile['memo_account']:
            return False
    return True
