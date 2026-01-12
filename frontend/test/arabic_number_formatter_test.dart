import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/utils/arabic_number_formatter.dart';

void main() {
  group('Arabic Number Conversion Tests', () {
    test('Convert Arabic numbers to Western', () {
      const input = 'الوزن: ٢٣.٥ جرام';
      final result = ArabicNumberTextInputFormatter.convertToWesternNumbers(
        input,
      );
      expect(result, 'الوزن: 23.5 جرام');
    });

    test('Convert Persian/Hindi numbers to Western', () {
      const input = 'قیمت: ۱۲۳۴.۵۶ تومان';
      final result = ArabicNumberTextInputFormatter.convertToWesternNumbers(
        input,
      );
      expect(result, 'قیمت: 1234.56 تومان');
    });

    test('Convert mixed Arabic and Persian numbers', () {
      const input = 'العدد الأول: ٥٠، والثاني: ۳۰';
      final result = ArabicNumberTextInputFormatter.convertToWesternNumbers(
        input,
      );
      expect(result, 'العدد الأول: 50، والثاني: 30');
    });

    test('Leave Western numbers unchanged', () {
      const input = 'الوزن: 123.45 جرام';
      final result = ArabicNumberTextInputFormatter.convertToWesternNumbers(
        input,
      );
      expect(result, 'الوزن: 123.45 جرام');
    });

    test('Convert all Arabic digits', () {
      const input = '٠١٢٣٤٥٦٧٨٩';
      final result = ArabicNumberTextInputFormatter.convertToWesternNumbers(
        input,
      );
      expect(result, '0123456789');
    });

    test('Convert all Persian digits', () {
      const input = '۰۱۲۳۴۵۶۷۸۹';
      final result = ArabicNumberTextInputFormatter.convertToWesternNumbers(
        input,
      );
      expect(result, '0123456789');
    });

    test('Handle empty string', () {
      const input = '';
      final result = ArabicNumberTextInputFormatter.convertToWesternNumbers(
        input,
      );
      expect(result, '');
    });

    test('Handle text without numbers', () {
      const input = 'نص بدون أرقام';
      final result = ArabicNumberTextInputFormatter.convertToWesternNumbers(
        input,
      );
      expect(result, 'نص بدون أرقام');
    });
  });

  group('ArabicNumberTextInputFormatter Tests', () {
    test('Format with decimal allowed', () {
      final formatter = ArabicNumberTextInputFormatter(
        allowDecimal: true,
        allowNegative: false,
      );

      const oldValue = TextEditingValue(text: '');
      const newValue = TextEditingValue(text: '٢٣.٥');

      final result = formatter.formatEditUpdate(oldValue, newValue);
      expect(result.text, '23.5');
    });

    test('Format with negative allowed', () {
      final formatter = ArabicNumberTextInputFormatter(
        allowDecimal: true,
        allowNegative: true,
      );

      const oldValue = TextEditingValue(text: '');
      const newValue = TextEditingValue(text: '-٢٣.٥');

      final result = formatter.formatEditUpdate(oldValue, newValue);
      expect(result.text, '-23.5');
    });

    test('Reject invalid input when decimal not allowed', () {
      final formatter = ArabicNumberTextInputFormatter(
        allowDecimal: false,
        allowNegative: false,
      );

      const oldValue = TextEditingValue(text: '23');
      const newValue = TextEditingValue(text: '23.5');

      final result = formatter.formatEditUpdate(oldValue, newValue);
      expect(result.text, '23'); // Should keep old value
    });

    test('Reject negative when not allowed', () {
      final formatter = ArabicNumberTextInputFormatter(
        allowDecimal: true,
        allowNegative: false,
      );

      const oldValue = TextEditingValue(text: '23');
      const newValue = TextEditingValue(text: '-23');

      final result = formatter.formatEditUpdate(oldValue, newValue);
      expect(result.text, '23'); // Should keep old value
    });
  });

  group('Real-world Scenarios', () {
    test('Weight input with Arabic numbers', () {
      const input = '٢٣.٥';
      final result = ArabicNumberTextInputFormatter.convertToWesternNumbers(
        input,
      );
      final weight = double.tryParse(result);

      expect(weight, 23.5);
    });

    test('Price input with mixed text and numbers', () {
      const input = 'السعر: ١٢٣٤.٥٦ ريال';
      final result = ArabicNumberTextInputFormatter.convertToWesternNumbers(
        input,
      );

      expect(result, 'السعر: 1234.56 ريال');
    });

    test('Address with building number', () {
      const input = 'شارع الملك، بناء رقم ٤٥، شقة ١٢';
      final result = ArabicNumberTextInputFormatter.convertToWesternNumbers(
        input,
      );

      expect(result, 'شارع الملك، بناء رقم 45، شقة 12');
    });

    test('Phone number with Arabic digits', () {
      const input = '٠٥٠١٢٣٤٥٦٧٨';
      final result = ArabicNumberTextInputFormatter.convertToWesternNumbers(
        input,
      );

      expect(result, '05012345678');
    });
  });
}
