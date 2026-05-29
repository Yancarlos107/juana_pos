package co.Juana.red_recarga_pos

import android.app.PendingIntent
import android.content.BroadcastReceiver
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

class MainActivity : FlutterActivity() {

    private val USB_STATUS_CHANNEL = "co.Juana.usb/status"
    private val PRINTER_CHANNEL    = "co.Juana.epson_printer"
    private val ACTION_USB_PERM    = "co.Juana.USB_PERMISSION"

    // Vendor ID 0x04B8 = 1208 decimal = Seiko Epson Corp.
    private val EPSON_VENDOR_ID = 0x04B8

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
        setupUsbStatusChannel(flutterEngine)
        setupPrinterChannel(flutterEngine)
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
            log("Sin permiso USB, solicitando...")
            val pi = PendingIntent.getBroadcast(
                this, 0, Intent(ACTION_USB_PERM), PendingIntent.FLAG_IMMUTABLE
            )
            usbManager.requestPermission(device, pi)
            result.error("NO_PERMISSION", "Permiso USB solicitado. Acepta el diálogo e intenta de nuevo.", null)
            return
        }

        Thread {
            try {
                val connection = usbManager.openDevice(device)
                    ?: throw Exception("openDevice() retornó null — verifica el permiso USB")

                log("Conexión USB abierta. Interfaces: ${device.interfaceCount}")

                var transferred = -1
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
        usbManager.deviceList.values.firstOrNull { it.vendorId == EPSON_VENDOR_ID }

    private fun isUsbDeviceConnected(targetVendorId: Int, targetProductId: Int): Boolean {
        return try {
            val usbManager = getSystemService(Context.USB_SERVICE) as UsbManager
            usbManager.deviceList.values.any { device ->
                when {
                    // Sin vendor específico: busca cualquier impresora USB (clase 7) — comportamiento original
                    targetVendorId == -1 -> (0 until device.interfaceCount).any { i ->
                        device.getInterface(i).interfaceClass == UsbConstants.USB_CLASS_PRINTER
                    }
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
}
