import 'package:dio/dio.dart';
import '../../../core/constants/api_constants.dart';
import '../../../core/storage/local_storage_repository.dart';
import '../../../core/database/database_helper.dart';
import 'package:sqflite/sqflite.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import '../models/user_model.dart';

/// Servicio de autenticación que maneja Login y contexto de usuario.
/// Consume POST /sanctum/token y GET /user.
class AuthService {
  final Dio _dio;
  final LocalStorageRepository _storage;

  AuthService(this._dio, this._storage);

  /// Realiza login con email y contraseña.
  /// Devuelve el UserModel si es exitoso (incluye token, sucursal, etc).
  Future<UserModel> login(String phoneOrEmail, String password) async {
    // Intentamos loguearnos directamente con el backend.
    // Si realmente no hay internet, Dio arrojará un connectionError y haremos el fallback.

    try {
      final response = await _dio.post(
        ApiConstants.login,
        data: {
          'phone_number': phoneOrEmail,
          'password': password,
          'device_name': 'pos_flutter',
        },
      );

      final data = response.data as Map<String, dynamic>?;
      if (data == null) throw Exception('Formato de respuesta inválido');
      
      final token = data['token']?.toString();
      if (token == null) throw Exception('No se encontró el token en la respuesta');
      
      // Guardamos el token para peticiones futuras
      await _storage.saveToken(token);

      // Creamos el modelo de usuario directamente desde esta respuesta
      final user = UserModel.fromJson(data);
      
      // Persistimos datos de contexto
      await _storage.saveBranchId(user.branchId);
      await _storage.saveRoles(user.roles);
      await _storage.saveBalance(user.initialBalance);

      // Guardamos en SQLite para permitir el login offline futuro
      final db = await DatabaseHelper.instance.database;
      await db.insert(
        'users',
        {
          'id': user.id,
          'email': phoneOrEmail,
          'password_hash': password, // Almacenado de forma simple para offline match
          'name': user.name,
          'branch_id': user.branchId,
          'roles': user.roles.join(','),
        },
        conflictAlgorithm: ConflictAlgorithm.replace,
      );

      return user;
    } on DioException catch (e) {
      // Detección de fallo de red para fallback offline
      if (e.type == DioExceptionType.connectionTimeout || 
          e.type == DioExceptionType.receiveTimeout || 
          e.type == DioExceptionType.connectionError ||
          e.type == DioExceptionType.unknown) {
        return _offlineLogin(phoneOrEmail, password);
      }

      final serverMessage = e.response?.data?['message'];
      if (e.response?.statusCode == 422) {
        throw Exception(serverMessage ?? 'Credenciales inválidas o falta device_name.');
      }
      final detail = serverMessage ?? e.message ?? e.type.toString();
      throw Exception('Error ($detail)');
    }
  }

  Future<UserModel> _offlineLogin(String email, String password) async {
    final db = await DatabaseHelper.instance.database;
    final results = await db.query(
      'users',
      where: 'email = ? AND password_hash = ?',
      whereArgs: [email, password],
    );
    
    if (results.isEmpty) {
      throw Exception('Modo Offline: Credenciales incorrectas o usuario no sincronizado. Inicia sesión con internet una vez.');
    }
    
    final userRow = results.first;

    final user = UserModel(
      id: userRow['id'] as int? ?? 0,
      name: userRow['name']?.toString() ?? 'Operador (Offline)',
      email: userRow['email']?.toString() ?? email,
      branchId: userRow['branch_id'] as int? ?? 0,
      branchName: 'Sucursal Offline',
      initialBalance: await _storage.getBalance() ?? 0.0,
      roles: (userRow['roles']?.toString() ?? '').split(','),
    );

    await _storage.saveBranchId(user.branchId);
    await _storage.saveRoles(user.roles);
    await _storage.saveBalance(user.initialBalance);

    return user;
  }

  /// Obtiene el usuario actual autenticado y guarda su contexto.
  Future<UserModel> fetchUser() async {
    try {
      final response = await _dio.get(ApiConstants.user);
      
      // Manejamos si la respuesta viene envuelta en 'data' o es directa
      final dataMap = response.data['data'] as Map<String, dynamic>? ?? response.data as Map<String, dynamic>;
      final user = UserModel.fromJson(dataMap);

      // Persistimos branch_id, roles y balance en almacenamiento local
      await _storage.saveBranchId(user.branchId);
      await _storage.saveRoles(user.roles);
      await _storage.saveBalance(user.initialBalance);

      return user;
    } on DioException catch (e) {
      if (e.response?.statusCode == 401) {
        throw Exception('Sesión expirada (Unauthorized). Token inválido o expirado.');
      }
      final detail = e.response?.data?['message'] ?? e.message ?? e.type.toString();
      throw Exception('Error al obtener usuario ($detail)');
    }
  }

  /// Cierra sesión eliminando todos los datos locales.
  Future<void> logout() async {
    await _storage.clearAll();
  }
}
