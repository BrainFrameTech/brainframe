package tech.brainframe.app

import android.Manifest
import android.app.Activity
import android.content.ActivityNotFoundException
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.os.storage.StorageManager
import android.provider.DocumentsContract
import android.provider.Settings
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File

/**
 * The Android side of `tech.brainframe.app/folder_access` — see
 * `lib/engram/channel_folder_access.dart` for the contract, and the sandboxed
 * folder adoption design (Decision 4) for why it is shaped this way.
 *
 * Everything here ends in a plain filesystem path, so the Dart side reaches the
 * folder with `dart:io` like on any desktop. That needs broad access: All files
 * access (`MANAGE_EXTERNAL_STORAGE`) from API 30, the storage runtime
 * permission below it. The system folder picker is used only for its answer;
 * the tree URI it returns is mapped to the path it names, and no URI grant is
 * kept.
 *
 * The activity forwards [onResume], [onActivityResult] and
 * [onRequestPermissionsResult]; each answers a call left pending when the app
 * handed over to a system screen.
 */
class FolderAccessChannel(
    private val activity: Activity,
    messenger: BinaryMessenger,
) : MethodChannel.MethodCallHandler {

    private val channel = MethodChannel(messenger, CHANNEL).also {
        it.setMethodCallHandler(this)
    }

    /** The `pick` call waiting for the folder picker to return. */
    private var pendingPick: MethodChannel.Result? = null

    /** The `requestBroadAccess` call waiting for the user's answer. */
    private var pendingAccess: MethodChannel.Result? = null

    /**
     * True while the All files access settings screen is up (API 30+). That
     * screen returns no result, so the answer is read on the way back, in
     * [onResume].
     */
    private var awaitingSettings = false

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "hasBroadAccess" -> result.success(hasBroadAccess())
            "requestBroadAccess" -> requestBroadAccess(result)
            "pick" -> pick(result)
            "resolve" -> resolve(call, result)
            else -> result.notImplemented()
        }
    }

    private fun hasBroadAccess(): Boolean =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            Environment.isExternalStorageManager()
        } else {
            activity.checkSelfPermission(Manifest.permission.WRITE_EXTERNAL_STORAGE) ==
                PackageManager.PERMISSION_GRANTED
        }

    private fun requestBroadAccess(result: MethodChannel.Result) {
        if (hasBroadAccess()) {
            result.success(true)
            return
        }
        if (pendingAccess != null) {
            result.error("busy", "Already asking for access.", null)
            return
        }
        pendingAccess = result
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            awaitingSettings = true
            try {
                // Straight to this app's own toggle where the system has it...
                activity.startActivity(
                    Intent(
                        Settings.ACTION_MANAGE_APP_ALL_FILES_ACCESS_PERMISSION,
                        Uri.parse("package:${activity.packageName}"),
                    ),
                )
            } catch (_: ActivityNotFoundException) {
                // ...and to the list of apps where it does not.
                activity.startActivity(
                    Intent(Settings.ACTION_MANAGE_ALL_FILES_ACCESS_PERMISSION),
                )
            }
        } else {
            activity.requestPermissions(
                arrayOf(
                    Manifest.permission.READ_EXTERNAL_STORAGE,
                    Manifest.permission.WRITE_EXTERNAL_STORAGE,
                ),
                PERMISSION_REQUEST,
            )
        }
    }

    private fun pick(result: MethodChannel.Result) {
        if (pendingPick != null) {
            result.error("busy", "A folder picker is already open.", null)
            return
        }
        pendingPick = result
        try {
            activity.startActivityForResult(
                Intent(Intent.ACTION_OPEN_DOCUMENT_TREE),
                PICK_REQUEST,
            )
        } catch (error: ActivityNotFoundException) {
            pendingPick = null
            result.error("noPicker", error.message, null)
        }
    }

    /**
     * A stored row is a plain path here, so resolving it only checks that the
     * app may still look: a revoked permission must read as lost access, not as
     * a deleted folder (Decision 6).
     */
    private fun resolve(call: MethodCall, result: MethodChannel.Result) {
        val path = call.argument<String>("path")
        when {
            path == null -> result.error("badArgs", "resolve needs a path.", null)
            !hasBroadAccess() ->
                result.error("accessNeeded", "Broad storage access is not granted.", null)
            else -> result.success(mapOf("path" to path))
        }
    }

    /** Answers a pending `requestBroadAccess` on return from settings. */
    fun onResume() {
        if (!awaitingSettings) return
        awaitingSettings = false
        pendingAccess?.success(hasBroadAccess())
        pendingAccess = null
    }

    /** True if [requestCode] was this channel's, and so is handled. */
    fun onRequestPermissionsResult(requestCode: Int): Boolean {
        if (requestCode != PERMISSION_REQUEST) return false
        pendingAccess?.success(hasBroadAccess())
        pendingAccess = null
        return true
    }

    /** True if [requestCode] was this channel's, and so is handled. */
    fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?): Boolean {
        if (requestCode != PICK_REQUEST) return false
        val result = pendingPick ?: return true
        pendingPick = null
        val uri = data?.data
        if (resultCode != Activity.RESULT_OK || uri == null) {
            result.success(null) // the user backed out of the picker
            return true
        }
        val path = pathOfTree(uri)
        if (path == null) {
            result.error("notLocal", "No filesystem path for $uri.", null)
        } else {
            result.success(mapOf("path" to path))
        }
        return true
    }

    /**
     * The filesystem path a picked tree URI names, or null when it names none
     * this app can reach — a folder from any provider but the device's own
     * storage (Drive, a Downloads virtual root).
     *
     * The external storage provider's document ids are `<volume>:<relative>`:
     * `primary` for the shared storage, `home` for its Documents directory,
     * and a volume's UUID for an SD card or USB drive.
     */
    private fun pathOfTree(uri: Uri): String? {
        if (uri.authority != EXTERNAL_STORAGE_AUTHORITY) return null
        val documentId = DocumentsContract.getTreeDocumentId(uri)
        val volume = documentId.substringBefore(':')
        val relative = documentId.substringAfter(':', "")
        @Suppress("DEPRECATION") // the path, not a way to write to it
        val shared = Environment.getExternalStorageDirectory()
        val base = when (volume) {
            "primary" -> shared.path
            "home" -> File(shared, Environment.DIRECTORY_DOCUMENTS).path
            else -> volumeDirectory(volume) ?: return null
        }
        return if (relative.isEmpty()) base else "$base/$relative"
    }

    /** Where the removable volume [uuid] is mounted, or null if it is not. */
    private fun volumeDirectory(uuid: String): String? {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            val storage = activity.getSystemService(StorageManager::class.java)
            return storage.storageVolumes
                .firstOrNull { it.uuid.equals(uuid, ignoreCase = true) }
                ?.directory
                ?.path
        }
        // Below API 30 there is no API for the mount point; this is where the
        // system mounts every removable volume.
        return File("/storage/$uuid").takeIf { it.isDirectory }?.path
    }

    companion object {
        const val CHANNEL = "tech.brainframe.app/folder_access"
        private const val EXTERNAL_STORAGE_AUTHORITY = "com.android.externalstorage.documents"
        private const val PICK_REQUEST = 0xB401
        private const val PERMISSION_REQUEST = 0xB402
    }
}
