import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/database/database_helper.dart';
import '../../../core/network/dio_client.dart';
import '../../../core/storage/local_storage_repository.dart';
import '../../auth/providers/auth_providers.dart';

final closureServiceProvider = Provider<ClosureService>((ref) {
  final dio = ref.watch(dioProvider);
  final storage = ref.watch(localStorageProvider);
  return ClosureService(dio, storage);
});

class ClosureService {
  final Dio _dio;
  final LocalStorageRepository _storage;

  ClosureService(this._dio, this._storage);

  /// Realiza la Apertura de Caja (RC171) en el backend
  Future<void> openRegister(String cashierName) async {
    try {
      final token = await _storage.getToken();
      if (token == null) return;

      await _dio.post(
        '/pos-transactions',
        data: {
          "type_code": "RC171",
          "token": "",
          "dat": (DateTime.now().millisecondsSinceEpoch ~/ 1000).toString(),
          "lat": "0.0",
          "lon": "0.0",
          "hw": "POS_FLUTTER",
          "ime": "IMEI_DEFAULT",
          "employee_full_name": cashierName,
          "typ": "RC171",
          "ver": "1.0.0"
        },
        options: Options(
          headers: {
            'Authorization': 'Bearer $token',
            'Accept': 'application/json',
          },
        ),
      );
      print('Apertura de caja RC171 enviada con éxito.');
    } catch (e) {
      print('Advertencia: Falló apertura de caja RC171: $e');
    }
  }

  /// Realiza el Cierre de Caja (RC172 v1) enviando los tokens de las ventas
  Future<Map<String, dynamic>> closeRegister(String cashierName) async {
    try {
      final token = await _storage.getToken();
      if (token == null) throw Exception('No hay sesión activa.');

      final db = await DatabaseHelper.instance.database;
      final branchId = await _storage.getBranchId() ?? 0;
      
      // Obtenemos la sesión abierta para esta sucursal
      final sessionQuery = await db.query(
        'sessions', 
        where: 'status = ? AND branch_id = ?', 
        whereArgs: ['open', branchId]
      );
      
      List<String> hexTokens = [];
      int? sessionId;
      
      double totalAmount = 0.0;
      if (sessionQuery.isNotEmpty) {
        sessionId = sessionQuery.first['id'] as int;
        
        final result = await db.rawQuery('SELECT SUM(amount) as total FROM transactions WHERE session_id = ? AND product_id != ?', [sessionId, 'CIERRE DE CAJA']);
        if (result.isNotEmpty && result.first['total'] != null) {
          totalAmount = (result.first['total'] as num).toDouble();
        }

        // Obtener todas las transacciones de esta sesión
        final txs = await db.query(
          'transactions',
          where: 'session_id = ? AND qr_data IS NOT NULL AND qr_data != ?',
          whereArgs: [sessionId, 'PMR_MANUAL']
        );
        
        hexTokens = txs
            .map((tx) => tx['qr_data'].toString())
            // Solo aquellos que parecen ser tokens hex SHA1 (vienen del gateway v2)
            .where((qr) => qr.length == 40 && !qr.startsWith('{'))
            .toList();
      }

      final csvTokens = hexTokens.join(',');
      
      // Enviamos el RC172
      final response = await _dio.post(
        '/pos-transactions',
        data: {
          "type_code": "RC172",
          "token": csvTokens,
          "dat": (DateTime.now().millisecondsSinceEpoch ~/ 1000).toString(),
          "lat": "0.0",
          "lon": "0.0",
          "hw": "POS_FLUTTER",
          "ime": "IMEI_DEFAULT",
          "employee_full_name": cashierName,
          "typ": "RC172",
          "ver": "1.0.0"
        },
        options: Options(
          headers: {
            'Authorization': 'Bearer $token',
            'Accept': 'application/json',
          },
        ),
      );

      // Si todo fue exitoso, cerramos la sesión localmente
      if (sessionId != null && (response.statusCode == 200 || response.statusCode == 201)) {
        await db.update(
          'sessions',
          {'status': 'closed', 'closed_at': DateTime.now().toIso8601String()},
          where: 'id = ?',
          whereArgs: [sessionId],
        );

        // También marcamos las transacciones como sincronizadas para que BackgroundSync no las repita
        await db.update(
          'transactions',
          {'status': 'synced'},
          where: 'session_id = ? AND status = ?',
          whereArgs: [sessionId, 'pending'],
        );

        // Insertar operación de cierre en el historial
        await db.insert('transactions', {
          'id': 'CIERRE-${DateTime.now().millisecondsSinceEpoch}',
          'session_id': sessionId,
          'product_id': 'CIERRE DE CAJA',
          'amount': totalAmount,
          'pmr': 0,
          'status': 'synced',
          'created_at': DateTime.now().toIso8601String(),
          'qr_data': 'CIERRE',
        });
      }

      return response.data as Map<String, dynamic>;
    } on DioException catch (e) {
      final serverMessage = e.response?.data?['message'];
      final detail = serverMessage ?? e.message ?? e.type.toString();
      throw Exception('Error al cerrar caja: $detail');
    }
  }
}
