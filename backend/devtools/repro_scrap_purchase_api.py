import json
import os
import sys
from datetime import datetime
from urllib import request


def _post_json(url: str, payload: dict):
    data = json.dumps(payload, ensure_ascii=False).encode("utf-8")
    req = request.Request(url, data=data, headers={"Content-Type": "application/json"})
    return request.urlopen(req)


def main() -> int:
    base = os.environ.get("BASE_URL", "http://127.0.0.1:8001/api").rstrip("/")

    # Create a minimal customer (fallback to 1 if endpoint not available)
    cust_id = 1
    try:
        resp = _post_json(
            f"{base}/customers",
            {
                "name": "عميل اختبار شراء كسر",
                "phone": "0500000000",
                "address": "test",
                "id_number": "1234567890",
                "id_issue_place": "test",
                "birth_date": "1990-01-01",
            },
        )
        body = json.loads(resp.read().decode("utf-8"))
        if isinstance(body, dict) and body.get("id"):
            cust_id = int(body["id"])
    except Exception:
        pass

    # Pick a cash safe if available
    safe_box_id = None
    try:
        resp = request.urlopen(f"{base}/safe-boxes")
        boxes = json.loads(resp.read().decode("utf-8"))
        for box in boxes or []:
            safe_type = str(box.get("safe_type") or box.get("type") or "").lower()
            if safe_type == "cash" and box.get("is_active", True):
                safe_box_id = box.get("id")
                break
    except Exception:
        safe_box_id = None

    invoice_payload = {
        "invoice_type": "شراء من عميل",
        "gold_type": "scrap",
        "date": datetime.now().date().isoformat(),
        "customer_id": cust_id,
        "safe_box_id": safe_box_id,
        "items": [
            {
                "item_id": None,
                "name": "حلق",
                "karat": 21,
                # mimic screen behavior: weight derived from total/price
                "weight": 10.015,
                "standing_weight": 10.00,
                "stones_weight": 0.0,
                "quantity": 1,
                "wage": 0.0,
                "direct_purchase_price_per_gram": 499.24,
                "cost": 5000.0,
                "profit": 0.0,
                "net": 5000.0,
                "tax": 0.0,
                "price": 5000.0,
            }
        ],
        "total_tax": 0.0,
        "amount_paid": 5000.0,
        "total": 5000.0,
    }

    try:
        resp = _post_json(f"{base}/invoices", invoice_payload)
        body_text = resp.read().decode("utf-8")
        print(resp.status)
        print(body_text)
        return 0
    except Exception as exc:
        # Try to extract API error body if present
        try:
            body = exc.read().decode("utf-8")  # type: ignore[attr-defined]
            print(getattr(exc, "code", "ERR"))
            print(body)
        except Exception:
            print(f"Request failed: {exc}")
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
