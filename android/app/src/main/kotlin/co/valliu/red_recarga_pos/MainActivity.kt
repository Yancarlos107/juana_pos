package co.Juana.red_recarga_pos

import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.hardware.usb.UsbConstants
import android.hardware.usb.UsbDevice
import android.hardware.usb.UsbManager
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import androidx.annotation.NonNull
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors

class MainActivity : FlutterActivity() {

    private val USB_STATUS_CHANNEL = "co.Juana.usb/status"
    private val USB_EVENTS_CHANNEL = "co.Juana.usb/events"
    private val PRINTER_CHANNEL    = "co.Juana.epson_printer"
    private val ACTION_USB_PERM    = "co.Juana.USB_PERMISSION"

    // Fabricantes de impresoras térmicas externas soportadas.
    // 0x04B8 = 1208 = Seiko Epson Corp. Si se despliega otra marca, agregar su VID aquí
    // y en device_filter.xml. NO se acepta cualquier dispositivo clase 7 (impresora):
    // la impresora interna de la tablet es clase 7 y generaba falsos positivos de
    // conexión e impresiones dirigidas al dispositivo equivocado.
    private val SUPPORTED_VENDOR_IDS = setOf(0x04B8)

    // Tamaño máximo por bulkTransfer; payloads más grandes se envían troceados.
    private val MAX_CHUNK = 16384
    private val TRANSFER_TIMEOUT_MS = 8000

    // Cola de un solo hilo: dos impresiones nunca compiten por la interfaz USB.
    private val printExecutor: ExecutorService = Executors.newSingleThreadExecutor()
    private val mainHandler = Handler(Looper.getMainLooper())

    private var usbEventsSink: EventChannel.EventSink? = null

    // Impresión en espera de permiso USB: se reanuda sola cuando el usuario acepta.
    // Solo se toca desde el hilo principal (MethodChannel y broadcasts llegan ahí).
    private var pendingPrintBytes: ByteArray? = null
    private var pendingPrintResult: MethodChannel.Result? = null

    private val logFile by lazy { File(filesDir, "epson_log.txt") }
    private fun log(msg: String) {
        try {
            val ts = SimpleDateFormat("HH:mm:ss.SSS", Locale.getDefault()).format(Date())
            logFile.appendText("[$ts] $msg\n")
        } catch (_: Exception) {}
    }

    // -------------------------------------------------------------------------
    // Receivers: hot-plug USB y permiso USB
    // -------------------------------------------------------------------------

    private val usbHotplugReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent) {
            @Suppress("DEPRECATION")
            val device = intent.getParcelableExtra<UsbDevice>(UsbManager.EXTRA_DEVICE)
            when (intent.action) {
                UsbManager.ACTION_USB_DEVICE_ATTACHED -> {
                    log("USB conectado: VID=${device?.vendorId} PID=${device?.productId}")
                    usbEventsSink?.success("attached")
                }
                UsbManager.ACTION_USB_DEVICE_DETACHED -> {
                    log("USB desconectado: VID=${device?.vendorId} PID=${device?.productId}")
                    usbEventsSink?.success("detached")
                }
            }
        }
    }

    private val usbPermissionReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent) {
            if (intent.action != ACTION_USB_PERM) return
            val granted = intent.getBooleanExtra(UsbManager.EXTRA_PERMISSION_GRANTED, false)
            val bytes = pendingPrintBytes
            val result = pendingPrintResult
            pendingPrintBytes = null
            pendingPrintResult = null
            if (bytes == null || result == null) return
            if (granted) {
                log("Permiso USB concedido; reanudando impresión pendiente")
                enqueuePrint(bytes, result)
            } else {
                log("Permiso USB denegado por el usuario")
                result.error("NO_PERMISSION", "Permiso USB denegado", null)
            }
        }
    }

    // -------------------------------------------------------------------------
    // Ciclo de vida
    // -------------------------------------------------------------------------

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val hotplugFilter = IntentFilter().apply {
            addAction(UsbManager.ACTION_USB_DEVICE_ATTACHED)
            addAction(UsbManager.ACTION_USB_DEVICE_DETACHED)
        }
        registerReceiverCompat(usbHotplugReceiver, hotplugFilter)
        registerReceiverCompat(usbPermissionReceiver, IntentFilter(ACTION_USB_PERM))
    }

    override fun onDestroy() {
        try { unregisterReceiver(usbHotplugReceiver) } catch (_: Exception) {}
        try { unregisterReceiver(usbPermissionReceiver) } catch (_: Exception) {}
        printExecutor.shutdown()
        super.onDestroy()
    }

    private fun registerReceiverCompat(receiver: BroadcastReceiver, filter: IntentFilter) {
        if (Build.VERSION.SDK_INT >= 33) {
            registerReceiver(receiver, filter, Context.RECEIVER_NOT_EXPORTED)
        } else {
            registerReceiver(receiver, filter)
        }
    }

    // -------------------------------------------------------------------------
    // Flutter engine setup
    // -------------------------------------------------------------------------

    override fun configureFlutterEngine(@NonNull flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        setupUsbStatusChannel(flutterEngine)
        setupUsbEventsChannel(flutterEngine)
        setupPrinterChannel(flutterEngine)
    }

    // -------------------------------------------------------------------------
    // Channel: USB status (consulta puntual del estado físico)
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
    // Channel: eventos de conexión/desconexión USB en tiempo real
    // -------------------------------------------------------------------------

    private fun setupUsbEventsChannel(flutterEngine: FlutterEngine) {
        EventChannel(flutterEngine.dartExecutor.binaryMessenger, USB_EVENTS_CHANNEL)
            .setStreamHandler(object : EventChannel.StreamHandler {
                override fun onListen(args: Any?, events: EventChannel.EventSink?) {
                    usbEventsSink = events
                }
                override fun onCancel(args: Any?) {
                    usbEventsSink = null
                }
            })
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
                        handlePrintRequest(buildTestEscPos(), result)
                    }

                    // Impresión de bytes ESC/POS arbitrarios desde Dart (Uint8List → ByteArray)
                    "printBytes" -> {
                        val bytes = call.argument<ByteArray>("bytes")
                        if (bytes == null || bytes.isEmpty()) {
                            result.error("INVALID_ARGS", "Se requieren bytes ESC/POS", null)
                        } else {
                            handlePrintRequest(bytes, result)
                        }
                    }

                    else -> result.notImplemented()
                }
            }
    }

    // -------------------------------------------------------------------------
    // Impresión directa — Android USB Host API
    // -------------------------------------------------------------------------

    private fun handlePrintRequest(bytes: ByteArray, result: MethodChannel.Result) {
        if (logFile.length() > 200_000) logFile.writeText("")
        log("printRequest: ${bytes.size} bytes")

        val usbManager = getSystemService(Context.USB_SERVICE) as UsbManager
        val device = findPrinterDevice(usbManager)

        if (device == null) {
            val allDevices = usbManager.deviceList.values
                .joinToString { "VID=${it.vendorId} PID=${it.productId}" }
            log("ERROR: No se encontró impresora soportada. Dispositivos USB: $allDevices")
            result.error("NO_DEVICE", "No se encontró impresora USB conectada", null)
            return
        }

        log("Dispositivo: VID=${device.vendorId} PID=${device.productId} name=${device.deviceName}")

        if (!usbManager.hasPermission(device)) {
            // Si había otra impresión esperando permiso, se descarta para no fugar su Result.
            pendingPrintResult?.error("NO_PERMISSION", "Reemplazada por una impresión más reciente", null)
            pendingPrintBytes = bytes
            pendingPrintResult = result

            log("Sin permiso USB; solicitando. La impresión continuará al conceder el permiso.")
            val intent = Intent(ACTION_USB_PERM).setPackage(packageName)
            val pi = PendingIntent.getBroadcast(
                this, 0, intent,
                PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
            )
            usbManager.requestPermission(device, pi)
            return
        }

        enqueuePrint(bytes, result)
    }

    private fun enqueuePrint(bytes: ByteArray, result: MethodChannel.Result) {
        printExecutor.execute {
            try {
                val ok = doPrint(bytes)
                mainHandler.post {
                    if (ok) {
                        result.success(true)
                    } else {
                        result.error("TRANSFER_FAILED", "No se pudo enviar datos a la impresora", null)
                    }
                }
            } catch (e: Exception) {
                log("EXCEPCION: ${e.javaClass.name}: ${e.message}")
                mainHandler.post {
                    result.error("USB_ERROR", "${e.javaClass.simpleName}: ${e.message}", null)
                }
            }
        }
    }

    /// Corre en el hilo del executor. La interfaz y la conexión se liberan SIEMPRE
    /// (try/finally): si quedaban reclamadas tras un fallo, la impresora aparecía
    /// "ocupada" hasta reiniciar la app.
    private fun doPrint(bytes: ByteArray): Boolean {
        val usbManager = getSystemService(Context.USB_SERVICE) as UsbManager
        // Re-localizar el dispositivo: pudo desconectarse mientras esperaba en cola o permiso
        val device = findPrinterDevice(usbManager)
            ?: throw Exception("La impresora se desconectó antes de imprimir")
        if (!usbManager.hasPermission(device)) {
            throw Exception("Sin permiso USB sobre la impresora")
        }

        val connection = usbManager.openDevice(device)
            ?: throw Exception("openDevice() retornó null — verifica el permiso USB")

        try {
            log("Conexión USB abierta. Interfaces: ${device.interfaceCount}")
            for (i in 0 until device.interfaceCount) {
                val iface = device.getInterface(i)
                log("  Interfaz $i: clase=${iface.interfaceClass} endpoints=${iface.endpointCount}")

                if (!connection.claimInterface(iface, true)) {
                    log("  -> claimInterface($i) falló, saltando")
                    continue
                }
                try {
                    val endpoint = (0 until iface.endpointCount)
                        .map { iface.getEndpoint(it) }
                        .firstOrNull {
                            it.type == UsbConstants.USB_ENDPOINT_XFER_BULK &&
                            it.direction == UsbConstants.USB_DIR_OUT
                        }
                    if (endpoint == null) {
                        log("  -> sin endpoint bulk OUT en esta interfaz")
                        continue
                    }

                    log("  -> Endpoint bulk OUT encontrado. Enviando ${bytes.size} bytes...")
                    var offset = 0
                    while (offset < bytes.size) {
                        val len = minOf(MAX_CHUNK, bytes.size - offset)
                        val chunk = if (offset == 0 && len == bytes.size) bytes
                                    else bytes.copyOfRange(offset, offset + len)
                        val sent = connection.bulkTransfer(endpoint, chunk, len, TRANSFER_TIMEOUT_MS)
                        // Una transferencia parcial también es fallo: el ticket saldría incompleto
                        if (sent != len) {
                            log("  -> bulkTransfer falló o fue parcial: $sent de $len")
                            return false
                        }
                        offset += len
                    }
                    log("EXITO: ${bytes.size} bytes transferidos")
                    return true
                } finally {
                    connection.releaseInterface(iface)
                }
            }
            log("ERROR: ninguna interfaz con endpoint bulk OUT")
            return false
        } finally {
            connection.close()
        }
    }

    // -------------------------------------------------------------------------
    // Helpers
    // -------------------------------------------------------------------------

    private fun findPrinterDevice(usbManager: UsbManager): UsbDevice? =
        usbManager.deviceList.values.firstOrNull { it.vendorId in SUPPORTED_VENDOR_IDS }

    private fun isUsbDeviceConnected(targetVendorId: Int, targetProductId: Int): Boolean {
        return try {
            val usbManager = getSystemService(Context.USB_SERVICE) as UsbManager
            usbManager.deviceList.values.any { device ->
                when {
                    // Sin filtro: solo impresoras externas soportadas (ver SUPPORTED_VENDOR_IDS)
                    targetVendorId == -1 -> device.vendorId in SUPPORTED_VENDOR_IDS
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
}
