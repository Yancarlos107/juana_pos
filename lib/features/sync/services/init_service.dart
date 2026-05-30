import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/constants/api_constants.dart';
import '../../../core/storage/local_storage_repository.dart';
import '../../auth/models/pos_location_model.dart';
import '../../sales/models/novelty_model.dart';

import '../../../core/network/dio_client.dart';
import '../../auth/providers/auth_providers.dart';

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
    try {
      final token = await _storage.getToken();
      if (token == null) throw Exception('No hay token disponible para la inicialización.');

      final response = await _dio.get(
        '/cashier-initialize',
        queryParameters: {'city': 'valledupar'},
        options: Options(
          headers: {
            'Authorization': 'Bearer $token',
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

      // 2. Extraer y guardar puntos de venta
      List<PosLocationModel> locations = [];
      if (data.containsKey('pos_locations')) {
        final locationsList = data['pos_locations'] as List<dynamic>;
        await _storage.savePosLocationsList(locationsList);
        locations = locationsList.map((l) => PosLocationModel.fromJson(l)).toList();
      }

      return {
        'locations': locations,
        'novelties': data['novelty_types'] ?? [],
      };
    } on DioException catch (e) {
      if (e.type == DioExceptionType.connectionTimeout || 
          e.type == DioExceptionType.receiveTimeout || 
          e.type == DioExceptionType.connectionError ||
          e.type == DioExceptionType.unknown) {
        
        // Intento offline
        final cachedLocations = await _storage.getPosLocationsList();
        if (cachedLocations != null && cachedLocations.isNotEmpty) {
          final locations = cachedLocations.map((l) => PosLocationModel.fromJson(l)).toList();
          return {
            'locations': locations,
            'novelties': [], // No importa, luego las busca con getCachedNovelties
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
        final locations = cachedLocations.map((l) => PosLocationModel.fromJson(l)).toList();
        return {
          'locations': locations,
          'novelties': [],
        };
      }
      throw Exception('Modo offline: No hay puntos de venta guardados en el dispositivo. Conéctate a internet e inicia sesión al menos una vez para sincronizarlos.');
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
          e.type == DioExceptionType.unknown) {
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
