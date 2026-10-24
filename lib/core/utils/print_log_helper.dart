import 'dart:io';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

class PrintLogHelper {
  static const String _counterKey = 'print_log_counter';

  /// Obtiene o inicializa el contador
  static Future<int> _getCounter() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getInt(_counterKey) ?? 0;
  }

  /// Incrementa y retorna el nuevo contador
  static Future<int> _incrementCounter() async {
    final prefs = await SharedPreferences.getInstance();
    int current = prefs.getInt(_counterKey) ?? 0;
    current++;
    await prefs.setInt(_counterKey, current);
    return current;
  }

  /// Resetea el contador a 0
  static Future<void> _resetCounter() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_counterKey, 0);
  }

  /// Obtiene el archivo log en el almacenamiento externo para acceso público
  static Future<File> _getLogFile() async {
    Directory? dir;
    try {
      if (Platform.isAndroid) {
        // En Android usamos getExternalStorageDirectory que apunta a Android/data/app/files/
        // Esto NO requiere permisos extra y es visible al conectar por USB.
        dir = await getExternalStorageDirectory();
        if (dir == null) {
          dir = await getApplicationDocumentsDirectory();
        }
      } else {
        // Windows, iOS, etc
        dir = await getApplicationDocumentsDirectory();
      }
    } catch (e) {
      dir = await getApplicationDocumentsDirectory();
    }
    
    if (dir == null) {
      dir = await getApplicationDocumentsDirectory();
    }

    final path = '${dir.path}/log_impresiones.txt';
    return File(path);
  }

  static String _formatDate(DateTime dt) {
    return '${dt.year}-${dt.month.toString().padLeft(2, '0')}-${dt.day.toString().padLeft(2, '0')} ${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}:${dt.second.toString().padLeft(2, '0')}';
  }

  /// Registra una nueva venta
  static Future<void> logSale(int itemsCount) async {
    try {
      final counter = await _incrementCounter();
      final file = await _getLogFile();
      final dateStr = _formatDate(DateTime.now());
      
      final line = '[$dateStr] Vez: $counter - Cantidad de ventas: $itemsCount\n';
      await file.writeAsString(line, mode: FileMode.append);
    } catch (e) {
      print('Error escribiendo log de venta: $e');
    }
  }

  /// Registra el cierre de caja y resetea el contador
  static Future<void> logClosure() async {
    try {
      final file = await _getLogFile();
      final dateStr = _formatDate(DateTime.now());
      
      final line = '[$dateStr] -----CIERRE DE CAJA------\n';
      await file.writeAsString(line, mode: FileMode.append);
      
      await _resetCounter();
    } catch (e) {
      print('Error escribiendo log de cierre: $e');
    }
  }

  /// Registra la conexión/desconexión de la impresora
  static Future<void> logPrinterEvent(bool connected, DateTime at) async {
    try {
      final file = await _getLogFile();
      final dateStr = _formatDate(at);

      final line = connected
          ? '[$dateStr] IMPRESORA CONECTADA (RC176)\n'
          : '[$dateStr] IMPRESORA DESCONECTADA (RC175)\n';
      await file.writeAsString(line, mode: FileMode.append);
    } catch (e) {
      print('Error escribiendo log de impresora: $e');
    }
  }

  /// Registra un fallo en la base de datos local SQLite
  static Future<void> logDbError(String errorMessage) async {
    try {
      final file = await _getLogFile();
      final dateStr = _formatDate(DateTime.now());
      
      final line = '[$dateStr] ERROR BD: Fallo al guardar en SQLite. Motivo: $errorMessage\n';
      await file.writeAsString(line, mode: FileMode.append);
    } catch (e) {
      print('Error escribiendo log de error de BD: $e');
    }
  }
}
