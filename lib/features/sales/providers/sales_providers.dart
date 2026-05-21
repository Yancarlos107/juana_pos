import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/network/dio_client.dart';
import '../../../core/storage/local_storage_repository.dart';
import '../../../core/database/database_helper.dart';
import '../models/tarifa_model.dart';
import '../services/sales_service.dart';

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
      state = state.copyWith(
        status: BalanceStatus.error,
        errorMessage: e.toString().replaceFirst('Exception: ', ''),
      );
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
  ProductsNotifier() : super(const ProductsState());

  Future<void> fetchProducts() async {
    state = state.copyWith(status: ProductsStatus.loading, errorMessage: null);
    try {
      final db = await DatabaseHelper.instance.database;
      final results = await db.query('products');
      
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
  return ProductsNotifier();
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

  QrPurchaseNotifier(this._salesService, this._storage) : super(const QrPurchaseState());

  Future<bool> purchase({required Product product}) async {
    state = state.copyWith(
        status: QrPurchaseStatus.loading, errorMessage: null);
    try {
      // 1. Verificación de saldo local preventiva
      final currentBalance = await _storage.getBalance();
      if (currentBalance < product.value) {
        throw Exception('Saldo insuficiente. Saldo actual: \$${currentBalance.toStringAsFixed(0)}. Requerido: \$${product.value.toStringAsFixed(0)}');
      }

      QrPurchaseResult result;
      bool isOffline = false;

      try {
        result = await _salesService.purchaseQr(productId: product.id);
      } catch (e) {
        // Asumimos error de red y pasamos a offline
        isOffline = true;
        final localId = "OFF-${DateTime.now().millisecondsSinceEpoch}";
        result = QrPurchaseResult(
          qrCode: '{"id":"$localId","product_id":"${product.id}","value":${product.value},"offline":true}',
          transactionId: localId,
          yourNewBalance: currentBalance - product.value,
          rawData: {},
        );
      }
      
      // 2. Decrementar saldo local tras éxito
      final newBalance = result.yourNewBalance ?? (currentBalance - product.value);
      await _storage.saveBalance(newBalance);

      // 3. Guardamos la venta en SQLite
      final db = await DatabaseHelper.instance.database;
      // Obtener la sesión activa para relacionarla
      final branchId = await _storage.getBranchId() ?? 0;
      final sessionQuery = await db.query('sessions', where: 'status = ? AND branch_id = ?', whereArgs: ['open', branchId]);
      final sessionId = sessionQuery.isNotEmpty ? sessionQuery.first['id'] : null;

      await db.insert('transactions', {
        'id': result.transactionId,
        'session_id': sessionId,
        'product_id': product.id,
        'amount': product.value,
        'pmr': product.pmr ? 1 : 0,
        'status': isOffline ? 'pending' : 'synced',
        'created_at': DateTime.now().toIso8601String(),
        'qr_data': result.qrCode,
      });

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
  return QrPurchaseNotifier(salesService, storage);
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
      
      if (sessionQuery.isEmpty) {
        state = state.copyWith(status: SalesHistoryStatus.loaded, sales: [], total: 0);
        return;
      }
      final sessionId = sessionQuery.first['id'];

      final data = await db.query('transactions', where: 'session_id = ?', whereArgs: [sessionId], orderBy: 'created_at DESC');
      
      state = state.copyWith(
        status: SalesHistoryStatus.loaded,
        sales: data,
        total: data.length,
      );
    } catch (e, stack) {
      state = state.copyWith(
        status: SalesHistoryStatus.error,
        errorMessage: e.toString().replaceFirst('Exception: ', ''),
      );
    }
  }

  // Cierre de caja: ya no eliminamos las ventas, solo se actualiza la sesión
  Future<void> clearHistory() async {
    state = const SalesHistoryState(status: SalesHistoryStatus.loaded);
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
      final sessionId = sessionQuery.first['id'];

      final data = await db.query('transactions', 
        where: 'session_id = ? AND (id LIKE ? OR amount LIKE ?)', 
        whereArgs: [sessionId, '%$query%', '%$query%'], 
        orderBy: 'created_at DESC');
      
      state = state.copyWith(
        status: SalesHistoryStatus.loaded,
        sales: data,
        total: data.length,
      );
    } catch (e) {
      state = state.copyWith(
        status: SalesHistoryStatus.error,
        errorMessage: 'Error en la búsqueda local',
      );
    }
  }
}

final salesHistoryProvider =
    StateNotifierProvider<SalesHistoryNotifier, SalesHistoryState>((ref) {
  final storage = ref.read(salesStorageProvider);
  return SalesHistoryNotifier(storage);
});
