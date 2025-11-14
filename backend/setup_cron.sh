#!/bin/bash
# سكريبت لإعداد Cron Job للقيود الدورية

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CRON_CMD="0 1 * * * cd $SCRIPT_DIR && source venv/bin/activate && python process_recurring_journals.py >> /tmp/recurring_journals.log 2>&1"

echo "🔧 إعداد Cron Job للقيود الدورية..."
echo ""
echo "الأمر المقترح للإضافة:"
echo "$CRON_CMD"
echo ""
echo "لإضافة Cron Job، قم بتشغيل:"
echo "  crontab -e"
echo ""
echo "ثم أضف السطر التالي:"
echo "$CRON_CMD"
echo ""
echo "💡 سيتم تشغيل المعالجة التلقائية يومياً الساعة 1:00 صباحاً"
