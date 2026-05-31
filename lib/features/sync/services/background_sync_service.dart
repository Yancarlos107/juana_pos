import 'dart:io';
import 'package:flutter/material.dart';
import '../../../main.dart';
import 'package:device_info_plus/device_info_plus.dart';
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
  Map<String, String>? _cachedDeviceInfo;

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
    final pending = await db
        .query('transactions', where: 'status = ?', whereArgs: ['pending']);

    if (pending.isEmpty) return;

    // Obtener datos del usuario activo
    final users = await db.query('users', limit: 1);
    int cashierid = 1;
    String employeeFullName = "Cajero Desconocido";
    if (users.isNotEmpty) {
      cashierid = (users.first['id'] as int?) ?? 1;
      employeeFullName = (users.first['name'] as String?) ?? "Cajero Desconocido";
    }

    // Obtener información del dispositivo
    final deviceInfo = await _getDeviceInfo();

    try {
      final List<Map<String, dynamic>> tokens = pending.map((tx) {
        return {
          "qr": tx['qr_data'],
          "cashierid": cashierid,
          "expiredtime": 60,
          "fareid": tx['product_id'],
          "productid": tx['product_id'],
          "versionid": 1,
          "datetime": DateTime.parse(tx['created_at'].toString()).millisecondsSinceEpoch ~/ 1000
        };
      }).toList();

      final payload = {
        "dat": (DateTime.now().millisecondsSinceEpoch ~/ 1000).toString(),
        "token": tokens,
        "lat": "0.0",
        "lon": "0.0",
        "hw": deviceInfo['hw'],
        "ime": deviceInfo['ime'],
        "employee_full_name": employeeFullName,
        "typ": "RC173",
        "ver": "1.0.0"
      };

      // Log visual de intento de envío para QA
      scaffoldMessengerKey.currentState?.showSnackBar(
        SnackBar(
          content: Text('Intentando enviar ${pending.length} tramas a RC173...', style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 20)),
          backgroundColor: Colors.blueAccent,
          duration: const Duration(seconds: 2),
        ),
      );

      // Endpoint de transacciones
      final response = await _dio.post('/pos-transactions', data: payload);

      if (response.statusCode == 200 || response.statusCode == 201) {
        // Marcar todas como synced usando un batch
        final batch = db.batch();
        for (final tx in pending) {
          batch.update('transactions', {'status': 'synced'},
              where: 'local_id = ?', whereArgs: [tx['local_id']]);
        }
        await batch.commit(noResult: true);
        
        // Log visual para QA
        scaffoldMessengerKey.currentState?.showSnackBar(
          SnackBar(
            content: Text('Sincronización masiva exitosa: ${pending.length} transacciones enviadas al servidor.', style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 20)),
            backgroundColor: Colors.green,
            duration: const Duration(seconds: 4),
          ),
        );

        print('DEBUG: ${pending.length} ventas offline sincronizadas masivamente (RC173).');
      }
    } catch (e) {
      String errorMessage = e.toString().split('\n').first;
      if (e is DioException && e.response != null) {
        final bodyData = e.response?.data;
        print('================ RC173 ERROR BODY ================');
        print('Status Code: ${e.response?.statusCode}');
        print('Response Body: $bodyData');
        print('==================================================');
        
        // Si hay un mensaje de validación o similar en el JSON, lo extraemos
        if (bodyData is Map && bodyData.containsKey('message')) {
          errorMessage = bodyData['message'].toString();
        } else if (bodyData != null) {
          errorMessage = bodyData.toString();
        }
      }

      // Log visual de error para QA
      scaffoldMessengerKey.currentState?.showSnackBar(
        SnackBar(
          content: Text('Fallo RC173: $errorMessage', style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 18)),
          backgroundColor: Colors.redAccent,
          duration: const Duration(seconds: 8), // Más tiempo para que puedan tomar pantallazo
        ),
      );
      print('DEBUG: Fallo al sincronizar tramas masivas RC173: $e');
      // Quedan en pending para el próximo intento
    }
  }

  Future<Map<String, String>> _getDeviceInfo() async {
    if (_cachedDeviceInfo != null) return _cachedDeviceInfo!;
    final DeviceInfoPlugin deviceInfoPlugin = DeviceInfoPlugin();
    String hw = "UNKNOWN";
    String ime = "UNKNOWN";

    try {
      if (Platform.isAndroid) {
        final build = await deviceInfoPlugin.androidInfo;
        hw = build.model; 
        ime = build.id;   
      } else if (Platform.isIOS) {
        final data = await deviceInfoPlugin.iosInfo;
        hw = data.model;
        ime = data.identifierForVendor ?? "UNKNOWN";
      }
    } catch (_) {}

    _cachedDeviceInfo = {"hw": hw, "ime": ime};
    return _cachedDeviceInfo!;
  }

  Future<void> _syncSessions() async {
    final db = await DatabaseHelper.instance.database;
    // Cierres de caja locales que aún no se sincronizan
    final closedSessions =
        await db.query('sessions', where: 'status = ?', whereArgs: ['closed']);

    // Si la API tiene un endpoint para consolidar sesiones, lo llamamos aquí.
    // Por el momento, preparamos la estructura marcándolas como "synced_closed"
    // una vez que los endpoints estén disponibles.
    for (final session in closedSessions) {
      try {
        // await _dio.post('/gateway/v1/sessions/close', data: {"session_id": session['id']});
        await db.update('sessions', {'status': 'synced_closed'},
            where: 'id = ?', whereArgs: [session['id']]);
        print('DEBUG: Sesión ${session['id']} marcada como sincronizada.');
      } catch (e) {
        print('DEBUG: Fallo al sincronizar sesion ${session['id']}: $e');
      }
    }
  }
}
