# Posting System Technical Documentation

## System Overview

A comprehensive posting management system with JWT authentication, role-based permissions, and complete audit logging.

## Architecture

### Backend Structure
```
backend/
├── posting_routes.py       # Main posting endpoints
├── auth_routes.py          # JWT authentication
├── models.py               # SQLAlchemy models (User, AuditLog, etc.)
└── utils.py                # Helper functions
```

### Frontend Structure
```
frontend/lib/
├── api_service.dart                      # API client with JWT
├── providers/auth_provider.dart          # Auth state management
└── screens/posting_management_screen.dart # Posting UI
```

## Authentication System

### JWT Token Generation
Location: `backend/auth_routes.py`

```python
def generate_token(user):
    """Generate JWT token for authenticated user"""
    payload = {
        'user_id': user.id,
        'username': user.username,
        'is_admin': user.is_admin,
        'exp': datetime.utcnow() + timedelta(days=1),  # 24 hours
        'iat': datetime.utcnow()
    }
    return jwt.encode(payload, app.config['SECRET_KEY'], algorithm='HS256')
```

### Token Validation
Location: `backend/posting_routes.py`

```python
@posting_bp.before_request
def verify_token():
    """Verify JWT token on every request"""
    token = request.headers.get('Authorization', '').replace('Bearer ', '')
    
    if not token:
        return jsonify({
            'success': False,
            'error': 'authentication_required',
            'message': 'يجب تسجيل الدخول أولاً'
        }), 401
    
    try:
        payload = jwt.decode(token, app.config['SECRET_KEY'], algorithms=['HS256'])
        user = User.query.get(payload['user_id'])
        g.current_user = user
    except jwt.ExpiredSignatureError:
        return jsonify({
            'success': False,
            'error': 'token_expired',
            'message': 'انتهت صلاحية الجلسة'
        }), 401
```

### Flutter Token Storage
Location: `frontend/lib/providers/auth_provider.dart`

```dart
// Save token on login
final prefs = await SharedPreferences.getInstance();
await prefs.setString('jwt_token', token);

// Retrieve token for API calls
final token = prefs.getString('jwt_token');
```

## Permission System

### Permission Decorator
Location: `backend/posting_routes.py`

```python
def require_permission(permission_code):
    """Decorator to check user permissions"""
    def decorator(f):
        @wraps(f)
        def decorated_function(*args, **kwargs):
            if not g.current_user:
                return jsonify({
                    'success': False,
                    'message': 'يجب تسجيل الدخول'
                }), 401
            
            # Admins have all permissions
            if g.current_user.is_admin:
                return f(*args, **kwargs)
            
            # Check specific permission
            if not g.current_user.has_permission(permission_code):
                return jsonify({
                    'success': False,
                    'message': 'ليس لديك صلاحية الوصول'
                }), 403
            
            return f(*args, **kwargs)
        return decorated_function
    return decorator
```

### Usage Example
```python
@posting_bp.route('/invoices/post/<int:invoice_id>', methods=['POST'])
@require_permission('invoice.post')
def post_invoice_endpoint(invoice_id):
    # Only users with 'invoice.post' permission can access
    pass
```

## Audit Logging System

### AuditLog Model
Location: `backend/models.py`

```python
class AuditLog(db.Model):
    __tablename__ = 'audit_logs'
    
    id = db.Column(db.Integer, primary_key=True)
    user_id = db.Column(db.Integer, db.ForeignKey('users.id'))
    action = db.Column(db.String(100))  # 'invoice_post', 'entry_unpost', etc.
    entity_type = db.Column(db.String(50))  # 'invoice', 'journal_entry'
    entity_id = db.Column(db.Integer)  # ID of posted/unposted entity
    details = db.Column(db.Text)  # JSON string with operation details
    ip_address = db.Column(db.String(50))
    user_agent = db.Column(db.String(255))
    timestamp = db.Column(db.DateTime, default=datetime.utcnow)
```

### Logging Operations
Location: `backend/posting_routes.py`

```python
# After successful posting
AuditLog.log_action(
    user_id=g.current_user.id,
    action='invoice_post',
    entity_type='invoice',
    entity_id=invoice.id,
    details=json.dumps({
        'invoice_number': invoice.invoice_number,
        'customer_name': invoice.customer.name_ar,
        'total_amount': str(invoice.total_amount)
    }),
    ip_address=request.remote_addr,
    user_agent=request.headers.get('User-Agent', 'Unknown')
)
db.session.commit()  # Commit both posting and audit log
```

**CRITICAL**: Always commit AFTER calling `log_action()`:
```python
# ❌ WRONG
db.session.commit()
AuditLog.log_action(...)  # Won't be saved!

# ✅ CORRECT
AuditLog.log_action(...)
db.session.commit()  # Saves both entity and log
```

## API Endpoints

### Invoice Posting

#### Get Unposted Invoices
```
GET /api/invoices/unposted
Headers: Authorization: Bearer <token>

Response:
{
    "success": true,
    "count": 5,
    "invoices": [...]
}
```

#### Post Single Invoice
```
POST /api/invoices/post/<invoice_id>
Headers: Authorization: Bearer <token>
Body: {"posted_by": "username"}

Response:
{
    "success": true,
    "message": "تم ترحيل الفاتورة بنجاح",
    "invoice": {...}
}
```

#### Batch Post Invoices
```
POST /api/invoices/post/batch
Headers: Authorization: Bearer <token>
Body: {
    "invoice_ids": [1, 2, 3],
    "posted_by": "username"
}

Response:
{
    "success": true,
    "message": "تم ترحيل 3 فواتير بنجاح",
    "posted_count": 3,
    "failed_count": 0
}
```

#### Unpost Invoice
```
POST /api/invoices/unpost/<invoice_id>
Headers: Authorization: Bearer <token>

Response:
{
    "success": true,
    "message": "تم إلغاء ترحيل الفاتورة"
}
```

### Journal Entry Posting

Similar endpoints for journal entries:
- `GET /api/journal-entries/unposted`
- `POST /api/journal-entries/post/<entry_id>`
- `POST /api/journal-entries/post/batch`
- `POST /api/journal-entries/unpost/<entry_id>`

### Audit Logs

#### Get All Audit Logs
```
GET /api/audit-logs
Headers: Authorization: Bearer <token>
Query: ?page=1&per_page=50

Response:
{
    "success": true,
    "logs": [...],
    "total": 150,
    "page": 1,
    "per_page": 50
}
```

#### Filter by User
```
GET /api/audit-logs/user/<user_id>
```

#### Filter by Action
```
GET /api/audit-logs/action/<action>
Actions: invoice_post, invoice_unpost, entry_post, entry_unpost, batch_invoice_post, batch_entry_post
```

## Flutter Integration

### API Service Methods
Location: `frontend/lib/api_service.dart`

```dart
class ApiService {
  Future<Map<String, dynamic>> getUnpostedInvoices() async {
    final prefs = await SharedPreferences.getInstance();
    final token = prefs.getString('jwt_token');
    
    if (token == null) {
      throw Exception('يجب تسجيل الدخول أولاً');
    }
    
    final response = await http.get(
      Uri.parse('$_baseUrl/invoices/unposted'),
      headers: {
        'Authorization': 'Bearer $token',
        'Content-Type': 'application/json; charset=UTF-8',
      },
    );
    
    if (response.statusCode == 401) {
      throw Exception('انتهت صلاحية الجلسة');
    } else if (response.statusCode == 403) {
      throw Exception('ليس لديك صلاحية الوصول');
    } else if (response.statusCode == 200) {
      return json.decode(utf8.decode(response.bodyBytes));
    } else {
      final errorData = json.decode(utf8.decode(response.bodyBytes));
      throw Exception(errorData['message'] ?? 'فشل التحميل');
    }
  }
}
```

### Error Handling Strategy

1. **No Token**: User must re-login
2. **401 Unauthorized**: Token expired, re-login required
3. **403 Forbidden**: User lacks permission
4. **200 OK**: Success
5. **Other**: Parse error message from response

## Database Schema

### Invoice Table
```sql
ALTER TABLE invoices ADD COLUMN is_posted BOOLEAN DEFAULT FALSE;
ALTER TABLE invoices ADD COLUMN posted_date DATETIME;
ALTER TABLE invoices ADD COLUMN posted_by VARCHAR(100);
```

### Journal Entry Table
```sql
ALTER TABLE journal_entries ADD COLUMN is_posted BOOLEAN DEFAULT FALSE;
ALTER TABLE journal_entries ADD COLUMN posted_date DATETIME;
ALTER TABLE journal_entries ADD COLUMN posted_by VARCHAR(100);
```

### Audit Log Table
```sql
CREATE TABLE audit_logs (
    id INTEGER PRIMARY KEY,
    user_id INTEGER,
    action VARCHAR(100),
    entity_type VARCHAR(50),
    entity_id INTEGER,
    details TEXT,  -- JSON string
    ip_address VARCHAR(50),
    user_agent VARCHAR(255),
    timestamp DATETIME,
    FOREIGN KEY (user_id) REFERENCES users(id)
);
```

## Security Considerations

### Token Expiration
- Default: 24 hours
- After expiration: User must re-authenticate
- Token includes: `user_id`, `username`, `is_admin`, `exp`, `iat`

### Permission Checks
- All posting endpoints require authentication
- Specific permissions checked before operations
- Admins bypass permission checks (have all permissions)

### Audit Trail
- Every operation logged with:
  - User who performed it
  - What was done (action type)
  - When it happened (timestamp)
  - Where from (IP address, user agent)
  - Details (JSON with entity information)

### SQL Injection Protection
- SQLAlchemy ORM used for all queries
- No raw SQL with user input
- Parameterized queries only

## Testing

### Backend Testing
```bash
# Test login
curl -X POST http://localhost:8001/api/auth/login \
  -H "Content-Type: application/json" \
  -d '{"username":"admin","password":"admin123"}'

# Extract token and test endpoint
TOKEN="<your_token>"
curl http://localhost:8001/api/invoices/unposted \
  -H "Authorization: Bearer $TOKEN"
```

### Flutter Testing
```dart
// Test in app
final api = ApiService();
final result = await api.getUnpostedInvoices();
print(result);
```

## Common Issues & Solutions

### Issue: "يجب تسجيل الدخول أولاً"
**Cause**: No JWT token found in SharedPreferences
**Solution**: Logout and login again to generate new token

### Issue: "انتهت صلاحية الجلسة"
**Cause**: JWT token expired (>24 hours old)
**Solution**: Login again

### Issue: Audit logs not saving
**Cause**: `db.session.commit()` called before `AuditLog.log_action()`
**Solution**: Always call `log_action()` BEFORE `commit()`

### Issue: Permission denied for admin
**Cause**: Admin flag not set correctly
**Solution**: Check `user.is_admin` in database

## Performance Considerations

### Batch Operations
- Use batch endpoints for multiple items
- Single transaction for all items
- Reduced database round-trips

### Pagination
- Audit logs endpoint supports pagination
- Default: 50 items per page
- Prevents memory issues with large datasets

### Indexing
Recommended indexes:
```sql
CREATE INDEX idx_invoices_posted ON invoices(is_posted);
CREATE INDEX idx_entries_posted ON journal_entries(is_posted);
CREATE INDEX idx_audit_user ON audit_logs(user_id);
CREATE INDEX idx_audit_action ON audit_logs(action);
CREATE INDEX idx_audit_timestamp ON audit_logs(timestamp);
```

## Future Enhancements

### Planned Features
1. Bulk unpost with confirmation
2. Posting approval workflow
3. Email notifications on post/unpost
4. Export audit logs to CSV
5. Advanced filtering in audit logs
6. Posting templates for recurring operations

### API Versioning
Consider versioning if breaking changes needed:
```
/api/v1/invoices/post
/api/v2/invoices/post
```

## Maintenance

### Regular Tasks
1. Clean old audit logs (>1 year)
2. Monitor token expiration issues
3. Review permission assignments
4. Backup audit logs before cleanup

### Monitoring
- Track failed authentication attempts
- Monitor permission denial rates
- Review audit log growth
- Check API response times

---

**Last Updated**: January 2025  
**Version**: 1.0  
**Maintainer**: Development Team
