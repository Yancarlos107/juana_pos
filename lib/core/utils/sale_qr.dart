import 'dart:convert';

/// Construye el contenido del QR que se IMPRIME en el tiquete de venta.
///
/// Es un JSON con la información de la venta, codificado en Base64, pensado
/// para que el validador lo lea directamente (sin consultar el backend).
///
/// IMPORTANTE: esto NO es el `qr_data` que se guarda/envía al backend (ese
/// sigue siendo el token único usado para el cuadre y la reconciliación).
/// Aquí solo definimos lo que se pinta en el papel.
class SaleQr {
  /// Tiempo de vida por defecto (tm), en segundos.
  static const int defaultTiempoVida = 120;

  /// Llaves (compactas para reducir el tamaño del QR):
  /// - fh: fecha/hora en unix timestamp (segundos)
  /// - fa: fare_id (id de la tarifa)
  /// - tm: tiempo de vida
  /// - pm: activación PMR (0/1)
  /// - sn: serial único de la venta (incluye el pos)
  /// - va: valor/precio de la tarifa
  static String build({
    required int fhUnix,
    required Object fareId,
    required int pmr,
    required String serial,
    required num value,
    int tiempoVida = defaultTiempoVida,
  }) {
    final payload = <String, dynamic>{
      'fh': fhUnix,
      'fa': fareId,
      'tm': tiempoVida,
      'pm': pmr,
      'sn': serial,
      'va': value,
    };
    return base64Encode(utf8.encode(jsonEncode(payload)));
  }
}
