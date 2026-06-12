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

class AuthGate extends StatelessWidget {
  const AuthGate({super.key});

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<String?>(
      future: LocalStorageRepository().getToken(),
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Scaffold(
            body: Center(
                child: CircularProgressIndicator(color: Color(0xFF6642F8))),
          );
        }
        if (snapshot.hasData &&
            snapshot.data != null &&
            snapshot.data!.isNotEmpty) {
          return const DashboardScreen();
        }
        return const LoginScreen();
      },
    );
  }
}
