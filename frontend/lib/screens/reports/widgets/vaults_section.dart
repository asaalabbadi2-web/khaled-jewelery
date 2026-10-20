import 'dart:ui' show ImageFilter;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_staggered_animations/flutter_staggered_animations.dart';
import 'package:intl/intl.dart' hide TextDirection;
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../../api_service.dart';
import '../../../../theme/app_theme.dart';
import '../../../../providers/settings_provider.dart';
import '../../../../utils/party_balance.dart';
import '../../safe_boxes_screen.dart';
import '../safe_box_hero_details_screen.dart';

class VaultsSection extends StatefulWidget {
  final List<dynamic> safeBoxes;
  final ApiService api;
  final bool isArabic;
  final double Function(double) scale;
  final NumberFormat currencyFormat;
  final NumberFormat weightFormat;

  const VaultsSection({
    super.key,
    required this.safeBoxes,
    required this.api,
    required this.isArabic,
    required this.scale,
    required this.currencyFormat,
    required this.weightFormat,
  });

  @override
  State<VaultsSection> createState() => _VaultsSectionState();
}

class _VaultsSectionState extends State<VaultsSection> {
  int? _expandedId;
  int? _pressedId;
  bool _isReordering = false;
  List<int> _order = [];
  final Set<int> _recentIds = {};
  final ScrollController _scrollCtrl = ScrollController();
  static const String _kOrderKey = 'dashboard_vault_order';

  double _s(double v) => widget.scale(v);
  String _fmtC(double v) => widget.currencyFormat.format(v);
  String _fmtW(double v) =>
      '${widget.weightFormat.format(v)} ${widget.isArabic ? "جم" : "g"}';
  double _asDouble(dynamic v) => v is num ? v.toDouble() : 0.0;
  int _asInt(dynamic v) => v is int ? v : (v is num ? v.toInt() : int.tryParse(v?.toString() ?? '') ?? 0);

  @override
  void initState() {
    super.initState();
    _loadOrder();
  }

  @override
  void dispose() {
    _scrollCtrl.dispose();
    super.dispose();
  }

  Future<void> _loadOrder() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getStringList(_kOrderKey) ?? [];
      if (mounted) {
        setState(() {
          _order = raw.map((s) => int.tryParse(s)).whereType<int>().toList();
        });
      }
    } catch (_) {}
  }

  Future<void> _saveOrder() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setStringList(_kOrderKey, _order.map((id) => id.toString()).toList());
    } catch (_) {}
  }

  List<Map<String, dynamic>> _sorted(List<dynamic> raw) {
    final maps = raw.whereType<Map<String, dynamic>>().toList();
    final known = _order.toSet();
    for (final sb in maps) {
      final id = sb['id'];
      final sbId = id is int ? id : int.tryParse(id?.toString() ?? '');
      if (sbId != null && !known.contains(sbId)) {
        _order.add(sbId);
        known.add(sbId);
      }
    }
    maps.sort((a, b) {
      final aId = a['id'] is int ? a['id'] as int : int.tryParse(a['id']?.toString() ?? '') ?? -1;
      final bId = b['id'] is int ? b['id'] as int : int.tryParse(b['id']?.toString() ?? '') ?? -1;
      final aRecent = _recentIds.contains(aId);
      final bRecent = _recentIds.contains(bId);
      if (aRecent && !bRecent) return -1;
      if (!aRecent && bRecent) return 1;
      final aRank = _order.indexOf(aId).let((p) => p < 0 ? 9999 : p);
      final bRank = _order.indexOf(bId).let((p) => p < 0 ? 9999 : p);
      return aRank.compareTo(bRank);
    });
    return maps;
  }

  double _sbWeight(Map<String, dynamic> sb, String key) {
    final wb = sb['weight_balance'];
    if (wb is Map) {
      final raw = wb[key];
      if (raw is num) return raw.toDouble();
      return double.tryParse(raw?.toString() ?? '') ?? 0.0;
    }
    return 0.0;
  }

  @override
  Widget build(BuildContext context) {
    if (widget.safeBoxes.isEmpty) return const SizedBox.shrink();

    final theme = Theme.of(context);
    final isAr = widget.isArabic;
    final anyExpanded = _expandedId != null;
    final listHeight = anyExpanded ? _s(260) : _s(168);
    final sorted = _sorted(widget.safeBoxes);

    Widget buildCard(int index, Map<String, dynamic> sb, {bool reorderMode = false}) {
      final id = sb['id'];
      final sbId = id is int ? id : int.tryParse(id?.toString() ?? '');
      final heroTag = sbId != null ? 'vault_safe_box_$sbId' : 'vault_safe_box_$index';
      final isExpanded = sbId != null && sbId == _expandedId;
      final isPressed = sbId != null && sbId == _pressedId;

      return _buildCard(
        sb,
        heroTag: heroTag,
        isExpanded: isExpanded,
        isPressed: isPressed,
        reorderMode: reorderMode,
        onTap: () {
          if (sbId == null) return;
          setState(() => _expandedId = isExpanded ? null : sbId);
        },
        onOpenDetails: () {
          if (sbId != null) setState(() => _recentIds.add(sbId));
          Navigator.of(context).push(
            MaterialPageRoute(
              builder: (_) => SafeBoxHeroDetailsScreen(
                api: widget.api,
                isArabic: isAr,
                safeBox: sb,
                heroTag: heroTag,
              ),
            ),
          );
        },
        onPressChanged: (pressed) {
          if (sbId == null) return;
          setState(() {
            if (pressed) {
              _pressedId = sbId;
            } else if (_pressedId == sbId) {
              _pressedId = null;
            }
          });
        },
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: EdgeInsets.symmetric(horizontal: _s(16)),
          child: Row(
            children: [
              Icon(Icons.inventory_2, color: theme.colorScheme.primary, size: _s(22)),
              SizedBox(width: _s(8)),
              Text(
                isAr ? 'توزيع العهد والخزائن' : 'Vaults & Custody',
                style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold),
              ),
              const Spacer(),
              Tooltip(
                message: _isReordering
                    ? (isAr ? 'تم الترتيب' : 'Done')
                    : (isAr ? 'إعادة ترتيب' : 'Reorder'),
                child: IconButton(
                  icon: Icon(
                    _isReordering ? Icons.check_circle_outline : Icons.swap_horiz,
                    size: _s(20),
                    color: _isReordering ? theme.colorScheme.primary : theme.hintColor,
                  ),
                  onPressed: () => setState(() => _isReordering = !_isReordering),
                ),
              ),
              TextButton(
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => SafeBoxesScreen(
                      api: widget.api,
                    ),
                  ),
                ),
                child: Text(isAr ? 'عرض الكل' : 'View all'),
              ),
            ],
          ),
        ),
        SizedBox(height: _s(12)),
        SizedBox(
          height: listHeight,
          child: Listener(
            onPointerSignal: (event) {
              if (event is PointerScrollEvent) {
                final offset = (_scrollCtrl.offset + event.scrollDelta.dy * 1.5)
                    .clamp(0.0, _scrollCtrl.position.maxScrollExtent);
                _scrollCtrl.jumpTo(offset);
              }
            },
            child: _isReordering
                ? ReorderableListView.builder(
                    scrollDirection: Axis.horizontal,
                    scrollController: _scrollCtrl,
                    padding: EdgeInsets.symmetric(horizontal: _s(16)),
                    itemCount: sorted.length,
                    onReorder: (oldIndex, newIndex) {
                      setState(() {
                        if (newIndex > oldIndex) newIndex--;
                        final item = sorted.removeAt(oldIndex);
                        sorted.insert(newIndex, item);
                        _order = sorted
                            .map((sb) {
                              final id = sb['id'];
                              return id is int ? id : int.tryParse(id?.toString() ?? '');
                            })
                            .whereType<int>()
                            .toList();
                      });
                      _saveOrder();
                    },
                    itemBuilder: (context, index) {
                      final sb = sorted[index];
                      final id = sb['id'];
                      final sbId = id is int ? id : int.tryParse(id?.toString() ?? '');
                      return KeyedSubtree(
                        key: ValueKey(sbId ?? index),
                        child: buildCard(index, sb, reorderMode: true),
                      );
                    },
                  )
                : AnimationLimiter(
                    child: ListView.builder(
                      scrollDirection: Axis.horizontal,
                      controller: _scrollCtrl,
                      padding: EdgeInsets.symmetric(horizontal: _s(16)),
                      itemCount: sorted.length,
                      itemBuilder: (context, index) {
                        final sb = sorted[index];
                        return AnimationConfiguration.staggeredList(
                          position: index,
                          duration: const Duration(milliseconds: 420),
                          child: SlideAnimation(
                            verticalOffset: 18.0,
                            child: FadeInAnimation(child: buildCard(index, sb)),
                          ),
                        );
                      },
                    ),
                  ),
          ),
        ),
      ],
    );
  }

  Widget _buildCard(
    Map<String, dynamic> sb, {
    required String heroTag,
    required bool isExpanded,
    required bool isPressed,
    required VoidCallback onTap,
    required VoidCallback onOpenDetails,
    required ValueChanged<bool> onPressChanged,
    bool reorderMode = false,
  }) {
    final theme = Theme.of(context);
    final isAr = widget.isArabic;

    final name = sb['name'] ?? '-';
    final safeType = sb['safe_type'] ?? 'cash';
    final cashBalance = _asDouble(sb['balance_cash']);
    final goldBalance = _asDouble(sb['balance_gold_21k']);
    final hasActivity = sb['has_recent_activity'] == true;

    final w18 = _sbWeight(sb, '18k');
    final w21 = _sbWeight(sb, '21k');
    final w22 = _sbWeight(sb, '22k');
    final w24 = _sbWeight(sb, '24k');
    final totalMain = _asDouble(sb['total_weight_main_karat']);
    final hasWeightBreakdown = sb['weight_balance'] is Map;
    final mainKaratFromApi = _asInt(sb['main_karat']);
    final displayMainKarat = mainKaratFromApi > 0
        ? mainKaratFromApi
        : context.read<SettingsProvider>().mainKarat;

    double totalMainFallback() {
      // Every karat by its fineness -- 21 too: it was added as it was, as if
      // the main karat were always 21.
      return goldInMainKarat({18: w18, 21: w21, 22: w22, 24: w24}, displayMainKarat);
    }

    final totalMainEffective = totalMain > 0
        ? totalMain
        : (hasWeightBreakdown ? totalMainFallback() : 0.0);
    final physicalTotal = hasWeightBreakdown ? (w18 + w21 + w22 + w24) : 0.0;

    IconData icon;
    Color color;
    String subtitle;
    double primaryValue;
    String Function(double) primaryFormatter;
    String? primaryCaption;

    switch (safeType) {
      case 'gold':
        icon = Icons.auto_awesome;
        color = AppColors.primaryGold;
        primaryValue = isExpanded ? physicalTotal : totalMainEffective;
        primaryFormatter = _fmtW;
        subtitle = isAr ? 'ذهب' : 'Gold';
        primaryCaption = isExpanded
            ? (isAr ? 'إجمالي فعلي (جميع العيارات)' : 'Physical total (all karats)')
            : (isAr
                ? 'مكافئ العيار الرئيسي (${displayMainKarat}k)'
                : 'Main karat equivalent (${displayMainKarat}k)');
        break;
      case 'bank':
        icon = Icons.account_balance;
        color = Colors.blue;
        primaryValue = cashBalance;
        primaryFormatter = _fmtC;
        subtitle = isAr ? 'بنك' : 'Bank';
        break;
      default:
        icon = Icons.account_balance_wallet;
        color = Colors.green;
        primaryValue = cashBalance;
        primaryFormatter = _fmtC;
        subtitle = isAr ? 'نقد' : 'Cash';
    }

    final cardWidth = isExpanded ? _s(290) : _s(172);

    Widget buildDetailChip(String label, String value, {Color? chipColor}) {
      final c = chipColor ?? color;
      return Container(
        padding: EdgeInsets.symmetric(horizontal: _s(8), vertical: _s(5)),
        decoration: BoxDecoration(
          color: c.withValues(alpha: 0.10),
          borderRadius: BorderRadius.circular(_s(10)),
          border: Border.all(color: c.withValues(alpha: 0.28)),
        ),
        child: Text(
          '$label: $value',
          style: theme.textTheme.bodySmall?.copyWith(
            fontSize: _s(11),
            fontWeight: FontWeight.w600,
            color: theme.brightness == Brightness.dark ? Colors.white : Colors.black87,
          ),
        ),
      );
    }

    final details = safeType == 'gold'
        ? (hasWeightBreakdown
            ? Wrap(
                spacing: _s(8),
                runSpacing: _s(8),
                children: [
                  buildDetailChip('24k', _fmtW(w24), chipColor: AppColors.karat24),
                  buildDetailChip('22k', _fmtW(w22), chipColor: AppColors.karat22),
                  buildDetailChip('21k', _fmtW(w21), chipColor: AppColors.karat21),
                  buildDetailChip('18k', _fmtW(w18), chipColor: AppColors.karat18),
                ],
              )
            : Wrap(
                spacing: _s(8),
                runSpacing: _s(8),
                children: [
                  buildDetailChip('21k', _fmtW(goldBalance), chipColor: AppColors.karat21),
                  buildDetailChip(
                    isAr ? 'ملاحظة' : 'Note',
                    isAr ? 'تفصيل العيارات غير متوفر بعد' : 'Karat breakdown not available yet',
                    chipColor: theme.hintColor,
                  ),
                ],
              ))
        : Wrap(
            spacing: _s(8),
            runSpacing: _s(8),
            children: [
              buildDetailChip(isAr ? 'الرصيد' : 'Balance', _fmtC(cashBalance), chipColor: color),
            ],
          );

    final borderAccent = hasActivity ? Colors.green : theme.hintColor;
    final borderColor = borderAccent.withValues(alpha: hasActivity ? 0.55 : 0.25);
    final glowColor =
        (hasActivity ? Colors.green : color).withValues(alpha: isPressed ? 0.22 : (isExpanded ? 0.14 : 0.10));
    final glassBase = theme.colorScheme.surface.withValues(
      alpha: theme.brightness == Brightness.dark ? 0.25 : 0.78,
    );

    final heroIconTag = '${heroTag}_icon';
    final heroNameTag = '${heroTag}_name';

    final cardBody = Material(
      color: Colors.transparent,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(14),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 10, sigmaY: 10),
          child: InkWell(
            borderRadius: BorderRadius.circular(14),
            onTapDown: (_) => onPressChanged(true),
            onTapCancel: () => onPressChanged(false),
            onTap: () {
              onPressChanged(false);
              onTap();
            },
            child: AnimatedScale(
              duration: const Duration(milliseconds: 140),
              curve: Curves.easeOut,
              scale: isPressed ? 0.985 : 1.0,
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 260),
                curve: Curves.easeOutCubic,
                width: cardWidth,
                padding: EdgeInsets.all(_s(12)),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: borderColor, width: isPressed ? 1.2 : 1.0),
                  gradient: LinearGradient(
                    begin: AlignmentDirectional.topStart,
                    end: AlignmentDirectional.bottomEnd,
                    colors: [
                      glassBase.withValues(alpha: 0.88),
                      glassBase.withValues(alpha: 0.72),
                    ],
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: glowColor,
                      blurRadius: isPressed ? 18 : (isExpanded ? 16 : 12),
                      offset: const Offset(0, 8),
                    ),
                  ],
                ),
                child: Stack(
                  children: [
                    PositionedDirectional(
                      start: 0,
                      top: 0,
                      bottom: 0,
                      child: Container(
                        width: _s(4),
                        decoration: BoxDecoration(
                          color: color.withValues(alpha: hasActivity ? 0.85 : 0.55),
                          borderRadius: BorderRadiusDirectional.horizontal(
                            start: Radius.circular(_s(14)),
                          ),
                        ),
                      ),
                    ),
                    Padding(
                      padding: EdgeInsetsDirectional.only(start: _s(6)),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Hero(
                                tag: heroIconTag,
                                createRectTween: (begin, end) =>
                                    MaterialRectArcTween(begin: begin, end: end),
                                child: Material(
                                  color: Colors.transparent,
                                  child: Icon(icon, color: color, size: _s(20)),
                                ),
                              ),
                              SizedBox(width: _s(6)),
                              if (hasActivity)
                                Container(
                                  width: _s(9),
                                  height: _s(9),
                                  decoration: const BoxDecoration(
                                    color: Colors.green,
                                    shape: BoxShape.circle,
                                  ),
                                ),
                              const Spacer(),
                              InkResponse(
                                onTap: () {
                                  onPressChanged(false);
                                  onOpenDetails();
                                },
                                radius: _s(18),
                                child: Icon(Icons.open_in_new, color: theme.hintColor, size: _s(18)),
                              ),
                              SizedBox(width: _s(6)),
                              AnimatedRotation(
                                turns: isExpanded ? 0.5 : 0.0,
                                duration: const Duration(milliseconds: 220),
                                curve: Curves.easeOutCubic,
                                child: Icon(Icons.expand_more, color: theme.hintColor, size: _s(18)),
                              ),
                            ],
                          ),
                          SizedBox(height: _s(8)),
                          Hero(
                            tag: heroNameTag,
                            createRectTween: (begin, end) =>
                                MaterialRectArcTween(begin: begin, end: end),
                            child: Material(
                              color: Colors.transparent,
                              child: Tooltip(
                                message: name.toString(),
                                child: Text(
                                  name,
                                  style: theme.textTheme.bodySmall?.copyWith(
                                    fontWeight: FontWeight.w700,
                                    fontSize: _s(12.5),
                                  ),
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                            ),
                          ),
                          SizedBox(height: _s(2)),
                          Text(
                            subtitle,
                            style: theme.textTheme.bodySmall?.copyWith(
                              fontSize: _s(11),
                              color: theme.hintColor,
                            ),
                          ),
                          if (!isExpanded) const Spacer(),
                          SizedBox(height: _s(10)),
                          if (primaryCaption != null) ...[
                            Text(
                              primaryCaption,
                              style: theme.textTheme.bodySmall?.copyWith(
                                fontSize: _s(10.5),
                                color: theme.hintColor,
                                fontWeight: FontWeight.w600,
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            SizedBox(height: _s(6)),
                          ],
                          _AnimatedValueText(
                            value: primaryValue,
                            formatter: primaryFormatter,
                            style: theme.textTheme.bodyMedium?.copyWith(
                              fontWeight: FontWeight.bold,
                              color: color,
                              fontSize: _s(14),
                            ),
                          ),
                          AnimatedCrossFade(
                            firstChild: const SizedBox.shrink(),
                            secondChild: Padding(
                              padding: EdgeInsets.only(top: _s(12)),
                              child: details,
                            ),
                            crossFadeState: isExpanded
                                ? CrossFadeState.showSecond
                                : CrossFadeState.showFirst,
                            duration: const Duration(milliseconds: 240),
                            firstCurve: Curves.easeOut,
                            secondCurve: Curves.easeOutCubic,
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );

    return Container(
      margin: EdgeInsetsDirectional.only(start: _s(12)),
      child: cardBody,
    );
  }
}

// ─── tiny extension to avoid temp var ────────────────────────────────────────
extension _IntX on int {
  T let<T>(T Function(int) f) => f(this);
}

// ─── Animated value counter ───────────────────────────────────────────────────
class _AnimatedValueText extends StatefulWidget {
  final double value;
  final String Function(double) formatter;
  final TextStyle? style;

  const _AnimatedValueText({
    required this.value,
    required this.formatter,
    this.style,
  });

  @override
  State<_AnimatedValueText> createState() => _AnimatedValueTextState();
}

class _AnimatedValueTextState extends State<_AnimatedValueText> {
  late double _from;
  late double _to;

  @override
  void initState() {
    super.initState();
    _from = 0.0;
    _to = widget.value;
  }

  @override
  void didUpdateWidget(covariant _AnimatedValueText oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.value != widget.value) {
      _from = _to;
      _to = widget.value;
    }
  }

  @override
  Widget build(BuildContext context) {
    return TweenAnimationBuilder<double>(
      tween: Tween<double>(begin: _from, end: _to),
      duration: const Duration(milliseconds: 650),
      curve: Curves.easeOutCubic,
      builder: (context, v, _) => Text(widget.formatter(v), style: widget.style),
      onEnd: () => _from = _to,
    );
  }
}
