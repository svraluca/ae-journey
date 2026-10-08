import 'package:intl/intl.dart';

final _dateFmt = DateFormat('d MMM yyyy');

String formatDate(DateTime date) => _dateFmt.format(date);

String formatMoney(num amount, String currency) {
  // Prefer a recognizable symbol (€, £, $) over the raw ISO code (EUR, GBP, USD).
  // Fall back to the code when unknown.
  const symbols = <String, String>{
    'EUR': '€',
    'GBP': '£',
    'USD': r'$',
    'RON': 'lei',
  };
  final symbol = symbols[currency.toUpperCase()] ?? currency;
  final abs = amount.abs();

  String amt;
  if (abs >= 10000) {
    // Compact thousands at/above 10k: 10k, 10,1k, 12,5k, 100k
    final k = abs / 1000.0;
    final rounded = (k * 10).roundToDouble() / 10.0;
    final compact = rounded == rounded.truncateToDouble()
        ? '${rounded.toInt()}k'
        : '${rounded.toStringAsFixed(1).replaceAll('.', ',')}k';
    amt = amount < 0 ? '-$compact' : compact;
  } else {
    final n = NumberFormat('#,##0');
    amt = n.format(amount);
  }

  // Match UI: currency after amount (e.g. 320€). Use a space for word-like symbols.
  final needsSpace = symbol.length > 1;
  return needsSpace ? '$amt $symbol' : '$amt$symbol';
}

