import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sqflite/sqflite.dart';
import '../../../core/constants/api_constants.dart';
import '../../../core/database/database_helper.dart';
import '../../../core/network/dio_client.dart';

final syncServiceProvider = Provider<SyncService>((ref) {
  final dio = ref.watch(dioProvider);
  return SyncService(dio);
});

class SyncService {
  final Dio _dio;

  SyncService(this._dio);

  /// Sincroniza toda la data inicial (Rutas, Tarifas, Usuarios).
  /// Esto debe llamarse al hacer login en línea o al iniciar la app si hay conexión.
  Future<void> syncInitialData() async {
    try {
      final db = await DatabaseHelper.instance.database;

      // 1. Sincronizar Tarifas (Productos)
      await _syncProducts(db);

      // 2. Sincronizar Usuarios (para login offline)
      await _syncUsers(db);

      // 3. Sincronizar Rutas
      await _syncRoutes(db);

    } catch (e) {
      throw Exception('Error durante la sincronización inicial: $e');
    }
  }

  Future<void> _syncProducts(Database db) async {
    try {
      final response = await _dio.get(ApiConstants.gatewayProducts);
      
      if (response.statusCode == 200) {
        final data = response.data['data'] as List?;
        if (data != null) {
          // Limpiar tabla actual
          await db.delete('products');

          final batch = db.batch();
          for (var item in data) {
            batch.insert('products', {
              // Asumiendo que la API devuelve _id o id, product_name, value
              'id': item['id'] ?? item['_id'],
              'product_name': item['product_name'] ?? 'Producto Desconocido',
              'value': item['value'] ?? 0.0,
              'pmr': item['pmr'] == true || item['pmr'] == 1 ? 1 : 0, // Nuevo campo
              'created_at': DateTime.now().toIso8601String(),
            }, conflictAlgorithm: ConflictAlgorithm.replace);
          }
          await batch.commit(noResult: true);
        }
      }
    } catch (e) {
      print('Error syncProducts: $e');
      rethrow;
    }
  }

  Future<void> _syncUsers(Database db) async {
    // TODO: Implementar llamada real al endpoint que devuelva los operadores permitidos.
    // Por ahora, solo tenemos el endpoint /user que devuelve el usuario actual.
    // En un flujo offline, se requeriría un endpoint /users/branch para bajar todos los 
    // hashes de los cajeros de esa sucursal.
    
    // Si tenemos el endpoint /user actual:
    try {
      final response = await _dio.get(ApiConstants.user);
      if (response.statusCode == 200) {
        final user = response.data;
        // Insertar o actualizar el usuario actual
        await db.insert('users', {
          'id': user['id'],
          'email': user['email'] ?? '',
          'password_hash': 'HASH_TEMPORAL', // Esto debería venir del backend o manejarse de otra forma
          'name': user['name'] ?? '',
          'branch_id': user['branch_id'],
          'roles': user['roles']?.toString() ?? '',
        }, conflictAlgorithm: ConflictAlgorithm.replace);
      }
    } catch (e) {
      print('Error syncUsers: $e');
    }
  }

  Future<void> _syncRoutes(Database db) async {
    // TODO: Implementar llamada real al endpoint de rutas
    // final response = await _dio.get('/routes');
    // ... insert logic ...
  }
}
