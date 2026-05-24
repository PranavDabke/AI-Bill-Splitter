import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'gemini_service.dart';

/// A completed bill split, persisted in [BillHistoryService].
class SavedBill {
  final String id;
  final DateTime savedAt;
  final List<BillItem> items;
  final List<String> people;
  final Map<String, Set<String>> assignments;
  final double tax;
  final double tip;

  SavedBill({
    required this.id,
    required this.savedAt,
    required this.items,
    required this.people,
    required this.assignments,
    required this.tax,
    required this.tip,
  });

  double get subtotal => items.fold(0.0, (s, i) => s + i.price);
  double get grandTotal => subtotal + tax + tip;

  Map<String, dynamic> toJson() => {
        'id': id,
        'savedAt': savedAt.toIso8601String(),
        'items': items.map((i) => i.toJson()).toList(),
        'people': people,
        // JSON has no native Set — store as List<String>, restore as Set.
        'assignments':
            assignments.map((k, v) => MapEntry(k, v.toList())),
        'tax': tax,
        'tip': tip,
      };

  factory SavedBill.fromJson(Map<String, dynamic> json) {
    return SavedBill(
      id: json['id'] as String,
      savedAt: DateTime.parse(json['savedAt'] as String),
      items: (json['items'] as List)
          .map((e) => BillItem.fromStoredJson(e as Map<String, dynamic>))
          .toList(),
      people: (json['people'] as List).cast<String>(),
      assignments:
          (json['assignments'] as Map<String, dynamic>).map(
        (k, v) => MapEntry(k, (v as List).cast<String>().toSet()),
      ),
      tax: (json['tax'] as num).toDouble(),
      tip: (json['tip'] as num).toDouble(),
    );
  }
}

/// In-memory mirror of the on-disk history, kept in sync by
/// [BillHistoryService]. UI watches this via [ValueListenableBuilder] so
/// adds/deletes show up immediately on `HomeScreen` without manual reload.
final ValueNotifier<List<SavedBill>> billHistoryNotifier =
    ValueNotifier(const []);

class BillHistoryService {
  static const _kKey = 'bill_history_v1';

  /// Reads the on-disk history. Returns `[]` for first-run or unparseable
  /// state (the latter is treated as "start fresh" rather than crashing —
  /// history is non-critical UX).
  static Future<List<SavedBill>> load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_kKey);
    if (raw == null) return [];
    try {
      final list = jsonDecode(raw) as List;
      return list
          .map((e) => SavedBill.fromJson(e as Map<String, dynamic>))
          .toList();
    } catch (_) {
      return [];
    }
  }

  /// Loads the on-disk history into [billHistoryNotifier]. Call once at
  /// app start.
  static Future<void> initialize() async {
    billHistoryNotifier.value = await load();
  }

  static Future<void> _saveAll(List<SavedBill> bills) async {
    final prefs = await SharedPreferences.getInstance();
    final raw = jsonEncode(bills.map((b) => b.toJson()).toList());
    await prefs.setString(_kKey, raw);
    billHistoryNotifier.value = List.unmodifiable(bills);
  }

  static Future<void> add(SavedBill bill) async {
    final bills = List.of(billHistoryNotifier.value);
    bills.insert(0, bill); // newest first
    await _saveAll(bills);
  }

  static Future<void> delete(String id) async {
    final bills = List.of(billHistoryNotifier.value)
      ..removeWhere((b) => b.id == id);
    await _saveAll(bills);
  }
}

/// Watched by [BillSplitterApp] to drive `MaterialApp.themeMode`.
final ValueNotifier<ThemeMode> themeModeNotifier =
    ValueNotifier(ThemeMode.system);

class SettingsService {
  static const _kThemeMode = 'theme_mode_v1';

  /// Loads the persisted theme mode into [themeModeNotifier]. Call once at
  /// app start.
  static Future<void> initialize() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_kThemeMode);
    if (raw == null) return; // keep default (system)
    themeModeNotifier.value = ThemeMode.values.firstWhere(
      (m) => m.name == raw,
      orElse: () => ThemeMode.system,
    );
  }

  static Future<void> setThemeMode(ThemeMode mode) async {
    themeModeNotifier.value = mode;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kThemeMode, mode.name);
  }
}
