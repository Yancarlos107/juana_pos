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

final systemStatusProvider = StateNotifierProvider<SystemStatusNotifier, SystemStatus>((ref) {
  final dio = ref.watch(dioProvider);
  final syncService = ref.watch(backgroundSyncProvider);
  final printerService = ref.watch(printerServiceProvider);
  return SystemStatusNotifier(dio, syncService, printerService);
});

class SystemStatusNotifier extends StateNotifier<SystemStatus> {
  final Dio _dio;
  final BackgroundSyncService _syncService;
  final PrinterService _printerService;
  Timer? _timer;

  SystemStatusNotifier(this._dio, this._syncService, this._printerService) : super(SystemStatus()) {
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
    await _checkInternetPing();
    await _checkPrinter();
    await _checkPmr();
    await _checkCameraPing();
    await _checkPendingTransactions();
  }

  Future<void> _checkInternetPing() async {
    try {
      final connectivityResult = await Connectivity().checkConnectivity();
      if (connectivityResult.contains(ConnectivityResult.none)) {
        state = state.copyWith(isInternetConnected: false);
        return;
      }
      
      // Ping a la propia API para validar conectividad real con el backend
      final response = await _dio.get('/user', options: Options(
        sendTimeout: const Duration(seconds: 3),
        receiveTimeout: const Duration(seconds: 3),
      ));
      
      final isOnline = (response.statusCode ?? 0) < 500;
      state = state.copyWith(isInternetConnected: isOnline);

      // Sincronización en segundo plano si hay red (independiente de pendientes)
      if (isOnline) {
        _syncService.syncPendingData();
      }
    } catch (e) {
      state = state.copyWith(isInternetConnected: false);
    }
  }

  Future<void> _checkPrinter() async {
    try {
      final isConnected = await _printerService.pingPrinter();
      state = state.copyWith(isPrinterConnected: isConnected);
    } catch (_) {
      state = state.copyWith(isPrinterConnected: false);
    }
  }

  /// Fuerza un chequeo inmediato de la impresora (ej. antes de una venta)
  Future<bool> checkPrinterNow() async {
    await _checkPrinter();
    return state.isPrinterConnected;
  }

  Future<void> _checkPmr() async {
    // TODO: Implementar ping al endpoint de la puerta PMR
    // Por ahora simulado
    state = state.copyWith(isPmrConnected: false);
  }

  Future<void> _checkCameraPing() async {
    try {
      // Mock temporal: Endpoint de la cámara
      final response = await _dio.get(
        'http://192.168.1.101', // IP placeholder
        options: Options(
          sendTimeout: const Duration(seconds: 2),
          receiveTimeout: const Duration(seconds: 2),
        ),
      );
      state = state.copyWith(isCameraConnected: (response.statusCode ?? 0) < 500);
    } catch (_) {
      state = state.copyWith(isCameraConnected: false);
    }
  }

  Future<void> _checkPendingTransactions() async {
    try {
      final db = await DatabaseHelper.instance.database;
      final result = await db.rawQuery('SELECT COUNT(*) as count FROM transactions WHERE status = ?', ['pending']);
      int count = Sqflite.firstIntValue(result) ?? 0;
      
      state = state.copyWith(pendingTransactions: count);
    } catch (e) {
      print('Error checking pending transactions: $e');
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }
}
