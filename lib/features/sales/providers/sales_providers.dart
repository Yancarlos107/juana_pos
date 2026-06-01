import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'dart:convert';
import 'dart:math';

import '../../../core/network/dio_client.dart';
import '../../../core/storage/local_storage_repository.dart';
import '../../../core/database/database_helper.dart';
import '../models/tarifa_model.dart';
import '../services/sales_service.dart';
import '../../../core/utils/currency_formatter.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import '../../monitoring/services/system_status_service.dart';
// ==================== Proveedor del Servicio ====================

final salesServiceProvider = Provider<SalesService>((ref) {
  final dio = ref.read(dioProvider);
  return SalesService(dio);
});

final salesStorageProvider = Provider<LocalStorageRepository>((ref) {
  return ref.read(localStorageProvider);
});

// ==================== Estado del Saldo ====================

enum BalanceStatus { initial, loading, loaded, error }

class BalanceState {
  final BalanceStatus status;
  final double balance;
  final String? errorMessage;

  const BalanceState({
    this.status = BalanceStatus.initial,
    this.balance = 0,
    this.errorMessage,
  });

  BalanceState copyWith({
    BalanceStatus? status,
    double? balance,
    String? errorMessage,
  }) {
    return BalanceState(
      status: status ?? this.status,
      balance: balance ?? this.balance,
      errorMessage: errorMessage,
    );
  }
}

class BalanceNotifier extends StateNotifier<BalanceState> {
  final SalesService _salesService;
  final LocalStorageRepository _storage;
  
  BalanceNotifier(this._salesService, this._storage) : super(const BalanceState());

  Future<void> fetchBalance(int branchId) async {
    state = state.copyWith(status: BalanceStatus.loading, errorMessage: null);
    try {
      final balance = await _salesService.fetchBranchBalance(branchId);
      // Actualizamos almacenamiento local
      await _storage.saveBalance(balance);
      state = state.copyWith(status: BalanceStatus.loaded, balance: balance);
    } catch (e) {
      // Siempre hacer fallback al saldo local si hay problemas de red o del servidor
      await loadLocalBalance();
    }
  }

  /// Carga el saldo desde almacenamiento local sin peticiones de red.
  Future<void> loadLocalBalance() async {
    final balance = await _storage.getBalance();
    state = state.copyWith(status: BalanceStatus.loaded, balance: balance);
  }

  /// Actualiza el estado del saldo manualmente (ej: tras una venta).
  void updateBalanceState(double newBalance) {
    state = state.copyWith(balance: newBalance);
  }
}

final balanceProvider =
    StateNotifierProvider<BalanceNotifier, BalanceState>((ref) {
  final salesService = ref.read(salesServiceProvider);
  final storage = ref.read(salesStorageProvider);
  return BalanceNotifier(salesService, storage);
});

// ==================== Estado de Productos/Tarifas ====================

enum ProductsStatus { initial, loading, loaded, error }

class ProductsState {
  final ProductsStatus status;
  final List<Product> products;
  final String? errorMessage;

  const ProductsState({
    this.status = ProductsStatus.initial,
    this.products = const [],
    this.errorMessage,
  });

  ProductsState copyWith({
    ProductsStatus? status,
    List<Product>? products,
    String? errorMessage,
  }) {
    return ProductsState(
      status: status ?? this.status,
      products: products ?? this.products,
      errorMessage: errorMessage,
    );
  }
}

class ProductsNotifier extends StateNotifier<ProductsState> {
  final SalesService _salesService;

  ProductsNotifier(this._salesService) : super(const ProductsState());

  Future<void> fetchProducts() async {
    state = state.copyWith(status: ProductsStatus.loading, errorMessage: null);

    // 1. Intentar cargar desde la API (API-first)
    try {
      final apiProducts = await _salesService.fetchProducts();

      // 2. Persistir en SQLite para uso offline
      final db = await DatabaseHelper.instance.database;
      await db.delete('products');
      for (final p in apiProducts) {
        try {
          await db.insert('products', {
            'id': p.id,              // MongoDB _id como TEXT (correcto)
            'product_name': p.productName,
            'value': p.value,
            'pmr': p.pmr ? 1 : 0,
            'created_at': DateTime.now().toIso8601String(),
          });
        } catch (e) {
          print('DEBUG: Error guardando producto ${p.productName} en cache: $e');
        }
      }

      state = state.copyWith(status: ProductsStatus.loaded, products: apiProducts);
      return;
    } catch (_) {
      // Si falla la red, caemos al caché local
    }

    // 3. Fallback: leer desde SQLite (modo offline)
    try {
      final db = await DatabaseHelper.instance.database;
      final results = await db.query('products');

      if (results.isEmpty) {
        state = state.copyWith(
          status: ProductsStatus.error,
          errorMessage: 'Sin conexión y sin tarifas en caché. Conéctese al menos una vez.',
        );
        return;
      }

      final products = results.map((row) => Product(
        id: row['id']?.toString() ?? '',
        productName: row['product_name']?.toString() ?? '',
        value: (row['value'] as num?)?.toDouble() ?? 0.0,
        pmr: row['pmr'] == 1,
      )).toList();

      state = state.copyWith(status: ProductsStatus.loaded, products: products);
    } catch (e) {
      state = state.copyWith(
        status: ProductsStatus.error,
        errorMessage: e.toString().replaceFirst('Exception: ', ''),
      );
    }
  }
}

final productsProvider =
    StateNotifierProvider<ProductsNotifier, ProductsState>((ref) {
  final salesService = ref.read(salesServiceProvider);
  return ProductsNotifier(salesService);
});

// ==================== Estado de Compra QR ====================

enum QrPurchaseStatus { idle, loading, success, error }

class QrPurchaseState {
  final QrPurchaseStatus status;
  final QrPurchaseResult? result;
  final String? errorMessage;

  const QrPurchaseState({
    this.status = QrPurchaseStatus.idle,
    this.result,
    this.errorMessage,
  });

  QrPurchaseState copyWith({
    QrPurchaseStatus? status,
    QrPurchaseResult? result,
    String? errorMessage,
  }) {
    return QrPurchaseState(
      status: status ?? this.status,
      result: result ?? this.result,
      errorMessage: errorMessage,
    );
  }
}

class QrPurchaseNotifier extends StateNotifier<QrPurchaseState> {
  final SalesService _salesService;
  final LocalStorageRepository _storage;
  final SystemStatusNotifier _statusNotifier;

  QrPurchaseNotifier(this._salesService, this._storage, this._statusNotifier) : super(const QrPurchaseState());

  Future<bool> purchase({required Product product, required int cashierId}) async {
    state = state.copyWith(
        status: QrPurchaseStatus.loading, errorMessage: null);
    try {
      // 1. Verificación de saldo local preventiva
      final connectivityResult = await Connectivity().checkConnectivity();
      final isOffline = connectivityResult.contains(ConnectivityResult.none) ||
          connectivityResult.isEmpty;

      final currentBalance = await _storage.getBalance();
      
      // Permitir la venta si hay saldo suficiente O si la máquina está offline
      if (currentBalance < product.value && !isOffline) {
        throw Exception('Saldo insuficiente. Saldo actual: \$${CurrencyFormatter.format(currentBalance)}. Requerido: \$${CurrencyFormatter.format(product.value)}');
      }

      // Se fuerza SIEMPRE la generación offline
      final localId = "OFF-${DateTime.now().microsecondsSinceEpoch}";
      
      final chars = 'abcdef0123456789';
      final random = Random();
      final qrCodeStr = String.fromCharCodes(Iterable.generate(
          32, (_) => chars.codeUnitAt(random.nextInt(chars.length))));

      
      // 2. Decrementar saldo local tras éxito
      final newBalance = currentBalance - product.value;
      await _storage.saveBalance(newBalance);

      // 3. Guardamos la venta en SQLite
      final db = await DatabaseHelper.instance.database;
      // Obtener la sesión activa para relacionarla
      final branchId = await _storage.getBranchId() ?? 0;
      final sessionQuery = await db.query('sessions', where: 'status = ? AND branch_id = ?', whereArgs: ['open', branchId]);
      final sessionId = sessionQuery.isNotEmpty ? sessionQuery.first['id'] : null;

      final insertedLocalId = await db.insert('transactions', {
        'id': localId,
        'session_id': sessionId,
        'cashier_id': cashierId, // <- USAMOS EL CASHIER QUE ESTA LOGUEADO REALMENTE
        'product_id': product.id,
        'amount': product.value,
        'pmr': product.pmr ? 1 : 0,
        'status': 'pending', // Siempre local first
        'created_at': DateTime.now().toIso8601String(),
        'qr_data': qrCodeStr,
        'print_status': 0, // Inicia en 0, la UI lo actualizará a 1 si imprime
      });

      final result = QrPurchaseResult(
        qrCode: qrCodeStr,
        transactionId: localId,
        yourNewBalance: newBalance,
        rawData: {'local_id': insertedLocalId},
      );

      // 5. Actualizar contador visual inmediatamente
      _statusNotifier.forceCheckPendingTransactions();

      state = state.copyWith(
        status: QrPurchaseStatus.success,
        result: result,
      );
      return true;
    } catch (e) {
      state = state.copyWith(
        status: QrPurchaseStatus.error,
        errorMessage: e.toString().replaceFirst('Exception: ', ''),
      );
      return false;
    }
  }

  void reset() {
    state = const QrPurchaseState();
  }
}

final qrPurchaseProvider =
    StateNotifierProvider<QrPurchaseNotifier, QrPurchaseState>((ref) {
  final salesService = ref.read(salesServiceProvider);
  final storage = ref.read(salesStorageProvider);
  final statusNotifier = ref.read(systemStatusProvider.notifier);
  return QrPurchaseNotifier(salesService, storage, statusNotifier);
});

// ==================== Estado del Histórico de Ventas ====================

enum SalesHistoryStatus { initial, loading, loaded, error }

class SalesHistoryState {
  final SalesHistoryStatus status;
  final List<Map<String, dynamic>> sales;
  final int currentPage;
  final int lastPage;
  final int total;
  final String? errorMessage;

  const SalesHistoryState({
    this.status = SalesHistoryStatus.initial,
    this.sales = const [],
    this.currentPage = 1,
    this.lastPage = 1,
    this.total = 0,
    this.errorMessage,
  });

  SalesHistoryState copyWith({
    SalesHistoryStatus? status,
    List<Map<String, dynamic>>? sales,
    int? currentPage,
    int? lastPage,
    int? total,
    String? errorMessage,
  }) {
    return SalesHistoryState(
      status: status ?? this.status,
      sales: sales ?? this.sales,
      currentPage: currentPage ?? this.currentPage,
      lastPage: lastPage ?? this.lastPage,
      total: total ?? this.total,
      errorMessage: errorMessage,
    );
  }
}

class SalesHistoryNotifier extends StateNotifier<SalesHistoryState> {
  final LocalStorageRepository _storage;
  SalesHistoryNotifier(this._storage) : super(const SalesHistoryState());

  Future<void> _fetchHistory({int page = 1}) async {
    state = state.copyWith(status: SalesHistoryStatus.loading, errorMessage: null);
    try {
      final db = await DatabaseHelper.instance.database;
      final branchId = await _storage.getBranchId() ?? 0;
      final sessionQuery = await db.query('sessions', where: 'status = ? AND branch_id = ?', whereArgs: ['open', branchId]);
      
      int? openSessionId;
      if (sessionQuery.isNotEmpty) {
        openSessionId = sessionQuery.first['id'] as int;
      }

      final now = DateTime.now();
      final todayStr = "${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}";

      // Buscar por fecha para no borrar de la vista las que ya se cerraron hoy,
      // pero excluir las aperturas PMR de la vista de historial.
      final data = await db.rawQuery(
        '''
        SELECT t.*, p.product_name 
        FROM transactions t
        LEFT JOIN products p ON t.product_id = p.id
        WHERE t.created_at LIKE ? AND t.product_id != 'PMR'
        ORDER BY t.created_at DESC
        ''',
        ['$todayStr%']
      );
      
      // Mapear con un flag 'is_closed'
      List<Map<String, dynamic>> mappedData = data.map((tx) {
         final map = Map<String, dynamic>.from(tx);
         map['is_closed'] = tx['session_id'] != openSessionId;
         return map;
      }).toList();
      
      state = state.copyWith(
        status: SalesHistoryStatus.loaded,
        sales: mappedData,
        total: mappedData.length,
      );
    } catch (e, stack) {
      state = state.copyWith(
        status: SalesHistoryStatus.error,
        errorMessage: e.toString().replaceFirst('Exception: ', ''),
      );
    }
  }

  // Cierre de caja: ya no vaciamos la lista, solo refrescamos
  Future<void> clearHistory() async {
    await fetchHistory();
  }

  // Reemplazamos el método original
  Future<void> fetchHistory({int page = 1}) => _fetchHistory(page: page);

  Future<void> search(String query, {int page = 1}) async {
    state = state.copyWith(status: SalesHistoryStatus.loading, errorMessage: null);
    try {
      final db = await DatabaseHelper.instance.database;
      final branchId = await _storage.getBranchId() ?? 0;
      final sessionQuery = await db.query('sessions', where: 'status = ? AND branch_id = ?', whereArgs: ['open', branchId]);
      
      if (sessionQuery.isEmpty) {
        state = state.copyWith(status: SalesHistoryStatus.loaded, sales: [], total: 0);
        return;
      }
      int? openSessionId;
      if (sessionQuery.isNotEmpty) {
        openSessionId = sessionQuery.first['id'] as int;
      }

      final now = DateTime.now();
      final todayStr = "${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}";

      final data = await db.query('transactions', 
        where: 'created_at LIKE ? AND (id LIKE ? OR amount LIKE ?)', 
        whereArgs: ['$todayStr%', '%$query%', '%$query%'], 
        orderBy: 'created_at DESC');
      
      List<Map<String, dynamic>> mappedData = data.map((tx) {
         final map = Map<String, dynamic>.from(tx);
         map['is_closed'] = tx['session_id'] != openSessionId;
         return map;
      }).toList();

      state = state.copyWith(
        status: SalesHistoryStatus.loaded,
        sales: mappedData,
        total: mappedData.length,
      );
    } catch (e) {
      state = state.copyWith(
        status: SalesHistoryStatus.error,
        errorMessage: 'Error en la búsqueda local',
      );
    }
  }

  Future<void> markAsPrinted(String transactionId, int newPrintStatus) async {
    try {
      final db = await DatabaseHelper.instance.database;
      await db.update(
        'transactions',
        {'print_status': newPrintStatus},
        where: 'id = ?',
        whereArgs: [transactionId],
      );
      // Actualizamos estado en memoria sin hacer fetch de nuevo (optimístico)
      final newSales = state.sales.map((sale) {
        if (sale['id'] == transactionId) {
          final updated = Map<String, dynamic>.from(sale);
          updated['print_status'] = newPrintStatus;
          return updated;
        }
        return sale;
      }).toList();
      state = state.copyWith(sales: newSales);
    } catch (e) {
      print('Error marcando como impreso: $e');
    }
  }
}

final salesHistoryProvider =
    StateNotifierProvider<SalesHistoryNotifier, SalesHistoryState>((ref) {
  final storage = ref.read(salesStorageProvider);
  return SalesHistoryNotifier(storage);
});
