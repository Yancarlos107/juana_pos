class ApiConstants {
  static const String baseUrl = 'http://35.209.80.61:8089/api';

  // Endpoints principales del POS Red de Recarga1
  static const String login = '/cashier-login';
  static const String user = '/user';
  static const String myCards = '/my-cards';
  static const String rechargeCard = '/recharge-card';
  static const String baseSearch = '/base-search';

  // Gateway - Ventas PAX QR
  static const String gatewayProducts = '/gateway/v2/products';
  static const String gatewayPurchases = '/gateway/v2/purchases';
}
