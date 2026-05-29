import 'dart:typed_data';
import 'package:flutter/services.dart';

class EpsonEposService {
  static const MethodChannel _channel = MethodChannel('co.Juana.epson_printer');

  Future<String> getEpsonLog() async {
    try {
      final result = await _channel.invokeMethod<String>('getEpsonLog');
      return result ?? 'Log vacío';
    } on PlatformException catch (e) {
      return 'Error leyendo log: ${e.message}';
    }
  }

  /// Retorna null si se solicitó permiso USB y el usuario debe reintentar.
  Future<bool?> printTestHola(String target) async {
    try {
      final result = await _channel.invokeMethod<bool>('printHola', {'target': target});
      return result ?? false;
    } on PlatformException catch (e) {
      if (e.code == 'NO_PERMISSION') return null;
      print("Error al imprimir [${e.code}]: ${e.message}");
      return false;
    }
  }

  /// Envía bytes ESC/POS arbitrarios vía USB Host API.
  Future<bool?> printBytes(Uint8List bytes) async {
    try {
      final result = await _channel.invokeMethod<bool>('printBytes', {'bytes': bytes});
      return result ?? false;
    } on PlatformException catch (e) {
      if (e.code == 'NO_PERMISSION') return null;
      print("Error printBytes [${e.code}]: ${e.message}");
      return false;
    }
  }

  /// Imprime un ticket de prueba con el mismo formato que PrinterService.printTicket.
  Future<bool?> printTestTicket() async {
    final nowUtc = DateTime.now().toUtc();
    final now = nowUtc.subtract(const Duration(hours: 5));
    final dateStr =
        '${now.day.toString().padLeft(2, '0')}/${now.month.toString().padLeft(2, '0')}/${now.year}';
    final timeStr =
        '${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}:${now.second.toString().padLeft(2, '0')}';

    const transactionId = 'TEST-0001';
    const cashierName  = 'Cajero Prueba';
    const branchName   = 'Sede Principal';
    const productName  = 'REGULAR';
    const amount       = 5000.0;
    const qrData       = 'TEST|CORREDOR-CENTRAL|5000|REGULAR|2024';

    final bytes = <int>[];
    bytes.addAll([0x1B, 0x40]);              // ESC @ — init
    bytes.addAll([0x1B, 0x61, 0x01]);        // ESC a 1 — centro
    bytes.addAll([0x1B, 0x45, 0x01]);        // ESC E 1 — bold
    bytes.addAll([0x1D, 0x21, 0x01]);        // GS ! 01 — doble alto
    bytes.addAll(_text('Corredor Central Norte\n'));

    bytes.addAll([0x1D, 0x21, 0x00]);        // normal
    bytes.addAll(_text('$branchName\n'));

    bytes.addAll([0x1B, 0x45, 0x00]);        // sin bold
    bytes.addAll([0x1B, 0x61, 0x00]);        // izquierda
    bytes.addAll(_text('Fecha:       $dateStr $timeStr\n'));
    bytes.addAll(_text('Transaccion: #$transactionId\n'));
    bytes.addAll(_text('Cajero:      $cashierName\n'));
    bytes.addAll(_text('\n'));

    bytes.addAll([0x1B, 0x61, 0x01]);        // centro
    bytes.addAll([0x1B, 0x45, 0x01]);        // bold
    bytes.addAll([0x1D, 0x21, 0x10]);        // doble ancho
    bytes.addAll(_text('${productName.toUpperCase()} \$ ${amount.toStringAsFixed(0)}\n'));
    bytes.addAll([0x1B, 0x45, 0x00]);        // sin bold

    bytes.addAll(_cmdQrCode(qrData));
    bytes.addAll(_text('\n'));

    bytes.addAll([0x1B, 0x64, 0x02]);        // ESC d 2 — 2 saltos
    bytes.addAll([0x1D, 0x56, 0x42, 0x00]); // GS V B 0 — corte parcial

    return printBytes(Uint8List.fromList(bytes));
  }

  // ---------------------------------------------------------------------------
  // Helpers ESC/POS (misma lógica que PrinterService)
  // ---------------------------------------------------------------------------

  List<int> _text(String text) {
    return text
        .replaceAll('á', 'a').replaceAll('é', 'e')
        .replaceAll('í', 'i').replaceAll('ó', 'o')
        .replaceAll('ú', 'u').replaceAll('ñ', 'n')
        .replaceAll('Á', 'A').replaceAll('É', 'E')
        .replaceAll('Í', 'I').replaceAll('Ó', 'O')
        .replaceAll('Ú', 'U').replaceAll('Ñ', 'N')
        .codeUnits;
  }

  List<int> _cmdQrCode(String data) {
    final dataBytes = data.codeUnits;
    final store = dataBytes.length + 3;
    final pL = store & 0xFF;
    final pH = (store >> 8) & 0xFF;
    return [
      0x1D, 0x28, 0x6B, 0x04, 0x00, 0x31, 0x41, 0x32, 0x00, // modelo 2
      0x1D, 0x28, 0x6B, 0x03, 0x00, 0x31, 0x43, 0x05,        // tamaño 5
      0x1D, 0x28, 0x6B, 0x03, 0x00, 0x31, 0x45, 0x31,        // nivel M
      0x1D, 0x28, 0x6B, pL,   pH,   0x31, 0x50, 0x30,        // cargar datos
      ...dataBytes,
      0x1D, 0x28, 0x6B, 0x03, 0x00, 0x31, 0x51, 0x30,        // imprimir
    ];
  }
}
