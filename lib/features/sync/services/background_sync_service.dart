import 'dart:io';
import 'dart:convert';
import 'dart:math';
import 'package:flutter/material.dart';
import '../../monitoring/services/system_status_service.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sqflite/sqflite.dart';
import '../../../main.dart';
import '../../../core/database/database_helper.dart';
import '../../../core/network/dio_client.dart';
import '../../../core/storage/local_storage_repository.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../../core/utils/device_utils.dart';
import '../../../core/services/kiosk_service.dart';
import '../../../core/constants/api_constants.dart';
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
    final pending = await db.query(
      'transactions',
      where: "status = 'pending' OR (status = 'synced' AND (server_id IS NULL OR server_id = ''))"
    );

    if (pending.isEmpty) return;

    // Obtener información del dispositivo
    final deviceInfo = await _getDeviceInfo();

    try {
      final pendingSales = pending
          .where((tx) =>
              tx['product_id'] != 'CIERRE DE CAJA' &&
              tx['product_id'] != 'APERTURA DE CAJA' &&
              tx['product_id'] != 'INGRESO_FISCALIZADOR' &&
              tx['product_id'] != 'PMR')
          .toList();
      final pendingClosures =
          pending.where((tx) => tx['product_id'] == 'CIERRE DE CAJA').toList();
      final pendingOpenings = pending
          .where((tx) => tx['product_id'] == 'APERTURA DE CAJA')
          .toList();
      final pendingSupervisorLogins = pending
          .where((tx) => tx['product_id'] == 'INGRESO_FISCALIZADOR')
          .toList();

      // Obtener el ID de la ubicación POS y el hash del dispositivo
      final posLocationId = await _storage.getPosLocationId();
      final deviceHash = await _storage.getDeviceHash();
      final isKiosk = await KioskService.isInKioskMode();

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
              final serialNumber = tx['serial_number']?.toString() ?? 'N/A';
              return {
                "qr": tx['qr_data'],
                "cashierid": tx[
                    'cashier_id'], // <- Se toma el ID REAL del cajero que hizo la venta
                "expiredtime": 60,
                "fareid": 1,
                "productid": tx['product_id'],
                "transaction_id": tx['id'],
                "serial_number": serialNumber,
                "pos_location_id": tx['pos_location_id'] ?? posLocationId,
                "versionid": 1,
                "lat": "0.0",
                "lon": "0.0",
                "hw": deviceInfo['hw'],
                "ime": deviceInfo['ime'],
                "mac_address": tx['mac_address'],
                "plot_id": tx['plot_id'] ?? _generatePlotId(),
                "type_code": "RC173",
                "app_version": ApiConstants.appVersion,
                "kiosk_mode": isKiosk,
                "datetime": DateTime.parse(tx['created_at'].toString())
                        .millisecondsSinceEpoch ~/
                    1000
              };
            }).toList();

            final payload = {
              "plot_id": _generatePlotId(),
              "type_code": "RC173",
              "dat": (DateTime.now().millisecondsSinceEpoch ~/ 1000).toString(),
              "token": tokens,
              "lat": "0.0",
              "lon": "0.0",
              "hw": "-1",
              "ime": "-1",
              "employee_full_name": "-1",
              "typ": "RC173",
              "ver": ApiConstants.appVersion,
              "pos_location_id": "-1",
            };
            // Loggear el body completo para validación
            print('DEBUG: [RC173] Payload a enviar:');
            print(jsonEncode(payload));

            // Endpoint de transacciones
            final response = await _dio.post(
              '/pos-transactions/rc173',
              data: payload,
              options: Options(
                validateStatus: (status) => status != null && status < 500,
              ),
            );

            if (response.statusCode == 200 ||
                response.statusCode == 201 ||
                response.statusCode == 409) {
              
              final responseData = response.data;
              List<dynamic> qrCodes = [];
              int? posTransactionId;
              
              if (responseData is Map && responseData['success'] == true) {
                final dataObj = responseData['data'];
                if (dataObj is Map) {
                  qrCodes = dataObj['qr_codes'] ?? [];
                  posTransactionId = dataObj['pos_transaction_id'];
                }
              }

              final batch = db.batch();
              int updatedCount = 0;
              for (final tx in chunk) {
                // Solo marcamos como synced si el servidor explícitamente nos devolvió su QR
                // o si es un 409 sin lista (fallback de que ya existía)
                if (qrCodes.contains(tx['qr_data']) || (response.statusCode == 409 && qrCodes.isEmpty)) {
                  // Solo lo marcamos como synced si TENEMOS el server_id
                  if (posTransactionId != null) {
                    batch.update('transactions', {
                        'status': 'synced',
                        'server_id': posTransactionId,
                      },
                      where: 'local_id = ?', whereArgs: [tx['local_id']]);
                    updatedCount++;
                  } else {
                    // Si no hay server_id, lo dejamos como pending (o no lo actualizamos para que se reenvíe)
                    print('DEBUG: Se omitió marcar como synced la tx local_id ${tx['local_id']} porque server_id es nulo.');
                  }
                }
              }
              await batch.commit(noResult: true);
              
              _ref
                  .read(systemStatusProvider.notifier)
                  .forceCheckPendingTransactions();
              print(
                  'DEBUG: Bloque RC173 enviado. Servidor confirmó $updatedCount de ${chunk.length} ventas.');
            } else {
              String errorMsg = 'Código ${response.statusCode}';
              if (response.data is Map && response.data.containsKey('errors')) {
                errorMsg = response.data['errors'].toString();
              } else if (response.data is Map &&
                  response.data.containsKey('message')) {
                errorMsg = response.data['message'].toString();
              } else if (response.data != null) {
                errorMsg = response.data.toString();
              }

              print(
                  'DEBUG: Fallo en bloque RC173, status ${response.statusCode}. Msg: $errorMsg');
              break;
            }
          } catch (e) {
            String errorMessage = e.toString().split('\n').first;
            if (e is DioException && e.response != null) {
              final bodyData = e.response?.data;
              if (bodyData is Map) {
                if (bodyData.containsKey('errors')) {
                  errorMessage = bodyData['errors'].toString();
                } else if (bodyData.containsKey('message')) {
                  errorMessage = bodyData['message'].toString();
                } else {
                  errorMessage = bodyData.toString();
                }
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

          // Extraer datos del QR
          Map<String, dynamic>? extraData;
          try {
            if (tx['qr_data'] != null) {
              final decodedStr = utf8.decode(base64Decode(tx['qr_data']));
              extraData = jsonDecode(decodedStr);
            }
          } catch (e) {
            print("DEBUG: Error decoding qr_data for RC172: $e");
          }

          final Map<String, dynamic> tokenObj = {
            "qr": tx['qr_data'],
            "cashierid": txCashierId,
            "expiredtime": 60,
            "fareid": 1,
            "productid": "CIERRE DE CAJA",
            "transaction_id": tx['id'],
            "pos_location_id": tx['pos_location_id'],
            "versionid": 1,
            "mac_address": tx['mac_address'],
            "datetime": DateTime.parse(tx['created_at'].toString())
                    .millisecondsSinceEpoch ~/
                1000
          };

          if (extraData != null) {
            if (extraData.containsKey('cash_list')) {
              tokenObj['cash_list'] = extraData['cash_list'];
            }
            if (extraData.containsKey('coins_total')) {
              tokenObj['coins_total'] = extraData['coins_total'];
            }
            if (extraData.containsKey('bills_total')) {
              tokenObj['bills_total'] = extraData['bills_total'];
            }
            if (extraData.containsKey('cash')) {
              tokenObj['cash'] = extraData['cash'];
            }
            if (extraData.containsKey('balance')) {
              tokenObj['balance'] = extraData['balance'];
            }
          }

          final List<Map<String, dynamic>> tokenArr = [tokenObj];

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


            final response = await _dio.post(
              '/pos-transactions',
              data: payload,
              options: Options(
                validateStatus: (status) => status != null && status < 500,
              ),
            );
            if (response.statusCode == 200 ||
                response.statusCode == 201 ||
                response.statusCode == 409) {
                
              int? posTransactionId;
              final responseData = response.data;
              if (responseData is Map && responseData['success'] == true) {
                final dataObj = responseData['data'];
                if (dataObj is Map) {
                  posTransactionId = dataObj['pos_transaction_id'];
                }
              }

              final updateData = <String, dynamic>{'status': 'synced'};
              if (posTransactionId != null) {
                updateData['server_id'] = posTransactionId;
              }

              await db.update('transactions', updateData,
                  where: 'local_id = ?', whereArgs: [tx['local_id']]);
              _ref
                  .read(systemStatusProvider.notifier)
                  .forceCheckPendingTransactions();
              print(
                  'DEBUG: Cierre offline sincronizado individualmente (RC172).');
            } else {
              print(
                  'DEBUG: Fallo al sincronizar Cierre de Caja (RC172) $txId: ${response.statusCode}');
            }
          } catch (e) {
            print(
                'DEBUG: Fallo al sincronizar Cierre de Caja (RC172) $txId: $e');
          }
        }
      }

      // Sincronizar Aperturas de Caja (RC174)
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
          "type_code": "RC174",
          "token": "",
          "dat": (DateTime.now().millisecondsSinceEpoch ~/ 1000).toString(),
          "lat": tx['lat']?.toString() ?? "0.0",
          "lon": tx['lon']?.toString() ?? "0.0",
          "hw": deviceInfo['hw'],
          "ime": deviceInfo['ime'],
          "employee_full_name": txEmployeeName,
          "cashier_id": txCashierId.toString(),
          "typ": "RC174",
          "ver": "1.0.0",
          if (posLocationId != null)
            "pos_location_id": posLocationId.toString(),
        };

        try {
          final response = await _dio.post(
            '/pos-transactions',
            data: payload,
            options: Options(
              validateStatus: (status) =>
                  status != null &&
                  status < 500, // No arrojar excepción para 4xx (como 409)
            ),
          );
          if (response.statusCode == 200 ||
              response.statusCode == 201 ||
              response.statusCode == 409) {

            int? posTransactionId;
            final responseData = response.data;
            if (responseData is Map && responseData['success'] == true) {
              final dataObj = responseData['data'];
              if (dataObj is Map) {
                posTransactionId = dataObj['pos_transaction_id'];
              }
            }

            final updateData = <String, dynamic>{'status': 'synced'};
            if (posTransactionId != null) {
              updateData['server_id'] = posTransactionId;
            }

            await db.update('transactions', updateData,
                where: 'id = ?', whereArgs: [txId]);
            print(
                'DEBUG: Apertura de Caja (RC174) sincronizada con éxito (o ya existía 409): $txId');
            _ref
                .read(systemStatusProvider.notifier)
                .forceCheckPendingTransactions();
          } else {
            print(
                'DEBUG: Error al sincronizar Apertura de Caja (RC174) $txId: ${response.statusCode}');
          }
        } catch (e) {
          print(
              'DEBUG: Fallo al sincronizar Apertura de Caja (RC174) $txId: $e');
        }
      }

      // Sincronizar Ingreso de Fiscalizador (RC171)
      for (final tx in pendingSupervisorLogins) {
        final txId = tx['id'];
        final txCashierId = tx['cashier_id'] ?? 1; // ID del taquillero
        final txReviewerId = tx['reviewer_id'] ?? txCashierId; // ID del fiscalizador

        // Buscar nombre del fiscalizador
        final userQuery = await db.query('users',
            where: 'id = ?', whereArgs: [txReviewerId], limit: 1);
        final txEmployeeName = userQuery.isNotEmpty
            ? (userQuery.first['name'] as String? ?? "Fiscalizador")
            : "Fiscalizador";

        final payload = {
          "type_code": "RC171",
          "token": "",
          "dat": (DateTime.parse(tx['created_at'].toString()).millisecondsSinceEpoch ~/ 1000).toString(),
          "lat": tx['lat']?.toString() ?? "0.0",
          "lon": tx['lon']?.toString() ?? "0.0",
          "hw": deviceInfo['hw'],
          "ime": tx['mac_address']?.toString() ?? deviceInfo['ime'],
          "employee_full_name": txEmployeeName, // Nombre del Fiscalizador
          "cashier_id": txCashierId.toString(), // Taquillero activo
          "reviewer_id": txReviewerId.toString(), // Fiscalizador que audita
          "typ": "RC171",
          "ver": "1.0.0",
          if (posLocationId != null)
            "pos_location_id": posLocationId.toString(),
        };

        try {
          final response = await _dio.post(
            '/pos-transactions',
            data: payload,
            options: Options(
              validateStatus: (status) =>
                  status != null &&
                  status < 500,
            ),
          );
          if (response.statusCode == 200 ||
              response.statusCode == 201 ||
              response.statusCode == 409) {

            int? posTransactionId;
            final responseData = response.data;
            if (responseData is Map && responseData['success'] == true) {
              final dataObj = responseData['data'];
              if (dataObj is Map) {
                posTransactionId = dataObj['pos_transaction_id'];
              }
            }

            final updateData = <String, dynamic>{'status': 'synced'};
            if (posTransactionId != null) {
              updateData['server_id'] = posTransactionId;
            }

            await db.update('transactions', updateData,
                where: 'id = ?', whereArgs: [txId]);
            print(
                'DEBUG: Ingreso Fiscalizador (RC171) sincronizado con éxito: $txId');
            _ref
                .read(systemStatusProvider.notifier)
                .forceCheckPendingTransactions();
          } else {
            print(
                'DEBUG: Error al sincronizar Ingreso Fiscalizador (RC171) $txId: ${response.statusCode}');
          }
        } catch (e) {
          print(
              'DEBUG: Fallo al sincronizar Ingreso Fiscalizador (RC171) $txId: $e');
        }
      }

    } catch (e) {
      print('DEBUG: Error general en syncPendingData: $e');
    }
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

        // 1. Intentar obtener MAC address real de Telpo o fallback a serial
        final macAddress = await DeviceUtils.getMacAddress();

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
