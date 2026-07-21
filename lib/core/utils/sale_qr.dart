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
  /// - pi: pos_location_id
  /// - t:  token de la venta (mismo `qr_data` que viaja al backend como `qr`,
  ///       para identificar la venta al validar contra el back)
  /// - tm: tiempo de vida
  /// - pm: activación PMR (0/1)
  /// - va: valor/precio de la tarifa
  static String build({
    required int fhUnix,
    required int posId,
    required String token,
    required int pmr,
    required num value,
    int tiempoVida = defaultTiempoVida,
  }) {
    final payload = <String, dynamic>{
      'fh': fhUnix,
      'pi': posId,
      't': token,
      'tm': tiempoVida,
      'pm': pmr,
      'va': value,
    };
    return base64Encode(utf8.encode(jsonEncode(payload)));
  }
}
