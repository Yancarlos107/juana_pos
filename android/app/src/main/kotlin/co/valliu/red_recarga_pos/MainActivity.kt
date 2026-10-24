package co.Juana.red_recarga_pos

import android.app.ActivityManager
import android.app.AlarmManager
import android.app.PendingIntent
import android.app.admin.DevicePolicyManager
import android.os.SystemClock
import android.content.BroadcastReceiver
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.hardware.usb.UsbConstants
import android.hardware.usb.UsbDevice
import android.hardware.usb.UsbManager
import androidx.annotation.NonNull
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import android.os.Handler
import android.os.Looper
import java.io.File
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import android.content.pm.PackageInstaller
import androidx.core.content.FileProvider
import java.io.FileInputStream
import java.io.OutputStream

class MainActivity : FlutterActivity() {

    private val USB_STATUS_CHANNEL = "co.Juana.usb/status"
    private val PRINTER_CHANNEL    = "co.Juana.epson_printer"
    private val KIOSK_CHANNEL      = "co.Juana.kiosk"
    private val OTA_CHANNEL        = "com.dashfleet.pos/ota"
    private val ACTION_USB_PERM    = "co.Juana.USB_PERMISSION"

    // Vendor ID 0x04B8 = 1208 decimal = Seiko Epson Corp.
    private val EPSON_VENDOR_ID = 0x04B8

    private var pendingPrintBytes: ByteArray? = null
    private var pendingPrintResult: MethodChannel.Result? = null

    private val usbReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent) {
            if (ACTION_USB_PERM == intent.action) {
                synchronized(this) {
                    val device: UsbDevice? = intent.getParcelableExtra(UsbManager.EXTRA_DEVICE)
                    if (intent.getBooleanExtra(UsbManager.EXTRA_PERMISSION_GRANTED, false)) {
                        log("Permiso USB concedido por el usuario")
                        val bytes = pendingPrintBytes
                        val result = pendingPrintResult
                        pendingPrintBytes = null
                        pendingPrintResult = null
                        if (bytes != null && result != null) {
                            printViaUsbDirect(bytes, result)
                        }
                    } else {
                        log("Permiso USB DENEGADO por el usuario")
                        pendingPrintResult?.error("NO_PERMISSION", "Permiso denegado por el usuario", null)
                        pendingPrintBytes = null
                        pendingPrintResult = null
                    }
                }
            }
        }
    }

    private val logFile by lazy { File(filesDir, "epson_log.txt") }
    private fun log(msg: String) {
        val ts = SimpleDateFormat("HH:mm:ss.SSS", Locale.getDefault()).format(Date())
        logFile.appendText("[$ts] $msg\n")
    }

    // -------------------------------------------------------------------------
    // Flutter engine setup
    // -------------------------------------------------------------------------

    override fun configureFlutterEngine(@NonNull flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val filter = IntentFilter(ACTION_USB_PERM)
        registerReceiver(usbReceiver, filter)
        
        setupUsbStatusChannel(flutterEngine)
        setupPrinterChannel(flutterEngine)
        setupKioskChannel(flutterEngine)
        setupOtaChannel(flutterEngine)
        enableMultiNetworkCoexist()
    }

    // Habilita la coexistencia multi-red del firmware (Ethernet = red interna,
    // datos externos por WiFi/4G). El cambio aplica tras reiniciar el equipo.
    private fun enableMultiNetworkCoexist() {
        try {
            val intent = Intent("android.intent.action.multiple_network_coexist")
            intent.putExtra("coexist_value", "on")
            applicationContext.sendBroadcast(intent)
            log("Broadcast multiple_network_coexist=on enviado")
        } catch (e: Exception) {
            log("Error enviando multiple_network_coexist: ${e.message}")
        }
    }

    override fun onDestroy() {
        super.onDestroy()
        try {
            unregisterReceiver(usbReceiver)
        } catch (e: Exception) {
            // Ignorar
        }
    }

    // -------------------------------------------------------------------------
    // Channel: USB status (usado por PrinterService existente)
    // -------------------------------------------------------------------------

    private fun setupUsbStatusChannel(flutterEngine: FlutterEngine) {
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, USB_STATUS_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "isUsbDeviceConnected" -> {
                        val vendorId  = call.argument<Int>("vendorId")
                        val productId = call.argument<Int>("productId")
                        result.success(isUsbDeviceConnected(vendorId ?: -1, productId ?: -1))
                    }
                    else -> result.notImplemented()
                }
            }
    }

    // -------------------------------------------------------------------------
    // Channel: impresión directa vía USB Host API (sin Epson SDK)
    // -------------------------------------------------------------------------

    private fun setupPrinterChannel(flutterEngine: FlutterEngine) {
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, PRINTER_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {

                    // Lectura del log de diagnóstico
                    "getEpsonLog" -> {
                        result.success(if (logFile.exists()) logFile.readText() else "Log vacío")
                    }

                    // Prueba rápida: imprime "Hola" vía USB Host API directo
                    "printHola" -> {
                        val bytes = buildTestEscPos()
                        printViaUsbDirect(bytes, result)
                    }

                    // Impresión de bytes ESC/POS arbitrarios desde Dart (Uint8List → ByteArray)
                    "printBytes" -> {
                        val bytes = call.argument<ByteArray>("bytes")
                        if (bytes == null || bytes.isEmpty()) {
                            result.error("INVALID_ARGS", "Se requieren bytes ESC/POS", null)
                        } else {
                            printViaUsbDirect(bytes, result)
                        }
                    }

                    else -> result.notImplemented()
                }
            }
    }

    // -------------------------------------------------------------------------
    // Channel: Kiosco (Lock Task Mode con Device Owner)
    // Bloquea barras del sistema, gestos y botones de forma real (no solo visual).
    // Requiere aprovisionar la tablet una vez:
    //   adb shell dpm set-device-owner co.Juana.red_recarga_pos/.KioskDeviceAdminReceiver
    // -------------------------------------------------------------------------

    private val dpm: DevicePolicyManager
        get() = getSystemService(Context.DEVICE_POLICY_SERVICE) as DevicePolicyManager

    private val adminComponent: ComponentName
        get() = ComponentName(this, KioskDeviceAdminReceiver::class.java)

    private fun isDeviceOwner(): Boolean = dpm.isDeviceOwnerApp(packageName)

    private fun isInLockTaskMode(): Boolean {
        val am = getSystemService(Context.ACTIVITY_SERVICE) as ActivityManager
        return am.lockTaskModeState != ActivityManager.LOCK_TASK_MODE_NONE
    }

    private fun setupKioskChannel(flutterEngine: FlutterEngine) {
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, KIOSK_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {

                    "isDeviceOwner" -> result.success(isDeviceOwner())

                    "isInKioskMode" -> result.success(isInLockTaskMode())

                    // Entra al kiosco. Solo si la app es Device Owner: así se evita
                    // el "screen pinning" débil (con diálogo y escape por botones).
                    "startKiosk" -> {
                        try {
                            if (!isDeviceOwner()) {
                                result.success(false)
                                return@setMethodCallHandler
                            }
                            dpm.setLockTaskPackages(adminComponent, arrayOf(packageName))
                            if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.P) {
                                dpm.setLockTaskFeatures(
                                    adminComponent,
                                    DevicePolicyManager.LOCK_TASK_FEATURE_NONE
                                )
                            }
                            // Declara esta app como HOME permanente: sobrevive OTA updates y
                            // reinicios sin necesidad de startActivity() desde background.
                            val homeFilter = IntentFilter(Intent.ACTION_MAIN).apply {
                                addCategory(Intent.CATEGORY_HOME)
                                addCategory(Intent.CATEGORY_DEFAULT)
                            }
                            dpm.addPersistentPreferredActivity(
                                adminComponent,
                                homeFilter,
                                ComponentName(packageName, MainActivity::class.java.name)
                            )
                            if (!isInLockTaskMode()) {
                                startLockTask()
                            }
                            result.success(true)
                        } catch (e: Exception) {
                            result.error("KIOSK_ERROR", "${e.javaClass.simpleName}: ${e.message}", null)
                        }
                    }

                    // Sale del kiosco (mantenimiento administrativo).
                    "stopKiosk" -> {
                        try {
                            if (isInLockTaskMode()) {
                                stopLockTask()
                            }
                            result.success(true)
                        } catch (e: Exception) {
                            result.error("KIOSK_ERROR", "${e.javaClass.simpleName}: ${e.message}", null)
                        }
                    }

                    // Libera el dispositivo: la app deja de ser Device Owner y vuelve
                    // a ser desinstalable. Necesario antes de bajar de versión.
                    "clearDeviceOwner" -> {
                        try {
                            if (isInLockTaskMode()) {
                                stopLockTask()
                            }
                            if (isDeviceOwner()) {
                                @Suppress("DEPRECATION")
                                dpm.clearDeviceOwnerApp(packageName)
                            }
                            result.success(true)
                        } catch (e: Exception) {
                            result.error("KIOSK_ERROR", "${e.javaClass.simpleName}: ${e.message}", null)
                        }
                    }

                    else -> result.notImplemented()
                }
            }
    }

    // -------------------------------------------------------------------------
    // Impresión directa — Android USB Host API
    // No usa el Epson SDK. Funciona con clase 7 y clase 255 (vendor-specific).
    // -------------------------------------------------------------------------

    private fun printViaUsbDirect(bytes: ByteArray, result: MethodChannel.Result) {
        logFile.writeText("")
        log("printViaUsbDirect: ${bytes.size} bytes")

        val usbManager = getSystemService(Context.USB_SERVICE) as UsbManager
        val device = findEpsonDevice(usbManager)

        if (device == null) {
            log("ERROR: No se encontró dispositivo Epson (VID=0x04B8)")
            val allDevices = usbManager.deviceList.values
                .joinToString { "VID=${it.vendorId} PID=${it.productId}" }
            log("Dispositivos USB encontrados: $allDevices")
            result.error("NO_DEVICE", "No se encontró impresora Epson USB conectada", null)
            return
        }

        log("Dispositivo encontrado: VID=${device.vendorId} PID=${device.productId} name=${device.deviceName}")

        if (!usbManager.hasPermission(device)) {
            log("Sin permiso USB, solicitando y esperando respuesta...")
            pendingPrintBytes = bytes
            pendingPrintResult = result
            val pi = PendingIntent.getBroadcast(
                this, 0, Intent(ACTION_USB_PERM),
                if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.S)
                    PendingIntent.FLAG_MUTABLE
                else
                    PendingIntent.FLAG_UPDATE_CURRENT
            )
            usbManager.requestPermission(device, pi)
            // No retornamos result.error aquí, esperamos a que el BroadcastReceiver lo maneje
            return
        }

        Thread {
            try {
                val connection = usbManager.openDevice(device)
                    ?: throw Exception("openDevice() retornó null — verifica el permiso USB")

                log("Conexión USB abierta. Interfaces: ${device.interfaceCount}")

                var transferred = -1
                var activeIface: android.hardware.usb.UsbInterface? = null
                
                /*
                // INTENTO DE FIX (Retirado temporalmente por inestabilidad)
                try {
                    outer@ for (i in 0 until device.interfaceCount) {
                        ...
                    }
                } finally {
                    if (activeIface != null) {
                        connection.releaseInterface(activeIface)
                    }
                    connection.close()
                    log("Conexión USB cerrada y limpiada correctamente en el bloque finally.")
                }
                */

                // Lógica original de transferencia (Sin el bloque finally estricto)
                outer@ for (i in 0 until device.interfaceCount) {
                    val iface = device.getInterface(i)
                    log("  Interfaz $i: clase=${iface.interfaceClass} endpoints=${iface.endpointCount}")

                    if (!connection.claimInterface(iface, true)) {
                        log("  -> claimInterface($i) falló, saltando")
                        continue
                    }
                    
                    for (j in 0 until iface.endpointCount) {
                        val ep = iface.getEndpoint(j)
                        log("    Endpoint $j: tipo=${ep.type} dir=${ep.direction}")

                        if (ep.type == UsbConstants.USB_ENDPOINT_XFER_BULK &&
                            ep.direction == UsbConstants.USB_DIR_OUT) {

                            log("    -> Endpoint bulk OUT encontrado. Enviando ${bytes.size} bytes...")
                            transferred = connection.bulkTransfer(ep, bytes, bytes.size, 8000)
                            log("    -> bulkTransfer resultado: $transferred")
                            connection.releaseInterface(iface)
                            break@outer
                        }
                    }
                    connection.releaseInterface(iface)
                }

                connection.close()

                if (transferred >= 0) {
                    log("EXITO: $transferred bytes transferidos")
                    Handler(Looper.getMainLooper()).post { result.success(true) }
                } else {
                    log("ERROR: bulkTransfer retornó $transferred (no se encontró endpoint bulk OUT o falló)")
                    Handler(Looper.getMainLooper()).post {
                        result.error("TRANSFER_FAILED", "No se pudo enviar datos a la impresora (resultado: $transferred)", null)
                    }
                }
            } catch (e: Exception) {
                log("EXCEPCION: ${e.javaClass.name}: ${e.message}")
                Handler(Looper.getMainLooper()).post {
                    result.error("USB_ERROR", "${e.javaClass.simpleName}: ${e.message}", null)
                }
            }
        }.start()
    }

    // -------------------------------------------------------------------------
    // Helpers
    // -------------------------------------------------------------------------

    private fun findEpsonDevice(usbManager: UsbManager): UsbDevice? =
        usbManager.deviceList.values.firstOrNull { device ->
            device.vendorId == EPSON_VENDOR_ID ||
            (0 until device.interfaceCount).any { i ->
                device.getInterface(i).interfaceClass == UsbConstants.USB_CLASS_PRINTER
            }
        }

    private fun isUsbDeviceConnected(targetVendorId: Int, targetProductId: Int): Boolean {
        return try {
            val usbManager = getSystemService(Context.USB_SERVICE) as UsbManager
            usbManager.deviceList.values.any { device ->
                when {
                    // Sin vendor: acepta clase 7 (estándar) O vendor Epson (clase 255)
                    targetVendorId == -1 ->
                        device.vendorId == EPSON_VENDOR_ID ||
                        (0 until device.interfaceCount).any { i ->
                            device.getInterface(i).interfaceClass == UsbConstants.USB_CLASS_PRINTER
                        }
                    // Vendor específico sin producto: cualquier modelo de ese fabricante
                    targetProductId == -1 -> device.vendorId == targetVendorId
                    // Coincidencia exacta vendor + producto
                    else -> device.vendorId == targetVendorId && device.productId == targetProductId
                }
            }
        } catch (e: Exception) {
            false
        }
    }

    // Bytes ESC/POS de prueba: "Hola" + 3 saltos + corte
    private fun buildTestEscPos(): ByteArray {
        val text = "Hola desde USB Host API\n".toByteArray(Charsets.US_ASCII)
        return byteArrayOf(
            0x1B, 0x40.toByte(),                    // ESC @ — init
            0x1B, 0x61.toByte(), 0x01,              // ESC a 1 — centrar
            *text,
            0x1B, 0x64.toByte(), 0x03,              // ESC d 3 — 3 saltos
            0x1D, 0x56.toByte(), 0x42.toByte(), 0x00 // GS V B 0 — corte parcial
        )
    }

    // -------------------------------------------------------------------------
    // Channel: OTA Update (Silencioso vía Device Owner o Fallback vía Intent)
    // -------------------------------------------------------------------------

    private fun setupOtaChannel(flutterEngine: FlutterEngine) {
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, OTA_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "installApk" -> {
                        val apkPath = call.argument<String>("apkPath")
                        if (apkPath != null) {
                            installApk(apkPath)
                            result.success(true)
                        } else {
                            result.error("INVALID_ARG", "apkPath is null", null)
                        }
                    }
                    else -> result.notImplemented()
                }
            }
    }

    private fun installApk(apkPath: String) {
        val dpm = getSystemService(Context.DEVICE_POLICY_SERVICE) as DevicePolicyManager
        if (dpm.isDeviceOwnerApp(packageName)) {
            // Instalación Silenciosa Kiosco
            try {
                val packageInstaller = packageManager.packageInstaller
                val params = PackageInstaller.SessionParams(PackageInstaller.SessionParams.MODE_FULL_INSTALL)
                params.setAppPackageName(packageName)
                val sessionId = packageInstaller.createSession(params)
                val session = packageInstaller.openSession(sessionId)
                val apkFile = File(apkPath)
                val inputStream = FileInputStream(apkFile)
                val outputStream = session.openWrite("package", 0, apkFile.length())
                
                inputStream.copyTo(outputStream)
                session.fsync(outputStream)
                inputStream.close()
                outputStream.close()
                
                // Agenda un alarm ANTES de que el proceso muera: los AlarmManager
                // alarms los guarda el SO, no el proceso, así que sobreviven el kill.
                // Si en 20 s el proceso no volvió solo, este alarm lo reabre.
                val wakeIntent = Intent(this, MainActivity::class.java).apply {
                    addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                }
                val wakePI = PendingIntent.getActivity(
                    this, 9999, wakeIntent,
                    PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
                )
                (getSystemService(Context.ALARM_SERVICE) as AlarmManager).set(
                    AlarmManager.ELAPSED_REALTIME_WAKEUP,
                    SystemClock.elapsedRealtime() + 20_000L,
                    wakePI
                )

                // Creamos un PendingIntent dirigido a nuestro InstallResultReceiver
                val intent = Intent(this, InstallResultReceiver::class.java)
                val pendingIntent = PendingIntent.getBroadcast(this, 0, intent, PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
                session.commit(pendingIntent.intentSender)
                session.close()
            } catch (e: Exception) {
                log("Error en instalacion silenciosa: \${e.message}")
                fallbackInstallApk(apkPath)
            }
        } else {
            // Instalación manual Fallback
            fallbackInstallApk(apkPath)
        }
    }

    private fun fallbackInstallApk(apkPath: String) {
        try {
            val apkFile = File(apkPath)
            val uri = FileProvider.getUriForFile(this, "\$packageName.fileprovider", apkFile)
            val intent = Intent(Intent.ACTION_VIEW)
            intent.setDataAndType(uri, "application/vnd.android.package-archive")
            intent.flags = Intent.FLAG_ACTIVITY_NEW_TASK
            intent.addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            startActivity(intent)
        } catch (e: Exception) {
            log("Error en fallback install: ${e.message}")
        }
    }
}
