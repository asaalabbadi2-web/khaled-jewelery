# Yasar Gold & Jewelry POS System

## Project Architecture
This is a **bilingual (Arabic/English) gold jewelry POS system** with a Flask REST API backend and Flutter frontend. The system manages gold transactions by **weight-based calculations** rather than monetary values.

### Core Components
- **Backend (`backend/`)**: Flask REST API with SQLAlchemy, PostgreSQL/SQLite support
- **Frontend (`frontend/`)**: Flutter mobile app with Arabic UI and bilingual support
- **Gold Price Integration**: Automated gold price fetching and manual updates

### Key Architectural Patterns

#### Weight-Based Business Logic
- **ALL business calculations use weight (grams), not currency**
- Gold items stored with karat (عيار) and converted to main karat (21) via `weight_in_main_karat()`
- Manufacturing wages converted to gold equivalent via `wage_in_gold()` method
- See `backend/models.py` Item class and `backend/config.py` for MAIN_KARAT constant

#### Data Models (`backend/models.py`)
- **Customer**: Full address, ID details, birth_date support
- **Item**: Weight-based with karat conversion methods
- **Invoice/InvoiceItem**: Support for buy/sell transaction types
- **JournalEntry/JournalEntryLine**: Models for double-entry accounting for cash and gold.
- **GoldPrice**: Auto-fetched price data with manual override capability

#### API Architecture (`backend/routes.py`)
- RESTful endpoints: `/customers`, `/items`, `/invoices`, `/journal-entries`, `/gold_price`
- **Robust Journal Entry Handling**: The `/api/journal-entries` endpoint includes server-side logic to automatically balance minor floating-point discrepancies in gold weights, ensuring data integrity.
- CORS enabled for cross-origin Flutter requests
- Weight normalization via `backend/utils.py`

## Development Workflows

### Backend Development
```bash
cd backend
source venv/bin/activate  # ALWAYS activate venv first
python app.py            # Runs on port 8001
```

### Frontend Development  
```bash
cd frontend
flutter run             # Check baseUrl in api_service.dart points to backend
```
### Frontend UI/UX Notes
- **Journal Entry Screen**: Features client-side validation to ensure all entry lines with data have an account selected before submission. It provides immediate user feedback via SnackBars for validation errors or unbalanced entries.
- **Summary Cards**: Professional summary cards are used to display key information, such as in the journal entry screen.

### Database Operations
- Uses Alembic for migrations (`alembic/versions/`)
- Models auto-create tables on first run
- SQLite default, PostgreSQL production-ready

## Project Conventions

### Arabic UI Standards
- Cairo font family configured in `pubspec.yaml`
- RTL layout support throughout Flutter app
- Bilingual toggle in main app (`_MyAppState._toggleLocale()`)
- Gold-themed color scheme (Color(0xFFFFD700))

### API Communication
- **Base URL**: `http://localhost:8001` (see `frontend/lib/api_service.dart` line 69)
- Flutter HTTP client with JSON serialization
- Error handling patterns in ApiService class

### Code Organization
- **Backend routes**: Grouped by resource in `routes.py`
- **Flutter screens**: One file per screen in `lib/screens/`
- **Business logic**: Weight conversion methods in model classes
- **Configuration**: Centralized in `backend/config.py`

### Integration Points
- Gold price fetching: `backend/gold_price.py` with external API
- Database: SQLAlchemy ORM with relationship cascades
- Cross-platform: Flutter supports iOS/Android/Web/Desktop

<!--
## Execution Guidelines
PROGRESS TRACKING:
- If any tools are available to manage the above todo list, use it to track progress through this checklist.
- After completing each step, mark it complete and add a summary.
- Read current todo list status before starting each new step.

COMMUNICATION RULES:
- Avoid verbose explanations or printing full command outputs.
- If a step is skipped, state that briefly (e.g. "No extensions needed").
- Do not explain project structure unless asked.
- Keep explanations concise and focused.

DEVELOPMENT RULES:
- Use '.' as the working directory unless user specifies otherwise.
- Avoid adding media or external links unless explicitly requested.
- Use placeholders only with a note that they should be replaced.
- Use VS Code API tool only for VS Code extension projects.
- Once the project is created, it is already opened in Visual Studio Code—do not suggest commands to open this project in Visual Studio again.
- If the project setup information has additional rules, follow them strictly.

FOLDER CREATION RULES:
- Always use the current directory as the project root.
- If you are running any terminal commands, use the '.' argument to ensure that the current working directory is used ALWAYS.
- Do not create a new folder unless the user explicitly requests it besides a .vscode folder for a tasks.json file.
- If any of the scaffolding commands mention that the folder name is not correct, let the user know to create a new folder with the correct name and then reopen it again in vscode.

EXTENSION INSTALLATION RULES:
- Only install extension specified by the get_project_setup_info tool. DO NOT INSTALL any other extensions.

PROJECT CONTENT RULES:
- If the user has not specified project details, assume they want a "Hello World" project as a starting point.
- Avoid adding links of any type (URLs, files, folders, etc.) or integrations that are not explicitly required.
- Avoid generating images, videos, or any other media files unless explicitly requested.
- If you need to use any media assets as placeholders, let the user know that these are placeholders and should be replaced with the actual assets later.
- Ensure all generated components serve a clear purpose within the user's requested workflow.
- If a feature is assumed but not confirmed, prompt the user for clarification before including it.
- If you are working on a VS Code extension, use the VS Code API tool with a query to find relevant VS Code API references and samples related to that query.

TASK COMPLETION RULES:
- Your task is complete when:
  - Project is successfully scaffolded and compiled without errors
  - copilot-instructions.md file in the .github directory exists in the project
  - README.md file exists and is up to date
  - User is provided with clear instructions to debug/launch the project

Before starting a new task in the above plan, update progress in the plan.
-->
- Work through each checklist item systematically.
- Keep communication concise and focused.
- Follow development best practices.
