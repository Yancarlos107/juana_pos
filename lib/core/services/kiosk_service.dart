import 'package:flutter/services.dart';

/// Controla el modo kiosco real de Android (Lock Task Mode con Device Owner).
///
/// A diferencia del modo inmersivo (que solo oculta las barras visualmente),
/// el Lock Task Mode bloquea de verdad la barra de estado, la barra de
/// navegación, los gestos del sistema y la salida de la app.
///
/// Requiere aprovisionar la tablet UNA VEZ (sin cuentas Google añadidas):
///   adb shell dpm set-device-owner co.Juana.red_recarga_pos/.KioskDeviceAdminReceiver
///
/// Si la app no es Device Owner, todos los métodos degradan de forma segura
/// (no hacen nada y retornan false), por lo que es seguro llamarlos siempre.
class KioskService {
  static const MethodChannel _channel = MethodChannel('co.Juana.kiosk');

  KioskService._();

  /// ¿La app está aprovisionada como Device Owner en esta tablet?
  static Future<bool> isDeviceOwner() async {
    try {
      return await _channel.invokeMethod<bool>('isDeviceOwner') ?? false;
    } catch (_) {
      return false;
    }
  }

  /// ¿El kiosco (lock task) está activo en este momento?
  static Future<bool> isInKioskMode() async {
    try {
      return await _channel.invokeMethod<bool>('isInKioskMode') ?? false;
    } catch (_) {
      return false;
    }
  }

  /// Activa el kiosco. Retorna false si la app no es Device Owner
  /// (en ese caso no se intenta el "screen pinning" débil).
  static Future<bool> start() async {
    try {
      return await _channel.invokeMethod<bool>('startKiosk') ?? false;
    } catch (_) {
      return false;
    }
  }

  /// Sale del kiosco para mantenimiento (requiere PIN admin en la UI).
  static Future<bool> stop() async {
    try {
      return await _channel.invokeMethod<bool>('stopKiosk') ?? false;
    } catch (_) {
      return false;
    }
  }

  /// Libera el dispositivo: la app deja de ser Device Owner y vuelve a ser
  /// desinstalable desde Ajustes. Irreversible sin volver a aprovisionar
  /// por ADB. Usar solo para desinstalar o bajar de versión.
  static Future<bool> clearDeviceOwner() async {
    try {
      return await _channel.invokeMethod<bool>('clearDeviceOwner') ?? false;
    } catch (_) {
      return false;
    }
  }
}
