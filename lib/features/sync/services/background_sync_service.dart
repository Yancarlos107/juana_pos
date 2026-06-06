import 'dart:io';
import 'dart:convert';
import 'dart:math';
import 'package:flutter/material.dart';
import '../../monitoring/services/system_status_service.dart';
import '../../../main.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/material.dart';
import '../../../../main.dart';
import '../../../core/database/database_helper.dart';
import '../../../core/network/dio_client.dart';
import '../../../core/storage/local_storage_repository.dart';
import 'package:shared_preferences/shared_preferences.dart';

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

    // Prevenir sincronización prematura durante el login (antes de seleccionar el Punto de Venta)
    final posLocationId = await _storage.getPosLocationId();
    if (posLocationId == null) {
      print(
          'DEBUG: Abortando sync - Aún no se ha seleccionado Punto de Venta.');
      return;
    }

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

    // Obtener información del dispositivo
    final deviceInfo = await _getDeviceInfo();

    try {
      final pendingSales =
          pending.where((tx) => tx['product_id'] != 'CIERRE DE CAJA' && tx['product_id'] != 'APERTURA DE CAJA').toList();
      final pendingClosures =
          pending.where((tx) => tx['product_id'] == 'CIERRE DE CAJA').toList();
      final pendingOpenings =
          pending.where((tx) => tx['product_id'] == 'APERTURA DE CAJA').toList();

      // Obtener el ID de la ubicación POS
      final posLocationId = await _storage.getPosLocationId();

      // Agrupar ventas por cashier_id
      Map<int, List<Map<String, dynamic>>> salesByCashier = {};
      for (var tx in pendingSales) {
        int cId = (tx['cashier_id'] as int?) ?? 1;
        salesByCashier.putIfAbsent(cId, () => []).add(tx);
      }

      // Sincronizar Ventas (RC173) agrupadas por cajero y en bloques
      for (var entry in salesByCashier.entries) {
        final currentCashierId = entry.key;
        final cashierSales = entry.value;

        final userQuery = await db
            .query('users', where: 'id = ?', whereArgs: [currentCashierId]);
        final employeeFullName = userQuery.isNotEmpty
            ? (userQuery.first['name'] as String?) ?? "Cajero Desconocido"
            : "Cajero Desconocido";

        const int chunkSize = 50;
        for (int i = 0; i < cashierSales.length; i += chunkSize) {
          int endIndex = i + chunkSize;
          if (endIndex > cashierSales.length) {
            endIndex = cashierSales.length;
          }
          final chunk = cashierSales.sublist(i, endIndex);

          try {
            final List<Map<String, dynamic>> tokens = chunk.map((tx) {
              return {
                "qr": tx['qr_data'],
                "cashierid": tx[
                    'cashier_id'], // <- Se toma el ID REAL del cajero que hizo la venta
                "expiredtime": 60,
                "fareid": 1,
                "productid": tx['product_id'],
                "transaction_id": tx['id'],
                "pos_location_id": tx['pos_location_id'] ?? posLocationId,
                "versionid": 1,
                "lat": "0.0",
                "lon": "0.0",
                "hw": deviceInfo['hw'],
                "ime": deviceInfo['ime'],
                "plot_id": _generatePlotId(),
                "type_code": "RC173",
                "datetime": DateTime.parse(tx['created_at'].toString())
                        .millisecondsSinceEpoch ~/
                    1000
              };
            }).toList();

            final payload = {
              "plot_id_container": _generatePlotId(),
              "token": tokens,
              "typ": "RC175",
              "ver": "1.0.0",
            };
            // Loggear el body completo para validación
            print('DEBUG: [RC175] Payload a enviar:');
            print(jsonEncode(payload));

            // Endpoint de transacciones
            final response =
                await _dio.post('/pos-transactions/rc173', data: payload);

            if (response.statusCode == 200 || response.statusCode == 201) {
              final batch = db.batch();
              for (final tx in chunk) {
                batch.update('transactions', {'status': 'synced'},
                    where: 'local_id = ?', whereArgs: [tx['local_id']]);
              }
              await batch.commit(noResult: true);
              _ref
                  .read(systemStatusProvider.notifier)
                  .forceCheckPendingTransactions();
              print(
                  'DEBUG: Bloque de ${chunk.length} ventas offline sincronizadas masivamente (RC173).');
            } else {
              print(
                  'DEBUG: Fallo en bloque RC173, status ${response.statusCode}. Abortando siguientes bloques.');
              break;
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
            print(
                'DEBUG: Fallo al sincronizar bloque RC173: $errorMessage. Abortando siguientes bloques.');
            break;
          }
        }
      }

      // Agrupar Cierres por cashier_id
      Map<int, List<Map<String, dynamic>>> closuresByCashier = {};
      for (var tx in pendingClosures) {
        int cId = (tx['cashier_id'] as int?) ?? 1;
        closuresByCashier.putIfAbsent(cId, () => []).add(tx);
      }

      // Sincronizar Cierres de Caja (RC172)
      for (var entry in closuresByCashier.entries) {
        final currentCashierId = entry.key;
        final cashierClosures = entry.value;

        final userQuery = await db
            .query('users', where: 'id = ?', whereArgs: [currentCashierId]);
        final employeeFullName = userQuery.isNotEmpty
            ? (userQuery.first['name'] as String?) ?? "Cajero Desconocido"
            : "Cajero Desconocido";

        for (final tx in cashierClosures) {
          final txId = tx['id'];
          final txCashierId = tx['cashier_id'] ?? currentCashierId;

          // Buscar nombre del cajero
          final userQuery = await db.query('users',
              where: 'id = ?', whereArgs: [txCashierId], limit: 1);
          final txEmployeeName = userQuery.isNotEmpty
              ? (userQuery.first['name'] as String? ?? "Cajero")
              : "Cajero";

          final List<Map<String, dynamic>> tokenArr = [
            {
              "qr": tx['qr_data'],
              "cashierid": txCashierId,
              "expiredtime": 60,
              "fareid": 1,
              "productid": "CIERRE DE CAJA",
              "transaction_id": tx['id'],
              "pos_location_id": tx['pos_location_id'],
              "versionid": 1,
              "datetime": DateTime.parse(tx['created_at'].toString())
                      .millisecondsSinceEpoch ~/
                  1000
            }
          ];

          final payload = {
            "plot_id": _generatePlotId(),
            "type_code": "RC172",
            "dat": (DateTime.now().millisecondsSinceEpoch ~/ 1000).toString(),
            "token": jsonEncode(tokenArr),
            "lat": "0.0",
            "lon": "0.0",
            "hw": deviceInfo['hw'],
            "ime": deviceInfo['ime'],
            "employee_full_name": txEmployeeName,
            "typ": "RC172",
            "ver": "1.0.0",
            if (posLocationId != null)
              "pos_location_id": posLocationId.toString(),
          };

          try {
            final response =
                await _dio.post('/pos-transactions', data: payload);
            if (response.statusCode == 200 || response.statusCode == 201) {
              await db.update('transactions', {'status': 'synced'},
                  where: 'local_id = ?', whereArgs: [tx['local_id']]);
              _ref
                  .read(systemStatusProvider.notifier)
                  .forceCheckPendingTransactions();
              print(
                  'DEBUG: Cierre offline sincronizado individualmente (RC172).');
            }
          } catch (e) {
            print(
                'DEBUG: Fallo al sincronizar Cierre de Caja (RC172) $txId: $e');
          }
        }
      }

      // Sincronizar Aperturas de Caja (RC171)
      for (final tx in pendingOpenings) {
        final txId = tx['id'];
        final txCashierId = tx['cashier_id'] ?? 1;

        // Buscar nombre del cajero
        final userQuery = await db.query('users',
            where: 'id = ?', whereArgs: [txCashierId], limit: 1);
        final txEmployeeName = userQuery.isNotEmpty
            ? (userQuery.first['name'] as String? ?? "Cajero")
            : "Cajero";

        final payload = {
          "type_code": "RC171",
          "token": "",
          "dat": (DateTime.now().millisecondsSinceEpoch ~/ 1000).toString(),
          "lat": tx['lat']?.toString() ?? "0.0",
          "lon": tx['lon']?.toString() ?? "0.0",
          "hw": deviceInfo['hw'],
          "ime": deviceInfo['ime'],
          "employee_full_name": txEmployeeName,
          "typ": "RC171",
          "ver": "1.0.0",
          if (posLocationId != null)
            "pos_location_id": posLocationId.toString(),
        };

        try {
          final response =
              await _dio.post('/pos-transactions', data: payload);
          if (response.statusCode == 200 || response.statusCode == 201) {
            await db.update('transactions', {'status': 'synced'},
                where: 'local_id = ?', whereArgs: [tx['local_id']]);
            _ref
                .read(systemStatusProvider.notifier)
                .forceCheckPendingTransactions();
            print(
                'DEBUG: Apertura offline sincronizada individualmente (RC171).');
          }
        } catch (e) {
          print(
              'DEBUG: Fallo al sincronizar Apertura de Caja (RC171) $txId: $e');
        }
      }
    } catch (e) {
      print('DEBUG: Error general en syncPendingData: $e');
    }
  }

  Future<String?> _getMacAddress() async {
    try {
      final wlanFile = File('/sys/class/net/wlan0/address');
      if (await wlanFile.exists()) {
        final mac = await wlanFile.readAsString();
        if (mac.trim().isNotEmpty && mac.trim() != '02:00:00:00:00:00') {
          return mac.trim().toUpperCase();
        }
      }
      final ethFile = File('/sys/class/net/eth0/address');
      if (await ethFile.exists()) {
        final mac = await ethFile.readAsString();
        if (mac.trim().isNotEmpty && mac.trim() != '02:00:00:00:00:00') {
          return mac.trim().toUpperCase();
        }
      }
    } catch (_) {}
    return null;
  }

  Future<String> _getPersistentUuid() async {
    final prefs = await SharedPreferences.getInstance();
    String? uuid = prefs.getString('persistent_device_uuid');
    if (uuid == null) {
      final random = Random();
      const chars = '0123456789ABCDEF';
      uuid =
          'OFFMAC-${List.generate(12, (index) => chars[random.nextInt(chars.length)]).join()}';
      await prefs.setString('persistent_device_uuid', uuid);
    }
    return uuid;
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

        // 1. Intentar obtener MAC address real de Telpo
        final macAddress = await _getMacAddress();

        if (macAddress != null) {
          ime = macAddress;
        } else {
          // 2. Fallback al Serial Number, ignorando si es igual al build ID (típico en boards chinas) o valores basura
          final serial = build.serialNumber.trim().toUpperCase();
          if (serial.isNotEmpty &&
              serial != 'UNKNOWN' &&
              serial != build.id.toUpperCase() &&
              !serial.contains('1234567')) {
            ime = build.serialNumber;
          } else {
            // 3. Fallback final: UUID persistente generado por software (100% único por tablet)
            ime = await _getPersistentUuid();
          }
        }
      } else if (Platform.isIOS) {
        final data = await deviceInfoPlugin.iosInfo;
        hw = data.model;
        ime = data.identifierForVendor ?? await _getPersistentUuid();
      }
    } catch (_) {}

    _cachedDeviceInfo = {"hw": hw, "ime": ime};
    return _cachedDeviceInfo!;
  }

  String _generatePlotId() {
    final random = Random();
    const chars = '0123456789abcdef';
    return List.generate(32, (index) => chars[random.nextInt(chars.length)])
        .join();
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
