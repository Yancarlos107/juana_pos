import '../../../core/utils/currency_formatter.dart';

/// Modelo que representa un producto/tarifa del gateway.
/// Se obtiene dinámicamente de GET /gateway/v1/products.
///
/// Campos según la documentación:
/// - `_id`: identificador único del producto en el gateway.
/// - `product_name`: nombre del tipo de tarifa (ej. "Estudiante", "Regular").
/// - `value`: valor/precio del pasaje.
class Product {
  final String id;         // _id del gateway
  final String productName;
  final double value;
  final bool pmr;

  const Product({
    required this.id,
    required this.productName,
    required this.value,
    this.pmr = false,
  });

  factory Product.fromJson(Map<String, dynamic> json) {
    return Product(
      id: json['_id']?.toString() ?? json['id']?.toString() ?? '',
      productName: json['product_name'] as String? ?? '',
      value: (json['value'] as num?)?.toDouble() ?? 0,
      pmr: json['pmr'] == 1 || json['pmr'] == true || json['pmr'] == '1',
    );
  }

  /// Formato de visualización idéntico al Angular: "Valor: <value> | <nombre>"
  String get displayLabel => 'Valor: ${CurrencyFormatter.format(value)} | $productName';

  @override
  String toString() => displayLabel;
}

/// Resultado de una compra QR (POST /gateway/v1/purchases).
/// La respuesta contiene `data` con `qr_code` y `transaction_id`.
class QrPurchaseResult {
  final String qrCode;
  final String transactionId;
  final double? yourNewBalance; // Nuevo campo opcional
  final Map<String, dynamic> rawData;

  const QrPurchaseResult({
    required this.qrCode,
    required this.transactionId,
    this.yourNewBalance,
    required this.rawData,
  });

  factory QrPurchaseResult.fromJson(Map<String, dynamic> json) {
    final data = json['data'] as Map<String, dynamic>? ?? json;
    return QrPurchaseResult(
      qrCode: data['qr_code']?.toString() ?? '',
      transactionId: data['transaction_id']?.toString() ?? '',
      yourNewBalance: (data['your_new_balance'] as num?)?.toDouble(),
      rawData: data,
    );
  }
}
