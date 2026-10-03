package tech.brainframe.app

import android.content.Context
import android.os.Build
import android.provider.Settings
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * The Android side of `tech.brainframe.app/device` — see
 * `lib/engram/device_name.dart` for the contract. One method, `name`: what
 * this phone is called, the last fallback for the device's name in an engram
 * (the device names design, Decision 1).
 *
 * The name the user gave the phone in Settings › About phone is
 * `Settings.Global.DEVICE_NAME`, readable without any permission since
 * Android 7.1 (API 25). Before that, or if it is blank, the model.
 */
class DeviceNameChannel(
    private val context: Context,
    messenger: BinaryMessenger,
) : MethodChannel.MethodCallHandler {
    init {
        MethodChannel(messenger, CHANNEL).setMethodCallHandler(this)
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "name" -> result.success(name())
            else -> result.notImplemented()
        }
    }

    private fun name(): String {
        val given = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N_MR1) {
            Settings.Global.getString(context.contentResolver, Settings.Global.DEVICE_NAME)
        } else {
            null
        }
        return given?.takeIf { it.isNotBlank() } ?: Build.MODEL
    }

    companion object {
        const val CHANNEL = "tech.brainframe.app/device"
    }
}
