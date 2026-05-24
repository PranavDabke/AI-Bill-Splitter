import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'gemini_service.dart';
import 'storage.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await dotenv.load(fileName: ".env");
  await SettingsService.initialize();
  await BillHistoryService.initialize();
  runApp(const BillSplitterApp());
}

/// Global toggle for "mobile view" — when true, [BillSplitterApp] renders
/// the app inside a centered ~414px frame on a tinted backdrop, so you can
/// preview the mobile layout while running on desktop or web.
final ValueNotifier<bool> mobileViewMode = ValueNotifier(false);

/// Warm restaurant palette — terracotta primary, cream surface in light mode,
/// deep-coffee surface in dark mode. Both modes share the same seed so
/// the brand colour stays recognisable across themes.
const Color _seedColor = Color(0xFFB45309); // deep amber / terracotta
const Color _lightSurface = Color(0xFFFAF6F0); // warm cream
const Color _darkSurface = Color(0xFF1A1714); // deep coffee

ThemeData _buildTheme(Brightness brightness) {
  final scheme = ColorScheme.fromSeed(
    seedColor: _seedColor,
    brightness: brightness,
  );
  final isDark = brightness == Brightness.dark;
  final scaffold = isDark ? _darkSurface : _lightSurface;
  return ThemeData(
    colorScheme: scheme,
    useMaterial3: true,
    scaffoldBackgroundColor: scaffold,
    appBarTheme: AppBarTheme(
      backgroundColor: scaffold,
      foregroundColor: scheme.onSurface,
      elevation: 0,
      scrolledUnderElevation: 0.5,
      centerTitle: false,
      titleTextStyle: TextStyle(
        color: scheme.onSurface,
        fontSize: 20,
        fontWeight: FontWeight.w600,
        letterSpacing: 0.2,
      ),
    ),
    cardTheme: CardThemeData(
      elevation: 0,
      color: isDark ? scheme.surfaceContainerLow : Colors.white,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(
            color: scheme.outlineVariant.withValues(alpha: isDark ? 0.4 : 0.5)),
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
        ),
      ),
    ),
    chipTheme: ChipThemeData(
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(20),
        side: BorderSide(color: scheme.outlineVariant),
      ),
    ),
    dividerTheme: DividerThemeData(
      color: scheme.outlineVariant.withValues(alpha: 0.6),
      space: 16,
    ),
    listTileTheme: ListTileThemeData(
      iconColor: scheme.primary,
    ),
  );
}

final ThemeData _lightTheme = _buildTheme(Brightness.light);
final ThemeData _darkTheme = _buildTheme(Brightness.dark);

/// Small palette for per-person avatar tints — picked deterministically from
/// the name hash so the same person keeps the same colour across sessions.
const List<Color> _personPalette = [
  Color(0xFFB45309), // terracotta
  Color(0xFF7B3F5A), // plum
  Color(0xFF3D7080), // teal
  Color(0xFF7A8264), // sage
  Color(0xFFC9941D), // mustard
  Color(0xFF5C3F2E), // coffee
];

Color colorForPerson(String name) {
  if (name.isEmpty) return _personPalette.first;
  final hash = name.codeUnits.fold<int>(0, (a, b) => a + b);
  return _personPalette[hash % _personPalette.length];
}

class BillSplitterApp extends StatelessWidget {
  const BillSplitterApp({super.key});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<ThemeMode>(
      valueListenable: themeModeNotifier,
      builder: (_, mode, _) => MaterialApp(
        title: 'Bill Splitter',
        debugShowCheckedModeBanner: false,
        theme: _lightTheme,
        darkTheme: _darkTheme,
        themeMode: mode,
        builder: (context, child) {
        if (child == null) return const SizedBox.shrink();
        return ValueListenableBuilder<bool>(
          valueListenable: mobileViewMode,
          builder: (_, isMobile, _) {
            if (!isMobile) return child;
            // Only constrain when the window is actually wider than the
            // mobile frame — otherwise it would clip the real mobile view.
            return LayoutBuilder(
              builder: (_, constraints) {
                if (constraints.maxWidth < 420) return child;
                return ColoredBox(
                  color: const Color(0xFF1F1A14),
                  child: Center(
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(28),
                      child: SizedBox(
                        width: 414,
                        height: constraints.maxHeight < 900
                            ? constraints.maxHeight - 32
                            : 896,
                        child: child,
                      ),
                    ),
                  ),
                );
              },
            );
          },
        );
      },
        home: const HomeScreen(),
      ),
    );
  }
}

class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});

  Future<void> _pickFromGallery(BuildContext context) async {
    final picker = ImagePicker();
    final XFile? pickedFile =
        await picker.pickImage(source: ImageSource.gallery);

    if (pickedFile != null && context.mounted) {
      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => ReviewScreen(imagePath: pickedFile.path),
        ),
      );
    }
  }

  void _openSavedBill(BuildContext context, SavedBill bill) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => SummaryScreen(
          items: bill.items,
          people: bill.people,
          assignments: bill.assignments,
          tax: bill.tax,
          tip: bill.tip,
          // Already in history — don't re-save when re-opening.
          saveToHistory: false,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Bill Splitter'),
        actions: const [
          _ThemeModeToggle(),
          _ViewModeToggle(),
        ],
      ),
      body: ValueListenableBuilder<List<SavedBill>>(
        valueListenable: billHistoryNotifier,
        builder: (_, bills, _) {
          final hasHistory = bills.isNotEmpty;
          return ListView(
            padding: EdgeInsets.fromLTRB(20, hasHistory ? 24 : 48, 20, 32),
            children: [
              _HomeHero(
                compact: hasHistory,
                onPick: () => _pickFromGallery(context),
              ),
              if (hasHistory) ...[
                const SizedBox(height: 28),
                _RecentSplitsHeader(count: bills.length),
                const SizedBox(height: 8),
                for (final bill in bills)
                  Dismissible(
                    key: ValueKey(bill.id),
                    direction: DismissDirection.endToStart,
                    background: _DeleteBackground(),
                    onDismissed: (_) => BillHistoryService.delete(bill.id),
                    child: _HistoryCard(
                      bill: bill,
                      onTap: () => _openSavedBill(context, bill),
                    ),
                  ),
              ],
            ],
          );
        },
      ),
    );
  }
}

class _HomeHero extends StatelessWidget {
  final bool compact;
  final VoidCallback onPick;
  const _HomeHero({required this.compact, required this.onPick});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final iconSize = compact ? 96.0 : 140.0;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        // Layered concentric circles for a bit of depth.
        SizedBox(
          width: iconSize,
          height: iconSize,
          child: Stack(
            alignment: Alignment.center,
            children: [
              Container(
                decoration: BoxDecoration(
                  color: scheme.primaryContainer.withValues(alpha: 0.3),
                  shape: BoxShape.circle,
                ),
              ),
              Container(
                margin: EdgeInsets.all(iconSize * 0.12),
                decoration: BoxDecoration(
                  color: scheme.primaryContainer.withValues(alpha: 0.55),
                  shape: BoxShape.circle,
                ),
              ),
              Container(
                margin: EdgeInsets.all(iconSize * 0.22),
                decoration: BoxDecoration(
                  color: scheme.primaryContainer,
                  shape: BoxShape.circle,
                ),
                child: Icon(
                  Icons.dinner_dining,
                  size: iconSize * 0.4,
                  color: scheme.onPrimaryContainer,
                ),
              ),
            ],
          ),
        ),
        SizedBox(height: compact ? 16 : 24),
        if (!compact) ...[
          Text(
            'Split the bill with ease!',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 22,
              fontWeight: FontWeight.w700,
              color: scheme.onSurface,
              letterSpacing: 0.2,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            "Snap a photo of the receipt and we'll do the math.",
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 14,
              color: scheme.onSurfaceVariant,
              height: 1.4,
            ),
          ),
          const SizedBox(height: 28),
        ],
        FilledButton.icon(
          onPressed: onPick,
          icon: const Icon(Icons.photo_library),
          label: const Text('Pick a receipt'),
        ),
      ],
    );
  }
}

class _RecentSplitsHeader extends StatelessWidget {
  final int count;
  const _RecentSplitsHeader({required this.count});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: Row(
        children: [
          Container(
            width: 4,
            height: 16,
            decoration: BoxDecoration(
              color: scheme.primary,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          const SizedBox(width: 8),
          Text(
            'Recent splits',
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w700,
              color: scheme.onSurfaceVariant,
              letterSpacing: 0.5,
            ),
          ),
          const Spacer(),
          Text(
            '$count',
            style: TextStyle(
              fontSize: 13,
              color: scheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}

class _DeleteBackground extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      decoration: BoxDecoration(
        color: scheme.errorContainer,
        borderRadius: BorderRadius.circular(14),
      ),
      alignment: Alignment.centerRight,
      padding: const EdgeInsets.only(right: 20),
      child: Icon(Icons.delete_outline, color: scheme.onErrorContainer),
    );
  }
}

class _HistoryCard extends StatelessWidget {
  final SavedBill bill;
  final VoidCallback onTap;
  const _HistoryCard({required this.bill, required this.onTap});

  String _relativeDate(DateTime when) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final whenDate = DateTime(when.year, when.month, when.day);
    final diff = today.difference(whenDate).inDays;
    if (diff == 0) return 'Today';
    if (diff == 1) return 'Yesterday';
    if (diff < 7) return '$diff days ago';
    return '${when.day}/${when.month}/${when.year}';
  }

  String _formatTime(DateTime when) {
    final hour12 = when.hour % 12 == 0 ? 12 : when.hour % 12;
    final minute = when.minute.toString().padLeft(2, '0');
    final period = when.hour >= 12 ? 'PM' : 'AM';
    return '$hour12:$minute $period';
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final itemCount = bill.items.length;
    final personCount = bill.people.length;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Card(
        margin: EdgeInsets.zero,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(14),
          child: Padding(
            padding:
                const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
            child: Row(
              children: [
                Container(
                  width: 44,
                  height: 44,
                  decoration: BoxDecoration(
                    color: scheme.primaryContainer.withValues(alpha: 0.6),
                    shape: BoxShape.circle,
                  ),
                  alignment: Alignment.center,
                  child: Icon(Icons.receipt_long,
                      color: scheme.onPrimaryContainer, size: 22),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              '${_relativeDate(bill.savedAt)} · ${_formatTime(bill.savedAt)}',
                              style: TextStyle(
                                fontSize: 14,
                                fontWeight: FontWeight.w600,
                                color: scheme.onSurface,
                              ),
                            ),
                          ),
                          Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 10, vertical: 3),
                            decoration: BoxDecoration(
                              color:
                                  scheme.primary.withValues(alpha: 0.1),
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: Text(
                              fmtTotal(bill.grandTotal),
                              style: TextStyle(
                                fontSize: 14,
                                fontWeight: FontWeight.bold,
                                color: scheme.primary,
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 4),
                      Text(
                        '$personCount ${personCount == 1 ? 'person' : 'people'} · '
                        '$itemCount ${itemCount == 1 ? 'item' : 'items'}',
                        style: TextStyle(
                          fontSize: 12,
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _ThemeModeToggle extends StatelessWidget {
  const _ThemeModeToggle();

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<ThemeMode>(
      valueListenable: themeModeNotifier,
      builder: (_, mode, _) {
        late IconData icon;
        late String tooltip;
        late ThemeMode next;
        switch (mode) {
          case ThemeMode.system:
            icon = Icons.brightness_auto;
            tooltip = 'Theme: system (tap for light)';
            next = ThemeMode.light;
          case ThemeMode.light:
            icon = Icons.light_mode_outlined;
            tooltip = 'Theme: light (tap for dark)';
            next = ThemeMode.dark;
          case ThemeMode.dark:
            icon = Icons.dark_mode_outlined;
            tooltip = 'Theme: dark (tap for system)';
            next = ThemeMode.system;
        }
        return IconButton(
          icon: Icon(icon),
          tooltip: tooltip,
          onPressed: () => SettingsService.setThemeMode(next),
        );
      },
    );
  }
}

/// AppBar action that flips [mobileViewMode]. Icon reflects the *target*
/// state (tap = switch to the other one).
class _ViewModeToggle extends StatelessWidget {
  const _ViewModeToggle();

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<bool>(
      valueListenable: mobileViewMode,
      builder: (_, isMobile, _) {
        return IconButton(
          icon: Icon(isMobile ? Icons.desktop_windows : Icons.smartphone),
          tooltip: isMobile
              ? 'Switch to desktop view'
              : 'Switch to mobile view',
          onPressed: () => mobileViewMode.value = !mobileViewMode.value,
        );
      },
    );
  }
}

class ReviewScreen extends StatefulWidget {
  final String imagePath;
  const ReviewScreen({super.key, required this.imagePath});

  @override
  State<ReviewScreen> createState() => _ReviewScreenState();
}

class _ReviewScreenState extends State<ReviewScreen> {
  bool _loading = true;
  String? _error;
  List<BillItem> _items = [];
  double _tax = 0;
  double _tip = 0;

  @override
  void initState() {
    super.initState();
    _extractBill();
  }

  Future<void> _extractBill() async {
    try {
      final bill = await GeminiService.extractBill(widget.imagePath);
      if (mounted) {
        setState(() {
          _items = List.from(bill.items);
          _tax = bill.tax;
          _tip = bill.tip;
          _loading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = e.toString();
          _loading = false;
        });
      }
    }
  }

  void _retry() {
    setState(() {
      _loading = true;
      _error = null;
    });
    _extractBill();
  }

  Widget _buildBillPreviewButton() {
    Widget thumbnail(BoxFit fit) {
      return kIsWeb
          ? Image.network(widget.imagePath, fit: fit,
              errorBuilder: (_, _, _) =>
                  Icon(Icons.receipt_long, color: Colors.grey[500]))
          : Image.file(File(widget.imagePath), fit: fit,
              errorBuilder: (_, _, _) =>
                  Icon(Icons.receipt_long, color: Colors.grey[500]));
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 0),
      child: Card(
        margin: EdgeInsets.zero,
        clipBehavior: Clip.antiAlias,
        child: ListTile(
          leading: SizedBox(
            width: 48,
            height: 48,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: ColoredBox(
                color: Colors.grey.shade200,
                child: thumbnail(BoxFit.cover),
              ),
            ),
          ),
          title: const Text('View bill photo'),
          subtitle: const Text('Tap to verify items against the receipt'),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => Navigator.push(
            context,
            MaterialPageRoute(
              builder: (_) => Scaffold(
                appBar: AppBar(),
                backgroundColor: Colors.black,
                body: Center(
                  child: InteractiveViewer(
                    child: thumbnail(BoxFit.contain),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  double get _subtotal => _items.fold(0.0, (sum, item) => sum + item.price);
  double get _total => _subtotal + _tax + _tip;

  Future<void> _editItem(int index) async {
    final item = _items[index];
    final result = await _showItemDialog(
      title: 'Edit Item',
      initialName: item.name,
      initialQty: item.quantity,
      initialPrice: item.price,
      existingId: item.id,
    );
    if (result != null) {
      setState(() => _items[index] = result);
    }
  }

  Future<void> _addItem() async {
    final result = await _showItemDialog(
      title: 'Add Item',
      initialName: '',
      initialQty: 1,
      initialPrice: 0,
    );
    if (result != null) {
      setState(() => _items.add(result));
    }
  }

  Future<BillItem?> _showItemDialog({
    required String title,
    required String initialName,
    required int initialQty,
    required double initialPrice,
    String? existingId,
  }) {
    return showDialog<BillItem>(
      context: context,
      builder: (_) => ItemFormDialog(
        title: title,
        initialName: initialName,
        initialQty: initialQty,
        initialPrice: initialPrice,
        existingId: existingId,
      ),
    );
  }

  Future<void> _editAmount(
      String label, double current, void Function(double) onSave) async {
    final result = await showDialog<double>(
      context: context,
      builder: (_) => AmountFormDialog(label: label, initial: current),
    );
    if (result != null) {
      setState(() => onSave(result));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Review Bill'),
        actions: [
          IconButton(
            icon: const Icon(Icons.add),
            onPressed: _loading ? null : _addItem,
            tooltip: 'Add item',
          ),
        ],
      ),
      body: _loading
          ? const Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  CircularProgressIndicator(),
                  SizedBox(height: 16),
                  Text('Reading your bill...'),
                ],
              ),
            )
          : _error != null
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        const Icon(Icons.error_outline,
                            size: 48, color: Colors.red),
                        const SizedBox(height: 16),
                        Text('$_error', textAlign: TextAlign.center),
                        const SizedBox(height: 24),
                        FilledButton.icon(
                          onPressed: _retry,
                          icon: const Icon(Icons.refresh),
                          label: const Text('Try again'),
                        ),
                      ],
                    ),
                  ),
                )
              : Column(
                  children: [
                    _buildBillPreviewButton(),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      child: Text(
                        'Tap an item to edit. Swipe to delete.',
                        style: TextStyle(color: Colors.grey[600]),
                      ),
                    ),
                    const SizedBox(height: 8),
                    Expanded(
                      child: ListView.builder(
                        itemCount: _items.length,
                        itemBuilder: (context, index) {
                          final item = _items[index];
                          return Dismissible(
                            key: ValueKey(item.id),
                            background: Container(
                              color: Colors.red,
                              alignment: Alignment.centerRight,
                              padding: const EdgeInsets.only(right: 16),
                              child: const Icon(Icons.delete, color: Colors.white),
                            ),
                            direction: DismissDirection.endToStart,
                            onDismissed: (_) {
                              setState(() => _items.removeAt(index));
                            },
                            child: ListTile(
                              title: Text(item.name),
                              subtitle: Text('Qty: ${item.quantity}'),
                              trailing: Text(fmtMoney(item.price)),
                              onTap: () => _editItem(index),
                            ),
                          );
                        },
                      ),
                    ),
                    Container(
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        border: Border(top: BorderSide(color: Colors.grey[300]!)),
                      ),
                      child: Column(
                        children: [
                          _summaryRow('Subtotal', _subtotal, null),
                          _summaryRow('Tax', _tax,
                              () => _editAmount('Tax', _tax, (v) => _tax = v)),
                          _summaryRow('Tip', _tip,
                              () => _editAmount('Tip', _tip, (v) => _tip = v)),
                          const Divider(),
                          _summaryRow('Total', _total, null,
                              bold: true, isTotal: true),
                          const SizedBox(height: 16),
                          SizedBox(
                            width: double.infinity,
                            child: FilledButton(
                              onPressed: _items.isEmpty
                                  ? null
                                  : () {
                                      Navigator.push(
                                        context,
                                        MaterialPageRoute(
                                          builder: (_) => PeopleScreen(
                                            items: _items,
                                            tax: _tax,
                                            tip: _tip,
                                          ),
                                        ),
                                      );
                                    },
                              child: const Text('Continue to split'),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
    );
  }

  Widget _summaryRow(String label, double amount, VoidCallback? onTap,
      {bool bold = false, bool isTotal = false}) {
    final style = TextStyle(
      fontSize: bold ? 18 : 14,
      fontWeight: bold ? FontWeight.bold : FontWeight.normal,
    );
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(
          children: [
            Text(label, style: style),
            if (onTap != null) ...[
              const SizedBox(width: 4),
              Icon(Icons.edit, size: 14, color: Colors.grey[600]),
            ],
            const Spacer(),
            Text(isTotal ? fmtTotal(amount) : fmtMoney(amount), style: style),
          ],
        ),
      ),
    );
  }
}

class PeopleScreen extends StatefulWidget {
  final List<BillItem> items;
  final double tax;
  final double tip;

  const PeopleScreen({
    super.key,
    required this.items,
    required this.tax,
    required this.tip,
  });

  @override
  State<PeopleScreen> createState() => _PeopleScreenState();
}

class _PeopleScreenState extends State<PeopleScreen> {
  final List<String> _people = [];
  final TextEditingController _nameController = TextEditingController();

  void _addPerson() {
    final name = _nameController.text.trim();
    if (name.isEmpty) return;
    final lower = name.toLowerCase();
    final dupeIndex =
        _people.indexWhere((p) => p.toLowerCase() == lower);
    if (dupeIndex >= 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('${_people[dupeIndex]} is already added')),
      );
      return;
    }
    setState(() {
      _people.add(name);
      _nameController.clear();
    });
  }

  @override
  void dispose() {
    _nameController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Who\'s splitting?')),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _nameController,
                    decoration: const InputDecoration(
                      labelText: 'Add a person',
                      border: OutlineInputBorder(),
                    ),
                    onSubmitted: (_) => _addPerson(),
                    textInputAction: TextInputAction.done,
                  ),
                ),
                const SizedBox(width: 8),
                IconButton.filled(
                  onPressed: _addPerson,
                  icon: const Icon(Icons.add),
                ),
              ],
            ),
          ),
          Expanded(
            child: _people.isEmpty
                ? Center(
                    child: Text(
                      'Add at least 2 people to continue',
                      style: TextStyle(color: Colors.grey[600]),
                    ),
                  )
                : ListView.builder(
                    itemCount: _people.length,
                    itemBuilder: (context, index) {
                      return Dismissible(
                        key: ValueKey(_people[index]),
                        background: Container(
                          color: Colors.red,
                          alignment: Alignment.centerRight,
                          padding: const EdgeInsets.only(right: 16),
                          child: const Icon(Icons.delete, color: Colors.white),
                        ),
                        direction: DismissDirection.endToStart,
                        onDismissed: (_) {
                          setState(() => _people.removeAt(index));
                        },
                        child: ListTile(
                          leading: CircleAvatar(
                            child: Text(_people[index][0].toUpperCase()),
                          ),
                          title: Text(_people[index]),
                        ),
                      );
                    },
                  ),
          ),
          Padding(
            padding: const EdgeInsets.all(16),
            child: SizedBox(
              width: double.infinity,
              child: FilledButton(
                onPressed: _people.length < 2
                    ? null
                    : () {
                        Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (_) => AssignScreen(
                              items: widget.items,
                              people: List.of(_people),
                              tax: widget.tax,
                              tip: widget.tip,
                            ),
                          ),
                        );
                      },
                child: const Text('Continue to assign items'),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class AssignScreen extends StatefulWidget {
  final List<BillItem> items;
  final List<String> people;
  final double tax;
  final double tip;

  const AssignScreen({
    super.key,
    required this.items,
    required this.people,
    required this.tax,
    required this.tip,
  });

  @override
  State<AssignScreen> createState() => _AssignScreenState();
}

class _AssignScreenState extends State<AssignScreen> {
  // itemId -> set of person names assigned to it
  late final Map<String, Set<String>> _assignments;

  @override
  void initState() {
    super.initState();
    _assignments = {
      for (final item in widget.items) item.id: <String>{},
    };
  }

  void _toggle(String itemId, String person) {
    setState(() {
      final set = _assignments[itemId]!;
      if (set.contains(person)) {
        set.remove(person);
      } else {
        set.add(person);
      }
    });
  }

  void _assignAll(String itemId) {
    setState(() {
      _assignments[itemId] = Set.of(widget.people);
    });
  }

  bool get _allAssigned =>
      _assignments.values.every((s) => s.isNotEmpty);

  int get _unassignedCount =>
      _assignments.values.where((s) => s.isEmpty).length;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Assign items')),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(12),
            child: Text(
              'Tap a person to add/remove them from an item. '
              'Shared items split equally.',
              style: TextStyle(color: Colors.grey[600]),
            ),
          ),
          Expanded(
            child: ListView.builder(
              itemCount: widget.items.length,
              itemBuilder: (context, index) {
                final item = widget.items[index];
                final assigned = _assignments[item.id]!;
                final perPersonShare = assigned.isEmpty
                    ? 0.0
                    : item.price / assigned.length;
                return Card(
                  margin: const EdgeInsets.symmetric(
                      horizontal: 12, vertical: 6),
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Expanded(
                              child: Text(
                                item.name,
                                style: const TextStyle(
                                    fontSize: 16,
                                    fontWeight: FontWeight.w500),
                              ),
                            ),
                            Text(fmtMoney(item.price)),
                          ],
                        ),
                        if (assigned.isNotEmpty)
                          Padding(
                            padding: const EdgeInsets.only(top: 4),
                            child: Text(
                              '${fmtMoney(perPersonShare)} per person',
                              style: TextStyle(
                                  fontSize: 12, color: Colors.grey[600]),
                            ),
                          ),
                        const SizedBox(height: 8),
                        Wrap(
                          spacing: 6,
                          runSpacing: 4,
                          children: [
                            for (final person in widget.people)
                              FilterChip(
                                label: Text(person),
                                selected: assigned.contains(person),
                                onSelected: (_) => _toggle(item.id, person),
                              ),
                            ActionChip(
                              avatar: const Icon(Icons.group, size: 18),
                              label: const Text('Everyone'),
                              onPressed: () => _assignAll(item.id),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              border: Border(top: BorderSide(color: Colors.grey[300]!)),
            ),
            child: Column(
              children: [
                if (!_allAssigned)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Text(
                      '$_unassignedCount item${_unassignedCount == 1 ? '' : 's'} not assigned yet',
                      style: TextStyle(color: Colors.orange[800]),
                    ),
                  ),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton(
                    onPressed: _allAssigned
                        ? () {
                            Navigator.push(
                              context,
                              MaterialPageRoute(
                                builder: (_) => SummaryScreen(
                                  items: widget.items,
                                  people: widget.people,
                                  assignments: _assignments,
                                  tax: widget.tax,
                                  tip: widget.tip,
                                ),
                              ),
                            );
                          }
                        : null,
                    child: const Text('See summary'),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Formats a regular line-item or per-person amount with 2 decimals.
String fmtMoney(double amount) => '₹${amount.toStringAsFixed(2)}';

/// Formats a *bill grand total* rounded to whole rupees — restaurants almost
/// always round the final total, so we follow suit. Per-person amounts and
/// component lines (subtotal / tax / tip) keep their full precision.
String fmtTotal(double amount) => '₹${amount.toStringAsFixed(0)}';

/// Per-person breakdown produced by [computeBillBreakdown].
class PersonBill {
  double subtotal = 0;
  double taxShare = 0;
  double tipShare = 0;
  double total = 0;
  final List<(String, double)> lines = [];
}

/// Computes per-person totals. Shared items split equally; tax/tip allocated
/// proportionally to each person's item subtotal, with equal-split fallback
/// when the bill subtotal is 0.
Map<String, PersonBill> computeBillBreakdown({
  required List<BillItem> items,
  required List<String> people,
  required Map<String, Set<String>> assignments,
  required double tax,
  required double tip,
}) {
  final result = <String, PersonBill>{
    for (final p in people) p: PersonBill(),
  };

  double billSubtotal = 0;
  for (final item in items) {
    billSubtotal += item.price;
    final assigned = assignments[item.id] ?? const <String>{};
    if (assigned.isEmpty) continue;
    final share = item.price / assigned.length;
    for (final person in assigned) {
      result[person]!.subtotal += share;
      result[person]!.lines.add((item.name, share));
    }
  }

  for (final person in people) {
    final bill = result[person]!;
    if (billSubtotal > 0) {
      final ratio = bill.subtotal / billSubtotal;
      bill.taxShare = tax * ratio;
      bill.tipShare = tip * ratio;
    } else {
      bill.taxShare = tax / people.length;
      bill.tipShare = tip / people.length;
    }
    bill.total = bill.subtotal + bill.taxShare + bill.tipShare;
  }

  return result;
}

/// Formats a bill split as plain text for sharing/copying.
String formatBillSummary({
  required List<BillItem> items,
  required List<String> people,
  required Map<String, Set<String>> assignments,
  required double tax,
  required double tip,
}) {
  final breakdown = computeBillBreakdown(
    items: items,
    people: people,
    assignments: assignments,
    tax: tax,
    tip: tip,
  );
  final grandTotal =
      breakdown.values.fold<double>(0, (sum, b) => sum + b.total);

  final buf = StringBuffer();
  buf.writeln('Bill split — Total ${fmtTotal(grandTotal)}');
  buf.writeln();
  for (final person in people) {
    final b = breakdown[person]!;
    buf.writeln('$person owes ${fmtMoney(b.total)}');
    for (final (name, share) in b.lines) {
      buf.writeln('  • $name — ${fmtMoney(share)}');
    }
    if (b.lines.isEmpty) {
      buf.writeln('  (no items assigned)');
    }
    if (b.taxShare > 0) {
      buf.writeln('  Tax share: ${fmtMoney(b.taxShare)}');
    }
    if (b.tipShare > 0) {
      buf.writeln('  Tip share: ${fmtMoney(b.tipShare)}');
    }
    buf.writeln();
  }
  return buf.toString().trimRight();
}

class SummaryScreen extends StatefulWidget {
  final List<BillItem> items;
  final List<String> people;
  final Map<String, Set<String>> assignments;
  final double tax;
  final double tip;

  /// When true (the default), the summary is auto-saved to bill history on
  /// first render. Set to `false` when re-opening a bill from history so we
  /// don't insert a duplicate.
  final bool saveToHistory;

  const SummaryScreen({
    super.key,
    required this.items,
    required this.people,
    required this.assignments,
    required this.tax,
    required this.tip,
    this.saveToHistory = true,
  });

  @override
  State<SummaryScreen> createState() => _SummaryScreenState();
}

class _SummaryScreenState extends State<SummaryScreen> {
  final GlobalKey _captureKey = GlobalKey();

  @override
  void initState() {
    super.initState();
    if (widget.saveToHistory) {
      _autoSave();
    }
  }

  Future<void> _autoSave() async {
    try {
      await BillHistoryService.add(SavedBill(
        id: 'bill_${DateTime.now().microsecondsSinceEpoch}',
        savedAt: DateTime.now(),
        items: widget.items,
        people: widget.people,
        assignments: widget.assignments,
        tax: widget.tax,
        tip: widget.tip,
      ));
    } catch (_) {
      // History is non-critical UX — never block or surface errors.
    }
  }

  String _buildText() => formatBillSummary(
        items: widget.items,
        people: widget.people,
        assignments: widget.assignments,
        tax: widget.tax,
        tip: widget.tip,
      );

  void _showShareSheet() {
    showModalBottomSheet(
      context: context,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.share),
              title: const Text('Share as text'),
              subtitle: const Text('Send via WhatsApp, SMS, email, …'),
              onTap: () {
                Navigator.pop(sheetContext);
                _shareText();
              },
            ),
            ListTile(
              leading: const Icon(Icons.content_copy),
              title: const Text('Copy to clipboard'),
              onTap: () {
                Navigator.pop(sheetContext);
                _copyText();
              },
            ),
            ListTile(
              leading: const Icon(Icons.image),
              title: const Text('Share as image'),
              subtitle: const Text('Screenshot of the summary'),
              onTap: () {
                Navigator.pop(sheetContext);
                _shareImage();
              },
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _shareText() async {
    try {
      await Share.share(_buildText(), subject: 'Bill split');
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text("Couldn't open share sheet: $e")),
      );
    }
  }

  Future<void> _copyText() async {
    try {
      await Clipboard.setData(ClipboardData(text: _buildText()));
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Summary copied to clipboard')),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text("Couldn't copy to clipboard: $e")),
      );
    }
  }

  Future<void> _shareImage() async {
    try {
      final boundary = _captureKey.currentContext?.findRenderObject()
          as RenderRepaintBoundary?;
      if (boundary == null) {
        throw StateError('Capture target not ready');
      }
      final image = await boundary.toImage(pixelRatio: 3.0);
      final byteData =
          await image.toByteData(format: ui.ImageByteFormat.png);
      if (byteData == null) {
        throw StateError('Failed to encode image');
      }
      final bytes = byteData.buffer.asUint8List();

      XFile file;
      if (kIsWeb) {
        file = XFile.fromData(bytes,
            name: 'bill_summary.png', mimeType: 'image/png');
      } else {
        final dir = await getTemporaryDirectory();
        final f = File('${dir.path}/bill_summary.png');
        await f.writeAsBytes(bytes);
        file = XFile(f.path);
      }

      await Share.shareXFiles([file], text: 'Bill split summary');
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text("Couldn't share image: $e")),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final breakdown = computeBillBreakdown(
      items: widget.items,
      people: widget.people,
      assignments: widget.assignments,
      tax: widget.tax,
      tip: widget.tip,
    );
    final grandTotal =
        breakdown.values.fold<double>(0, (sum, b) => sum + b.total);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Summary'),
        actions: [
          IconButton(
            icon: const Icon(Icons.share),
            tooltip: 'Share',
            onPressed: _showShareSheet,
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: SingleChildScrollView(
              child: RepaintBoundary(
                key: _captureKey,
                child: Container(
                  // Solid background so the captured PNG is opaque.
                  color: Theme.of(context).scaffoldBackgroundColor,
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Padding(
                        padding: const EdgeInsets.fromLTRB(4, 0, 4, 12),
                        child: Row(
                          children: [
                            const Text('Bill split',
                                style: TextStyle(
                                    fontSize: 20,
                                    fontWeight: FontWeight.bold)),
                            const Spacer(),
                            Text(fmtTotal(grandTotal),
                                style: const TextStyle(
                                    fontSize: 20,
                                    fontWeight: FontWeight.bold)),
                          ],
                        ),
                      ),
                      for (final person in widget.people)
                        Card(
                          child: Padding(
                            padding: const EdgeInsets.all(12),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(
                                  children: [
                                    CircleAvatar(
                                      backgroundColor:
                                          colorForPerson(person)
                                              .withValues(alpha: 0.18),
                                      foregroundColor:
                                          colorForPerson(person),
                                      child: Text(
                                        person.isNotEmpty
                                            ? person[0].toUpperCase()
                                            : '?',
                                        style: const TextStyle(
                                            fontWeight: FontWeight.bold),
                                      ),
                                    ),
                                    const SizedBox(width: 12),
                                    Expanded(
                                      child: Text(
                                        person,
                                        style: const TextStyle(
                                            fontSize: 18,
                                            fontWeight: FontWeight.w600),
                                      ),
                                    ),
                                    Container(
                                      padding: const EdgeInsets.symmetric(
                                          horizontal: 12, vertical: 4),
                                      decoration: BoxDecoration(
                                        color: Theme.of(context)
                                            .colorScheme
                                            .primary
                                            .withValues(alpha: 0.1),
                                        borderRadius:
                                            BorderRadius.circular(10),
                                      ),
                                      child: Text(
                                        fmtMoney(breakdown[person]!.total),
                                        style: TextStyle(
                                          fontSize: 16,
                                          fontWeight: FontWeight.bold,
                                          color: Theme.of(context)
                                              .colorScheme
                                              .primary,
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                                const Divider(),
                                for (final (name, share)
                                    in breakdown[person]!.lines)
                                  Padding(
                                    padding: const EdgeInsets.symmetric(
                                        vertical: 2),
                                    child: Row(
                                      children: [
                                        Expanded(
                                          child: Text(name,
                                              style: const TextStyle(
                                                  fontSize: 13)),
                                        ),
                                        Text(
                                            fmtMoney(share),
                                            style: const TextStyle(
                                                fontSize: 13)),
                                      ],
                                    ),
                                  ),
                                if (breakdown[person]!.lines.isEmpty)
                                  Padding(
                                    padding: const EdgeInsets.symmetric(
                                        vertical: 2),
                                    child: Text(
                                      'No items assigned',
                                      style: TextStyle(
                                          fontSize: 13,
                                          color: Colors.grey[600],
                                          fontStyle: FontStyle.italic),
                                    ),
                                  ),
                                const SizedBox(height: 6),
                                _miniRow(
                                    'Subtotal', breakdown[person]!.subtotal),
                                _miniRow('Tax', breakdown[person]!.taxShare),
                                _miniRow('Tip', breakdown[person]!.tipShare),
                              ],
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ),
          ),
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              border: Border(top: BorderSide(color: Colors.grey[300]!)),
            ),
            child: Column(
              children: [
                Row(
                  children: [
                    const Text('Grand total',
                        style: TextStyle(
                            fontSize: 16, fontWeight: FontWeight.bold)),
                    const Spacer(),
                    Text(fmtTotal(grandTotal),
                        style: const TextStyle(
                            fontSize: 16, fontWeight: FontWeight.bold)),
                  ],
                ),
                const SizedBox(height: 12),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton(
                    onPressed: () {
                      Navigator.popUntil(context, (r) => r.isFirst);
                    },
                    child: const Text('Done'),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _miniRow(String label, double amount) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 1),
      child: Row(
        children: [
          Text(label,
              style: TextStyle(fontSize: 12, color: Colors.grey[700])),
          const Spacer(),
          Text(fmtMoney(amount),
              style: TextStyle(fontSize: 12, color: Colors.grey[700])),
        ],
      ),
    );
  }
}

/// Dialog for adding or editing a [BillItem]. Public so widget tests can
/// pump it directly.
class ItemFormDialog extends StatefulWidget {
  final String title;
  final String initialName;
  final int initialQty;
  final double initialPrice;
  final String? existingId;

  const ItemFormDialog({
    super.key,
    required this.title,
    required this.initialName,
    required this.initialQty,
    required this.initialPrice,
    this.existingId,
  });

  @override
  State<ItemFormDialog> createState() => _ItemFormDialogState();
}

class _ItemFormDialogState extends State<ItemFormDialog> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _nameController;
  late final TextEditingController _qtyController;
  late final TextEditingController _priceController;

  @override
  void initState() {
    super.initState();
    _nameController = TextEditingController(text: widget.initialName);
    _qtyController = TextEditingController(text: widget.initialQty.toString());
    _priceController = TextEditingController(
      text: widget.initialPrice == 0 ? '' : widget.initialPrice.toString(),
    );
  }

  @override
  void dispose() {
    _nameController.dispose();
    _qtyController.dispose();
    _priceController.dispose();
    super.dispose();
  }

  void _save() {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    Navigator.pop(
      context,
      BillItem(
        id: widget.existingId,
        name: _nameController.text.trim(),
        quantity: int.parse(_qtyController.text),
        price: double.parse(_priceController.text),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.title),
      content: Form(
        key: _formKey,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextFormField(
              controller: _nameController,
              decoration: const InputDecoration(labelText: 'Name'),
              autofocus: true,
              validator: (v) =>
                  (v == null || v.trim().isEmpty) ? 'Required' : null,
            ),
            TextFormField(
              controller: _qtyController,
              decoration: const InputDecoration(labelText: 'Quantity'),
              keyboardType: TextInputType.number,
              validator: (v) {
                final n = int.tryParse(v ?? '');
                if (n == null) return 'Enter a whole number';
                if (n < 1) return 'Must be at least 1';
                return null;
              },
            ),
            TextFormField(
              controller: _priceController,
              decoration: const InputDecoration(labelText: 'Price'),
              keyboardType: TextInputType.number,
              validator: (v) {
                final n = double.tryParse(v ?? '');
                if (n == null) return 'Enter a number';
                if (n < 0) return 'Cannot be negative';
                return null;
              },
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _save,
          child: const Text('Save'),
        ),
      ],
    );
  }
}

/// Dialog for editing a single non-negative amount (tax or tip).
class AmountFormDialog extends StatefulWidget {
  final String label;
  final double initial;

  const AmountFormDialog({
    super.key,
    required this.label,
    required this.initial,
  });

  @override
  State<AmountFormDialog> createState() => _AmountFormDialogState();
}

class _AmountFormDialogState extends State<AmountFormDialog> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _controller;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.initial.toString());
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _save() {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    Navigator.pop(context, double.parse(_controller.text));
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text('Edit ${widget.label}'),
      content: Form(
        key: _formKey,
        child: TextFormField(
          controller: _controller,
          decoration: InputDecoration(labelText: widget.label),
          keyboardType: TextInputType.number,
          autofocus: true,
          validator: (v) {
            final n = double.tryParse(v ?? '');
            if (n == null) return 'Enter a number';
            if (n < 0) return 'Cannot be negative';
            return null;
          },
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _save,
          child: const Text('Save'),
        ),
      ],
    );
  }
}