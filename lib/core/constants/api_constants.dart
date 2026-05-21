class ApiConstants {
  static const String baseUrl = 'http://200.7.96.34:8089/api';
  
  // Endpoints principales del POS Red de Recarga
  static const String login = '/sanctum/token';
  static const String user = '/user';
  static const String myCards = '/my-cards';
  static const String rechargeCard = '/recharge-card';
  static const String baseSearch = '/base-search';

  // Gateway - Ventas PAX QR
  static const String gatewayProducts = '/gateway/v1/products';
  static const String gatewayPurchases = '/gateway/v1/purchases';
}
