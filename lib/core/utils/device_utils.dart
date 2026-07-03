import 'dart:io';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

class DeviceUtils {
  static const String _macKey = 'device_mac_address_persistent';

  static bool _isInvalidMac(String mac) {
    final m = mac.trim().toUpperCase();
    return m.isEmpty ||
        m == '02:00:00:00:00:00' ||
        m == '00:00:00:00:00:00' ||
        m == 'FF:FF:FF:FF:FF:FF';
  }

  static Future<String?> getMacAddress() async {
    // 1. Devolver el valor persistido si existe — inmune a la interfaz bajando
    //    durante activación de Device Owner / kiosk mode en Android 7
    try {
      final prefs = await SharedPreferences.getInstance();
      final cached = prefs.getString(_macKey);
      if (cached != null && cached.isNotEmpty) return cached;
    } catch (_) {}

    // 2. Leer del sistema (solo en el primer arranque exitoso)
    String? mac;
    try {
      final wlanFile = File('/sys/class/net/wlan0/address');
      if (await wlanFile.exists()) {
        final raw = await wlanFile.readAsString();
        if (!_isInvalidMac(raw)) mac = raw.trim().toUpperCase();
      }
      if (mac == null) {
        final ethFile = File('/sys/class/net/eth0/address');
        if (await ethFile.exists()) {
          final raw = await ethFile.readAsString();
          if (!_isInvalidMac(raw)) mac = raw.trim().toUpperCase();
        }
      }
    } catch (_) {}

    // 3. Fallback al serial number del hardware
    if (mac == null) {
      try {
        if (Platform.isAndroid) {
          final build = await DeviceInfoPlugin().androidInfo;
          final serial = build.serialNumber.trim().toUpperCase();
          if (serial.isNotEmpty &&
              serial != 'UNKNOWN' &&
              serial != build.id.toUpperCase()) {
            mac = serial;
          }
        }
      } catch (_) {}
    }

    // 4. Persistir para que futuras llamadas (incluso con interfaz down) sean estables
    if (mac != null) {
      try {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString(_macKey, mac);
      } catch (_) {}
    }

    return mac;
  }
}
