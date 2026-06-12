package co.Juana.red_recarga_pos

import android.app.admin.DeviceAdminReceiver

/**
 * Receiver requerido para que la app pueda ser aprovisionada como Device Owner.
 * No necesita lógica: su sola presencia (declarada en el Manifest con el permiso
 * BIND_DEVICE_ADMIN) habilita el Lock Task Mode real (kiosco sin escape).
 *
 * Aprovisionamiento (tablet sin cuentas Google):
 *   adb shell dpm set-device-owner co.Juana.red_recarga_pos/.KioskDeviceAdminReceiver
 */
class KioskDeviceAdminReceiver : DeviceAdminReceiver()
