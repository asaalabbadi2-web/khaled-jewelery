// The settings follow the sign-in (the owner, 23 Nov 2026: «الفاتورة احتسبت
// ضريبة والضريبة غير مفعله في الاعدادات»). A device that opened the app
// signed out, at an address with no copy of the settings kept, sold with the
// defaults -- VAT charged -- and the server refused the sale. Signed in, the
// settings are asked of the server again.

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/providers/settings_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _SignIn extends ChangeNotifier {
  bool signedIn = false;
  void set(bool value) {
    signedIn = value;
    notifyListeners();
  }
}

void main() {
  test('signed in after the app opened: the server\'s settings, not the defaults', () async {
    SharedPreferences.setMockInitialValues({});            // a new address: nothing kept
    var asked = 0;
    final settings = SettingsProvider(fetch: () async {
      asked++;
      return {'sales_vat_enabled': false, 'main_karat': 21};
    });
    final auth = _SignIn();
    await settings.loadSettings(fetchRemote: false);       // the app opens signed out
    settings.followSignIn(auth, () => auth.signedIn);
    expect(settings.salesVatEnabled, isTrue, reason: 'the default, before anyone signs in');

    auth.set(true);
    await pumpEventQueue();
    expect(asked, 1);
    expect(settings.salesVatEnabled, isFalse, reason: 'the server\'s: no VAT on the sales');

    auth.set(true);
    await pumpEventQueue();
    expect(asked, 1, reason: 'asked once per sign-in, not on every change');
    auth.set(false);
    auth.set(true);
    await pumpEventQueue();
    expect(asked, 2, reason: 'a new sign-in asks again');
  });

  test('a sign-in the server does not answer keeps what is held', () async {
    SharedPreferences.setMockInitialValues({});
    final settings = SettingsProvider(fetch: () async => throw Exception('no network'));
    final auth = _SignIn();
    settings.followSignIn(auth, () => auth.signedIn);
    auth.set(true);
    await pumpEventQueue();
    expect(settings.salesVatEnabled, isTrue);
  });
}
