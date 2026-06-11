import 'dart:io';
import 'package:device_info_plus/device_info_plus.dart';

class DeviceUtils {
  static Future<String?> getMacAddress() async {
    try {
      final wlanFile = File('/sys/class/net/wlan0/address');
      if (await wlanFile.exists()) {
        final mac = await wlanFile.readAsString();
        if (mac.trim().isNotEmpty && mac.trim() != '02:00:00:00:00:00') {
          return mac.trim().toUpperCase();
        }
      }
      final ethFile = File('/sys/class/net/eth0/address');
      if (await ethFile.exists()) {
        final mac = await ethFile.readAsString();
        if (mac.trim().isNotEmpty && mac.trim() != '02:00:00:00:00:00') {
          return mac.trim().toUpperCase();
        }
      }
    } catch (_) {}
    
    // Fallback to hardware serial if mac is not available
    try {
      if (Platform.isAndroid) {
        final DeviceInfoPlugin deviceInfoPlugin = DeviceInfoPlugin();
        final build = await deviceInfoPlugin.androidInfo;
        final serial = build.serialNumber.trim().toUpperCase();
        if (serial.isNotEmpty && serial != 'UNKNOWN' && serial != build.id.toUpperCase()) {
          return serial;
        }
      }
    } catch (_) {}
    
    return null;
  }
}
