import 'package:dio/dio.dart';
import '../../../core/constants/api_constants.dart';
import '../models/tarifa_model.dart';

/// Servicio de ventas.
/// Consume los endpoints del gateway para productos/tarifas y compras QR,
/// además de /my-cards para saldo y /recharge-card + /base-search para recaudo.
class SalesService {
  final Dio _dio;

  SalesService(this._dio);

  // ==================== Saldo ====================

  /// Obtiene el saldo del punto de venta desde /my-cards?branch_id={id}
  Future<double> fetchBranchBalance(int branchId) async {
    try {
      final response = await _dio.get(
        ApiConstants.myCards,
        queryParameters: {'branch_id': branchId},
      );
      final data = response.data['data'] as List;
      if (data.isEmpty) {
        throw Exception('No se encontró información de saldo para esta sucursal.');
      }
      return (data[0]['balance'] as num).toDouble();
    } on DioException catch (e) {
      if (e.response?.statusCode == 401) {
        throw Exception('Sesión expirada. Inicie sesión nuevamente.');
      }
      throw Exception('Error al obtener el saldo de la caja.');
    }
  }

  // ==================== Gateway: Productos / Tarifas ====================

  /// Obtiene la lista de productos/tarifas desde GET /gateway/v1/products.
  /// El frontend Angular deduplica por product_name quedándose con el mayor id,
  /// replicamos esa lógica aquí.
  Future<List<Product>> fetchProducts({int? page}) async {
    try {
      final queryParams = <String, dynamic>{};
      if (page != null && page > 0) {
        queryParams['page'] = page;
      }

      final response = await _dio.get(
        ApiConstants.gatewayProducts,
        queryParameters: queryParams,
      );

      final rawData = response.data['data'] as List? ?? [];
      final allProducts =
          rawData.map((e) => Product.fromJson(e as Map<String, dynamic>)).toList();

      // Deduplicar por product_name, quedándonos con el de mayor id
      // (misma lógica que el Angular)
      final Map<String, Product> deduplicated = {};
      for (final product in allProducts) {
        final existing = deduplicated[product.productName];
        if (existing == null || product.id.compareTo(existing.id) > 0) {
          deduplicated[product.productName] = product;
        }
      }

      return deduplicated.values.toList();
    } on DioException catch (e) {
      if (e.response?.statusCode == 401) {
        throw Exception('Sesión expirada. Inicie sesión nuevamente.');
      }
      throw Exception('Error al obtener las tarifas disponibles.');
    }
  }

  // ==================== Gateway: Compra QR ====================

  /// Registra una venta QR con POST /gateway/v1/purchases.
  /// Envía { "product_id": "<_id del producto seleccionado>" }.
  /// Retorna el QR code y transaction_id de la respuesta.
  Future<QrPurchaseResult> purchaseQr({required String productId}) async {
    try {
      final response = await _dio.post(
        ApiConstants.gatewayPurchases,
        data: {'product_id': productId},
      );

      return QrPurchaseResult.fromJson(
        response.data is Map<String, dynamic>
            ? response.data as Map<String, dynamic>
            : {},
      );
    } on DioException catch (e) {
      if (e.response?.statusCode == 422) {
        final errors = e.response?.data;
        if (errors is Map && errors.containsKey('message')) {
          throw Exception(errors['message']);
        }
        throw Exception('Error de validación. Verifique los datos.');
      }
      if (e.response?.statusCode == 401) {
        throw Exception('Sesión expirada. Inicie sesión nuevamente.');
      }
      throw Exception('Error al generar el QR. Intente nuevamente.');
    }
  }

  // ==================== Recaudo / Histórico ====================

  /// Obtiene el histórico de ventas/transacciones
  Future<Map<String, dynamic>> fetchSalesHistory({int page = 1}) async {
    try {
      final response = await _dio.get(
        ApiConstants.rechargeCard,
        queryParameters: {'page': page},
      );
      return response.data as Map<String, dynamic>;
    } on DioException catch (e) {
      if (e.response?.statusCode == 401) {
        throw Exception('Sesión expirada.');
      }
      throw Exception('Error al obtener el historial de ventas.');
    }
  }

  /// Buscar transacciones
  Future<Map<String, dynamic>> searchTransactions({
    required String query,
    int page = 1,
  }) async {
    try {
      final response = await _dio.get(
        ApiConstants.baseSearch,
        queryParameters: {'query': query, 'page': page},
      );
      return response.data as Map<String, dynamic>;
    } on DioException catch (e) {
      if (e.response?.statusCode == 401) {
        throw Exception('Sesión expirada.');
      }
      throw Exception('Error en la búsqueda.');
    }
  }
}
