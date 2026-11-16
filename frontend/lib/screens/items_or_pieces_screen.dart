import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../api_service.dart';
import '../providers/settings_provider.dart';
import 'items_screen_enhanced.dart';
import 'pieces_screen.dart';

/// The one door to the stock's list (ADR-087 §8): the catalogue's items while
/// receiving is off -- 2026's base -- and the pieces once it works -- 2027's,
/// where a piece is born on receiving alone. The items' screen and this door
/// go with the old path after the opening (R6).
class ItemsOrPiecesScreen extends StatelessWidget {
  const ItemsOrPiecesScreen({super.key, required this.api});

  final ApiService api;

  @override
  Widget build(BuildContext context) => context.watch<SettingsProvider>().receivingActive
      ? PiecesScreen(api: api)
      : ItemsScreenEnhanced(api: api);
}
