// Smoke + flow tests for the bill splitter app.
//
// `main()` in lib/main.dart loads .env via flutter_dotenv before running the
// app. These tests bypass main() and pump screens directly, so we don't need
// the .env asset. None of the screens covered here call GeminiService.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:bill_splitter/main.dart';
import 'package:bill_splitter/gemini_service.dart';
import 'package:bill_splitter/storage.dart';

void main() {
  // Global notifiers persist across tests; reset them and the
  // SharedPreferences mock before each one so tests stay independent.
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    billHistoryNotifier.value = const [];
    themeModeNotifier.value = ThemeMode.system;
    mobileViewMode.value = false;
  });

  // ---------- Smoke tests ----------

  testWidgets('Home screen shows pick-receipt button and tagline',
      (tester) async {
    await tester.pumpWidget(const BillSplitterApp());

    expect(find.text('Bill Splitter'), findsOneWidget);
    expect(find.text('Pick a receipt'), findsOneWidget);
    expect(find.text('Split the bill with ease!'), findsOneWidget);
  });

  testWidgets('View mode toggle in AppBar flips mobileViewMode notifier',
      (tester) async {
    await tester.pumpWidget(const BillSplitterApp());

    // Initial: desktop view — icon should be smartphone (tap to switch to
    // mobile).
    expect(find.byTooltip('Switch to mobile view'), findsOneWidget);
    expect(mobileViewMode.value, isFalse);

    await tester.tap(find.byTooltip('Switch to mobile view'));
    await tester.pumpAndSettle();

    expect(mobileViewMode.value, isTrue);
    // Icon flipped — now offers a way back.
    expect(find.byTooltip('Switch to desktop view'), findsOneWidget);
  });

  // ---------- Item dialog ----------

  testWidgets('ItemFormDialog opens, accepts valid input, returns a BillItem',
      (tester) async {
    BillItem? saved;
    late BuildContext capturedContext;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) {
            capturedContext = context;
            return Center(
              child: ElevatedButton(
                onPressed: () async {
                  saved = await showDialog<BillItem>(
                    context: capturedContext,
                    builder: (_) => const ItemFormDialog(
                      title: 'Add Item',
                      initialName: '',
                      initialQty: 1,
                      initialPrice: 0,
                    ),
                  );
                },
                child: const Text('OPEN'),
              ),
            );
          },
        ),
      ),
    ));

    await tester.tap(find.text('OPEN'));
    await tester.pumpAndSettle();

    // Dialog is up.
    expect(find.text('Add Item'), findsOneWidget);

    // Find the three fields by their labels.
    final nameField = find.widgetWithText(TextFormField, 'Name');
    final qtyField = find.widgetWithText(TextFormField, 'Quantity');
    final priceField = find.widgetWithText(TextFormField, 'Price');

    await tester.enterText(nameField, 'Pasta');
    await tester.enterText(qtyField, '2');
    await tester.enterText(priceField, '120.50');

    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    // Dialog closed, item returned.
    expect(find.text('Add Item'), findsNothing);
    expect(saved, isNotNull);
    expect(saved!.name, 'Pasta');
    expect(saved!.quantity, 2);
    expect(saved!.price, 120.5);
  });

  testWidgets('ItemFormDialog rejects empty name, negative price, qty < 1',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => Center(
            child: ElevatedButton(
              onPressed: () => showDialog<BillItem>(
                context: context,
                builder: (_) => const ItemFormDialog(
                  title: 'Add Item',
                  initialName: '',
                  initialQty: 1,
                  initialPrice: 0,
                ),
              ),
              child: const Text('OPEN'),
            ),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('OPEN'));
    await tester.pumpAndSettle();

    final qtyField = find.widgetWithText(TextFormField, 'Quantity');
    final priceField = find.widgetWithText(TextFormField, 'Price');

    // Leave name empty; set qty to 0; set price to -5.
    await tester.enterText(qtyField, '0');
    await tester.enterText(priceField, '-5');
    await tester.tap(find.text('Save'));
    await tester.pump();

    // All three errors should appear inline. Dialog stays open.
    expect(find.text('Required'), findsOneWidget);
    expect(find.text('Must be at least 1'), findsOneWidget);
    expect(find.text('Cannot be negative'), findsOneWidget);
    expect(find.text('Add Item'), findsOneWidget);
  });

  testWidgets('ItemFormDialog preserves existingId when editing',
      (tester) async {
    BillItem? saved;
    final original = BillItem(
        id: 'fixed-id-123', name: 'Old', quantity: 1, price: 10);

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => Center(
            child: ElevatedButton(
              onPressed: () async {
                saved = await showDialog<BillItem>(
                  context: context,
                  builder: (_) => ItemFormDialog(
                    title: 'Edit Item',
                    initialName: original.name,
                    initialQty: original.quantity,
                    initialPrice: original.price,
                    existingId: original.id,
                  ),
                );
              },
              child: const Text('OPEN'),
            ),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('OPEN'));
    await tester.pumpAndSettle();

    final nameField = find.widgetWithText(TextFormField, 'Name');
    await tester.enterText(nameField, 'Renamed');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    expect(saved, isNotNull);
    expect(saved!.id, 'fixed-id-123');
    expect(saved!.name, 'Renamed');
    expect(saved!.quantity, 1);
    expect(saved!.price, 10);
  });

  testWidgets('ItemFormDialog cancel returns null and disposes cleanly',
      (tester) async {
    BillItem? saved = BillItem(name: 'sentinel', quantity: 1, price: 0);
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => Center(
            child: ElevatedButton(
              onPressed: () async {
                saved = await showDialog<BillItem>(
                  context: context,
                  builder: (_) => const ItemFormDialog(
                    title: 'Edit Item',
                    initialName: 'foo',
                    initialQty: 1,
                    initialPrice: 5,
                  ),
                );
              },
              child: const Text('OPEN'),
            ),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('OPEN'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();

    expect(saved, isNull);
    // No exceptions thrown (would surface in tester.takeException()).
    expect(tester.takeException(), isNull);
  });

  // ---------- Amount dialog ----------

  testWidgets('AmountFormDialog saves a non-negative number', (tester) async {
    double? saved;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => Center(
            child: ElevatedButton(
              onPressed: () async {
                saved = await showDialog<double>(
                  context: context,
                  builder: (_) =>
                      const AmountFormDialog(label: 'Tax', initial: 0),
                );
              },
              child: const Text('OPEN'),
            ),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('OPEN'));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextFormField), '15.75');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    expect(saved, 15.75);
  });

  testWidgets('AmountFormDialog rejects negative and non-numeric',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => Center(
            child: ElevatedButton(
              onPressed: () => showDialog<double>(
                context: context,
                builder: (_) =>
                    const AmountFormDialog(label: 'Tip', initial: 0),
              ),
              child: const Text('OPEN'),
            ),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('OPEN'));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextFormField), '-3');
    await tester.tap(find.text('Save'));
    await tester.pump();
    expect(find.text('Cannot be negative'), findsOneWidget);

    await tester.enterText(find.byType(TextFormField), 'abc');
    await tester.tap(find.text('Save'));
    await tester.pump();
    expect(find.text('Enter a number'), findsOneWidget);
  });

  // ---------- People screen ----------

  testWidgets('PeopleScreen rejects duplicate names case-insensitively',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: PeopleScreen(
        items: [BillItem(name: 'Coffee', quantity: 1, price: 50)],
        tax: 0,
        tip: 0,
      ),
    ));

    final textField = find.byType(TextField);

    await tester.enterText(textField, 'Alice');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump();
    expect(find.text('Alice'), findsOneWidget);

    await tester.enterText(textField, 'alice');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump();

    expect(find.text('Alice is already added'), findsOneWidget);
    expect(find.byType(ListTile), findsOneWidget);
  });

  testWidgets('PeopleScreen continue button enables only with 2+ people',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: PeopleScreen(
        items: [BillItem(name: 'Coffee', quantity: 1, price: 50)],
        tax: 0,
        tip: 0,
      ),
    ));

    final textField = find.byType(TextField);
    final continueButton =
        find.widgetWithText(FilledButton, 'Continue to assign items');

    // 0 people: button disabled.
    expect(tester.widget<FilledButton>(continueButton).onPressed, isNull);

    // 1 person: still disabled.
    await tester.enterText(textField, 'Alice');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump();
    expect(tester.widget<FilledButton>(continueButton).onPressed, isNull);

    // 2 people: enabled.
    await tester.enterText(textField, 'Bob');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump();
    expect(tester.widget<FilledButton>(continueButton).onPressed, isNotNull);
  });

  // ---------- Assign screen ----------

  testWidgets(
      'AssignScreen blocks See summary until every item has an assignee',
      (tester) async {
    final item1 = BillItem(name: 'Pasta', quantity: 1, price: 60);
    final item2 = BillItem(name: 'Soup', quantity: 1, price: 40);

    await tester.pumpWidget(MaterialApp(
      home: AssignScreen(
        items: [item1, item2],
        people: const ['Alice', 'Bob'],
        tax: 0,
        tip: 0,
      ),
    ));

    final seeSummary = find.widgetWithText(FilledButton, 'See summary');
    expect(tester.widget<FilledButton>(seeSummary).onPressed, isNull);
    expect(find.text('2 items not assigned yet'), findsOneWidget);

    // Assign Alice to Pasta — still one item unassigned.
    await tester.tap(find.widgetWithText(FilterChip, 'Alice').first);
    await tester.pump();
    expect(tester.widget<FilledButton>(seeSummary).onPressed, isNull);
    expect(find.text('1 item not assigned yet'), findsOneWidget);

    // Assign Bob to Soup — all assigned, button enables.
    await tester.tap(find.widgetWithText(FilterChip, 'Bob').last);
    await tester.pump();
    expect(tester.widget<FilledButton>(seeSummary).onPressed, isNotNull);
    expect(find.textContaining('not assigned yet'), findsNothing);
  });

  testWidgets('AssignScreen "Everyone" chip assigns all people to the item',
      (tester) async {
    final item = BillItem(name: 'Pizza', quantity: 1, price: 90);

    await tester.pumpWidget(MaterialApp(
      home: AssignScreen(
        items: [item],
        people: const ['Alice', 'Bob', 'Carol'],
        tax: 0,
        tip: 0,
      ),
    ));

    await tester.tap(find.widgetWithText(ActionChip, 'Everyone'));
    await tester.pump();

    // Per-person share line shows ₹30.00.
    expect(find.text('₹30.00 per person'), findsOneWidget);

    // All three FilterChips selected.
    for (final name in ['Alice', 'Bob', 'Carol']) {
      final chip = tester.widget<FilterChip>(
          find.widgetWithText(FilterChip, name));
      expect(chip.selected, isTrue, reason: '$name should be selected');
    }
  });

  // ---------- Summary math ----------

  testWidgets('Summary splits tax/tip proportionally to per-person subtotal',
      (tester) async {
    final item1 = BillItem(name: 'Pasta', quantity: 1, price: 60);
    final item2 = BillItem(name: 'Soup', quantity: 1, price: 40);

    await tester.pumpWidget(MaterialApp(
      home: SummaryScreen(
        items: [item1, item2],
        people: const ['Alice', 'Bob'],
        assignments: {
          item1.id: {'Alice'},
          item2.id: {'Bob'},
        },
        tax: 10,
        tip: 20,
      ),
    ));

    expect(find.text('₹78.00'), findsOneWidget); // Alice per-person total
    expect(find.text('₹52.00'), findsOneWidget); // Bob per-person total
    // Bill grand total rounded to whole rupees, shown in captured header + bottom bar.
    expect(find.text('₹130'), findsNWidgets(2));
  });

  testWidgets('Summary splits a shared item equally among assignees',
      (tester) async {
    final item = BillItem(name: 'Pizza', quantity: 1, price: 90);

    await tester.pumpWidget(MaterialApp(
      home: SummaryScreen(
        items: [item],
        people: const ['Alice', 'Bob', 'Carol'],
        assignments: {
          item.id: {'Alice', 'Bob', 'Carol'},
        },
        tax: 0,
        tip: 0,
      ),
    ));

    // 3 person cards × 3 instances of ₹30.00 each (per-person header total,
    // line item share, subtotal mini-row) = 9.
    expect(find.text('₹30.00'), findsNWidgets(9));
    // Bill grand total in captured header + bottom bar — rounded to whole rupees.
    expect(find.text('₹90'), findsNWidgets(2));
  });

  // ---------- Rounding (grand total only) ----------

  test('fmtMoney always uses 2 decimals', () {
    expect(fmtMoney(0), '₹0.00');
    expect(fmtMoney(100), '₹100.00');
    expect(fmtMoney(100.5), '₹100.50');
    expect(fmtMoney(100.567), '₹100.57'); // standard rounding
    expect(fmtMoney(99.999), '₹100.00');
  });

  test('fmtTotal rounds to whole rupees with no decimal point', () {
    expect(fmtTotal(0), '₹0');
    expect(fmtTotal(100), '₹100');
    expect(fmtTotal(100.4), '₹100');
    expect(fmtTotal(100.6), '₹101');
    expect(fmtTotal(99.999), '₹100');
    expect(fmtTotal(0.4), '₹0');
    // No '.' anywhere in the output.
    expect(fmtTotal(123.45), isNot(contains('.')));
  });

  test('formatBillSummary rounds only the grand total — components keep 2dp',
      () {
    // Real-bill scenario: subtotal 423.56, tax 54.45 → total 478.01.
    final item = BillItem(name: 'Combo', quantity: 1, price: 423.56);
    final text = formatBillSummary(
      items: [item],
      people: const ['Alice'],
      assignments: {
        item.id: {'Alice'},
      },
      tax: 54.45,
      tip: 0,
    );

    // Grand total rounded.
    expect(text, contains('Total ₹478'));
    expect(text, isNot(contains('Total ₹478.01')));
    // Per-person total NOT rounded (the customer's accurate share).
    expect(text, contains('Alice owes ₹478.01'));
    // Line item NOT rounded.
    expect(text, contains('• Combo — ₹423.56'));
    // Tax share NOT rounded.
    expect(text, contains('Tax share: ₹54.45'));
  });

  testWidgets(
      'SummaryScreen renders grand total rounded and per-person amounts at 2dp',
      (tester) async {
    // Subtotal 423.56, tax 54.45, tip 0 → total 478.01, rounded display ₹478.
    final item = BillItem(name: 'Combo', quantity: 1, price: 423.56);
    await tester.pumpWidget(MaterialApp(
      home: SummaryScreen(
        items: [item],
        people: const ['Alice', 'Bob'],
        assignments: {
          item.id: {'Alice', 'Bob'},
        },
        tax: 54.45,
        tip: 0,
      ),
    ));

    // Grand total: ₹478 (rounded), shown in header + bottom bar.
    expect(find.text('₹478'), findsNWidgets(2));
    // Not the unrounded form.
    expect(find.text('₹478.01'), findsNothing);
    // Per-person totals (239.005 each, rounded by toStringAsFixed(2) to 239.01
    // or 239.00 depending on banker's rounding) — assert it shows with .XX.
    // We don't pin the exact value; just verify each person shows a 2dp value.
    final perPersonTexts =
        find.byWidgetPredicate((w) => w is Text && (w.data?.startsWith('₹239.') ?? false));
    expect(perPersonTexts.evaluate().length, greaterThanOrEqualTo(2));
  });

  // ---------- Edge cases ----------

  test('formatBillSummary on an empty bill (no items, no tax/tip) is sane',
      () {
    final text = formatBillSummary(
      items: const [],
      people: const ['Alice', 'Bob'],
      assignments: const {},
      tax: 0,
      tip: 0,
    );
    expect(text, contains('Total ₹0'));
    expect(text, contains('Alice owes ₹0.00'));
    expect(text, contains('Bob owes ₹0.00'));
    expect(text, contains('(no items assigned)'));
  });

  test('computeBillBreakdown handles empty people list without crashing', () {
    final item = BillItem(name: 'A', quantity: 1, price: 50);
    final result = computeBillBreakdown(
      items: [item],
      people: const [],
      assignments: const {},
      tax: 10,
      tip: 5,
    );
    expect(result, isEmpty);
  });

  test('Item assigned to nobody contributes nothing to per-person totals', () {
    final eaten = BillItem(name: 'Eaten', quantity: 1, price: 100);
    final orphan = BillItem(name: 'Orphan', quantity: 1, price: 50);
    final result = computeBillBreakdown(
      items: [eaten, orphan],
      people: const ['Alice'],
      assignments: {
        eaten.id: {'Alice'},
        // orphan deliberately left unassigned
      },
      tax: 0,
      tip: 0,
    );
    expect(result['Alice']!.subtotal, 100);
    expect(result['Alice']!.lines, hasLength(1));
    expect(result['Alice']!.lines.first.$1, 'Eaten');
  });

  test('formatBillSummary handles a single-person split', () {
    final item = BillItem(name: 'Solo', quantity: 1, price: 100);
    final text = formatBillSummary(
      items: [item],
      people: const ['Alice'],
      assignments: {
        item.id: {'Alice'},
      },
      tax: 10,
      tip: 5,
    );
    expect(text, contains('Alice owes ₹115.00'));
    expect(text, contains('Tax share: ₹10.00'));
    expect(text, contains('Tip share: ₹5.00'));
  });

  test('Shared item among many people splits evenly with no rounding error',
      () {
    // ₹100 split 8 ways = ₹12.50 each.
    final item = BillItem(name: 'Cake', quantity: 1, price: 100);
    final people =
        List<String>.generate(8, (i) => 'Person$i', growable: false);
    final result = computeBillBreakdown(
      items: [item],
      people: people,
      assignments: {item.id: people.toSet()},
      tax: 0,
      tip: 0,
    );
    for (final p in people) {
      expect(result[p]!.subtotal, 12.5);
      expect(result[p]!.total, 12.5);
    }
    final totalSum = result.values.fold<double>(0, (s, b) => s + b.total);
    expect(totalSum, closeTo(100, 1e-9));
  });

  test(
      'BillItem.fromJson tolerates missing fields and weird types via defaults',
      () {
    // Empty JSON → fallbacks (name 'Unknown', qty 1, price 0).
    final a = BillItem.fromJson(<String, dynamic>{});
    expect(a.name, 'Unknown');
    expect(a.quantity, 1);
    expect(a.price, 0.0);

    // Numeric strings that aren't numbers don't crash — they fall through
    // the `as num?` cast (which returns null) and default.
    final b = BillItem.fromJson(<String, dynamic>{
      'item_name': 42, // non-string name
      'quantity': null,
      'price': null,
    });
    expect(b.name, '42'); // toString() of the int
    expect(b.quantity, 1);
    expect(b.price, 0.0);
  });

  test('BillItem.copyWith preserves id and overrides only specified fields',
      () {
    final original = BillItem(
        id: 'fixed-1', name: 'A', quantity: 2, price: 50);
    final renamed = original.copyWith(name: 'B');
    expect(renamed.id, 'fixed-1');
    expect(renamed.name, 'B');
    expect(renamed.quantity, 2);
    expect(renamed.price, 50);

    final repriced = original.copyWith(price: 75);
    expect(repriced.id, 'fixed-1');
    expect(repriced.name, 'A');
    expect(repriced.price, 75);
  });

  test(
      'Auto-generated BillItem ids are unique even when created rapidly',
      () {
    final items = List.generate(
        50, (i) => BillItem(name: 'I$i', quantity: 1, price: 10));
    final ids = items.map((i) => i.id).toSet();
    expect(ids.length, 50, reason: 'all ids should be distinct');
  });

  test('Equal-split fallback when bill subtotal is 0 distributes tax+tip',
      () {
    final result = computeBillBreakdown(
      items: const [],
      people: const ['A', 'B', 'C', 'D'],
      assignments: const {},
      tax: 12,
      tip: 8,
    );
    for (final p in ['A', 'B', 'C', 'D']) {
      expect(result[p]!.taxShare, 3); // 12 / 4
      expect(result[p]!.tipShare, 2); // 8 / 4
      expect(result[p]!.total, 5);
    }
  });

  test(
      'formatBillSummary with a large bill produces a single readable string',
      () {
    final items = List.generate(
        20,
        (i) => BillItem(
            name: 'Item ${i + 1}', quantity: 1, price: 100.0 + i));
    final people = const ['Alice', 'Bob', 'Carol'];
    final assignments = {
      for (var i = 0; i < items.length; i++)
        items[i].id: {people[i % 3]},
    };
    final text = formatBillSummary(
      items: items,
      people: people,
      assignments: assignments,
      tax: 53.27,
      tip: 0,
    );
    // Sanity: contains the header and every person.
    expect(text, contains('Bill split — Total'));
    for (final p in people) {
      expect(text, contains('$p owes ₹'));
    }
    // No "Tax share" lines for amounts that round to 0.00.
    // Every "₹" line should be either ₹X (total) or ₹X.YY (everything else).
    final lines = text.split('\n');
    for (final line in lines) {
      if (!line.contains('₹')) continue;
      // Either it's the grand-total line (ends with "₹\d+"), or all other
      // ₹ values in the line should have ".XX" precision.
      if (line.startsWith('Bill split')) continue;
      final amounts = RegExp(r'₹[\d.]+').allMatches(line);
      for (final m in amounts) {
        final amount = m.group(0)!;
        expect(amount.contains('.') && amount.split('.').last.length == 2,
            isTrue,
            reason: 'Expected 2dp in non-total amount "$amount" on line "$line"');
      }
    }
  });

  // ---------- Share / copy ----------

  test('formatBillSummary produces a readable per-person breakdown', () {
    final pasta = BillItem(name: 'Pasta', quantity: 1, price: 60);
    final wine = BillItem(name: 'Wine', quantity: 1, price: 40);
    final text = formatBillSummary(
      items: [pasta, wine],
      people: const ['Alice', 'Bob'],
      assignments: {
        pasta.id: {'Alice'},
        wine.id: {'Alice', 'Bob'},
      },
      tax: 10,
      tip: 0,
    );

    // Header with grand total (rounded — restaurants round the total).
    expect(text, contains('Total ₹110'));
    // Per-person totals.
    //   Alice: pasta 60 + wine/2 20 = 80, tax = 10 * 80/100 = 8 → 88
    //   Bob:   wine/2 20,             tax = 10 * 20/100 = 2 → 22
    expect(text, contains('Alice owes ₹88.00'));
    expect(text, contains('Bob owes ₹22.00'));
    // Item lines.
    expect(text, contains('• Pasta — ₹60.00'));
    expect(text, contains('• Wine — ₹20.00'));
    // Tax lines (Alice and Bob both have tax > 0).
    expect(text, contains('Tax share: ₹8.00'));
    expect(text, contains('Tax share: ₹2.00'));
    // Tip is 0 so no "Tip share" line.
    expect(text, isNot(contains('Tip share')));
  });

  test('formatBillSummary handles a person with no items assigned', () {
    final item = BillItem(name: 'Coffee', quantity: 1, price: 50);
    final text = formatBillSummary(
      items: [item],
      people: const ['Alice', 'Bob'],
      assignments: {
        item.id: {'Alice'},
      },
      tax: 0,
      tip: 0,
    );
    expect(text, contains('Alice owes ₹50.00'));
    expect(text, contains('Bob owes ₹0.00'));
    expect(text, contains('(no items assigned)'));
  });

  testWidgets('Share button on summary opens a sheet with three options',
      (tester) async {
    final item = BillItem(name: 'Coffee', quantity: 1, price: 50);
    await tester.pumpWidget(MaterialApp(
      home: SummaryScreen(
        items: [item],
        people: const ['Alice', 'Bob'],
        assignments: {
          item.id: {'Alice', 'Bob'},
        },
        tax: 0,
        tip: 0,
      ),
    ));

    expect(find.byTooltip('Share'), findsOneWidget);
    await tester.tap(find.byTooltip('Share'));
    await tester.pumpAndSettle();

    expect(find.text('Share as text'), findsOneWidget);
    expect(find.text('Copy to clipboard'), findsOneWidget);
    expect(find.text('Share as image'), findsOneWidget);
  });

  testWidgets('Copy to clipboard puts the formatted summary on the clipboard',
      (tester) async {
    // Intercept the platform clipboard channel so we can read what was set.
    String? captured;
    TestWidgetsFlutterBinding.ensureInitialized();
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          captured = (call.arguments as Map)['text'] as String?;
        }
        return null;
      },
    );

    final item = BillItem(name: 'Coffee', quantity: 1, price: 50);
    await tester.pumpWidget(MaterialApp(
      home: SummaryScreen(
        items: [item],
        people: const ['Alice', 'Bob'],
        assignments: {
          item.id: {'Alice', 'Bob'},
        },
        tax: 0,
        tip: 0,
      ),
    ));

    await tester.tap(find.byTooltip('Share'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Copy to clipboard'));
    await tester.pumpAndSettle();

    expect(captured, isNotNull);
    expect(captured!, contains('Alice owes ₹25.00'));
    expect(captured!, contains('Bob owes ₹25.00'));
    expect(find.text('Summary copied to clipboard'), findsOneWidget);
  });

  testWidgets('Summary falls back to equal split when bill subtotal is 0',
      (tester) async {
    // No items, but tax+tip still need to split. Should distribute equally.
    await tester.pumpWidget(MaterialApp(
      home: SummaryScreen(
        items: const [],
        people: const ['Alice', 'Bob'],
        assignments: const {},
        tax: 10,
        tip: 0,
      ),
    ));

    // Each owes ₹5.00. Grand total ₹10.
    // Per person: header ₹5.00 + tax mini-row ₹5.00 = 2 per card × 2 = 4.
    expect(find.text('₹5.00'), findsNWidgets(4));
    // Bill grand total rounded, in captured header + bottom bar.
    expect(find.text('₹10'), findsNWidgets(2));
  });

  // ---------- Storage / history ----------

  test('SavedBill JSON roundtrip preserves all fields including assignments',
      () {
    final pasta = BillItem(name: 'Pasta', quantity: 1, price: 60);
    final wine = BillItem(name: 'Wine', quantity: 1, price: 40);
    final original = SavedBill(
      id: 'bill_42',
      savedAt: DateTime(2026, 5, 18, 19, 30),
      items: [pasta, wine],
      people: const ['Alice', 'Bob'],
      assignments: {
        pasta.id: {'Alice'},
        wine.id: {'Alice', 'Bob'},
      },
      tax: 10.5,
      tip: 5,
    );
    final restored = SavedBill.fromJson(original.toJson());

    expect(restored.id, original.id);
    expect(restored.savedAt, original.savedAt);
    expect(restored.tax, original.tax);
    expect(restored.tip, original.tip);
    expect(restored.people, original.people);
    expect(restored.items, hasLength(2));
    expect(restored.items[0].id, pasta.id);
    expect(restored.items[0].name, 'Pasta');
    expect(restored.items[0].price, 60);
    // Assignments preserved as Sets, not Lists.
    expect(restored.assignments[pasta.id], equals({'Alice'}));
    expect(restored.assignments[wine.id], equals({'Alice', 'Bob'}));
    expect(restored.grandTotal, closeTo(60 + 40 + 10.5 + 5, 1e-9));
  });

  test('BillHistoryService.add inserts newest-first and updates the notifier',
      () async {
    final first = SavedBill(
      id: '1',
      savedAt: DateTime(2026, 1, 1),
      items: const [],
      people: const ['Alice'],
      assignments: const {},
      tax: 0,
      tip: 0,
    );
    final second = SavedBill(
      id: '2',
      savedAt: DateTime(2026, 1, 2),
      items: const [],
      people: const ['Bob'],
      assignments: const {},
      tax: 0,
      tip: 0,
    );

    await BillHistoryService.add(first);
    await BillHistoryService.add(second);

    expect(billHistoryNotifier.value, hasLength(2));
    // Newest first.
    expect(billHistoryNotifier.value[0].id, '2');
    expect(billHistoryNotifier.value[1].id, '1');
  });

  test(
      'BillHistoryService.delete removes the bill from disk and the notifier',
      () async {
    final bill = SavedBill(
      id: 'gone',
      savedAt: DateTime(2026, 1, 1),
      items: const [],
      people: const ['Alice'],
      assignments: const {},
      tax: 0,
      tip: 0,
    );
    await BillHistoryService.add(bill);
    expect(billHistoryNotifier.value, hasLength(1));

    await BillHistoryService.delete('gone');
    expect(billHistoryNotifier.value, isEmpty);

    // And on a fresh load from disk, still gone.
    final reloaded = await BillHistoryService.load();
    expect(reloaded, isEmpty);
  });

  test(
      'BillHistoryService.load returns empty when the stored JSON is corrupt',
      () async {
    SharedPreferences.setMockInitialValues(
        {'bill_history_v1': 'not valid json {{'});
    final bills = await BillHistoryService.load();
    expect(bills, isEmpty);
  });

  // ---------- Theme mode ----------

  test('SettingsService persists and reloads theme mode', () async {
    await SettingsService.setThemeMode(ThemeMode.dark);
    expect(themeModeNotifier.value, ThemeMode.dark);

    // Simulate a fresh app launch: reset the notifier, re-initialize.
    themeModeNotifier.value = ThemeMode.system;
    await SettingsService.initialize();
    expect(themeModeNotifier.value, ThemeMode.dark);
  });

  testWidgets(
      'Theme toggle cycles system → light → dark → system and updates icon',
      (tester) async {
    await tester.pumpWidget(const BillSplitterApp());

    // Starts at "system" — the auto-brightness icon is shown.
    expect(find.byIcon(Icons.brightness_auto), findsOneWidget);

    await tester.tap(find.byIcon(Icons.brightness_auto));
    await tester.pumpAndSettle();
    expect(themeModeNotifier.value, ThemeMode.light);
    expect(find.byIcon(Icons.light_mode_outlined), findsOneWidget);

    await tester.tap(find.byIcon(Icons.light_mode_outlined));
    await tester.pumpAndSettle();
    expect(themeModeNotifier.value, ThemeMode.dark);
    expect(find.byIcon(Icons.dark_mode_outlined), findsOneWidget);

    await tester.tap(find.byIcon(Icons.dark_mode_outlined));
    await tester.pumpAndSettle();
    expect(themeModeNotifier.value, ThemeMode.system);
  });

  // ---------- Home screen history list ----------

  testWidgets('Home screen hides recent splits header when history is empty',
      (tester) async {
    await tester.pumpWidget(const BillSplitterApp());
    expect(find.text('Recent splits'), findsNothing);
    // Full hero (with tagline) is shown.
    expect(find.text('Split the bill with ease!'), findsOneWidget);
  });

  testWidgets(
      'Home screen shows recent splits with rich rows once history exists',
      (tester) async {
    final item = BillItem(name: 'Coffee', quantity: 1, price: 100);
    await BillHistoryService.add(SavedBill(
      id: 'h1',
      savedAt: DateTime.now(),
      items: [item],
      people: const ['Alice', 'Bob'],
      assignments: {
        item.id: {'Alice', 'Bob'},
      },
      tax: 0,
      tip: 0,
    ));

    await tester.pumpWidget(const BillSplitterApp());
    await tester.pumpAndSettle();

    expect(find.text('Recent splits'), findsOneWidget);
    expect(find.text('2 people · 1 item'), findsOneWidget);
    expect(find.text('₹100'), findsOneWidget); // rounded total in history pill
    // Compact hero: no tagline (only shown in the empty/landing state).
    expect(find.text('Split the bill with ease!'), findsNothing);
    expect(find.text('Pick a receipt'), findsOneWidget);
  });

  testWidgets('Swiping a history row deletes the bill', (tester) async {
    final bill = SavedBill(
      id: 'swipe-me',
      savedAt: DateTime.now(),
      items: const [],
      people: const ['Alice'],
      assignments: const {},
      tax: 0,
      tip: 0,
    );
    await BillHistoryService.add(bill);

    await tester.pumpWidget(const BillSplitterApp());
    await tester.pumpAndSettle();

    expect(find.byType(Dismissible), findsOneWidget);
    await tester.drag(find.byType(Dismissible), const Offset(-500, 0));
    await tester.pumpAndSettle();

    expect(billHistoryNotifier.value, isEmpty);
    expect(find.byType(Dismissible), findsNothing);
  });

  testWidgets(
      'SummaryScreen with saveToHistory: false does not insert into history',
      (tester) async {
    final item = BillItem(name: 'Coffee', quantity: 1, price: 50);
    await tester.pumpWidget(MaterialApp(
      home: SummaryScreen(
        items: [item],
        people: const ['Alice'],
        assignments: {
          item.id: {'Alice'},
        },
        tax: 0,
        tip: 0,
        saveToHistory: false,
      ),
    ));
    await tester.pumpAndSettle();

    expect(billHistoryNotifier.value, isEmpty);
  });

  testWidgets('SummaryScreen auto-saves to history on first render',
      (tester) async {
    final item = BillItem(name: 'Coffee', quantity: 1, price: 50);
    await tester.pumpWidget(MaterialApp(
      home: SummaryScreen(
        items: [item],
        people: const ['Alice', 'Bob'],
        assignments: {
          item.id: {'Alice', 'Bob'},
        },
        tax: 10,
        tip: 0,
      ),
    ));
    // Auto-save is async — settle to let it complete.
    await tester.pumpAndSettle();

    expect(billHistoryNotifier.value, hasLength(1));
    final saved = billHistoryNotifier.value.first;
    expect(saved.people, ['Alice', 'Bob']);
    expect(saved.tax, 10);
    expect(saved.items, hasLength(1));
    expect(saved.items.first.name, 'Coffee');
  });

  // ---------- Per-person avatar palette ----------

  test('colorForPerson is deterministic and within the palette', () {
    final a1 = colorForPerson('Alice');
    final a2 = colorForPerson('Alice');
    expect(a1, equals(a2),
        reason: 'Same name should always get the same colour');

    // Empty name doesn't crash and returns a valid palette colour.
    expect(() => colorForPerson(''), returnsNormally);
  });
}
