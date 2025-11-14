# ⚡ DEVELOPER QUICK REFERENCE - Trial Balance V2

## 🎯 What Changed?

### Backend (`/backend/routes.py`)
```python
# OLD
@api.route('/trial_balance', methods=['GET'])
def get_trial_balance():
    # No filters, simple totals only
    return jsonify({'trial_balance': [...], 'totals': {...}})

# NEW ✨
@api.route('/trial_balance', methods=['GET'])
def get_trial_balance():
    # Query params: start_date, end_date, karat_detail
    # Returns: entries + totals + balances + filters + count
    return jsonify({
        'trial_balance': [...],  # with account_id, account_number, balances
        'totals': {...},         # with balances
        'filters': {...},        # applied filters
        'count': 15              # number of entries
    })
```

### Frontend (`/frontend/lib/api_service.dart`)
```dart
// OLD
Future<Map<String, dynamic>> getTrialBalance() async {
  final response = await http.get(Uri.parse('$_baseUrl/trial_balance'));
  return json.decode(utf8.decode(response.bodyBytes));
}

// NEW ✨
Future<Map<String, dynamic>> getTrialBalance({
  String? startDate,      // YYYY-MM-DD
  String? endDate,        // YYYY-MM-DD
  bool karatDetail = false,
}) async {
  // Build query params dynamically
  final queryParams = <String, String>{};
  if (startDate != null) queryParams['start_date'] = startDate;
  if (endDate != null) queryParams['end_date'] = endDate;
  if (karatDetail) queryParams['karat_detail'] = 'true';
  
  final uri = Uri.parse('$_baseUrl/trial_balance').replace(queryParameters: queryParams);
  final response = await http.get(uri);
  return json.decode(utf8.decode(response.bodyBytes));
}
```

---

## 🔧 API Reference

### Endpoint
```
GET /api/trial_balance
```

### Query Parameters
| Parameter | Type | Required | Default | Description |
|-----------|------|----------|---------|-------------|
| `start_date` | string | No | null | Filter from date (YYYY-MM-DD) |
| `end_date` | string | No | null | Filter to date (YYYY-MM-DD) |
| `karat_detail` | boolean | No | false | Show karat breakdown vs normalized total |

### Response Structure

#### Normal Mode (`karat_detail=false`)
```json
{
  "trial_balance": [
    {
      "account_id": 1,
      "account_number": "1010",
      "account_name": "Cash",
      "gold_debit": 150.500,      // ← 21K equivalent
      "gold_credit": 100.250,
      "gold_balance": 50.250,     // ← NEW: debit - credit
      "cash_debit": 50000.00,
      "cash_credit": 30000.00,
      "cash_balance": 20000.00    // ← NEW: debit - credit
    }
  ],
  "totals": {
    "gold_debit": 150.500,
    "gold_credit": 100.250,
    "gold_balance": 50.250,       // ← NEW
    "cash_debit": 50000.00,
    "cash_credit": 30000.00,
    "cash_balance": 20000.00      // ← NEW
  },
  "filters": {
    "start_date": null,
    "end_date": null,
    "karat_detail": false
  },
  "count": 15
}
```

#### Karat Detail Mode (`karat_detail=true`)
```json
{
  "trial_balance": [
    {
      "account_id": 1,
      "account_number": "1010",
      "account_name": "Cash",
      "debit_18k": 10.500,
      "credit_18k": 5.250,
      "balance_18k": 5.250,       // ← NEW
      "debit_21k": 100.000,
      "credit_21k": 80.000,
      "balance_21k": 20.000,      // ← NEW
      "debit_22k": 20.000,
      "credit_22k": 10.000,
      "balance_22k": 10.000,      // ← NEW
      "debit_24k": 15.000,
      "credit_24k": 5.000,
      "balance_24k": 10.000,      // ← NEW
      "cash_debit": 50000.00,
      "cash_credit": 30000.00,
      "cash_balance": 20000.00    // ← NEW
    }
  ],
  "totals": {
    "debit_18k": 10.500,
    "credit_18k": 5.250,
    "balance_18k": 5.250,         // ← NEW
    "debit_21k": 100.000,
    "credit_21k": 80.000,
    "balance_21k": 20.000,        // ← NEW
    "debit_22k": 20.000,
    "credit_22k": 10.000,
    "balance_22k": 10.000,        // ← NEW
    "debit_24k": 15.000,
    "credit_24k": 5.000,
    "balance_24k": 10.000,        // ← NEW
    "cash_debit": 50000.00,
    "cash_credit": 30000.00,
    "cash_balance": 20000.00      // ← NEW
  },
  "filters": {
    "start_date": null,
    "end_date": null,
    "karat_detail": true
  },
  "count": 15
}
```

---

## 💻 Code Examples

### Backend: Testing API
```bash
# No filters (all data, normalized)
curl http://localhost:8001/api/trial_balance

# Date filter
curl "http://localhost:8001/api/trial_balance?start_date=2024-01-01&end_date=2024-12-31"

# Karat detail
curl "http://localhost:8001/api/trial_balance?karat_detail=true"

# All options
curl "http://localhost:8001/api/trial_balance?start_date=2024-01-01&end_date=2024-12-31&karat_detail=true"
```

### Frontend: Using the API
```dart
// 1. Default: All data, normalized to 21K
final allData = await ApiService().getTrialBalance();

// 2. Filter by date range
final q1Data = await ApiService().getTrialBalance(
  startDate: '2024-01-01',
  endDate: '2024-03-31',
);

// 3. Show karat breakdown
final detailedData = await ApiService().getTrialBalance(
  karatDetail: true,
);

// 4. Combination: Q1 with karat detail
final q1DetailedData = await ApiService().getTrialBalance(
  startDate: '2024-01-01',
  endDate: '2024-03-31',
  karatDetail: true,
);

// 5. Process response
final entries = List<Map<String, dynamic>>.from(allData['trial_balance']);
final totals = allData['totals'];
final count = allData['count'];

entries.forEach((entry) {
  print('${entry['account_name']}: ${entry['gold_balance']} g');
});
```

---

## 🎨 UI Components Reference

### Main Widget Tree
```
TrialBalanceScreenV2 (StatefulWidget)
├── AppBar
│   ├── Title: "ميزان المراجعة"
│   └── Actions: [Filter Button, Refresh Button]
├── Column
│   ├── _buildFilterSummary() ← Shows active filters
│   ├── _buildSummaryCards() ← Gold/Cash summary
│   └── Expanded
│       ├── _isLoading ? CircularProgressIndicator
│       ├── _errorMessage ? _buildErrorWidget()
│       ├── _entries.isEmpty ? "لا توجد بيانات"
│       └── _buildTrialBalanceTable()
│           ├── _showKaratDetail ? _buildKaratDetailTable()
│           └── _buildNormalTable()
```

### State Variables
```dart
// Filter states
DateTime? _startDate;
DateTime? _endDate;
bool _showKaratDetail = false;

// Data states
List<Map<String, dynamic>> _entries = [];
Map<String, dynamic> _totals = {};

// UI states
bool _isLoading = false;
String? _errorMessage;
```

### Key Methods
```dart
// Data loading
Future<void> _loadTrialBalance() async {
  setState(() => _isLoading = true);
  try {
    final response = await _apiService.getTrialBalance(...);
    setState(() {
      _entries = response['trial_balance'];
      _totals = response['totals'];
      _isLoading = false;
    });
  } catch (e) {
    setState(() {
      _errorMessage = 'خطأ: $e';
      _isLoading = false;
    });
  }
}

// Filter dialog
void _showFilterDialog() {
  // Uses StatefulBuilder for reactive dialog
  DateTime? tempStartDate = _startDate;
  DateTime? tempEndDate = _endDate;
  bool tempKaratDetail = _showKaratDetail;
  
  showDialog(
    builder: (context) => StatefulBuilder(
      builder: (context, setDialogState) => AlertDialog(
        // Dialog UI with date pickers and switch
        // On "Apply": setState main screen + _loadTrialBalance()
      ),
    ),
  );
}

// Clear filters
void _clearFilters() {
  setState(() {
    _startDate = null;
    _endDate = null;
    _showKaratDetail = false;
  });
  _loadTrialBalance();
}
```

---

## 🎨 Design Tokens

### Colors
```dart
// Primary
Colors.blue.shade700      // #1976D2
Colors.white              // #FFFFFF

// Semantic
Colors.green.shade700     // #2E7D32 - Positive
Colors.red.shade700       // #C62828 - Negative
Colors.grey.shade200      // #EEEEEE - Headers
Colors.grey.shade700      // #616161 - Text

// Accents
Colors.amber.shade700     // #FFA000
Colors.amber.shade50      // #FFF8E1
Colors.blue.shade50       // #E3F2FD
```

### Typography
```dart
// Headers
TextStyle(fontWeight: FontWeight.bold, fontSize: 18)

// Table headers
TextStyle(fontWeight: FontWeight.bold, color: Color(0xFF1976D2), fontSize: 14)

// Balances
TextStyle(fontWeight: FontWeight.bold, color: green/red.shade700)
```

### Icons
```dart
Icons.filter_alt          // Filters
Icons.refresh             // Refresh
Icons.savings             // Gold
Icons.account_balance_wallet // Cash
Icons.calendar_today      // Date
Icons.details             // Details
Icons.check               // Apply
Icons.clear_all           // Clear all
Icons.error_outline       // Error
```

---

## 📋 Testing Checklist

### Unit Tests (Backend)
```python
def test_trial_balance_no_filters():
    response = client.get('/api/trial_balance')
    assert response.status_code == 200
    assert 'trial_balance' in response.json
    assert 'totals' in response.json

def test_trial_balance_with_dates():
    response = client.get('/api/trial_balance?start_date=2024-01-01&end_date=2024-12-31')
    assert response.json['filters']['start_date'] == '2024-01-01'

def test_trial_balance_karat_detail():
    response = client.get('/api/trial_balance?karat_detail=true')
    data = response.json['trial_balance'][0]
    assert 'debit_18k' in data
    assert 'balance_21k' in data
```

### Widget Tests (Frontend)
```dart
testWidgets('TrialBalanceScreenV2 loads data', (tester) async {
  await tester.pumpWidget(MaterialApp(home: TrialBalanceScreenV2()));
  await tester.pump();
  
  expect(find.byType(CircularProgressIndicator), findsOneWidget);
  await tester.pumpAndSettle();
  expect(find.byType(DataTable), findsOneWidget);
});

testWidgets('Filter dialog opens and closes', (tester) async {
  await tester.pumpWidget(MaterialApp(home: TrialBalanceScreenV2()));
  await tester.pumpAndSettle();
  
  await tester.tap(find.byIcon(Icons.filter_alt));
  await tester.pumpAndSettle();
  
  expect(find.text('خيارات الفلترة'), findsOneWidget);
});
```

---

## 🐛 Common Issues & Solutions

### Issue: Date filter not applying
**Symptom:** Selected dates don't filter data  
**Cause:** StatefulBuilder not used in dialog  
**Solution:**
```dart
// ❌ WRONG
showDialog(
  builder: (context) => AlertDialog(
    // setState here won't update dialog UI
  ),
);

// ✅ CORRECT
showDialog(
  builder: (context) => StatefulBuilder(
    builder: (context, setDialogState) => AlertDialog(
      // Use setDialogState for dialog UI
      // Use setState for main screen on Apply
    ),
  ),
);
```

### Issue: Null safety errors with dates
**Symptom:** `The argument type 'DateTime?' can't be assigned to 'DateTime'`  
**Solution:**
```dart
// ❌ WRONG
DateFormat('yyyy-MM-dd').format(tempStartDate)

// ✅ CORRECT
DateFormat('yyyy-MM-dd').format(tempStartDate!)
// OR
tempStartDate != null ? DateFormat('yyyy-MM-dd').format(tempStartDate) : 'غير محدد'
```

### Issue: Table too wide on small screens
**Symptom:** Can't see all columns  
**Solution:**
```dart
// Already implemented:
SingleChildScrollView(
  scrollDirection: Axis.horizontal,
  child: DataTable(...),
)
```

---

## 🚀 Deployment Steps

1. **Backend:**
   ```bash
   cd backend
   source venv/bin/activate
   python app.py
   ```

2. **Frontend:**
   ```bash
   cd frontend
   flutter run -d macos
   ```

3. **Verify:**
   - Open "ميزان المراجعة" from sidebar
   - Test date filtering
   - Toggle karat detail
   - Check color contrast
   - Test on different screen sizes

---

## 📚 Related Files

- **Backend:** `/backend/routes.py` (line ~2927)
- **Frontend Screen:** `/frontend/lib/screens/trial_balance_screen_v2.dart`
- **API Service:** `/frontend/lib/api_service.dart`
- **Home Screen:** `/frontend/lib/screens/home_screen.dart`
- **Docs:** `/docs/trial_balance_v2.md`
- **Quick Start:** `/docs/QUICK_START_TRIAL_BALANCE.md`

---

**Last Updated:** 16 October 2025  
**Version:** 2.0.0  
**Maintainer:** Yasar Gold & Jewelry POS Team
