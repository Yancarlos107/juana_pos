import 'dart:io';
import 'dart:convert';
import 'dart:math';
import 'package:flutter/material.dart';
import '../../monitoring/services/system_status_service.dart';
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
  return BackgroundSyncService(dio, storage, ref);
});

class BackgroundSyncService {
  final Dio _dio;
  final LocalStorageRepository _storage;
  final ProviderRef _ref;
  bool _isSyncing = false;
  Map<String, String>? _cachedDeviceInfo;

  BackgroundSyncService(this._dio, this._storage, this._ref);

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
      final pendingSales = pending.where((tx) => tx['product_id'] != 'CIERRE DE CAJA').toList();
      final pendingClosures = pending.where((tx) => tx['product_id'] == 'CIERRE DE CAJA').toList();

      // Sincronizar Ventas (RC173)
      if (pendingSales.isNotEmpty) {
        try {
          final List<Map<String, dynamic>> tokens = pendingSales.map((tx) {
            return {
              "qr": tx['qr_data'],
              "cashierid": cashierid,
              "expiredtime": 60,
              "fareid": 1,
              "productid": tx['product_id'],
              "versionid": 1,
              "datetime": DateTime.parse(tx['created_at'].toString()).millisecondsSinceEpoch ~/ 1000
            };
          }).toList();

          final payload = {
            "plot_id": _generatePlotId(),
            "type_code": "RC173",
            "dat": (DateTime.now().millisecondsSinceEpoch ~/ 1000).toString(),
            "token": jsonEncode(tokens),
            "lat": "0.0",
            "lon": "0.0",
            "hw": deviceInfo['hw'],
            "ime": deviceInfo['ime'],
            "employee_full_name": employeeFullName,
            "typ": "RC173",
            "ver": "1.0.0"
          };

          // Endpoint de transacciones
          final response = await _dio.post('/pos-transactions', data: payload);

          if (response.statusCode == 200 || response.statusCode == 201) {
            final batch = db.batch();
            for (final tx in pendingSales) {
              batch.update('transactions', {'status': 'synced'},
                  where: 'local_id = ?', whereArgs: [tx['local_id']]);
            }
            await batch.commit(noResult: true);
            _ref.read(systemStatusProvider.notifier).forceCheckPendingTransactions();
            print('DEBUG: ${pendingSales.length} ventas offline sincronizadas masivamente (RC173).');
          }
        } catch (e) {
          String errorMessage = e.toString().split('\n').first;
          if (e is DioException && e.response != null) {
            final bodyData = e.response?.data;
            if (bodyData is Map && bodyData.containsKey('message')) {
              errorMessage = bodyData['message'].toString();
            } else if (bodyData != null) {
              errorMessage = bodyData.toString();
            }
          }
          print('DEBUG: Fallo al sincronizar tramas masivas RC173: $errorMessage');
        }
      }

      // Sincronizar Cierres de Caja (RC172)
      if (pendingClosures.isNotEmpty) {
        for (final tx in pendingClosures) {
          try {
            final payload = {
              "plot_id": _generatePlotId(),
              "type_code": "RC172",
              "dat": (DateTime.now().millisecondsSinceEpoch ~/ 1000).toString(),
              "token": tx['qr_data'],
              "lat": "0.0",
              "lon": "0.0",
              "hw": deviceInfo['hw'],
              "ime": deviceInfo['ime'],
              "employee_full_name": employeeFullName,
              "typ": "RC172",
              "ver": "1.0.0"
            };

            final response = await _dio.post('/pos-transactions', data: payload);
            if (response.statusCode == 200 || response.statusCode == 201) {
              await db.update('transactions', {'status': 'synced'},
                  where: 'local_id = ?', whereArgs: [tx['local_id']]);
              _ref.read(systemStatusProvider.notifier).forceCheckPendingTransactions();
              print('DEBUG: Cierre offline sincronizado individualmente (RC172).');
            }
          } catch (e) {
            print('DEBUG: Fallo al sincronizar cierre RC172: $e');
          }
        }
      }
    } catch (e) {
      print('DEBUG: Error general en syncPendingData: $e');
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

  String _generatePlotId() {
    final random = Random();
    const chars = '0123456789abcdef';
    return List.generate(32, (index) => chars[random.nextInt(chars.length)]).join();
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
