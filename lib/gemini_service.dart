import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:http/http.dart' as http;

class BillItem {
  static int _nextId = 0;

  final String id;
  final String name;
  final int quantity;
  final double price;

  BillItem({
    String? id,
    required this.name,
    required this.quantity,
    required this.price,
  }) : id = id ?? 'item_${_nextId++}';

  BillItem copyWith({String? name, int? quantity, double? price}) {
    return BillItem(
      id: id,
      name: name ?? this.name,
      quantity: quantity ?? this.quantity,
      price: price ?? this.price,
    );
  }

  /// Parses an item out of Gemini's OCR response (uses `item_name`, no `id`).
  factory BillItem.fromJson(Map<String, dynamic> json) {
    return BillItem(
      name: json['item_name']?.toString() ?? 'Unknown',
      quantity: (json['quantity'] as num?)?.toInt() ?? 1,
      price: (json['price'] as num?)?.toDouble() ?? 0.0,
    );
  }

  /// Serializes this item for persistence (preserves [id]).
  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'quantity': quantity,
        'price': price,
      };

  /// Restores an item from its own [toJson] output. Unlike [fromJson], this
  /// preserves the original `id` so reloaded bills keep stable widget keys.
  factory BillItem.fromStoredJson(Map<String, dynamic> json) {
    return BillItem(
      id: json['id'] as String?,
      name: json['name'] as String? ?? 'Unknown',
      quantity: (json['quantity'] as num?)?.toInt() ?? 1,
      price: (json['price'] as num?)?.toDouble() ?? 0.0,
    );
  }
}

class ExtractedBill {
  final List<BillItem> items;
  final double subtotal;
  final double tax;
  final double tip;
  final double total;

  ExtractedBill({
    required this.items,
    required this.subtotal,
    required this.tax,
    required this.tip,
    required this.total,
  });
}

class GeminiService {
  static const String _model = 'gemini-2.5-flash';
  static const String _endpoint =
      'https://generativelanguage.googleapis.com/v1beta/models';

  static Future<ExtractedBill> extractBill(String imagePath) async {
    final apiKey = dotenv.env['GEMINI_API_KEY'];
    if (apiKey == null || apiKey.isEmpty) {
      throw Exception('GEMINI_API_KEY not found in .env');
    }

    // Read image bytes (works on both web and mobile)
    final List<int> imageBytes;
    if (kIsWeb) {
      final response = await http.get(Uri.parse(imagePath));
      imageBytes = response.bodyBytes;
    } else {
      imageBytes = await File(imagePath).readAsBytes();
    }
    final base64Image = base64Encode(imageBytes);

    const prompt = '''
Extract all line items from this restaurant bill.
Return ONLY valid JSON with this exact structure (no markdown, no code fences):
{
  "items": [
    {"item_name": "string", "quantity": number, "price": number}
  ],
  "subtotal": number,
  "tax": number,
  "tip": number,
  "total": number
}
If a field is not visible, use 0. Price is per line, not per unit.
''';

    final url = Uri.parse('$_endpoint/$_model:generateContent?key=$apiKey');

    final body = jsonEncode({
      'contents': [
        {
          'parts': [
            {'text': prompt},
            {
              'inline_data': {
                'mime_type': 'image/jpeg',
                'data': base64Image,
              }
            }
          ]
        }
      ]
    });

    final response = await http
        .post(
          url,
          headers: {'Content-Type': 'application/json'},
          body: body,
        )
        .timeout(
          const Duration(seconds: 30),
          onTimeout: () => throw Exception(
              'Gemini API timed out after 30s. Check your connection and try again.'),
        );

    if (response.statusCode != 200) {
      throw Exception('Gemini API error: ${response.statusCode} ${response.body}');
    }

    final data = jsonDecode(response.body);
    String text = data['candidates'][0]['content']['parts'][0]['text'];

    // Strip markdown code fences if Gemini added them
    text = text.replaceAll(RegExp(r'```json\s*'), '').replaceAll('```', '').trim();

    final parsed = jsonDecode(text);
    final items = (parsed['items'] as List)
        .map((e) => BillItem.fromJson(e))
        .toList();

    return ExtractedBill(
      items: items,
      subtotal: (parsed['subtotal'] as num?)?.toDouble() ?? 0.0,
      tax: (parsed['tax'] as num?)?.toDouble() ?? 0.0,
      tip: (parsed['tip'] as num?)?.toDouble() ?? 0.0,
      total: (parsed['total'] as num?)?.toDouble() ?? 0.0,
    );
  }
}