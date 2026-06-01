/// Modelo que representa un producto/tarifa del gateway.
/// Se obtiene dinámicamente de GET /gateway/v1/products.
///
/// Campos según la documentación:
/// - `_id`: identificador único del producto en el gateway.
/// - `product_name`: nombre del tipo de tarifa (ej. "Estudiante", "Regular").
/// - `value`: valor/precio del pasaje.
class Product {
  final int? localId;
  final String id;
  final String productName;
  final double value;
  final bool pmr;

  Product({
    this.localId,
    required this.id,
    required this.productName,
    required this.value,
    this.pmr = false,
  });

  factory Product.fromMap(Map<String, dynamic> map) {
    return Product(
      localId: map['local_id'],
      id: map['id'].toString(),
      productName: map['product_name'] ?? 'Desconocido',
      value: (map['value'] as num?)?.toDouble() ?? 0.0,
      pmr: (map['pmr'] == 1 || map['pmr'] == true),
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
