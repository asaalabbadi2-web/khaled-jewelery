#!/bin/bash

# Script to safely run Python commands with venv activated
# سكريبت لتشغيل أوامر Python بشكل آمن مع تفعيل البيئة الافتراضية

set -e  # Exit on error

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
cd "$SCRIPT_DIR"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${YELLOW}  Yasar Gold - Python Safe Runner${NC}"
echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""

# Check if venv exists
if [ ! -d "venv" ]; then
    echo -e "${RED}❌ خطأ: مجلد venv غير موجود!${NC}"
    echo -e "${RED}❌ Error: venv directory not found!${NC}"
    echo ""
    echo -e "لإنشاء البيئة الافتراضية، استخدم:"
    echo -e "To create virtual environment, use:"
    echo ""
    echo -e "    ${GREEN}python3 -m venv venv${NC}"
    echo ""
    exit 1
fi

# Check if command provided
if [ $# -eq 0 ]; then
    echo -e "${YELLOW}الاستخدام / Usage:${NC}"
    echo ""
    echo -e "  ${GREEN}./run_python.sh <python_command>${NC}"
    echo ""
    echo -e "أمثلة / Examples:"
    echo -e "  ${GREEN}./run_python.sh app.py${NC}"
    echo -e "  ${GREEN}./run_python.sh test_invoices.py${NC}"
    echo -e "  ${GREEN}./run_python.sh -m pip install requests${NC}"
    echo ""
    exit 1
fi

# Activate venv
echo -e "${GREEN}✓ تفعيل البيئة الافتراضية...${NC}"
echo -e "${GREEN}✓ Activating virtual environment...${NC}"
source venv/bin/activate

# Check if activated
if [ -z "$VIRTUAL_ENV" ]; then
    echo -e "${RED}❌ فشل تفعيل البيئة الافتراضية!${NC}"
    echo -e "${RED}❌ Failed to activate virtual environment!${NC}"
    exit 1
fi

echo -e "${GREEN}✓ تم التفعيل بنجاح!${NC}"
echo -e "${GREEN}✓ Successfully activated!${NC}"
echo ""

# Run the command
echo -e "${YELLOW}تشغيل الأمر / Running command:${NC}"
echo -e "  ${GREEN}python $@${NC}"
echo ""
echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""

python "$@"

EXIT_CODE=$?

echo ""
echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

if [ $EXIT_CODE -eq 0 ]; then
    echo -e "${GREEN}✅ اكتمل بنجاح!${NC}"
    echo -e "${GREEN}✅ Completed successfully!${NC}"
else
    echo -e "${RED}❌ فشل بخطأ: $EXIT_CODE${NC}"
    echo -e "${RED}❌ Failed with error: $EXIT_CODE${NC}"
fi

echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

exit $EXIT_CODE
