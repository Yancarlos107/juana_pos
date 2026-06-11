import 'dart:typed_data';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/utils/currency_formatter.dart';
import 'epson_epos_service.dart';

/// Servicio de impresión térmica POS vía USB Host API.
///
/// Toda la impresión sale por el canal nativo (MainActivity.kt), que localiza
/// la impresora externa por fabricante soportado (Epson VID 1208 / 0x04B8).
/// La detección de conexión consulta la lista USB real del sistema en cada
/// chequeo, por lo que desconectar el cable se refleja de inmediato y nunca
/// queda un estado "fantasma".
class PrinterService {
  final EpsonEposService _epsonService = EpsonEposService();
  static const _statusChannel = MethodChannel('co.Juana.usb/status');
  static const _eventsChannel = EventChannel('co.Juana.usb/events');

  Stream<String>? _usbEvents;

  /// Eventos nativos de conexión/desconexión USB: emite "attached"/"detached"
  /// en el instante en que se conecta o desconecta cualquier dispositivo USB.
  Stream<String> get usbEvents {
    _usbEvents ??= _eventsChannel
        .receiveBroadcastStream()
        .map((event) => event.toString())
        .asBroadcastStream();
    return _usbEvents!;
  }

  /// true solo si hay una impresora externa soportada físicamente conectada.
  /// El filtrado por fabricante ocurre en nativo (SUPPORTED_VENDOR_IDS): no se
  /// acepta cualquier dispositivo clase 7 porque la impresora interna de la
  /// tablet es clase 7 y daba falsos positivos al desconectar la Epson.
  Future<bool> isPrinterAvailable() async {
    try {
      final bool connected =
          await _statusChannel.invokeMethod('isUsbDeviceConnected', {
        'vendorId': -1,
        'productId': -1,
      });
      return connected;
    } catch (e) {
      print('DEBUG: Error consultando estado USB: $e');
      return false; // NUNCA asumir conectada si el canal falla
    }
  }

  Future<bool> pingPrinter() => isPrinterAvailable();

  /// Verifica conexión física y envía los bytes por USB Host API.
  /// null = permiso USB pendiente, true/false = éxito/fallo.
  Future<bool?> _send(List<int> bytes) async {
    if (!await isPrinterAvailable()) {
      print('DEBUG: Impresora no conectada; impresión cancelada');
      return false;
    }
    return _epsonService.printBytes(Uint8List.fromList(bytes));
  }

  Future<bool> printFontAndQrTest() async {
    try {
      final bytes = <int>[];
      bytes.addAll([0x1B, 0x40]); // Init
      bytes.addAll([0x1B, 0x61, 0x01]); // Center

      bytes.addAll([0x1B, 0x45, 0x01]); // Bold
      bytes.addAll([0x1D, 0x21, 0x00]); // Normal
      bytes.addAll(_text('--- PRUEBA DE FUENTES ---\n\n'));

      bytes.addAll([0x1D, 0x21, 0x00]); // Normal
      bytes.addAll(_text('TAMANO NORMAL (0x00):\nCorredor Central Norte\n\n'));

      bytes.addAll([0x1D, 0x21, 0x01]); // Doble alto
      bytes.addAll(_text('DOBLE ALTO (0x01):\nCorredor Central Norte\n\n'));

      bytes.addAll([0x1D, 0x21, 0x10]); // Doble ancho
      bytes.addAll(_text('DOBLE ANCHO (0x10):\nCorredor Central Norte\n\n'));

      bytes.addAll([0x1D, 0x21, 0x11]); // Doble ancho y alto
      bytes.addAll(_text('GIGANTE (0x11):\nCorredor Central Norte\n\n'));

      bytes.addAll([0x1D, 0x21, 0x00]); // Normal
      bytes.addAll(_text('--- PRUEBA DE QR ---\n\n'));
      bytes.addAll([0x1B, 0x45, 0x00]); // No Bold

      for (final size in [0x04, 0x05, 0x06]) {
        bytes.addAll(_text('QR TAMANO $size:\n'));
        bytes.addAll(
            [0x1D, 0x28, 0x6B, 0x04, 0x00, 0x31, 0x41, 0x32, 0x00]); // Model 2
        bytes.addAll([0x1D, 0x28, 0x6B, 0x03, 0x00, 0x31, 0x43, size]);
        bytes.addAll([0x1D, 0x28, 0x6B, 0x03, 0x00, 0x31, 0x45, 0x31]); // Lvl M
        final data = 'TEST-QR-SIZE-$size'.codeUnits;
        bytes.addAll([
          0x1D,
          0x28,
          0x6B,
          (data.length + 3) & 0xFF,
          ((data.length + 3) >> 8) & 0xFF,
          0x31,
          0x50,
          0x30
        ]);
        bytes.addAll(data);
        bytes.addAll([0x1D, 0x28, 0x6B, 0x03, 0x00, 0x31, 0x51, 0x30]); // Print
        bytes.addAll(_text('\n\n'));
      }

      bytes.addAll([0x1B, 0x64, 0x04]);
      bytes.addAll([0x1D, 0x56, 0x42, 0x00]);

      return await _send(bytes) == true;
    } catch (e) {
      return false;
    }
  }

  // ==================== Impresión x RAW Bytes ====================

  // bool?  → null significa permiso USB pendiente, true/false éxito/fallo
  Future<bool?> printTicket({
    required String transactionId,
    required double amount,
    required String qrData,
    required String cashierName,
    required String cashierId,
    int? posLocationId,
    String? branchName,
    String? productName,
    bool isReprint = false,
    dynamic context,
  }) async {
    bool? success = await _printTicketInternal(
      transactionId: transactionId,
      amount: amount,
      cashierId: cashierId,
      branchName: branchName,
      isReprint: isReprint,
    );
    if (success == false) {
      print('DEBUG: Fallo primer intento, reintentando en 500ms...');
      await Future.delayed(const Duration(milliseconds: 500));
      success = await _printTicketInternal(
        transactionId: transactionId,
        amount: amount,
        cashierId: cashierId,
        branchName: branchName,
        isReprint: isReprint,
      );
    }
    return success;
  }

  Future<bool?> _printTicketInternal({
    required String transactionId,
    required double amount,
    required String cashierId,
    String? branchName,
    bool isReprint = false,
  }) async {
    print('DEBUG: Iniciando impresión de venta...');
    try {
      print('DEBUG: Generando bytes ESC/POS...');
      // Forzamos UTC-5 para Ecuador/Colombia
      final nowUtc = DateTime.now().toUtc();
      final now = nowUtc.subtract(const Duration(hours: 5));

      final dateStr =
          '${now.day.toString().padLeft(2, '0')}/${now.month.toString().padLeft(2, '0')}/${now.year}';
      final timeStr =
          '${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}:${now.second.toString().padLeft(2, '0')}';

      final bytes = <int>[];
      bytes.addAll([0x1B, 0x40]); // Init
      bytes.addAll([0x1B, 0x61, 0x00]); // Todo a la Izquierda
      bytes.addAll([0x1B, 0x45, 0x01]); // Bold
      bytes.addAll([0x1D, 0x21, 0x00]); // Tamaño NORMAL
      bytes.addAll(_text('Corredor Central Norte\n'));

      if (branchName != null && branchName.trim().isNotEmpty) {
        bytes.addAll(_text('Estacion: ${branchName.trim().toUpperCase()}\n'));
      }

      if (isReprint) {
        bytes.addAll(_text('*** REIMPRESIÓN ***\n'));
      }

      bytes.addAll([0x1B, 0x45, 0x00]); // Quitar bold
      bytes.addAll(_text('Fecha: $dateStr $timeStr\n'));
      bytes.addAll(_text('Serial: $transactionId-$cashierId\n'));

      bytes.addAll([0x1B, 0x45, 0x01]); // Bold
      bytes.addAll([0x1D, 0x21, 0x33]); // Tamaño GIGANTE (x4)

      bytes.addAll(_text('\$${CurrencyFormatter.format(amount)}\n'));

      bytes.addAll([0x1B, 0x45, 0x00]); // Quitar bold
      bytes.addAll([0x1D, 0x21, 0x00]); // Tamaño NORMAL

      // Se comenta el código QR temporalmente a solicitud del usuario
      // bytes.addAll(_cmdQrCode(qrData));

      bytes.addAll([0x1B, 0x64, 0x01]); // 1 salto
      bytes.addAll([0x1D, 0x56, 0x42, 0x00]); // Cortar papel

      return await _send(bytes);
    } catch (e) {
      print('DEBUG: Fallo en printTicket: $e');
      return false;
    }
  }

  /// Imprime ticket de Arqueo.
  Future<bool?> printArqueoTicket({
    required double totalAmount,
    required List<Map<String, dynamic>> products,
    required String cashierName,
    String? reviewerName,
  }) async {
    print('DEBUG: Iniciando impresión de ARQUEO...');
    try {
      final bytes = <int>[];
      bytes.addAll([0x1B, 0x40]); // Init
      bytes.addAll([0x1B, 0x61, 0x00]); // Izquierda para todo el tiquete
      bytes.addAll([0x1B, 0x45, 0x01]); // Bold
      bytes.addAll(_text('CORREDOR CENTRAL NORTE\n'));
      bytes.addAll([0x1D, 0x21, 0x11]); // Tamaño x2
      bytes.addAll(_text('ARQUEO DE CAJA\n'));
      bytes.addAll([0x1D, 0x21, 0x00]); // Normal
      bytes.addAll([0x1B, 0x45, 0x00]); // Quitar bold

      final now = DateTime.now();
      final dateStr =
          '${now.day.toString().padLeft(2, '0')}/${now.month.toString().padLeft(2, '0')}/${now.year}';
      final timeStr =
          '${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}';
      bytes.addAll(_text('Fecha Hora: $dateStr $timeStr\n\n'));

      // Detalle de productos
      for (var p in products) {
        final qty = p['qty'].toString();
        final name = p['name'].toString().toUpperCase();
        final total = CurrencyFormatter.format(p['total'] as double);
        bytes.addAll(_text('$qty x $name: $total\n'));
      }
      bytes.addAll(_text('\n'));

      bytes.addAll([0x1B, 0x45, 0x01]); // Bold
      bytes.addAll([0x1B, 0x61, 0x00]); // Izquierda
      bytes.addAll([0x1D, 0x21, 0x10]); // Doble ancho
      bytes.addAll(
          _text('TOTAL: \$${CurrencyFormatter.format(totalAmount)}\n\n'));
      bytes.addAll([0x1D, 0x21, 0x00]); // Normal
      bytes.addAll([0x1B, 0x45, 0x00]); // Quitar bold

      bytes.addAll(_text('EFECTIVO:____________\n\n'));
      bytes.addAll(_text('SOBRANTE:__________\n'));
      bytes.addAll(_text('FALTANTE:___________\n\n\n'));

      bytes.addAll(_text('Fiscalizador:\n'));
      if (reviewerName != null && reviewerName.isNotEmpty) {
        bytes.addAll(_text('Nombre: $reviewerName\n'));
      } else {
        bytes.addAll(_text('Nombre:____________________\n'));
      }
      bytes.addAll(_text('Firma:_______________________\n\n\n'));

      bytes.addAll(_text('Cajero:\n'));
      bytes.addAll(_text('Nombre: $cashierName\n'));
      bytes.addAll(_text('Firma:_______________________\n\n\n\n'));

      bytes.addAll([0x1B, 0x64, 0x01]); // 1 salto
      bytes.addAll([0x1D, 0x56, 0x42, 0x00]); // Cortar papel

      return await _send(bytes);
    } catch (e) {
      print('DEBUG: Fallo en printArqueoTicket: $e');
      return false;
    }
  }

  /// Imprime ticket de cierre. Retorna null si se requiere permiso USB.
  Future<bool?> printClosingTicket({
    required String cashierName,
    required String cashierId,
    required String branchName,
    required int totalTransactions,
    required double totalAmount,
    required String startTime,
    required String endTime,
    int? posLocationId,
    String? qrData,
    List<String>? breakdown,
    int pmrCount = 0,
    List<String>? pmrHours,
    int reprintsCount = 0,
    dynamic cashList,
    double? cash,
    double? balance,
    dynamic context,
  }) async {
    bool? success = await _printClosingTicketInternal(
      cashierName: cashierName,
      cashierId: cashierId,
      branchName: branchName,
      totalTransactions: totalTransactions,
      totalAmount: totalAmount,
      endTime: endTime,
      posLocationId: posLocationId,
      qrData: qrData,
      breakdown: breakdown,
      pmrCount: pmrCount,
      pmrHours: pmrHours,
      reprintsCount: reprintsCount,
      cashList: cashList,
      cash: cash,
      balance: balance,
    );
    if (success == false) {
      print('DEBUG: Fallo primer intento de cierre, reintentando en 500ms...');
      await Future.delayed(const Duration(milliseconds: 500));
      success = await _printClosingTicketInternal(
        cashierName: cashierName,
        cashierId: cashierId,
        branchName: branchName,
        totalTransactions: totalTransactions,
        totalAmount: totalAmount,
        endTime: endTime,
        posLocationId: posLocationId,
        qrData: qrData,
        breakdown: breakdown,
        pmrCount: pmrCount,
        pmrHours: pmrHours,
        reprintsCount: reprintsCount,
        cashList: cashList,
        cash: cash,
        balance: balance,
      );
    }
    return success;
  }

  Future<bool?> _printClosingTicketInternal({
    required String cashierName,
    required String cashierId,
    required String branchName,
    required int totalTransactions,
    required double totalAmount,
    required String endTime,
    int? posLocationId,
    String? qrData,
    List<String>? breakdown,
    int pmrCount = 0,
    List<String>? pmrHours,
    int reprintsCount = 0,
    dynamic cashList,
    double? cash,
    double? balance,
  }) async {
    print('DEBUG: Iniciando impresión de CIERRE...');
    try {
      final bytes = <int>[];
      bytes.addAll([0x1B, 0x40]); // Init
      bytes.addAll([0x1B, 0x61, 0x00]); // Left (Justificado a la izquierda)
      bytes.addAll([0x1B, 0x45, 0x01]); // Bold
      bytes.addAll([0x1D, 0x21, 0x11]); // Tamaño x2
      bytes.addAll(_text('CIERRE DE CAJA\n'));
      bytes.addAll([0x1D, 0x21, 0x00]); // Normal
      bytes.addAll([0x1B, 0x45, 0x00]);
      bytes.addAll(_text('Estacion: $branchName\n\n'));
      bytes.addAll([0x1B, 0x61, 0x00]); // Left
      bytes.addAll(_text('Cajero: $cashierName\n'));
      bytes.addAll(_text('Código: $cashierId - ${posLocationId ?? 0}\n'));
      bytes.addAll(_text('Cierre: $endTime\n\n'));

      bool isManualCash = false;
      double coinsTotal = 0.0;
      double billsTotal = 0.0;

      if (cashList is Map && cash != null) {
        coinsTotal = (cashList["coins_total"] as num?)?.toDouble() ?? 0.0;
        billsTotal = (cashList["bills_total"] as num?)?.toDouble() ?? 0.0;

        isManualCash = (coinsTotal == 0.0 && billsTotal == 0.0);
      }

      if (breakdown != null && breakdown.isNotEmpty && !isManualCash) {
        bytes.addAll([0x1B, 0x61, 0x00]); // Left
        for (final line in breakdown) {
          bytes.addAll(_text('$line\n'));
        }
        bytes.addAll(_text('\n'));
      }

      if (pmrCount > 0) {
        bytes.addAll([0x1B, 0x61, 0x00]); // Left
        bytes.addAll(_text('Aperturas PMR: $pmrCount\n'));
        if (pmrHours != null && pmrHours.isNotEmpty) {
          bytes.addAll(_text('Horas: ${pmrHours.join(", ")}\n'));
        }
        bytes.addAll(_text('\n'));
      }

      bytes.addAll([0x1B, 0x61, 0x00]); // Left
      bytes.addAll(_text('Transacciones: $totalTransactions\n'));
      bytes.addAll(_text('Reimpresiones: $reprintsCount\n\n'));

      if (!isManualCash) {
        bytes.addAll([0x1B, 0x45, 0x01]); // Bold
        bytes.addAll([0x1B, 0x61, 0x00]); // Left
        bytes.addAll([0x1D, 0x21, 0x10]); // Doble ancho
        bytes.addAll(
            _text('TOTAL: \$${CurrencyFormatter.format(totalAmount)}\n\n'));
        bytes.addAll([0x1D, 0x21, 0x00]); // Normal
        bytes.addAll([0x1B, 0x45, 0x00]); // Quitar bold
      }

      if (cashList is Map && cash != null) {
        bytes.addAll([0x1B, 0x61, 0x00]); // Left

        if (isManualCash) {
          bytes.addAll([0x1B, 0x45, 0x01]); // Bold on
          bytes.addAll(_text('DIGITE EFECTIVO:\n\n'));
          bytes.addAll([0x1B, 0x45, 0x00]); // Bold off

          bytes.addAll(_text('Monedas: __________\n\n'));
          bytes.addAll(_text('Billetes: __________\n\n'));
          bytes.addAll(_text('Total: __________\n\n'));
          bytes.addAll(_text('FONDO: \$5\n\n'));
        } else {
          bytes.addAll([0x1B, 0x45, 0x00]); // Bold off
          bytes.addAll(
              _text('Monedas: \$${CurrencyFormatter.format(coinsTotal)}\n'));
          bytes.addAll(
              _text('Billetes: \$${CurrencyFormatter.format(billsTotal)}\n'));

          bytes.addAll([0x1B, 0x45, 0x01]); // Bold on
          bytes.addAll([0x1D, 0x21, 0x11]); // x2 size
          bytes.addAll(
              _text('\nEFECTIVO: \$${CurrencyFormatter.format(cash)}\n'));
          bytes.addAll([0x1D, 0x21, 0x00]); // Normal size
          bytes.addAll([0x1B, 0x45, 0x00]); // Bold off
          bytes.addAll(_text('\nFONDO: \$5\n\n'));
        }

        bytes.addAll([0x1B, 0x45, 0x00]); // Bold off
        bytes.addAll([0x1D, 0x21, 0x00]); // Normal size
      }

      if (qrData != null && qrData.isNotEmpty) {
        bytes.addAll(_text('\n'));
        bytes.addAll(_cmdQrCode(qrData));
        bytes.addAll(_text('\n\n'));
      }

      if (!isManualCash && balance != null && balance.abs() >= 0.01) {
        if (balance < 0) {
          // Efectivo - Sistema = Negativo -> FALTANTE
          bytes.addAll([0x1B, 0x61, 0x00]); // Left
          bytes.addAll([0x1B, 0x45, 0x01]); // Bold
          bytes.addAll([0x1D, 0x21, 0x00]); // Normal size
          bytes.addAll(_text(
              'FALTANTE: \$${CurrencyFormatter.format(balance.abs())}\n'));
          bytes.addAll([0x1D, 0x21, 0x00]);
          bytes.addAll([0x1B, 0x45, 0x00]);
          bytes.addAll(_text('\n\n'));
        }
        // Si hay sobrante (balance > 0), no se imprime visualmente por petición del cliente.
      }

      bytes.addAll([
        0x1B,
        0x64,
        0x04
      ]); // Feed 4 lines para asegurar que salga del cabezal
      bytes.addAll([0x1D, 0x56, 0x42, 0x00]); // Cortar papel

      return await _send(bytes);
    } catch (e) {
      print('DEBUG: Error en printClosingTicket: $e');
      return false;
    }
  }

  // ==================== Utilidades UTF8 -> ASCII ====================

  List<int> _text(String text) {
    // Reemplazo simple para caracteres latinos
    final mapped = text
        .replaceAll('á', 'a')
        .replaceAll('é', 'e')
        .replaceAll('í', 'i')
        .replaceAll('ó', 'o')
        .replaceAll('ú', 'u')
        .replaceAll('ñ', 'n')
        .replaceAll('Á', 'A')
        .replaceAll('É', 'E')
        .replaceAll('Í', 'I')
        .replaceAll('Ó', 'O')
        .replaceAll('Ú', 'U')
        .replaceAll('Ñ', 'N');
    // Cualquier otro carácter fuera de ASCII imprimible se sustituye por '?'
    // para no enviar bytes inválidos que la impresora dibuje como basura.
    return mapped.codeUnits
        .map((c) =>
            (c == 0x0A || c == 0x0D || (c >= 0x20 && c <= 0x7E)) ? c : 0x3F)
        .toList();
  }

  /// Genera comando nativo ESC/POS para QR Code (GS ( k)
  List<int> _cmdQrCode(String data) {
    final dataBytes = data.codeUnits;
    final store = dataBytes.length + 3;
    final bytes = <int>[];

    // 1. Modelo QR (Modelo 2)
    bytes.addAll([0x1D, 0x28, 0x6B, 0x04, 0x00, 0x31, 0x41, 0x32, 0x00]);
    // 2. Tamaño del módulo (5 en lugar de 6 para hacerlo un poco más pequeño)
    bytes.addAll([0x1D, 0x28, 0x6B, 0x03, 0x00, 0x31, 0x43, 0x05]);
    // 3. Nivel de corrección (M)
    bytes.addAll([0x1D, 0x28, 0x6B, 0x03, 0x00, 0x31, 0x45, 0x31]);
    // 4. Cargar datos
    final pL = store & 0xFF;
    final pH = (store >> 8) & 0xFF;
    bytes.addAll([0x1D, 0x28, 0x6B, pL, pH, 0x31, 0x50, 0x30]);
    bytes.addAll(dataBytes);
    // 5. Imprimir QR
    bytes.addAll([0x1D, 0x28, 0x6B, 0x03, 0x00, 0x31, 0x51, 0x30]);

    return bytes;
  }
}

final printerServiceProvider = Provider<PrinterService>((ref) {
  return PrinterService();
});
