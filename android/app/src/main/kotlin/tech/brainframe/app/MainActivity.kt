package tech.brainframe.app

import android.content.Intent
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine

class MainActivity : FlutterActivity() {
    /** Picking and reaching folders outside the app's own storage. */
    private var folderAccess: FolderAccessChannel? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        folderAccess = FolderAccessChannel(this, flutterEngine.dartExecutor.binaryMessenger)
    }

    override fun onResume() {
        super.onResume()
        folderAccess?.onResume()
    }

    @Suppress("OVERRIDE_DEPRECATION") // FlutterActivity is a plain Activity
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        if (folderAccess?.onActivityResult(requestCode, resultCode, data) == true) return
        super.onActivityResult(requestCode, resultCode, data)
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ) {
        if (folderAccess?.onRequestPermissionsResult(requestCode) == true) return
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
    }
}
