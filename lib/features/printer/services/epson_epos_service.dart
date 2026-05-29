import 'package:flutter/services.dart';

class EpsonEposService {
  static const MethodChannel _channel = MethodChannel('co.Juana.epson_printer');

  /// Imprime "Hola" en la impresora Epson.
  /// [target] puede ser "TCP:192.168.1.100", "BT:MAC_ADDRESS", o "USB:"
  Future<String> getEpsonLog() async {
    try {
      final result = await _channel.invokeMethod<String>('getEpsonLog');
      return result ?? 'Log vacío';
    } on PlatformException catch (e) {
      return 'Error leyendo log: ${e.message}';
    }
  }

  /// Retorna null si se solicitó permiso USB y el usuario debe reintentar.
  /// Retorna true/false para éxito/error de impresión.
  Future<bool?> printTestHola(String target) async {
    try {
      final result = await _channel.invokeMethod<bool>('printHola', {'target': target});
      return result ?? false;
    } on PlatformException catch (e) {
      if (e.code == 'NO_PERMISSION') {
        print("Permiso USB solicitado: ${e.message}");
        return null; // señal de "reintenta después del diálogo"
      }
      print("Error al imprimir [${e.code}]: ${e.message}");
      return false;
    }
  }
}
