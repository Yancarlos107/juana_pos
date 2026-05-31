import 'dart:io';
import 'package:dio/dio.dart';
import 'package:dio/io.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../constants/api_constants.dart';
import '../storage/local_storage_repository.dart';

// Proveedor global para inyectar el LocalStorageRepository en donde se necesite
final localStorageProvider = Provider<LocalStorageRepository>((ref) {
  return LocalStorageRepository();
});

// Proveedor global del cliente HTTP (Dio)
final dioProvider = Provider<Dio>((ref) {
  final storage = ref.read(localStorageProvider);
  
  final dio = Dio(BaseOptions(
    baseUrl: ApiConstants.baseUrl,
    connectTimeout: const Duration(seconds: 15),
    receiveTimeout: const Duration(seconds: 15),
    headers: {
      'Accept': 'application/json',
      'Content-Type': 'application/json',
    },
  ));

  // Bypass SSL for certificates that might not be trusted on port 8085
  dio.httpClientAdapter = IOHttpClientAdapter(
    createHttpClient: () {
      final client = HttpClient();
      client.badCertificateCallback = (X509Certificate cert, String host, int port) => true;
      return client;
    },
  );

  // Agregamos el interceptor para inyectar el token en cada petición
  dio.interceptors.add(AuthInterceptor(storage));
  
  return dio;
});

class AuthInterceptor extends Interceptor {
  final LocalStorageRepository _storage;

  AuthInterceptor(this._storage);

  @override
  void onRequest(RequestOptions options, RequestInterceptorHandler handler) async {
    final token = await _storage.getToken();
    if (token != null && token.isNotEmpty) {
      options.headers['Authorization'] = 'Bearer $token';
    }
    super.onRequest(options, handler);
  }

  @override
  void onError(DioException err, ErrorInterceptorHandler handler) {
    if (err.response?.statusCode == 401) {
      // TODO: Propagar evento para forzar Logout
    }
    super.onError(err, handler);
  }
}
