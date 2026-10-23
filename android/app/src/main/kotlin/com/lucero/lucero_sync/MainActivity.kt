package com.lucero.lucero_sync

import android.content.ClipData
import android.content.ComponentName
import android.content.Intent
import android.media.MediaScannerConnection
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.os.Handler
import android.os.Looper
import android.provider.OpenableColumns
import android.webkit.MimeTypeMap
import androidx.core.content.FileProvider
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.util.UUID
import java.util.concurrent.Executors

class MainActivity : FlutterActivity() {
    private var platformChannel: MethodChannel? = null

    /** Batches shared into the app (share sheet), waiting for Dart to take them. */
    private val sharedBatches = mutableListOf<Map<String, Any>>()
    private val copier = Executors.newSingleThreadExecutor()
    private val main = Handler(Looper.getMainLooper())

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "lucero_sync/storage")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "picturesDir" -> result.success(
                        Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_PICTURES).absolutePath
                    )
                    "downloadsDir" -> result.success(
                        Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_DOWNLOADS).absolutePath
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
                    "share" -> {
                        // False (e.g. a file outside the shareable folders) falls back to share_plus.
                        result.success(runCatching {
                            share(call.argument<List<String>>("paths") ?: emptyList(), call.argument<String>("text"))
                        }.isSuccess)
                    }
                    else -> result.notImplemented()
                }
            }

        platformChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "lucero_sync/platform").apply {
            setMethodCallHandler { call, result ->
                when (call.method) {
                    "takeSharedItems" -> {
                        val out = synchronized(sharedBatches) { sharedBatches.toList().also { sharedBatches.clear() } }
                        result.success(out)
                    }
                    "liveActivity" -> result.success(null) // iOS only
                    else -> result.notImplemented()
                }
            }
        }
        handleShare(intent)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        handleShare(intent)
    }

    /** "Lucero Sync" in Android's share sheet: copies the shared items into the cache. */
    private fun handleShare(intent: Intent?) {
        if (intent == null) return
        val action = intent.action
        if (action != Intent.ACTION_SEND && action != Intent.ACTION_SEND_MULTIPLE) return
        // Don't handle the same intent again after a rotation / re-attach.
        if (intent.getBooleanExtra(HANDLED, false)) return
        intent.putExtra(HANDLED, true)

        val uris = mutableListOf<Uri>()
        if (action == Intent.ACTION_SEND_MULTIPLE) {
            uris += intent.parcelableList(Intent.EXTRA_STREAM)
        } else {
            intent.parcelable(Intent.EXTRA_STREAM)?.let { uris += it }
        }
        val texts = mutableListOf<String>()
        if (uris.isEmpty()) {
            intent.getCharSequenceExtra(Intent.EXTRA_TEXT)?.toString()?.takeIf { it.isNotBlank() }?.let { texts += it }
        }
        if (uris.isEmpty() && texts.isEmpty()) return

        copier.execute {
            val folder = File(cacheDir, "shared/${UUID.randomUUID()}").apply { mkdirs() }
            val files = uris.mapNotNull { copyToCache(it, folder) }
            synchronized(sharedBatches) {
                sharedBatches += mapOf("files" to files, "texts" to texts, "folder" to folder.absolutePath)
            }
            main.post { platformChannel?.invokeMethod("sharedItemsChanged", null) }
        }
    }

    private fun copyToCache(uri: Uri, folder: File): String? = try {
        var name = displayName(uri) ?: uri.lastPathSegment ?: "file"
        name = name.replace(Regex("[/\\\\:\\u0000]"), "_").trim('.', ' ').ifEmpty { "file" }.take(180)
        var target = File(folder, name)
        var n = 1
        while (target.exists()) {
            val dot = name.lastIndexOf('.')
            target = if (dot > 0) File(folder, "${name.substring(0, dot)} ($n)${name.substring(dot)}") else File(folder, "$name ($n)")
            n++
        }
        contentResolver.openInputStream(uri)?.use { input ->
            target.outputStream().use { output -> input.copyTo(output, 1 shl 16) }
        }
        if (target.exists()) target.absolutePath else null
    } catch (e: Exception) {
        null
    }

    private fun displayName(uri: Uri): String? = try {
        contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)?.use { c ->
            if (c.moveToFirst()) c.getString(0) else null
        }
    } catch (e: Exception) {
        null
    }

    @Suppress("DEPRECATION")
    private fun Intent.parcelable(key: String): Uri? =
        if (Build.VERSION.SDK_INT >= 33) getParcelableExtra(key, Uri::class.java) else getParcelableExtra(key)

    @Suppress("DEPRECATION")
    private fun Intent.parcelableList(key: String): List<Uri> =
        (if (Build.VERSION.SDK_INT >= 33) getParcelableArrayListExtra(key, Uri::class.java) else getParcelableArrayListExtra(key))
            ?: emptyList()

    companion object {
        private const val HANDLED = "lucero_share_handled"
    }

    /** The system share sheet (Quick Share first), without Lucero Sync itself in it. */
    private fun share(paths: List<String>, text: String?) {
        val uris = ArrayList(paths.map { FileProvider.getUriForFile(this, "$packageName.files", File(it)) })
        val intent = Intent(if (uris.size > 1) Intent.ACTION_SEND_MULTIPLE else Intent.ACTION_SEND).apply {
            type = if (uris.isEmpty()) "text/plain" else mimeOf(paths)
            if (uris.size == 1) putExtra(Intent.EXTRA_STREAM, uris[0])
            if (uris.size > 1) putParcelableArrayListExtra(Intent.EXTRA_STREAM, uris)
            if (!text.isNullOrEmpty()) putExtra(Intent.EXTRA_TEXT, text)
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            if (uris.isNotEmpty()) clipData = ClipData.newRawUri(null, uris[0]).apply { uris.drop(1).forEach { addItem(ClipData.Item(it)) } }
        }
        val chooser = Intent.createChooser(intent, null).apply {
            putExtra(Intent.EXTRA_EXCLUDE_COMPONENTS, arrayOf(ComponentName(this@MainActivity, MainActivity::class.java)))
        }
        startActivity(chooser)
    }

    // One MIME type for all the files: exact if they agree, else the shared family (image, video…), else any.
    private fun mimeOf(paths: List<String>): String {
        val types = paths.map {
            MimeTypeMap.getSingleton().getMimeTypeFromExtension(it.substringAfterLast('.', "").lowercase()) ?: "application/octet-stream"
        }.toSet()
        if (types.size == 1) return types.first()
        val families = types.map { it.substringBefore('/') }.toSet()
        return if (families.size == 1) "${families.first()}/*" else "*/*"
    }
}
