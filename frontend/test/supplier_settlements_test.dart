import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:frontend/api_service.dart';
import 'package:frontend/models/supplier_settlement_model.dart';
import 'package:frontend/providers/auth_provider.dart';
import 'package:frontend/providers/settings_provider.dart';
import 'package:frontend/screens/supplier_settlements_screen.dart';

/// صلاحيات مضبوطة يدويًا — الواجهة تقرأ منها فقط، والخادم يبقى الحكم النهائي.
class _FakeAuth extends AuthProvider {
  final Set<String> granted;
  _FakeAuth(this.granted);

  @override
  bool hasPermission(String key) => granted.contains(key);
}

/// يستبدل نداءات الشبكة فقط. لا يحاكي أي منطق محاسبي — القيم ثابتة كما لو
/// أرجعها الخادم.
class _FakeApi extends ApiService {
  _FakeApi({this.rows = const [], this.error}) : super(baseUrl: 'http://test');

  final List<dynamic> rows;
  final Object? error;

  final List<String> calls = [];
  Map<String, dynamic>? lastCreatePayload;

  /// ما يعيده `/preview`. الاختبار يحقنه كما يرسله الخادم تمامًا.
  Map<String, dynamic>? previewBody;
  Object? previewError;

  @override
  Future<Map<String, dynamic>> getSupplierSettlementPreview(int id) async {
    calls.add('preview');
    if (previewError != null) throw previewError!;
    return {'success': true, 'preview': previewBody ?? _previewJson()};
  }

  @override
  Future<List<dynamic>> getSupplierSettlementAdjustments(
    int supplierId, {
    String? status,
  }) async {
    calls.add('list');
    if (error != null) throw error!;
    return rows;
  }

  @override
  Future<Map<String, dynamic>> createSupplierSettlementAdjustment(
    int supplierId, {
    required String reasonCode,
    String? note,
  }) async {
    calls.add('create');
    lastCreatePayload = {'reason_code': reasonCode, 'note': note};
    return {'success': true, 'adjustment': _row(id: 9, status: 'draft')};
  }

  @override
  Future<Map<String, dynamic>> recalculateSupplierSettlementAdjustment(
      int id) async {
    calls.add('recalculate');
    return {'success': true, 'adjustment': _row(id: id, status: 'draft')};
  }

  @override
  Future<Map<String, dynamic>> approveSupplierSettlementAdjustment(
      int id) async {
    calls.add('approve');
    return {'success': true, 'adjustment': _row(id: id, status: 'approved')};
  }

  @override
  Future<Map<String, dynamic>> postSupplierSettlementAdjustment(int id) async {
    calls.add('post');
    return {'success': true, 'adjustment': _row(id: id, status: 'posted')};
  }

  @override
  Future<Map<String, dynamic>> reverseSupplierSettlementAdjustment(
    int id, {
    required String reason,
  }) async {
    calls.add('reverse');
    return {'success': true, 'adjustment': _row(id: id, status: 'reversed')};
  }

  @override
  Future<Map<String, dynamic>> cancelSupplierSettlementAdjustment(
    int id, {
    required String reason,
  }) async {
    calls.add('cancel');
    return {'success': true, 'adjustment': _row(id: id, status: 'cancelled')};
  }
}

/// استجابة `/preview` كما يبنيها الخادم — كل الأرقام محسوبة هناك.
Map<String, dynamic> _previewJson({
  bool eligible = true,
  String? blockingCode,
  String blockingMessage = '',
  double cash = -1.33,
  Map<String, dynamic> weights = const {},
  double mainKaratEquivalent = 0.0,
  bool snapshotMatches = true,
  Map<String, dynamic>? policy,
  List<Map<String, dynamic>> checks = const [],
}) {
  return {
    'adjustment_id': 1,
    'supplier_id': 7,
    'status': 'draft',
    'computed_at': '2026-09-17T10:00:00',
    'period_key': '2026-09',
    'balance_before_financial': cash,
    'balance_before_weight': weights,
    'main_karat_equivalent': mainKaratEquivalent,
    'stored_snapshot_matches': snapshotMatches,
    'eligibility': {
      'eligible': eligible,
      'blocking_reason': blockingCode == null
          ? null
          : {'code': blockingCode, 'message': blockingMessage},
      'checks': checks,
    },
    'policy': policy ??
        {
          'policy_id': 1,
          'tolerance_cash': 5.0,
          'tolerance_weight': 0.05,
          'period_cap_cash': 50.0,
          'period_cap_weight': 0.5,
          'review_threshold_cash': 500.0,
          'cash_consumed': 12.5,
          'weight_consumed': 0.02,
          'remaining_cash_cap': 37.5,
          'remaining_weight_cap': 0.48,
        },
  };
}

Map<String, dynamic> _row({
  int id = 1,
  String status = 'draft',
  String number = 'SAD-2026-00001',
  String reason = 'ROUNDING_DIFFERENCE',
  double cash = -1.33,
  Map<String, dynamic> weights = const {},
  int? voucherId,
  int? journalEntryId,
  int? reversalOfId,
}) {
  return {
    'id': id,
    'adjustment_number': number,
    'supplier_id': 7,
    'supplier_name': 'مورد اختبار',
    'status': status,
    'reason_code': reason,
    'note': null,
    'balance_before_financial': cash,
    'balance_before_weight': weights,
    'posted_amount_cash': status == 'posted' || status == 'reversed' ? cash : null,
    'posted_amount_weight': status == 'posted' || status == 'reversed' ? weights : {},
    'voucher_id': voucherId,
    'journal_entry_id': journalEntryId,
    'reversal_of_id': reversalOfId,
    'created_by': 'tester',
    'created_at': '2026-09-17T10:00:00',
    'approved_by': status == 'draft' ? null : 'approver',
    'approved_by_manager': false,
  };
}

Future<void> _pump(
  WidgetTester tester, {
  required _FakeApi api,
  Set<String> permissions = const {},
}) async {
  await tester.pumpWidget(
    MultiProvider(
      providers: [
        ChangeNotifierProvider<AuthProvider>.value(value: _FakeAuth(permissions)),
        ChangeNotifierProvider<SettingsProvider>(
            create: (_) => SettingsProvider()),
      ],
      child: MaterialApp(
        home: SupplierSettlementsScreen(
          api: api,
          supplierId: 7,
          supplierName: 'مورد اختبار',
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  // ── النموذج ────────────────────────────────────────────────────────────
  group('SupplierSettlementAdjustment model', () {
    test('يقرأ حقول الخادم كما هي', () {
      final a = SupplierSettlementAdjustment.fromJson(_row(
        status: 'posted',
        cash: 3.5,
        weights: {'21k': 0.03},
        voucherId: 12,
        journalEntryId: 34,
      ));

      expect(a.adjustmentNumber, 'SAD-2026-00001');
      expect(a.status, kSettlementStatusPosted);
      expect(a.isPosted, isTrue);
      expect(a.balanceBeforeFinancial, 3.5);
      expect(a.postedAmountCash, 3.5);
      expect(a.voucherId, 12);
      expect(a.journalEntryId, 34);
      expect(a.createdBy, 'tester');
    });

    test('يعرض كل عيار مستقلًا ولا يجمع الأوزان الخام', () {
      final a = SupplierSettlementAdjustment.fromJson(_row(
        weights: {'18k': 0.010, '21k': -0.012, '22k': 0.0, '24k': 0.008},
      ));

      final shown = a.openBalanceWeights;
      // العيار 22 صفر فلا يُعرض، والباقي كما هو بإشاراته.
      expect(shown.keys.toList(), ['18k', '21k', '24k']);
      expect(shown['18k'], 0.010);
      expect(shown['21k'], -0.012);
      expect(shown['24k'], 0.008);
    });

    test('يحافظ على ترتيب العيارات المعروض', () {
      final a = SupplierSettlementAdjustment.fromJson(_row(
        weights: {'24k': 1.0, '18k': 2.0, '21k': 3.0},
      ));
      expect(a.openBalanceWeights.keys.toList(), ['18k', '21k', '24k']);
    });

    test('يميّز وثيقة العكس', () {
      final original = SupplierSettlementAdjustment.fromJson(_row());
      final reversal =
          SupplierSettlementAdjustment.fromJson(_row(id: 2, reversalOfId: 1));
      expect(original.isReversalDocument, isFalse);
      expect(reversal.isReversalDocument, isTrue);
      expect(reversal.reversalOfId, 1);
    });

    test('تسميات الحالات بالعربية', () {
      expect(settlementStatusLabel(kSettlementStatusDraft), 'مسودة');
      expect(settlementStatusLabel(kSettlementStatusApproved), 'معتمدة');
      expect(settlementStatusLabel(kSettlementStatusPosted), 'مرحّلة');
      expect(settlementStatusLabel(kSettlementStatusReversed), 'معكوسة');
      expect(settlementStatusLabel(kSettlementStatusCancelled), 'ملغاة');
    });

    test('أسباب التسوية تطابق الخادم ولا تتضمن خصم المشتريات', () {
      expect(kSettlementReasonCodes, hasLength(5));
      expect(kSettlementReasonCodes, contains('ROUNDING_DIFFERENCE'));
      expect(kSettlementReasonCodes, isNot(contains('PURCHASE_DISCOUNT')));
      expect(settlementReasonLabel(kSettlementReasonWeight), 'فرق وزن');
    });
  });

  // ── القائمة والحالات ───────────────────────────────────────────────────
  group('القائمة', () {
    testWidgets('تعرض التسويات مع حالاتها', (tester) async {
      final api = _FakeApi(rows: [
        _row(id: 1, number: 'SAD-2026-00001', status: 'draft'),
        _row(
            id: 2,
            number: 'SAD-2026-00002',
            status: 'posted',
            voucherId: 5,
            journalEntryId: 9),
      ]);
      await _pump(tester, api: api);

      expect(find.text('SAD-2026-00001'), findsOneWidget);
      expect(find.text('SAD-2026-00002'), findsOneWidget);
      expect(find.text('مسودة'), findsOneWidget);
      expect(find.text('مرحّلة'), findsOneWidget);
      expect(api.calls, contains('list'));
    });

    testWidgets('تعرض مرجع القيد للمرحّلة', (tester) async {
      await _pump(
        tester,
        api: _FakeApi(rows: [
          _row(status: 'posted', voucherId: 5, journalEntryId: 9),
        ]),
      );
      expect(find.textContaining('قيد #9'), findsOneWidget);
    });

    testWidgets('تعرض كل عيار على حدة', (tester) async {
      await _pump(
        tester,
        api: _FakeApi(rows: [
          _row(weights: {'18k': 0.010, '21k': -0.012, '24k': 0.008}),
        ]),
      );
      expect(find.textContaining('18K'), findsOneWidget);
      expect(find.textContaining('21K'), findsOneWidget);
      expect(find.textContaining('24K'), findsOneWidget);
    });

    testWidgets('حالة فارغة', (tester) async {
      await _pump(tester, api: _FakeApi(rows: const []));
      expect(find.text('لا توجد تسويات'), findsOneWidget);
    });

    testWidgets('تعرض خطأ التحميل بدل إخفائه', (tester) async {
      await _pump(
        tester,
        api: _FakeApi(
          error: const ApiException(
            statusCode: 409,
            code: 'not_eligible',
            message: 'المورد غير مؤهل: يوجد 3 فاتورة غير مسددة.',
          ),
        ),
      );
      expect(find.textContaining('غير مؤهل'), findsOneWidget);
      expect(find.text('إعادة المحاولة'), findsOneWidget);
    });
  });

  // ── الصلاحيات ──────────────────────────────────────────────────────────
  group('الصلاحيات', () {
    testWidgets('يُخفى زر الاعتماد بلا صلاحية', (tester) async {
      await _pump(
        tester,
        api: _FakeApi(rows: [_row(status: 'draft')]),
        permissions: const {},
      );
      expect(find.text('اعتماد'), findsNothing);
    });

    testWidgets('يظهر زر الاعتماد مع الصلاحية', (tester) async {
      await _pump(
        tester,
        api: _FakeApi(rows: [_row(status: 'draft')]),
        permissions: const {'supplier_settlement_adjustments.approve'},
      );
      expect(find.text('اعتماد'), findsOneWidget);
    });

    testWidgets('يُخفى زر الإنشاء بلا صلاحية', (tester) async {
      await _pump(tester, api: _FakeApi(rows: const []));
      expect(find.text('إنشاء تسوية'), findsNothing);
    });
  });

  // ── الإجراءات حسب الحالة ───────────────────────────────────────────────
  group('الإجراءات حسب الحالة', () {
    const all = {
      'supplier_settlement_adjustments.create',
      'supplier_settlement_adjustments.approve',
      'supplier_settlement_adjustments.post',
      'supplier_settlement_adjustments.reverse',
      'supplier_settlement_adjustments.cancel',
    };

    testWidgets('المسودة: إعادة تحقق واعتماد وإلغاء — بلا ترحيل أو عكس',
        (tester) async {
      await _pump(tester,
          api: _FakeApi(rows: [_row(status: 'draft')]), permissions: all);
      expect(find.text('إعادة التحقق'), findsOneWidget);
      expect(find.text('اعتماد'), findsOneWidget);
      expect(find.text('إلغاء المسودة'), findsOneWidget);
      expect(find.text('ترحيل'), findsNothing);
      expect(find.text('عكس التسوية'), findsNothing);
    });

    testWidgets('المعتمدة: ترحيل فقط (مع الإلغاء)', (tester) async {
      await _pump(tester,
          api: _FakeApi(rows: [_row(status: 'approved')]), permissions: all);
      expect(find.text('ترحيل'), findsOneWidget);
      expect(find.text('اعتماد'), findsNothing);
      expect(find.text('عكس التسوية'), findsNothing);
    });

    testWidgets('المرحّلة: عكس فقط — لا تعديل ولا إلغاء', (tester) async {
      await _pump(tester,
          api: _FakeApi(rows: [_row(status: 'posted')]), permissions: all);
      expect(find.text('عكس التسوية'), findsOneWidget);
      expect(find.text('ترحيل'), findsNothing);
      expect(find.text('إلغاء المسودة'), findsNothing);
    });

    testWidgets('المعكوسة والملغاة: بلا إجراءات', (tester) async {
      await _pump(tester,
          api: _FakeApi(rows: [
            _row(id: 1, status: 'reversed'),
            _row(id: 2, number: 'SAD-2026-00002', status: 'cancelled'),
          ]),
          permissions: all);
      expect(find.text('ترحيل'), findsNothing);
      expect(find.text('عكس التسوية'), findsNothing);
      expect(find.text('اعتماد'), findsNothing);
      expect(find.text('إلغاء المسودة'), findsNothing);
    });
  });

  // ── الإنشاء ────────────────────────────────────────────────────────────
  group('إنشاء مسودة', () {
    testWidgets('يرسل السبب فقط ولا يطلب مبالغ من المستخدم', (tester) async {
      final api = _FakeApi(rows: const []);
      await _pump(tester,
          api: api,
          permissions: const {'supplier_settlement_adjustments.create'});

      await tester.tap(find.text('إنشاء تسوية'));
      await tester.pumpAndSettle();

      // مدخلان لا ثالث لهما: السبب (قائمة) والملاحظة (نص). أي حقل مبلغ أو وزن
      // أو حساب كان سيظهر كـ TextField إضافي.
      expect(find.text('السبب'), findsOneWidget);
      expect(find.text('ملاحظة'), findsOneWidget);
      expect(find.byType(TextField), findsOneWidget);
      expect(find.byType(DropdownButtonFormField<String>), findsOneWidget);

      await tester.tap(find.text('إنشاء'));
      await tester.pumpAndSettle();

      expect(api.calls, contains('create'));
      expect(api.lastCreatePayload!['reason_code'], 'ROUNDING_DIFFERENCE');
    });
  });

  // ── تأكيد الترحيل والعكس ───────────────────────────────────────────────
  group('التأكيد قبل التنفيذ', () {
    testWidgets('الترحيل يطلب تأكيدًا ولا يُنفَّذ عند الإلغاء', (tester) async {
      final api = _FakeApi(rows: [_row(status: 'approved')]);
      await _pump(tester,
          api: api,
          permissions: const {'supplier_settlement_adjustments.post'});

      await tester.tap(find.text('ترحيل'));
      await tester.pumpAndSettle();
      expect(find.text('ترحيل التسوية'), findsOneWidget);

      await tester.tap(find.text('إلغاء'));
      await tester.pumpAndSettle();
      expect(api.calls, isNot(contains('post')));
    });

    testWidgets('العكس يستلزم سببًا مكتوبًا', (tester) async {
      final api = _FakeApi(rows: [_row(status: 'posted')]);
      await _pump(tester,
          api: api,
          permissions: const {'supplier_settlement_adjustments.reverse'});

      await tester.tap(find.text('عكس التسوية'));
      await tester.pumpAndSettle();

      // تأكيد بلا سبب لا يُغلق الحوار ولا يستدعي الخادم.
      await tester.tap(find.text('تأكيد'));
      await tester.pumpAndSettle();
      expect(api.calls, isNot(contains('reverse')));

      await tester.enterText(find.byType(TextField), 'قيد خاطئ');
      await tester.tap(find.text('تأكيد'));
      await tester.pumpAndSettle();
      expect(api.calls, contains('reverse'));
    });
  });

  // ── المعاينة ───────────────────────────────────────────────────────────
  // كل رقم معروض هنا وصل من الخادم. الاختبارات تثبت أن الواجهة تعرضه كما هو
  // ولا تشتق بديلًا عنه.
  group('SettlementPreview model', () {
    test('يقرأ حقول المعاينة كما أرسلها الخادم', () {
      final p = SettlementPreview.fromJson(_previewJson(
        cash: -1.33,
        weights: {'18k': 0.010, '21k': 0.012},
        mainKaratEquivalent: 0.0205714,
      ));

      expect(p.balanceBeforeFinancial, -1.33);
      expect(p.mainKaratEquivalent, 0.0205714);
      expect(p.storedSnapshotMatches, isTrue);
      expect(p.eligible, isTrue);
      expect(p.blockingCode, isNull);
      expect(p.policy!.remainingCashCap, 37.5);
      expect(p.policy!.remainingWeightCap, 0.48);
      expect(p.periodKey, '2026-09');
    });

    test('المكافئ لا يُشتق من الأوزان الخام بل يُقرأ من الخادم', () {
      // 0.010 + 0.012 + 0.008 = 0.030 خامًا، والخادم أرسل 0.029714.
      final p = SettlementPreview.fromJson(_previewJson(
        weights: {'18k': 0.010, '21k': 0.012, '24k': 0.008},
        mainKaratEquivalent: 0.029714,
      ));

      expect(p.mainKaratEquivalent, 0.029714);
      final rawSum = p.openWeights.values.fold<double>(0, (a, b) => a + b);
      expect(p.mainKaratEquivalent, isNot(closeTo(rawSum, 1e-9)));
    });

    test('يحمل سبب المنع المهيكل ورمزه', () {
      final p = SettlementPreview.fromJson(_previewJson(
        eligible: false,
        blockingCode: 'no_pending_vouchers',
        blockingMessage: 'يوجد 1 سند معلّق للمورد.',
        checks: const [
          {'name': 'no_pending_vouchers', 'passed': false, 'detail': 'يوجد 1 سند معلّق للمورد.'},
          {'name': 'has_residual', 'passed': true, 'detail': ''},
        ],
      ));

      expect(p.eligible, isFalse);
      expect(p.blockingCode, 'no_pending_vouchers');
      expect(p.blockingMessage, 'يوجد 1 سند معلّق للمورد.');
      expect(p.failedChecks.map((c) => c.name), ['no_pending_vouchers']);
    });

    test('غياب السياسة لا يُستبدل بقيم مخترعة', () {
      final json = _previewJson()..['policy'] = null;
      expect(SettlementPreview.fromJson(json).policy, isNull);
    });
  });

  group('حوار المراجعة', () {
    testWidgets('يعرض المكافئ والحدود والمستهلك كما أرسلها الخادم',
        (tester) async {
      final api = _FakeApi(rows: [_row(status: 'draft')])
        ..previewBody = _previewJson(
          weights: {'18k': 0.010, '21k': 0.012},
          mainKaratEquivalent: 0.029714,
        );
      await _pump(tester,
          api: api,
          permissions: const {'supplier_settlement_adjustments.view'});

      await tester.tap(find.text('مراجعة'));
      await tester.pumpAndSettle();

      expect(api.calls, contains('preview'));
      expect(find.text('مؤهلة للترحيل'), findsOneWidget);
      // المكافئ معروض كسطر مستقل بقيمة الخادم.
      expect(find.text('المكافئ بالعيار الرئيسي'), findsOneWidget);
      expect(find.text('0.030'), findsOneWidget); // 0.029714 بثلاث خانات
      // كل عيار على حدة.
      expect(find.text('18K'), findsOneWidget);
      expect(find.text('21K'), findsOneWidget);
      // الحدود والمستهلك من الخادم.
      expect(find.textContaining('37.50'), findsOneWidget);
      expect(find.text('2026-09'), findsOneWidget);
    });

    testWidgets('يعرض سبب المنع ورسالة الخادم ورمزه', (tester) async {
      final api = _FakeApi(rows: [_row(status: 'draft')])
        ..previewBody = _previewJson(
          eligible: false,
          blockingCode: 'below_review_threshold',
          blockingMessage: 'الرصيد 600.0 يتجاوز حد المراجعة 500.0',
        );
      await _pump(tester,
          api: api,
          permissions: const {'supplier_settlement_adjustments.view'});

      await tester.tap(find.text('مراجعة'));
      await tester.pumpAndSettle();

      expect(find.text('يتجاوز حد المراجعة'), findsOneWidget);
      // رسالة الخادم ورمزه يبقيان ظاهرين للتشخيص.
      expect(find.text('الرصيد 600.0 يتجاوز حد المراجعة 500.0'), findsOneWidget);
      expect(find.text('below_review_threshold'), findsOneWidget);
    });

    testWidgets('ينبّه إلى تغيّر الرصيد منذ إنشاء المسودة', (tester) async {
      final api = _FakeApi(rows: [_row(status: 'draft')])
        ..previewBody = _previewJson(snapshotMatches: false);
      await _pump(tester,
          api: api,
          permissions: const {'supplier_settlement_adjustments.view'});

      await tester.tap(find.text('مراجعة'));
      await tester.pumpAndSettle();

      expect(
        find.text('تغيّر الرصيد منذ إنشاء المسودة — أعد التحقق قبل الترحيل.'),
        findsOneWidget,
      );
    });

    testWidgets('يُخفى زر المراجعة بلا صلاحية العرض', (tester) async {
      final api = _FakeApi(rows: [_row(status: 'draft')]);
      await _pump(tester, api: api, permissions: const {});

      expect(find.text('مراجعة'), findsNothing);
    });

    testWidgets('خطأ المعاينة يُعرض ولا يُخفى', (tester) async {
      final api = _FakeApi(rows: [_row(status: 'draft')])
        ..previewError = ApiException(
          statusCode: 403,
          code: 'permission_denied',
          message: 'لا تملك صلاحية',
        );
      await _pump(tester,
          api: api,
          permissions: const {'supplier_settlement_adjustments.view'});

      await tester.tap(find.text('مراجعة'));
      await tester.pumpAndSettle();

      expect(find.textContaining('لا تملك صلاحية'), findsOneWidget);
    });
  });
}
