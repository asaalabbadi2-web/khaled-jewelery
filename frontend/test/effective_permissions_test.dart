import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/models/app_user_model.dart';

/// The app reads what the server checks: the role's grants with the user's
/// overrides on top (ADR-036). It read the overrides alone, and hid from the
/// manager and the sellers what the server allowed them.
void main() {
  Map<String, dynamic> user(Map<String, dynamic> extra) => {
        'id': 1, 'username': 'm', 'role': 'manager', 'permissions': null, ...extra,
      };

  test('the effective permissions are read from the server', () {
    final u = AppUserModel.fromJson(user({'effective_permissions': ['vouchers.approve', 'invoices.view']}));
    expect(u.effectivePermissions, ['vouchers.approve', 'invoices.view']);
  });

  test('they survive the stored session', () {
    final u = AppUserModel.fromJson(user({'effective_permissions': ['vouchers.approve']}));
    final again = AppUserModel.fromStorageMap(u.toStorageMap());
    expect(again.effectivePermissions, ['vouchers.approve']);
  });

  test('an older server sends none', () {
    expect(AppUserModel.fromJson(user({})).effectivePermissions, isNull);
  });
}
