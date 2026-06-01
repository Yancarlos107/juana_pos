class CurrencyFormatter {
  static String format(double value) {
    // Si tiene decimales reales (ej: 12.50) muestra 2 decimales, sino 0 (ej: 12)
    final hasDecimals = value % 1 != 0;
    
    if (hasDecimals) {
      final parts = value.toStringAsFixed(2).split('.');
      final intPart = parts[0].replaceAllMapped(RegExp(r'(\d)(?=(\d{3})+(?!\d))'), (m) => '${m[1]},');
      return '$intPart.${parts[1]}';
    } else {
      return value.toStringAsFixed(0).replaceAllMapped(RegExp(r'(\d)(?=(\d{3})+(?!\d))'), (m) => '${m[1]},');
    }
  }
}
