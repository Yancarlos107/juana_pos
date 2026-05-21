import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/network/dio_client.dart';
import '../models/user_model.dart';
import '../services/auth_service.dart';
import '../services/session_service.dart';

/// Proveedor del servicio de autenticación
final authServiceProvider = Provider<AuthService>((ref) {
  final dio = ref.read(dioProvider);
  final storage = ref.read(localStorageProvider);
  return AuthService(dio, storage);
});

/// Estados posibles de la autenticación
enum AuthStatus { initial, loading, authenticated, unauthenticated, error }

/// Estado completo de autenticación
class AuthState {
  final AuthStatus status;
  final UserModel? user;
  final String? errorMessage;

  const AuthState({
    this.status = AuthStatus.initial,
    this.user,
    this.errorMessage,
  });

  AuthState copyWith({
    AuthStatus? status,
    UserModel? user,
    String? errorMessage,
  }) {
    return AuthState(
      status: status ?? this.status,
      user: user ?? this.user,
      errorMessage: errorMessage,
    );
  }
}

/// Notifier que maneja el flujo completo de autenticación.
class AuthNotifier extends StateNotifier<AuthState> {
  final AuthService _authService;
  final SessionService _sessionService;

  AuthNotifier(this._authService, this._sessionService) : super(const AuthState());

  /// Flujo completo: Login (ya trae datos de usuario) → Estado Autenticado
  Future<void> login(String email, String password) async {
    state = state.copyWith(status: AuthStatus.loading, errorMessage: null);

    try {
      // El login ahora ya devuelve el UserModel completo
      final user = await _authService.login(email, password);

      // Validar y crear sesión de caja en SQLite
      await _sessionService.validateAndOpenSession(user.branchId);

      state = state.copyWith(
        status: AuthStatus.authenticated,
        user: user,
      );
    } catch (e) {
      state = state.copyWith(
        status: AuthStatus.error,
        errorMessage: e.toString().replaceFirst('Exception: ', ''),
      );
    }
  }

  /// Cerrar sesión
  Future<void> logout() async {
    await _authService.logout();
    state = const AuthState(status: AuthStatus.unauthenticated);
  }
}

/// Proveedor global del estado de autenticación
final authProvider = StateNotifierProvider<AuthNotifier, AuthState>((ref) {
  final authService = ref.read(authServiceProvider);
  final sessionService = ref.read(sessionServiceProvider);
  return AuthNotifier(authService, sessionService);
});
