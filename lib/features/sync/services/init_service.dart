import 'package:flutter/material.dart';
import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../main.dart';
import '../../../core/constants/api_constants.dart';
import '../../../core/storage/local_storage_repository.dart';
import '../../auth/models/pos_location_model.dart';
import '../../sales/models/novelty_model.dart';

import '../../../core/network/dio_client.dart';
import '../../auth/providers/auth_providers.dart';
import '../../../core/database/database_helper.dart';
import 'package:sqflite/sqflite.dart';
import '../../../core/utils/device_utils.dart';
import 'ota_update_service.dart';

final initServiceProvider = Provider<InitService>((ref) {
  final dio = ref.watch(dioProvider);
  final storage = ref.watch(localStorageProvider);
  return InitService(dio, storage);
});

class InitService {
  final Dio _dio;
  final LocalStorageRepository _storage;

  InitService(this._dio, this._storage);

  Future<Map<String, dynamic>> initializePOS() async {
    String? tokenValidator;
    try {
      tokenValidator = await _storage.getTokenValidator();
      final userToken = await _storage.getToken();
      final activeToken = tokenValidator ?? userToken;

      if (activeToken == null)
        throw Exception('No hay token disponible para la inicialización.');

      final macAddress = await DeviceUtils.getMacAddress();

      final response = await _dio.get(
        '/cashier-initialize',
        queryParameters: {
          'city': 'valledupar',
          'ime': macAddress,
        },
        options: Options(
          headers: {
            'Authorization': 'Bearer $activeToken',
            'Accept': 'application/json',
          },
        ),
      );

      final data = response.data as Map<String, dynamic>;

      // 1. Guardar novedades en caché local para uso offline
      if (data.containsKey('novelty_types')) {
        final noveltiesList = data['novelty_types'] as List<dynamic>;
        await _storage.saveNovelties(noveltiesList);
      }

      // 1.5. Guardar el catálogo de cajeros autorizados
      if (data.containsKey('cashiers')) {
        final cashiersList = data['cashiers'] as List<dynamic>;
        final db = await DatabaseHelper.instance.database;
        final batch = db.batch();
        batch.delete(
            'users'); // Limpiamos la tabla para que no queden IDs fantasma del bug anterior
        for (var cData in cashiersList) {
          final u = cData['user'];
          final c = cData['cashier'];
          if (u != null && c != null) {
            batch.insert(
                'users',
                {
                  'id': c['id'],
                  'email':
                      u['phone_number'], // Usamos phone_number como login id
                  'password_hash':
                      u['device_login_password'], // Contraseña hasheada (sha1)
                  'name': c['name'] ?? u['name'],
                  'branch_id': c['branch_id'],
                  'roles': 'Cajero', // Rol por defecto offline
                  'is_reviewer':
                      (c['is_reviewer'] == true || c['is_reviewer'] == 1)
                          ? 1
                          : 0,
                  'reviewer_code': c['reviewer_code']?.toString(),
                },
                conflictAlgorithm: ConflictAlgorithm.replace);
          }
        }
        await batch.commit(noResult: true);
      }

      // 2. Extraer y guardar puntos de venta
      List<PosLocationModel> locations = [];
      if (data.containsKey('pos_locations')) {
        final locationsList = data['pos_locations'] as List<dynamic>;
        await _storage.savePosLocationsList(locationsList);
        locations =
            locationsList.map((l) => PosLocationModel.fromJson(l)).toList();
      }

      // 3. Asignación automática de punto de venta (pos_assign_pos_location)
      bool autoAssignedLocation = false;
      if (data.containsKey('pos_assign_pos_location') &&
          data['pos_assign_pos_location'] != null) {
        final assignedLoc = data['pos_assign_pos_location'];
        if (assignedLoc is Map) {
          final locId = assignedLoc['id'];
          final locName = assignedLoc['name'];
          if (locId != null && locName != null) {
            await _storage.savePosLocationId(locId as int);
            await _storage.savePosLocationName(locName.toString());
            await updatePosSchedule(locId as int);
            autoAssignedLocation = true;
          }
        }
      }

      // 4. Procesar bloque config (OTA y Token Validator)
      if (data.containsKey('config') && data['config'] != null) {
        final configData = data['config'];
        print('DEBUG OTA: Config completo recibido -> $configData');
        if (configData is Map) {
          if (configData.containsKey('token_validator') && configData['token_validator'] != null) {
            await _storage.saveTokenValidator(configData['token_validator'].toString());
          }
          
          if (configData.containsKey('host_url') && configData['host_url'] != null) {
            final newHostUrl = configData['host_url'].toString();
            final oldHostUrl = await _storage.getHostUrl();
            if (newHostUrl != oldHostUrl) {
              await _storage.saveHostUrl(newHostUrl);
              _dio.options.baseUrl = newHostUrl;
            }
          }
          
          if (configData.containsKey('env') && configData['env'] != null) {
            final newEnv = configData['env'].toString();
            final oldEnv = await _storage.getEnv();
            if (newEnv != oldEnv) {
              await _storage.saveEnv(newEnv);
            }
          }
          
          if (configData.containsKey('version') && configData['version'] != null && configData.containsKey('url_apk') && configData['url_apk'] != null) {
            final newVersion = configData['version'].toString();
            final urlApk = configData['url_apk'].toString();
            final oldVersion = await _storage.getApkVersion() ?? ApiConstants.appVersion;
            
            print('DEBUG OTA: Backend reporta versión [$newVersion] con URL [$urlApk]');
            print('DEBUG OTA: Versión actual instalada es [$oldVersion]');
            
            if (newVersion != oldVersion) {
              print('DEBUG OTA: ¡Hay actualización! Disparando OtaUpdateService...');
              OtaUpdateService.triggerUpdateModal(newVersion, urlApk);
            } else {
              print('DEBUG OTA: Ya estamos en la última versión, se ignora.');
            }
          }
        }
      }

      return {
        'locations': locations,
        'novelties': data['novelty_types'] ?? [],
        'auto_assigned_location': autoAssignedLocation,
      };
    } on DioException catch (e) {
      if (e.type == DioExceptionType.connectionTimeout ||
          e.type == DioExceptionType.receiveTimeout ||
          e.type == DioExceptionType.connectionError ||
          e.type == DioExceptionType.unknown ||
          (e.type == DioExceptionType.badResponse &&
              e.response?.statusCode == 302)) {
        // Intento offline
        final cachedLocations = await _storage.getPosLocationsList();
        if (cachedLocations != null && cachedLocations.isNotEmpty) {
          final locations =
              cachedLocations.map((l) => PosLocationModel.fromJson(l)).toList();
          return {
            'locations': locations,
            'novelties':
                [], // No importa, luego las busca con getCachedNovelties
            'auto_assigned_location': false,
          };
        }
        throw Exception('offline_no_cache');
      }

      final serverMessage = e.response?.data?['message'];
      final detail = serverMessage ?? e.message ?? e.type.toString();
      throw Exception('Error al inicializar POS ($detail)');
    } catch (e) {
      // Si no hay token u otro error genérico, intentar offline
      final cachedLocations = await _storage.getPosLocationsList();
      if (cachedLocations != null && cachedLocations.isNotEmpty) {
        final locations =
            cachedLocations.map((l) => PosLocationModel.fromJson(l)).toList();
        return {
          'locations': locations,
          'novelties': [],
        };
      }
      throw Exception(
          'Modo offline: No hay puntos de venta guardados en el dispositivo. Conéctate a internet e inicia sesión al menos una vez para sincronizarlos.');
    }
  }

  Future<List<NoveltyModel>> getCachedNovelties() async {
    final cached = await _storage.getNovelties();
    if (cached != null) {
      return cached.map((n) => NoveltyModel.fromJson(n)).toList();
    }
    return [];
  }

  Future<void> updatePosSchedule(int posLocationId) async {
    try {
      final token = await _storage.getToken();
      if (token == null) {
        // Modo offline o sesión parcial: no enviar actualización de schedule al servidor
        return;
      }

      await _dio.put(
        '/pos-schedules/my-today',
        data: {'pos_location_id': posLocationId},
        options: Options(
          headers: {
            'Authorization': 'Bearer $token',
            'Accept': 'application/json',
            'Content-Type': 'application/json',
          },
        ),
      );
    } on DioException catch (e) {
      if (e.type == DioExceptionType.connectionTimeout ||
          e.type == DioExceptionType.receiveTimeout ||
          e.type == DioExceptionType.connectionError ||
          e.type == DioExceptionType.unknown ||
          (e.type == DioExceptionType.badResponse &&
              e.response?.statusCode == 302)) {
        // Offline: Permitimos avanzar usando el punto de venta guardado localmente
        return;
      }
      final serverMessage = e.response?.data?['message'];
      final detail = serverMessage ?? e.message ?? e.type.toString();
      throw Exception('Error al actualizar sucursal ($detail)');
    }
  }

  Future<void> sendNovelty(int noveltyTypeId, String name) async {
    try {
      final token = await _storage.getToken();
      if (token == null) throw Exception('No hay token disponible.');

      await _dio.post(
        '/novelties',
        data: {
          'novelty_type_id': noveltyTypeId,
          'name': name,
          'description': 'Reportado desde POS',
        },
        options: Options(
          headers: {
            'Authorization': 'Bearer $token',
            'Accept': 'application/json',
            'Content-Type': 'application/json',
          },
        ),
      );
    } on DioException catch (e) {
      final serverMessage = e.response?.data?['message'];
      final detail = serverMessage ?? e.message ?? e.type.toString();
      throw Exception('Error al enviar novedad ($detail)');
    }
  }
}
