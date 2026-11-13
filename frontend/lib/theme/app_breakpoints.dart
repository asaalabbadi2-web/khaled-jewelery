import 'package:flutter/widgets.dart';

/// The shop's devices, by width (the owner, 9 Nov 2026: «هاتف ايفون وتابلت
/// بحجم اي باد ميني»): an iPhone upright (375-430), an iPad mini upright
/// (744) or a phone on its side, and the counter's desktop. One place for the
/// thresholds the screens ask -- they were a dozen numbers, each its own.
enum DeviceClass { phone, tablet, wide }

abstract final class AppBreakpoints {
  /// From here a screen is a tablet's: an iPad mini upright is 744.
  static const double tablet = 600;

  /// From here two columns: the desktop, an iPad mini on its side (1133).
  static const double wide = 1100;

  static DeviceClass of(BuildContext context) => forWidth(MediaQuery.sizeOf(context).width);

  static DeviceClass forWidth(double width) =>
      width >= wide ? DeviceClass.wide : (width >= tablet ? DeviceClass.tablet : DeviceClass.phone);

  static bool isPhone(BuildContext context) => of(context) == DeviceClass.phone;

  /// A list's rows as cards on a phone, as a table from a tablet up (the owner,
  /// 13 Nov 2026: «في الشاشات الصغيره اجعل العرض كبطاقات»): the default of
  /// every list that has both; its own toggle still changes it.
  static bool listsAsCards(BuildContext context) => isPhone(context);
}
