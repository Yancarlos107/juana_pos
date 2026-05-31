import 'dart:convert';
import 'dart:io';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Repositorio para manejar la persistencia local de la sesión del usuario.
/// Se usa [FlutterSecureStorage] para datos sensibles (Token JWT) y
/// [SharedPreferences] para datos comunes (Branch ID, Roles).
class LocalStorageRepository {
  final FlutterSecureStorage _secureStorage = const FlutterSecureStorage();

  static const String _tokenKey = 'sanctum_token';
  static const String _branchIdKey = 'branch_id';
  static const String _userRolesKey = 'user_roles';
  static const String _balanceKey = 'branch_balance';
  static const String _deviceHashKey = 'device_hash_cache';

  Future<String> getDeviceHash() async {
    final prefs = await SharedPreferences.getInstance();
    String? hash = prefs.getString(_deviceHashKey);
    if (hash != null) return hash;

    final DeviceInfoPlugin deviceInfoPlugin = DeviceInfoPlugin();
    String deviceId = "UNKNOWN";
    try {
      if (Platform.isAndroid) {
        deviceId = (await deviceInfoPlugin.androidInfo).id;
      } else if (Platform.isIOS) {
        deviceId = (await deviceInfoPlugin.iosInfo).identifierForVendor ?? "UNKNOWN";
      }
    } catch (_) {}

    final int hashNum = deviceId.hashCode.abs();
    final char1 = String.fromCharCode(65 + (hashNum % 26));
    final char2 = String.fromCharCode(65 + ((hashNum ~/ 26) % 26));
    hash = '$char1$char2';
    
    await prefs.setString(_deviceHashKey, hash);
    return hash;
  }

  // ================= Manejo del Token =================
  
  Future<void> saveToken(String token) async {
    await _secureStorage.write(key: _tokenKey, value: token);
  }

  Future<String?> getToken() async {
    return await _secureStorage.read(key: _tokenKey);
  }

  Future<void> deleteToken() async {
    await _secureStorage.delete(key: _tokenKey);
  }

  // ================= Manejo de Datos de Usuario =================

  Future<void> saveBranchId(int branchId) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_branchIdKey, branchId);
  }

  Future<int?> getBranchId() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getInt(_branchIdKey);
  }

  Future<void> saveRoles(List<String> roles) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_userRolesKey, roles);
  }

  Future<List<String>?> getRoles() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getStringList(_userRolesKey);
  }

  Future<void> savePosLocationId(int locationId) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt('active_pos_location_id', locationId);
  }

  Future<int?> getPosLocationId() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getInt('active_pos_location_id');
  }

  Future<void> savePosLocationName(String name) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('active_pos_location_name', name);
  }

  Future<String?> getPosLocationName() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString('active_pos_location_name');
  }

  static const String _locationsListKey = 'cached_locations';

  Future<void> savePosLocationsList(List<dynamic> locationsJson) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_locationsListKey, jsonEncode(locationsJson));
  }

  Future<List<dynamic>?> getPosLocationsList() async {
    final prefs = await SharedPreferences.getInstance();
    final jsonString = prefs.getString(_locationsListKey);
    if (jsonString != null) {
      return jsonDecode(jsonString) as List<dynamic>;
    }
    return null;
  }

  static const String _noveltiesKey = 'cached_novelties';

  Future<void> saveNovelties(List<dynamic> noveltiesJson) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_noveltiesKey, jsonEncode(noveltiesJson));
  }

  Future<List<dynamic>?> getNovelties() async {
    final prefs = await SharedPreferences.getInstance();
    final jsonString = prefs.getString(_noveltiesKey);
    if (jsonString != null) {
      return jsonDecode(jsonString) as List<dynamic>;
    }
    return null;
  }

  Future<void> saveBalance(double balance) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble(_balanceKey, balance);
  }

  Future<double> getBalance() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getDouble(_balanceKey) ?? 0.0;
  }

  /// Limpia toda la sesión (al hacer logout)
  Future<void> clearAll() async {
    await _secureStorage.deleteAll();
    final prefs = await SharedPreferences.getInstance();
    
    // Borramos datos de sesión activa, conservando cachés para uso offline futuro
    await prefs.remove(_branchIdKey);
    await prefs.remove(_userRolesKey);
    await prefs.remove('active_pos_location_id');
    await prefs.remove('active_pos_location_name');
  }

  // ================= Manejo de Ventas Locales (Recaudo) =================
  static const String _salesKey = 'local_sales_history';

  Future<void> saveLocalSale(Map<String, dynamic> sale) async {
    final prefs = await SharedPreferences.getInstance();
    final List<String> currentSales = prefs.getStringList(_salesKey) ?? [];
    
    // Añadimos la venta al inicio (más reciente primero)
    currentSales.insert(0, jsonEncode(sale));
    
    // Limitamos a las últimas 200 ventas para no saturar el almacenamiento
    if (currentSales.length > 200) {
      currentSales.removeLast();
    }
    
    await prefs.setStringList(_salesKey, currentSales);
  }

  Future<List<Map<String, dynamic>>> getLocalSales() async {
    final prefs = await SharedPreferences.getInstance();
    final List<String> rawSales = prefs.getStringList(_salesKey) ?? [];
    
    return rawSales.map((s) => jsonDecode(s) as Map<String, dynamic>).toList();
  }

  Future<void> clearLocalSales() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_salesKey);
  }
}
