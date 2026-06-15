class ApiConstants {
  static const bool isProduction =
      false; // <-- Cambiar a false para usar el entorno de pruebas

  static const String baseUrlProd = 'http://35.208.37.141:8089/api';
  static const String baseUrlDev = 'http://35.209.80.61:8089/api';

  static const String baseUrl = isProduction ? baseUrlProd : baseUrlDev;

  // Versión de la aplicación
  static const String appVersion = '1.4.4';
  static String get displayVersion =>
      isProduction ? 'v$appVersion' : 'v_test $appVersion';

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
