#!/bin/bash
# تشغيل سريع لإنشاء البيانات التجريبية
# Quick script to seed test vaults and payment methods

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BACKEND_DIR="$SCRIPT_DIR/backend"

echo ""
echo "════════════════════════════════════════════════════════"
echo "🏦 إنشاء الخزائن ووسائل الدفع التجريبية"
echo "   Creating Test Vaults & Payment Methods"
echo "════════════════════════════════════════════════════════"
echo ""

cd "$BACKEND_DIR"

# تحديد مسار قاعدة البيانات
export DATABASE_URL="sqlite:///../app.db"

# تحديد المترجم
if [ -x "./venv/bin/python" ]; then
    PYTHON_CMD="./venv/bin/python"
else
    PYTHON_CMD="python3"
fi

# تشغيل السكريبت
$PYTHON_CMD seed_test_vaults_and_payments.py

echo ""
echo "════════════════════════════════════════════════════════"
echo "✅ تم الانتهاء بنجاح!"
echo "════════════════════════════════════════════════════════"
echo ""
echo "📖 للمزيد من المعلومات، اقرأ:"
echo "   SEED_TEST_DATA_GUIDE.md"
echo ""
