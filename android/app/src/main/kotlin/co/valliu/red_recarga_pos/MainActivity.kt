package co.Juana.red_recarga_pos

import android.content.Context
import android.hardware.usb.UsbConstants
import android.hardware.usb.UsbManager
import androidx.annotation.NonNull
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity: FlutterActivity() {
    private val CHANNEL = "co.Juana.usb/status"

    override fun configureFlutterEngine(@NonNull flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL).setMethodCallHandler { call, result ->
            if (call.method == "isUsbDeviceConnected") {
                val vendorId = call.argument<Int>("vendorId")
                val productId = call.argument<Int>("productId")
                if (vendorId != null && productId != null) {
                    result.success(checkUsbDeviceConnected(vendorId, productId))
                } else {
                    result.success(false)
                }
            } else {
                result.notImplemented()
            }
        }
    }

    private fun checkUsbDeviceConnected(targetVendorId: Int, targetProductId: Int): Boolean {
        try {
            val usbManager = getSystemService(Context.USB_SERVICE) as UsbManager
            val deviceList = usbManager.deviceList
            for (device in deviceList.values) {
                if (device.vendorId == targetVendorId && device.productId == targetProductId) {
                    return true
                }
            }
        } catch (e: Exception) {
            e.printStackTrace()
        }
        return false
    }
}
