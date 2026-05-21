import 'package:dio/dio.dart';
import '../../../core/constants/api_constants.dart';
import '../../../core/storage/local_storage_repository.dart';
import '../../../core/database/database_helper.dart';
import '../models/user_model.dart';

/// Servicio de autenticación que maneja Login y contexto de usuario.
/// Consume POST /sanctum/token y GET /user.
class AuthService {
  final Dio _dio;
  final LocalStorageRepository _storage;

  AuthService(this._dio, this._storage);

  /// Realiza login con email y contraseña.
  /// Devuelve el UserModel si es exitoso (incluye token, sucursal, etc).
  Future<UserModel> login(String email, String password) async {
    try {
      final response = await _dio.post(
        ApiConstants.login,
        data: {
          'email': email,
          'password': password,
          'device_name': 'pos_flutter',
        },
      );

      final data = response.data['data'] as Map<String, dynamic>?;
      if (data == null) throw Exception('Formato de respuesta inválido (falta data)');
      
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

      return user;
    } on DioException catch (e) {
      // Detección de fallo de red para fallback offline
      if (e.type == DioExceptionType.connectionTimeout || 
          e.type == DioExceptionType.receiveTimeout || 
          e.type == DioExceptionType.connectionError ||
          e.type == DioExceptionType.unknown) {
        return _offlineLogin(email, password);
      }

      final serverMessage = e.response?.data?['message'];
      if (e.response?.statusCode == 422) {
        throw Exception(serverMessage ?? 'Credenciales inválidas o falta device_name.');
      }
      final detail = serverMessage ?? e.message ?? e.type.toString();
      throw Exception('Error ($detail)');
    }
  }

  /// Login utilizando SQLite como fuente de verdad cuando no hay red.
  Future<UserModel> _offlineLogin(String email, String password) async {
    final db = await DatabaseHelper.instance.database;
    final results = await db.query('users', where: 'email = ?', whereArgs: [email]);
    
    if (results.isEmpty) {
      throw Exception('Modo Offline: Usuario no sincronizado en el dispositivo.');
    }
    
    final userRow = results.first;
    // TODO: Implementar validación de hash real
    // if (userRow['password_hash'] != hash(password)) throw Exception('Credenciales offline inválidas');

    return UserModel(
      id: userRow['id'] as int? ?? 0,
      name: userRow['name']?.toString() ?? 'Operador (Offline)',
      email: userRow['email']?.toString() ?? email,
      branchId: userRow['branch_id'] as int? ?? 0,
      branchName: 'Sucursal Offline',
      initialBalance: await _storage.getBalance() ?? 0.0,
      roles: (userRow['roles']?.toString() ?? '').split(','),
    );
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
