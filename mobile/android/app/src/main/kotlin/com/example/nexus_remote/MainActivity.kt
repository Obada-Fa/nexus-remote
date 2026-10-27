package com.example.nexus_remote

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.os.ResultReceiver
import android.view.KeyEvent
import android.webkit.CookieManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private var pendingStart: (() -> Unit)? = null
    private var pendingResult: MethodChannel.Result? = null
    private var pendingImage: MethodChannel.Result? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "nexus_remote/tv_volume")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "pairCookie" -> {
                        try {
                            val origin = call.argument<String>("origin") ?: ""
                            TvConnection.validate(origin, "imactv=check")
                            val cookie = CookieManager.getInstance().getCookie(origin).orEmpty()
                                .split(';').map { it.trim() }.firstOrNull { it.startsWith("imactv=") }
                            result.success(cookie?.removePrefix("imactv=") ?: "")
                        } catch (_: Exception) { result.error("invalid_connection", "Check the TV address", null) }
                    }
                    "pickImage" -> {
                        if (pendingImage != null) result.success(emptyList<String>())
                        else {
                            pendingImage = result
                            try {
                                @Suppress("DEPRECATION")
                                startActivityForResult(Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
                                    addCategory(Intent.CATEGORY_OPENABLE)
                                    type = "image/*"
                                    addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                                }, 7303)
                            } catch (_: Exception) {
                                pendingImage = null
                                result.error("picker_unavailable", "Could not open the picture picker", null)
                            }
                        }
                    }
                    "status" -> result.success(TvVolumeService.status())
                    "stop" -> {
                        pendingStart = null
                        pendingResult?.error("cancelled", "TV volume controls were turned off", null)
                        pendingResult = null
                        TvVolumeService.stop(this)
                        result.success(null)
                    }
                    "start" -> {
                        if (pendingResult != null) {
                            result.error("busy", "TV volume controls are starting", null)
                            return@setMethodCallHandler
                        }
                        val origin = call.argument<String>("origin") ?: ""
                        val cookie = call.argument<String>("cookie") ?: ""
                        try {
                            TvConnection.validate(origin, cookie)
                        } catch (_: Exception) {
                            result.error("invalid_connection", "Pair with the TV first", null)
                            return@setMethodCallHandler
                        }
                        pendingResult = result
                        val launch = {
                            try {
                                val receiver = object : ResultReceiver(Handler(Looper.getMainLooper())) {
                                    override fun onReceiveResult(code: Int, data: Bundle?) {
                                        if (pendingResult !== result) return
                                        if (code == 0) pendingResult?.success(null)
                                        else pendingResult?.error("start_failed", data?.getString("error"), null)
                                        pendingResult = null
                                    }
                                }
                                startForegroundService(Intent(this, TvVolumeService::class.java)
                                    .putExtra("origin", origin).putExtra("cookie", cookie)
                                    .putExtra("receiver", receiver))
                            } catch (_: Exception) {
                                pendingResult?.error("start_failed", "Could not start TV controls. Keep Nexus Remote open and try again.", null)
                                pendingResult = null
                            }
                            Unit
                        }
                        if (Build.VERSION.SDK_INT >= 33 && checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED) {
                            pendingStart = launch
                            requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), 7301)
                        } else launch()
                    }
                    else -> result.notImplemented()
                }
            }
    }

    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode == 7301) {
            val launch = pendingStart
            pendingStart = null
            if (grantResults.firstOrNull() == PackageManager.PERMISSION_GRANTED) launch?.invoke()
            else {
                pendingResult?.error("notifications_denied", "Allow notifications to keep the TV controls and Turn off button available.", null)
                pendingResult = null
            }
        }
    }

    // The activity path works on every Nexus tab. Background/locked events are
    // routed by Android's MediaSession to the same service, never to Flutter.
    override fun dispatchKeyEvent(event: KeyEvent): Boolean {
        if (TvVolumeService.handleKey(event)) return true
        return super.dispatchKeyEvent(event)
    }

    @Suppress("DEPRECATION")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode == 7303) {
            val uri = data?.data?.toString()
            pendingImage?.success(if (resultCode == RESULT_OK && uri != null) listOf(uri) else emptyList<String>())
            pendingImage = null
        }
    }

    override fun onDestroy() {
        pendingImage?.success(emptyList<String>())
        pendingImage = null
        pendingResult?.error("cancelled", "TV controls were not started. Try again.", null)
        pendingResult = null
        pendingStart = null
        super.onDestroy()
    }
}
