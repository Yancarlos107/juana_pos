import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/database/database_helper.dart';
import '../../../core/network/dio_client.dart';
import '../../../core/storage/local_storage_repository.dart';

final backgroundSyncProvider = Provider<BackgroundSyncService>((ref) {
  final dio = ref.watch(dioProvider);
  final storage = ref.watch(localStorageProvider);
  return BackgroundSyncService(dio, storage);
});

class BackgroundSyncService {
  final Dio _dio;
  final LocalStorageRepository _storage;
  bool _isSyncing = false;

  BackgroundSyncService(this._dio, this._storage);

  /// Inicia el proceso de sincronización si no hay uno activo.
  Future<void> syncPendingData() async {
    if (_isSyncing) return;
    _isSyncing = true;
    try {
      print('DEBUG: Iniciando sincronización en segundo plano...');
      await _syncTransactions();
      await _syncSessions();
      print('DEBUG: Sincronización en segundo plano completada.');
    } catch (e) {
      print('DEBUG: Error en sincronización: $e');
    } finally {
      _isSyncing = false;
    }
  }

  Future<void> _syncTransactions() async {
    final db = await DatabaseHelper.instance.database;
    final pending = await db.query('transactions', where: 'status = ?', whereArgs: ['pending']);
    
    if (pending.isEmpty) return;

    for (final tx in pending) {
      try {
        // Reconstruimos el payload para Valliu
        final payload = {
          "product_id": tx['product_id'],
          "amount": tx['amount'],
          "offline_id": tx['id'], // ID generado localmente
          "pmr": tx['pmr'] == 1,
          "created_at": tx['created_at']
        };

        // endpoint para compras. Se asume que el backend acepta "offline_id" para evitar duplicados.
        final response = await _dio.post('/gateway/v1/purchases', data: payload);
        
        if (response.statusCode == 200 || response.statusCode == 201) {
           await db.update('transactions', {'status': 'synced'}, where: 'id = ?', whereArgs: [tx['id']]);
           print('DEBUG: Venta offline ${tx['id']} sincronizada con éxito.');
        }
      } catch (e) {
        print('DEBUG: Fallo al sincronizar transaccion ${tx['id']}: $e');
        // Si falla, se queda en pending para el próximo intento de ping
      }
    }
  }

  Future<void> _syncSessions() async {
    final db = await DatabaseHelper.instance.database;
    // Cierres de caja locales que aún no se sincronizan
    final closedSessions = await db.query('sessions', where: 'status = ?', whereArgs: ['closed']);
    
    // Si la API tiene un endpoint para consolidar sesiones, lo llamamos aquí.
    // Por el momento, preparamos la estructura marcándolas como "synced_closed" 
    // una vez que los endpoints estén disponibles.
    for (final session in closedSessions) {
      try {
         // await _dio.post('/gateway/v1/sessions/close', data: {"session_id": session['id']});
         await db.update('sessions', {'status': 'synced_closed'}, where: 'id = ?', whereArgs: [session['id']]);
         print('DEBUG: Sesión ${session['id']} marcada como sincronizada.');
      } catch (e) {
         print('DEBUG: Fallo al sincronizar sesion ${session['id']}: $e');
      }
    }
  }
}
