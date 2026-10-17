import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/widgets/app_table.dart';

/// UI-4 (ADR-049): a list's table is as wide as the room it is given.
void main() {
  const columns = {
    'number': AppTableColumn(100),
    'party': AppTableColumn(150, grow: 3),
    'note': AppTableColumn(100, grow: 1),
    'amount': AppTableColumn(120),
  };

  test('spare room is shared by grow; the rest keep their width', () {
    final fit = fitTableColumns(columns, 870); // 400 spare over 470 least
    expect(fit.width, 870);
    expect(fit.widths, {
      'number': 100,
      'party': 150 + 300,
      'note': 100 + 100,
      'amount': 120,
    });
  });

  test('too little room: every column its least, and the table scrolls', () {
    final fit = fitTableColumns(columns, 300);
    expect(fit.width, 470);
    expect(fit.widths['party'], 150);
  });

  test('no column grows: the table keeps its own width', () {
    final fit = fitTableColumns(const {'a': AppTableColumn(100)}, 900);
    expect(fit.width, 100);
  });

  testWidgets('in a side panel it is the panel\'s width, not the screen\'s', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Row(
            children: [
              const SizedBox(width: 800),
              SizedBox(
                width: 600,
                child: AppTableFrame(
                  columns: columns,
                  header: (w) => const SizedBox(height: 40),
                  rowCount: 3,
                  row: (_, i, w) => SizedBox(height: 40, child: Text('row $i')),
                  onRefresh: () async {},
                ),
              ),
            ],
          ),
        ),
      ),
    );
    expect(tester.getSize(find.byKey(const Key('app-table'))).width, 600);
    expect(find.text('row 2'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
