import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'features/auth/screens/login_screen.dart';
import 'features/sales/screens/dashboard_screen.dart';
import 'features/sales/screens/recaudo_screen.dart';
import 'features/printer/screens/epson_test_screen.dart';
import 'core/storage/local_storage_repository.dart';
import 'core/services/kiosk_service.dart';
import 'core/theme/app_theme.dart';
import 'features/auth/providers/auth_providers.dart';
import 'features/auth/services/session_service.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
  runApp(const ProviderScope(child: MyApp()));
  // Kiosco real (Lock Task Mode): se activa tras el primer frame, cuando el
  // canal nativo ya está registrado. Si la tablet no está aprovisionada como
  // Device Owner, no hace nada (queda solo el modo inmersivo visual).
  WidgetsBinding.instance.addPostFrameCallback((_) {
    KioskService.start();
  });
}

final GlobalKey<ScaffoldMessengerState> scaffoldMessengerKey = GlobalKey<ScaffoldMessengerState>();
final GlobalKey<NavigatorState> navigatorKey = GlobalKey<NavigatorState>();

class MyApp extends ConsumerWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return MaterialApp(
      navigatorKey: navigatorKey,
      scaffoldMessengerKey: scaffoldMessengerKey,
      title: 'Juana POS',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.lightTheme,
      home: const AuthGate(),
      routes: {
        '/login': (context) => const LoginScreen(),
        '/dashboard': (context) => const DashboardScreen(),
        '/recaudo': (context) => const RecaudoScreen(),
        '/epson-test': (context) => const EpsonTestScreen(),
      },
    );
  }
}

class AuthGate extends ConsumerStatefulWidget {
  const AuthGate({super.key});

  @override
  ConsumerState<AuthGate> createState() => _AuthGateState();
}

class _AuthGateState extends ConsumerState<AuthGate> {
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _checkAuth();
  }

  Future<void> _checkAuth() async {
    try {
      final storage = LocalStorageRepository();
      final token = await storage.getToken();

      if (token != null && token.isNotEmpty) {
        // Restaurar usuario desde SQLite
        await ref.read(authProvider.notifier).restoreOfflineUser();
        final user = ref.read(authProvider).user;

        if (user != null) {
          // Asegurarnos de que hay una sesión abierta para evitar ventas huérfanas
          final sessionService = ref.read(sessionServiceProvider);
          await sessionService.validateAndOpenSession(user.branchId);
        } else {
          // El token existe pero el usuario no se pudo restaurar (ej. DB limpia)
          await storage.deleteToken();
        }
      }
    } catch (e) {
      print('DEBUG: Error en AuthGate: $e');
    } finally {
      if (mounted) {
        setState(() {
          _isLoading = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return const Scaffold(
        body: Center(
          child: CircularProgressIndicator(color: Color(0xFF6642F8)),
        ),
      );
    }

    final user = ref.watch(authProvider).user;
    if (user != null) {
      return const DashboardScreen();
    } else {
      return const LoginScreen();
    }
  }
}
