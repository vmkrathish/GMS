import 'dart:convert';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:GMS/core/app_state.dart';

class CurrencyFormatter {
  static final Map<String, _CurrencyRule> _rules = {};

  static bool _loaded = false;

  /// Call once during app startup (or lazy-loaded)
  static Future<void> load() async {
    if (_loaded) return;

    final raw = await rootBundle.loadString('assets/currencies.json');
    final List<dynamic> list = json.decode(raw);

    for (final item in list) {
      if (item is! String) continue;

      // "₹ - Indian Rupee"
      final parts = item.split(' - ');
      if (parts.isEmpty) continue;

      final symbol = parts.first.trim();
      if (symbol.isEmpty) continue;

      _rules.putIfAbsent(symbol, () => _CurrencyRule.fromSymbol(symbol));
    }

    _loaded = true;
  }

  /// 🔹 MAIN FORMATTER (VIEW ONLY)
  static String format(String rawCharge) {
    if (!_loaded) {
      // fallback (safe)
      return rawCharge;
    }

    final cleaned = rawCharge.replaceAll(',', '').trim();
    final value = double.tryParse(cleaned);
    if (value == null) return rawCharge;

    final full = AppState.selectedCurrency;
    final symbol = full.isNotEmpty ? full.split(' ').first.trim() : '₹';

    final rule = _rules[symbol] ?? _CurrencyRule.fromSymbol(symbol);

    final formatter = NumberFormat.currency(
      locale: rule.locale,
      symbol: symbol,
      decimalDigits: rule.forceNoDecimal ? 0 : (value % 1 == 0 ? 0 : 2),
    );

    return formatter.format(value);
  }
}

/// 🔒 Internal rule model
class _CurrencyRule {
  final String locale;
  final bool forceNoDecimal;

  const _CurrencyRule({required this.locale, required this.forceNoDecimal});

  /// Auto-derived defaults by symbol
  factory _CurrencyRule.fromSymbol(String symbol) {
    switch (symbol) {
      // ---- ZERO DECIMAL CURRENCIES ----
      case '¥': // JPY
      case '₩': // KRW
      case '₫': // VND
      case '₭': // LAK
      case '₮': // MNT
      case '₲': // PYG
        return const _CurrencyRule(locale: 'en_US', forceNoDecimal: true);

      // ---- INDIAN SYSTEM ----
      case '₹':
      case '৳':
      case '₨':
        return const _CurrencyRule(locale: 'en_IN', forceNoDecimal: false);

      // ---- EUROPE ----
      case '€':
        return const _CurrencyRule(locale: 'de_DE', forceNoDecimal: false);

      // ---- POUNDS ----
      case '£':
        return const _CurrencyRule(locale: 'en_GB', forceNoDecimal: false);

      // ---- KRONA / KORUNA ----
      case 'kr':
      case 'Kč':
      case 'zł':
      case 'Ft':
      case 'lei':
      case 'лв':
        return const _CurrencyRule(locale: 'en_US', forceNoDecimal: false);

      // ---- ARABIC ----
      case 'د.إ':
      case '﷼':
      case 'د.ك':
      case 'د.ب':
      case 'د.ج':
      case 'د.ت':
      case 'د.م':
        return const _CurrencyRule(locale: 'ar', forceNoDecimal: false);

      // ---- CRYPTO ----
      case '₿':
        return const _CurrencyRule(locale: 'en_US', forceNoDecimal: false);

      // ---- DEFAULT ----
      default:
        return const _CurrencyRule(locale: 'en_US', forceNoDecimal: false);
    }
  }
}
