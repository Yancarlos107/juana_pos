import 'dart:async';
import 'dart:typed_data';
import 'package:flutter/services.dart';
import '../../auth/providers/auth_providers.dart';
import '../../../core/utils/currency_formatter.dart';
import 'package:flutter_thermal_printer/flutter_thermal_printer.dart';
import 'package:flutter_thermal_printer/utils/printer.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'epson_epos_service.dart';

/// Servicio de impresión térmica POS vía USB.
/// Detecta automáticamente si hay una impresora Epson (vendor 0x04B8) y usa
/// USB Host API directo. Para otras impresoras usa flutter_thermal_printer.
class PrinterService {
  final FlutterThermalPrinter _printer = FlutterThermalPrinter.instance;
  final EpsonEposService _epsonService = EpsonEposService();
  Printer? _connectedPrinter;
  static const _platform = MethodChannel('co.Juana.usb/status');

  int? _lastVendorId;
  int? _lastProductId;

  Future<bool> checkHardwareConnection() async {
    try {
      final bool isConnected =
          await _platform.invokeMethod('isUsbDeviceConnected', {
        'vendorId': _lastVendorId ?? -1,
        'productId': _lastProductId ?? -1,
      });
      return isConnected;
    } catch (e) {
      print('DEBUG: Error native check: $e');
      return false; // NUNCA asumir true si hay error, para no ocultar la desconexión
    }
  }

  // Vendor ID 1208 = 0x04B8 = Seiko Epson Corp.
  Future<bool> _isEpsonConnected() async {
    try {
      return await _platform.invokeMethod('isUsbDeviceConnected', {
        'vendorId': 1208,
        'productId': -1,
      });
    } catch (_) {
      return false;
    }
  }

  // ==================== Gestión de conexión ====================

  Future<List<Printer>> scanUsbPrinters() async {
    print('DEBUG: Inciando escaneo de impresoras USB...');
    final completer = Completer<List<Printer>>();

    // Iniciar escaneo nativo
    _printer.getPrinters(connectionTypes: [ConnectionType.USB]);

    final sub = _printer.devicesStream.listen((list) {
      if (!completer.isCompleted && list.isNotEmpty) {
        completer.complete(
            list.where((p) => p.connectionType == ConnectionType.USB).toList());
      }
    });

    try {
      final printers =
          await completer.future.timeout(const Duration(seconds: 2));
      await sub.cancel();
      return printers;
    } catch (e) {
      await sub.cancel();
      return [];
    }
  }

  Future<bool> connectToFirstUsb() async {
    print('DEBUG: Iniciando autoconexión USB Directa...');
    try {
      // Si ya sabíamos qué impresora era, verificamos físicamente primero
      if (_lastVendorId != null) {
        final hardwareConnected = await checkHardwareConnection();
        if (!hardwareConnected) {
          print(
              'DEBUG: Impresora física desconectada (vendor/product no encontrado).');
          return false;
        }
      }

      final printers = await scanUsbPrinters();
      if (printers.isEmpty) {
        print('DEBUG: No se encontró hardware USB compatible en la librería');
        return false;
      }

      // Conectamos a la primera detectada por USB
      print('DEBUG: Enlazando con USB: ${printers.first.name}');
      final success = await connectToPrinter(printers.first);

      if (success) {
        // Guardamos las credenciales de hardware para verificarlas rápido la próxima vez
        _lastVendorId = int.tryParse(printers.first.vendorId ?? '');
        _lastProductId = int.tryParse(printers.first.productId ?? '');
      }

      return success;
    } catch (e) {
      print('DEBUG: Error de autoconexión: $e');
      return false;
    }
  }

  Future<bool> connectToPrinter(Printer printer) async {
    print(
        'DEBUG: Estableciendo enlace con ${printer.name} (${printer.address})...');
    try {
      await _printer.connect(printer);
      _connectedPrinter = printer;
      print('DEBUG: ¡Conectado!');
      return true;
    } catch (e) {
      print('DEBUG: Fallo de enlace: $e');
      _connectedPrinter = null;
      return false;
    }
  }

  bool get isConnected => _connectedPrinter?.isConnected == true;

  Future<bool> pingPrinter() async {
    return await checkHardwareConnection();
  }

  Future<bool> printFontAndQrTest() async {
    try {
      final hardwareConnected = await checkHardwareConnection();
      if (!hardwareConnected) return false;
      final connected = await connectToFirstUsb();
      if (!connected) return false;

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

      bytes.addAll(_text('QR TAMANO 4 (0x04):\n'));
      bytes.addAll([0x1D, 0x28, 0x6B, 0x04, 0x00, 0x31, 0x41, 0x32, 0x00]); // Model 2
      bytes.addAll([0x1D, 0x28, 0x6B, 0x03, 0x00, 0x31, 0x43, 0x04]); // Size 4
      bytes.addAll([0x1D, 0x28, 0x6B, 0x03, 0x00, 0x31, 0x45, 0x31]); // Lvl M
      final d4 = 'TEST-QR-SIZE-4'.codeUnits;
      bytes.addAll([0x1D, 0x28, 0x6B, (d4.length + 3) & 0xFF, ((d4.length + 3) >> 8) & 0xFF, 0x31, 0x50, 0x30]);
      bytes.addAll(d4);
      bytes.addAll([0x1D, 0x28, 0x6B, 0x03, 0x00, 0x31, 0x51, 0x30]); // Print
      bytes.addAll(_text('\n\n'));

      bytes.addAll(_text('QR TAMANO 5 (0x05):\n'));
      bytes.addAll([0x1D, 0x28, 0x6B, 0x04, 0x00, 0x31, 0x41, 0x32, 0x00]);
      bytes.addAll([0x1D, 0x28, 0x6B, 0x03, 0x00, 0x31, 0x43, 0x05]); // Size 5
      bytes.addAll([0x1D, 0x28, 0x6B, 0x03, 0x00, 0x31, 0x45, 0x31]);
      final d5 = 'TEST-QR-SIZE-5'.codeUnits;
      bytes.addAll([0x1D, 0x28, 0x6B, (d5.length + 3) & 0xFF, ((d5.length + 3) >> 8) & 0xFF, 0x31, 0x50, 0x30]);
      bytes.addAll(d5);
      bytes.addAll([0x1D, 0x28, 0x6B, 0x03, 0x00, 0x31, 0x51, 0x30]);
      bytes.addAll(_text('\n\n'));

      bytes.addAll(_text('QR TAMANO 6 (0x06):\n'));
      bytes.addAll([0x1D, 0x28, 0x6B, 0x04, 0x00, 0x31, 0x41, 0x32, 0x00]);
      bytes.addAll([0x1D, 0x28, 0x6B, 0x03, 0x00, 0x31, 0x43, 0x06]); // Size 6
      bytes.addAll([0x1D, 0x28, 0x6B, 0x03, 0x00, 0x31, 0x45, 0x31]);
      final d6 = 'TEST-QR-SIZE-6'.codeUnits;
      bytes.addAll([0x1D, 0x28, 0x6B, (d6.length + 3) & 0xFF, ((d6.length + 3) >> 8) & 0xFF, 0x31, 0x50, 0x30]);
      bytes.addAll(d6);
      bytes.addAll([0x1D, 0x28, 0x6B, 0x03, 0x00, 0x31, 0x51, 0x30]);
      bytes.addAll(_text('\n\n'));

      bytes.addAll([0x1B, 0x64, 0x04]);
      bytes.addAll([0x1D, 0x56, 0x42, 0x00]);

      if (_connectedPrinter == null) return false;
      await _printer.printData(_connectedPrinter!, Uint8List.fromList(bytes));
      return true;
    } catch (e) {
      return false;
    }
  }

  // ==================== Impresión x RAW Bytes ====================

  // bool?  → null significa permiso USB pendiente (solo Epson), true/false éxito/fallo
  Future<bool?> printTicket({
    required String transactionId,
    required double amount,
    required String qrData,
    required String cashierName,
    String? branchName,
    String? productName,
    bool isReprint = false,
    dynamic context,
  }) async {
    print('DEBUG: Iniciando impresión de venta...');
    try {
      final hardwareConnected = await checkHardwareConnection();
      if (!hardwareConnected) {
        print('DEBUG: Hardware desconectado abortando printTicket.');
        return false;
      }

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
        bytes.addAll(_text('${branchName.trim().toUpperCase()}\n'));
      }

      if (isReprint) {
        bytes.addAll(_text('*** REIMPRESIÓN ***\n'));
      }

      bytes.addAll([0x1B, 0x45, 0x00]); // Quitar bold
      bytes.addAll(_text('Fecha: $dateStr $timeStr\n'));
      bytes.addAll(_text('Serial: $transactionId\n'));

      bytes.addAll([0x1B, 0x45, 0x01]); // Bold
      bytes.addAll([0x1D, 0x21, 0x33]); // Tamaño GIGANTE (x4)

      bytes.addAll(_text('\$${CurrencyFormatter.format(amount)}\n'));

      bytes.addAll([0x1B, 0x45, 0x00]); // Quitar bold
      bytes.addAll([0x1D, 0x21, 0x00]); // Tamaño NORMAL

      // Se comenta el código QR temporalmente a solicitud del usuario
      // bytes.addAll(_cmdQrCode(qrData));

      bytes.addAll([0x1B, 0x64, 0x01]);        // 1 salto
      bytes.addAll([0x1D, 0x56, 0x42, 0x00]); // Cortar papel

      final epson = await _isEpsonConnected();
      if (epson) {
        print('DEBUG: Enviando ticket vía USB Host API (Epson)...');
        return await _epsonService.printBytes(Uint8List.fromList(bytes));
      }

      // Ruta flutter_thermal_printer para otras impresoras
      final connected = await connectToFirstUsb();
      if (!connected) {
        print('DEBUG: No se pudo establecer conexión USB para el ticket');
        return false;
      }
      if (_connectedPrinter == null) return false;
      await _printer.printData(_connectedPrinter!, Uint8List.fromList(bytes));
      print('DEBUG: Impresión de ticket completada');
      return true;
    } catch (e) {
      print('DEBUG: Fallo en printTicket: $e');
      return false;
    }
  }

  /// Imprime ticket de cierre. Retorna null si se requiere permiso USB (Epson).
  Future<bool?> printClosingTicket({
    required String cashierName,
    required String branchName,
    required int totalTransactions,
    required double totalAmount,
    required String startTime,
    required String endTime,
    String? qrData,
    List<String>? breakdown,
    int pmrCount = 0,
    List<String>? pmrHours,
    int reprintsCount = 0,
    dynamic context,
  }) async {
    print('DEBUG: Iniciando impresión de CIERRE (Conexión forzada)...');
    try {
      final hardwareConnected = await checkHardwareConnection();
      if (!hardwareConnected) {
        print('DEBUG: Hardware desconectado abortando cierre.');
        return false;
      }

      final bytes = <int>[];
      bytes.addAll([0x1B, 0x40]); // Init
      bytes.addAll([0x1B, 0x61, 0x01]); // Center
      bytes.addAll([0x1B, 0x45, 0x01]); // Bold
      bytes.addAll([0x1D, 0x21, 0x00]); // Normal
      bytes.addAll(_text('CIERRE DE CAJA\n'));
      bytes.addAll([0x1B, 0x45, 0x00]);
      bytes.addAll(_text('$branchName\n\n'));
      bytes.addAll([0x1B, 0x61, 0x00]); // Left
      bytes.addAll(_text('Cajero: $cashierName\n'));
      bytes.addAll(_text('Inicio: $startTime\n'));
      bytes.addAll(_text('Cierre: $endTime\n\n'));

      if (breakdown != null && breakdown.isNotEmpty) {
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
      bytes.addAll(_text('Reimpresiones: $reprintsCount\n\n')); // NEW
      bytes.addAll([0x1B, 0x61, 0x01]); // Center
      bytes.addAll([0x1B, 0x45, 0x01]);
      bytes.addAll([0x1D, 0x21, 0x11]);
      bytes.addAll(_text('TOTAL: \$ ${CurrencyFormatter.format(totalAmount)}\n'));
      bytes.addAll([0x1D, 0x21, 0x00]);
      bytes.addAll([0x1B, 0x45, 0x00]);

      if (qrData != null && qrData.isNotEmpty) {
        bytes.addAll(_text('\n'));
        bytes.addAll(_cmdQrCode(qrData));
        bytes.addAll(_text('\n\n'));
      }

      bytes.addAll([0x1B, 0x64, 0x02]);
      bytes.addAll([0x1D, 0x56, 0x42, 0x00]);

      final epson = await _isEpsonConnected();
      if (epson) {
        print('DEBUG: Enviando cierre vía USB Host API (Epson)...');
        return await _epsonService.printBytes(Uint8List.fromList(bytes));
      }

      final connected = await connectToFirstUsb();
      if (!connected) {
        print('DEBUG: No se pudo establecer conexión USB para el cierre');
        return false;
      }
      if (_connectedPrinter == null) return false;
      await _printer.printData(_connectedPrinter!, Uint8List.fromList(bytes));
      print('DEBUG: Cierre impreso exitosamente');
      return true;
    } catch (e) {
      print('DEBUG: Error en printClosingTicket: $e');
      return false;
    }
  }

  // ==================== Utilidades UTF8 -> ASCII ====================

  List<int> _text(String text) {
    // Reemplazo simple para caracteres latinos
    return text
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
        .replaceAll('Ñ', 'N')
        .codeUnits;
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
