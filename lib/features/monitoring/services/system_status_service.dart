import 'dart:async';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sqflite/sqflite.dart';
import '../../../core/database/database_helper.dart';
import '../../../core/network/dio_client.dart';
import '../models/system_status.dart';
import '../../sync/services/background_sync_service.dart';
import '../../printer/services/printer_service.dart';
import '../../sync/services/init_service.dart';

final systemStatusProvider = StateNotifierProvider<SystemStatusNotifier, SystemStatus>((ref) {
  final dio = ref.watch(dioProvider);
  final syncService = ref.watch(backgroundSyncProvider);
  final printerService = ref.watch(printerServiceProvider);
  final initService = ref.watch(initServiceProvider);
  return SystemStatusNotifier(dio, syncService, printerService, initService);
});

class SystemStatusNotifier extends StateNotifier<SystemStatus> {
  final Dio _dio;
  final BackgroundSyncService _syncService;
  final PrinterService _printerService;
  final InitService _initService;
  Timer? _timer;
  DateTime? _lastConfigSync;

  SystemStatusNotifier(this._dio, this._syncService, this._printerService, this._initService) : super(SystemStatus()) {
    _initMonitoring();
  }

  void _initMonitoring() {
    // Escuchar cambios de red nativos
    Connectivity().onConnectivityChanged.listen((List<ConnectivityResult> results) {
      final isConnected = results.isNotEmpty && results.first != ConnectivityResult.none;
      if (isConnected) {
        // Doble validación haciendo ping
        _checkInternetPing();
      } else {
        state = state.copyWith(isInternetConnected: false);
      }
    });

    // Validar inicialmente
    _checkAllStatuses();

    // Loop de validación cada 5 segundos
    _timer = Timer.periodic(const Duration(seconds: 5), (_) {
      _checkAllStatuses();
    });
  }

  Future<void> _checkAllStatuses() async {
    final isOnline = await _checkInternetPing();
    final isPrinterConnected = await _checkPrinter();
    final isPmrConnected = await _checkPmr();
    final isCameraConnected = await _checkCameraPing();
    final pendingCount = await _checkPendingTransactions();

    if (isOnline) {
      final now = DateTime.now();
      if (_lastConfigSync == null || now.difference(_lastConfigSync!).inMinutes >= 5) {
        _lastConfigSync = now;
        try {
          await _initService.initializePOS();
        } catch (e) {
          // Ignorar silenciosamente errores de red en background
        }
      }
    }

    // Actualizamos el estado de la UI una sola vez para evitar 5 rebuilds consecutivos
    // que estaban causando lentitud extrema en la app cada 5 segundos.
    if (mounted) {
      state = state.copyWith(
        isInternetConnected: isOnline,
        isPrinterConnected: isPrinterConnected,
        isPmrConnected: isPmrConnected,
        isCameraConnected: isCameraConnected,
        pendingTransactions: pendingCount,
      );
    }
  }

  Future<bool> _checkInternetPing() async {
    try {
      final response = await _dio.get('/user', options: Options(
        sendTimeout: const Duration(seconds: 3),
        receiveTimeout: const Duration(seconds: 3),
      ));
      
      // Detección de Captive Portal: SIM card interceptó y devolvió HTML con 200 OK
      final contentType = response.headers.value('content-type') ?? '';
      if (contentType.contains('text/html') || 
         (response.data is String && (response.data as String).toLowerCase().contains('<html'))) {
        return false;
      }
      
      final isOnline = (response.statusCode ?? 0) < 500;
      if (isOnline) {
        _syncService.syncPendingData();
      }
      return isOnline;
    } catch (e) {
      if (e is DioException && e.response != null) {
        // Redirección de la SIM o HTML inyectado como error
        final contentType = e.response?.headers.value('content-type') ?? '';
        final isHtml = contentType.contains('text/html') || 
                       (e.response?.data is String && (e.response?.data as String).toLowerCase().contains('<html'));
                       
        if (e.response?.statusCode == 302 || isHtml) {
          return false; // Es la SIM bloqueando, no hay internet real
        }
        
        // Si es 401, 404, 422, etc, el servidor Laravel respondió, por lo que SÍ hay internet
        _syncService.syncPendingData();
        return true;
      }
      return false;
    }
  }

  Future<bool> _checkPrinter() async {
    try {
      return await _printerService.pingPrinter();
    } catch (_) {
      return false;
    }
  }

  /// Fuerza un chequeo inmediato de la impresora
  Future<bool> checkPrinterNow() async {
    final isConnected = await _checkPrinter();
    if (mounted) {
      state = state.copyWith(isPrinterConnected: isConnected);
    }
    return isConnected;
  }

  Future<bool> _checkPmr() async {
    return false;
  }

  Future<bool> _checkCameraPing() async {
    try {
      final response = await _dio.get(
        'http://192.168.1.101', // IP placeholder
        options: Options(
          sendTimeout: const Duration(seconds: 2),
          receiveTimeout: const Duration(seconds: 2),
        ),
      );
      return (response.statusCode ?? 0) < 500;
    } catch (_) {
      return false;
    }
  }

  Future<int> _checkPendingTransactions() async {
    try {
      final db = await DatabaseHelper.instance.database;
      final result = await db.rawQuery('SELECT COUNT(*) as count FROM transactions WHERE status = ?', ['pending']);
      return Sqflite.firstIntValue(result) ?? 0;
    } catch (e) {
      return 0;
    }
  }

  Future<void> forceCheckPendingTransactions() async {
    final count = await _checkPendingTransactions();
    if (mounted) {
      state = state.copyWith(pendingTransactions: count);
    }
  }



  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }
}
