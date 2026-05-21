import 'dart:async';
import 'dart:typed_data';
import 'package:flutter_thermal_printer/flutter_thermal_printer.dart';
import 'package:flutter_thermal_printer/utils/printer.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Servicio de impresión térmica POS vía USB.
/// Usa comandos ESC/POS nativos en lugar de imágenes (printWidget)
/// para asegurar máxima compatibilidad con impresoras de 58mm.
class PrinterService {
  final FlutterThermalPrinter _printer = FlutterThermalPrinter.instance;
  Printer? _connectedPrinter;
  StreamSubscription<List<Printer>>? _devicesSubscription;

  // ==================== Gestión de conexión ====================

  Future<List<Printer>> scanUsbPrinters() async {
    print('DEBUG: Escaneando impresoras USB (Alta Velocidad)...');
    final completer = Completer<List<Printer>>();
    
    _devicesSubscription?.cancel();
    _devicesSubscription = _printer.devicesStream.listen((list) {
      print('DEBUG: Stream detectó ${list.length} dispositivos USB');
      if (list.isNotEmpty && !completer.isCompleted) {
        completer.complete(list.where((p) => p.connectionType == ConnectionType.USB).toList());
      }
    });

    try {
      await _printer.getPrinters(connectionTypes: [ConnectionType.USB]);
      
      return await completer.future.timeout(
        const Duration(seconds: 3),
        onTimeout: () {
          print('DEBUG: Tiempo de espera agotado buscando USB');
          return [];
        },
      );
    } catch (e) {
      print('DEBUG: Error en escaneo USB: $e');
      return [];
    } finally {
      _devicesSubscription?.cancel();
    }
  }

  Future<bool> connectToFirstUsb() async {
    print('DEBUG: Iniciando autoconexión USB Directa...');
    try {
      final printers = await scanUsbPrinters();
      if (printers.isEmpty) {
        print('DEBUG: No se encontró hardware USB compatible');
        return false;
      }
      
      // Conectamos a la primera detectada por USB
      print('DEBUG: Enlazando con USB: ${printers.first.name}');
      return await connectToPrinter(printers.first);
    } catch (e) {
      print('DEBUG: Error de autoconexión: $e');
      return false;
    }
  }

  Future<bool> connectToPrinter(Printer printer) async {
    print('DEBUG: Estableciendo enlace con ${printer.name} (${printer.address})...');
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

  // ==================== Impresión x RAW Bytes ====================

  Future<bool> printTicket({
    required String transactionId,
    required double amount,
    required String qrData,
    required String cashierName,
    String? branchName,
    String? productName,
    dynamic context, 
  }) async {
    print('DEBUG: Iniciando impresión de venta (Conexión forzada)...');
    try {
      // SIEMPRE intentamos conectar para asegurar que el canal está abierto
      final connected = await connectToFirstUsb();
      if (!connected) {
        print('DEBUG: No se pudo establecer conexión USB para el ticket');
        return false;
      }

      print('DEBUG: Generando bytes ESC/POS...');
      // Forzamos UTC-5 para Ecuador/Colombia
      final nowUtc = DateTime.now().toUtc();
      final now = nowUtc.subtract(const Duration(hours: 5));
      
      final dateStr = '${now.day.toString().padLeft(2, '0')}/${now.month.toString().padLeft(2, '0')}/${now.year}';
      final timeStr = '${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}:${now.second.toString().padLeft(2, '0')}';

      final bytes = <int>[];
      bytes.addAll([0x1B, 0x40]); // Init
      bytes.addAll([0x1B, 0x61, 0x01]); // Centro
      bytes.addAll([0x1B, 0x45, 0x01]); // Bold
      bytes.addAll([0x1D, 0x21, 0x11]); // Doble
      bytes.addAll(_text('VALLIU-SIR\n'));
      bytes.addAll([0x1D, 0x21, 0x00]); 
      bytes.addAll(_text('Corredor Central Norte\n'));
      if (branchName != null) bytes.addAll(_text('$branchName\n'));
      bytes.addAll(_text('================================\n'));
      bytes.addAll([0x1B, 0x61, 0x00]); // Izquierda
      bytes.addAll(_text('Fecha:       $dateStr\n'));
      bytes.addAll(_text('Hora:        $timeStr\n'));
      bytes.addAll(_text('Transaccion: #$transactionId\n'));
      bytes.addAll(_text('Cajero:      $cashierName\n'));
      bytes.addAll([0x1B, 0x61, 0x01]); // Centro
      bytes.addAll(_text('--------------------------------\n'));
      bytes.addAll([0x1B, 0x45, 0x01]); 
      bytes.addAll(_text('PASAJE DE TRANSPORTE\n'));
      if (productName != null) bytes.addAll(_text('$productName\n'));
      bytes.addAll(_text('--------------------------------\n'));
      bytes.addAll([0x1D, 0x21, 0x11]); 
      bytes.addAll(_text('\$ ${amount.toStringAsFixed(0)}\n'));
      bytes.addAll([0x1D, 0x21, 0x00]); 
      bytes.addAll(_text('--------------------------------\n\n'));
      bytes.addAll(_cmdQrCode(qrData));
      bytes.addAll(_text('\n'));
      bytes.addAll([0x1B, 0x45, 0x00]); 
      bytes.addAll(_text('--------------------------------\n'));
      bytes.addAll([0x1B, 0x45, 0x01]); 
      bytes.addAll(_text('Gracias por usar Valliu!\n'));
      bytes.addAll([0x1B, 0x45, 0x00]); 
      bytes.addAll(_text('Conserve este recibo como\n'));
      bytes.addAll(_text('comprobante de su pasaje.\n'));
      bytes.addAll(_text('================================\n'));
      bytes.addAll([0x1B, 0x64, 0x04]); 
      bytes.addAll([0x1D, 0x56, 0x42, 0x00]); 

      if (_connectedPrinter == null) return false;
      
      await _printer.printData(_connectedPrinter!, Uint8List.fromList(bytes));
      print('DEBUG: Impresión de ticket completada');
      return true;
    } catch (e) {
      print('DEBUG: Fallo en printTicket: $e');
      return false;
    }
  }

  /// Imprime ticket de cierre usando comandos RAW (Conexión forzada).
  Future<bool> printClosingTicket({
    required String cashierName,
    required String branchName,
    required int totalTransactions,
    required double totalAmount,
    required String startTime,
    required String endTime,
    String? qrData,
    List<String>? breakdown,
    dynamic context,
  }) async {
    // Nota: El usuario pasa startTime y endTime como String desde el RecaudoScreen.
    // Asumiremos que ya vienen en la zona horaria correcta o los ajustaremos allí.
    print('DEBUG: Iniciando impresión de CIERRE (Conexión forzada)...');
    try {
      final connected = await connectToFirstUsb();
      if (!connected) {
        print('DEBUG: No se pudo establecer conexión USB para el cierre');
        return false;
      }

      final bytes = <int>[];
      bytes.addAll([0x1B, 0x40]); // Init
      bytes.addAll([0x1B, 0x61, 0x01]); // Center
      bytes.addAll([0x1B, 0x45, 0x01]); // Bold
      bytes.addAll([0x1D, 0x21, 0x11]); // Double
      bytes.addAll(_text('VALLIU\n'));
      bytes.addAll([0x1D, 0x21, 0x00]); 
      bytes.addAll(_text('CIERRE DE CAJA\n'));
      bytes.addAll([0x1B, 0x45, 0x00]); 
      bytes.addAll(_text('$branchName\n'));
      bytes.addAll(_text('================================\n'));
      bytes.addAll([0x1B, 0x61, 0x00]); // Left
      bytes.addAll(_text('Cajero: $cashierName\n'));
      bytes.addAll(_text('Inicio: $startTime\n'));
      bytes.addAll(_text('Cierre: $endTime\n'));
      bytes.addAll([0x1B, 0x61, 0x01]); // Center
      bytes.addAll(_text('--------------------------------\n'));
      
      if (breakdown != null && breakdown.isNotEmpty) {
        bytes.addAll([0x1B, 0x61, 0x00]); // Left
        for (final line in breakdown) {
          bytes.addAll(_text('$line\n'));
        }
        bytes.addAll([0x1B, 0x61, 0x01]); // Center
        bytes.addAll(_text('--------------------------------\n'));
      }

      bytes.addAll(_text('Transacciones: $totalTransactions\n'));
      bytes.addAll([0x1B, 0x45, 0x01]); 
      bytes.addAll([0x1D, 0x21, 0x11]); 
      bytes.addAll(_text('TOTAL: \$ ${totalAmount.toStringAsFixed(0)}\n'));
      bytes.addAll([0x1D, 0x21, 0x00]); 
      bytes.addAll([0x1B, 0x45, 0x00]); 
      
      if (qrData != null && qrData.isNotEmpty) {
        bytes.addAll(_text('--------------------------------\n\n'));
        bytes.addAll(_cmdQrCode(qrData));
        bytes.addAll(_text('\n'));
      }
      
      bytes.addAll(_text('================================\n'));
      bytes.addAll([0x1B, 0x64, 0x04]); 
      bytes.addAll([0x1D, 0x56, 0x42, 0x00]); 

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
        .replaceAll('á', 'a').replaceAll('é', 'e').replaceAll('í', 'i')
        .replaceAll('ó', 'o').replaceAll('ú', 'u').replaceAll('ñ', 'n')
        .replaceAll('Á', 'A').replaceAll('É', 'E').replaceAll('Í', 'I')
        .replaceAll('Ó', 'O').replaceAll('Ú', 'U').replaceAll('Ñ', 'N')
        .codeUnits;
  }

  /// Genera comando nativo ESC/POS para QR Code (GS ( k)
  List<int> _cmdQrCode(String data) {
    final dataBytes = data.codeUnits;
    final store = dataBytes.length + 3;
    final bytes = <int>[];

    // 1. Modelo QR (Modelo 2)
    bytes.addAll([0x1D, 0x28, 0x6B, 0x04, 0x00, 0x31, 0x41, 0x32, 0x00]);
    // 2. Tamaño del módulo (6)
    bytes.addAll([0x1D, 0x28, 0x6B, 0x03, 0x00, 0x31, 0x43, 0x06]);
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
