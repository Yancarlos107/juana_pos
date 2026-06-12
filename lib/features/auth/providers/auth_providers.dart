import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/network/dio_client.dart';
import '../models/user_model.dart';
import '../services/auth_service.dart';
import '../services/session_service.dart';
import '../../../core/database/database_helper.dart';
import '../../../core/storage/local_storage_repository.dart';

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
  final LocalStorageRepository _storage;

  AuthNotifier(this._authService, this._sessionService, this._storage) : super(const AuthState());

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
  Future<void> logout(WidgetRef ref) async {
    ref.read(reviewerNameProvider.notifier).state = null;
    await _authService.logout();
    state = const AuthState(status: AuthStatus.unauthenticated);
  }

  /// Restaura el usuario desde SQLite si el estado se perdió (ej. reinicio en background)
  Future<void> restoreOfflineUser() async {
    if (state.user != null) return;
    try {
      final storage = _storage;
      final cashierId = await storage.getActiveCashierId();
      final cashierName = await storage.getActiveCashierName();

      if (cashierId != null && cashierName != null) {
        final db = await DatabaseHelper.instance.database;
        final results = await db.query('users', where: 'id = ?', whereArgs: [cashierId], limit: 1);
        
        if (results.isNotEmpty) {
          final userRow = results.first;
          final user = UserModel(
            id: cashierId,
            name: cashierName,
            email: userRow['email']?.toString() ?? '01',
            branchId: userRow['branch_id'] as int? ?? 0,
            branchName: 'Sucursal',
            initialBalance: 0.0,
            roles: (userRow['roles']?.toString() ?? '').split(','),
          );
          state = state.copyWith(status: AuthStatus.authenticated, user: user);
        } else {
          // Si por alguna razón el usuario no está en la base de datos pero sí en Storage, lo creamos con lo mínimo.
          final user = UserModel(
            id: cashierId,
            name: cashierName,
            email: '01',
            branchId: await storage.getBranchId() ?? 0,
            branchName: 'Sucursal',
            initialBalance: 0.0,
            roles: ['Cajero'],
          );
          state = state.copyWith(status: AuthStatus.authenticated, user: user);
        }
      } else {
        // Fallback: Si no hay cajero guardado, cerramos sesión para obligar a login
        state = state.copyWith(status: AuthStatus.unauthenticated, user: null);
      }
    } catch (e) {
      // Fallback silencioso
    }
  }
}

/// Proveedor global del estado de autenticación
final authProvider = StateNotifierProvider<AuthNotifier, AuthState>((ref) {
  final authService = ref.read(authServiceProvider);
  final sessionService = ref.read(sessionServiceProvider);
  final storage = ref.read(localStorageProvider);
  return AuthNotifier(authService, sessionService, storage);
});

/// Proveedor que guarda el nombre del fiscalizador que desbloqueó la pestaña Recaudo
final reviewerNameProvider = StateProvider<String?>((ref) => null);
