package com.xctraining.xc_training_app

import android.content.Intent
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterFragmentActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "com.xctraining/health_perms"
        ).setMethodCallHandler { call, result ->
            if (call.method == "openHealthConnectPermissions") {
                // Not resolvable on Android 13 and below, or where Health Connect
                // is absent — fail soft so the Dart side can show guidance instead
                // of crashing on an unhandled ActivityNotFoundException.
                try {
                    val intent = Intent("android.health.connect.action.MANAGE_HEALTH_PERMISSIONS")
                    intent.putExtra(Intent.EXTRA_PACKAGE_NAME, packageName)
                    startActivity(intent)
                    result.success(true)
                } catch (e: Exception) {
                    result.success(false)
                }
            } else {
                result.notImplemented()
            }
        }
    }
}
