package com.lucero.lucero_sync

import android.media.MediaScannerConnection
import android.os.Build
import android.os.Environment
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "lucero_sync/storage")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "picturesDir" -> result.success(
                        Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_PICTURES).absolutePath
                    )
                    "hasAllFilesAccess" -> result.success(
                        Build.VERSION.SDK_INT < Build.VERSION_CODES.R || Environment.isExternalStorageManager()
                    )
                    "scanFile" -> {
                        val path = call.argument<String>("path")
                        if (path == null) {
                            result.error("ARG", "path required", null)
                        } else {
                            MediaScannerConnection.scanFile(this, arrayOf(path), null, null)
                            result.success(null)
                        }
                    }
                    else -> result.notImplemented()
                }
            }
    }
}
