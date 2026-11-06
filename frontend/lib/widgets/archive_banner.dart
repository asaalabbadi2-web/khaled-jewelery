import 'package:flutter/material.dart';

import '../api_service.dart';
import '../theme/app_theme.dart';

/// ADR-044 phase 2: a closed year's archive says so above every screen, signed
/// in or not. The year is the server's (check-setup's archive_year); a working
/// year's says nothing. The archive refuses every write itself -- this only
/// says where one is.
class ArchiveBanner extends StatefulWidget {
  const ArchiveBanner({super.key, required this.child});
  final Widget child;

  @override
  State<ArchiveBanner> createState() => _ArchiveBannerState();
}

class _ArchiveBannerState extends State<ArchiveBanner> {
  int? _year;

  @override
  void initState() {
    super.initState();
    _read();
  }

  Future<void> _read() async {
    try {
      final setup = await ApiService().checkSetup();
      final year = setup['archive_year'];
      if (mounted && year is int) setState(() => _year = year);
    } catch (_) {
      // no answer: nothing is said -- the server still refuses what it must
    }
  }

  @override
  Widget build(BuildContext context) {
    final year = _year;
    if (year == null) return widget.child;
    final tone = AppSemanticColors.of(context).warning;
    return Column(
      children: [
        Material(
          color: tone.container,
          child: SafeArea(
            bottom: false,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: AppSpace.lg, vertical: AppSpace.sm),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.inventory_2_outlined, color: tone.onContainer, size: 18),
                  const SizedBox(width: AppSpace.sm),
                  Flexible(
                    child: Text(
                      'أرشيف $year — للقراءة فقط',
                      textDirection: TextDirection.rtl,
                      style: Theme.of(context).textTheme.titleSmall?.copyWith(color: tone.onContainer),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
        Expanded(child: widget.child),
      ],
    );
  }
}
