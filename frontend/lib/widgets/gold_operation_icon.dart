import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

/// العمليتان اللتان تنقلان الذهب بين المعروض والكسر، ولكل منهما أيقونتها.
enum GoldOperation {
  /// تكسير: قطعة من المعروض تصير كسرًا -- مطرقة فوق سبيكة متصدّعة.
  breaking('assets/icons/gold_breaking.svg'),

  /// تجديد: القطعة نفسها بالية تعود جديدة -- الخاتم الباهت المخدوش يعود
  /// يلمع. لا سبيكة فيها: السبيكة التي تصير خاتمًا «تصنيع» (المالك).
  renewal('assets/icons/gold_renewal.svg');

  const GoldOperation(this.asset);

  /// ملف الـ SVG وهو المرجع الوحيد للرسم: لا يُعاد رسمه في Dart.
  final String asset;
}

/// أيقونة عملية الذهب بلغة أيقونات التطبيق (Material): لون واحد هو لون
/// موضعها كأي `Icon` -- لون نوعها حيث يُعطى، وإلا لون `IconTheme` (التبويب
/// المختار، والزر المعطَّل، والوضع الداكن). الملفان مرسومان بـ
/// `currentColor` وخطّ 2 كأيقونات Material، وما يُفصل (صدع السبيكة، خدوش
/// الخاتم البالي) محفور بقناع لا بلون خلفية، فيصحّ على كل خلفية. اختارهما
/// المالك (10 نوفمبر 2026) بعد صيغ عدة: الخاتم والزرادية لم يُقرآ «تكسيرًا»
/// على المقاس الصغير.
///
/// التجديد اتجاهه من القديم إلى الجديد، فيُعكس في الواجهة العربية ليُقرأ من
/// اليمين إلى اليسار؛ التكسير لا اتجاه له فلا يُعكس.
class GoldOperationIcon extends StatelessWidget {
  const GoldOperationIcon(
    this.operation, {
    super.key,
    this.size,
    this.color,
    this.semanticLabel,
  });

  final GoldOperation operation;

  /// الحجم؛ إن لم يُعطَ فحجم `IconTheme` ثم ٢٤.
  final double? size;

  /// اللون؛ إن لم يُعطَ فلون `IconTheme`.
  final Color? color;

  /// اسم الأيقونة لقارئ الشاشة؛ إن لم يُعطَ فهي زخرفة بجوار نصّها.
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) {
    final iconTheme = IconTheme.of(context);
    final paint =
        color ?? iconTheme.color ?? Theme.of(context).colorScheme.onSurface;
    final side = size ?? iconTheme.size ?? 24;
    return SvgPicture.asset(
      operation.asset,
      width: side,
      height: side,
      matchTextDirection: operation == GoldOperation.renewal,
      theme: SvgTheme(currentColor: paint),
      semanticsLabel: semanticLabel,
      excludeFromSemantics: semanticLabel == null,
    );
  }
}
