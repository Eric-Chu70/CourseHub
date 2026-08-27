package com.coursehub.app

import android.content.Intent
import android.os.Build
import android.os.Bundle
import android.view.WindowManager
import android.graphics.Color
import android.util.Log
import androidx.core.view.WindowCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {

    companion object {
        @Volatile
        var pendingWidgetRoute: String? = null
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        window.statusBarColor = Color.TRANSPARENT
        window.navigationBarColor = Color.TRANSPARENT

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            window.setDecorFitsSystemWindows(false)
        }

        val windowInsetsController = WindowCompat.getInsetsController(window, window.decorView)
        windowInsetsController.isAppearanceLightStatusBars = true
        windowInsetsController.isAppearanceLightNavigationBars = true

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            window.attributes.layoutInDisplayCutoutMode =
                WindowManager.LayoutParams.LAYOUT_IN_DISPLAY_CUTOUT_MODE_SHORT_EDGES
        }

        setMiuiStatusBarLightMode(true)
        applyHighRefreshRateHint()

        intent?.dataString?.let { pendingWidgetRoute = it }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        intent.dataString?.let { pendingWidgetRoute = it }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "coursehub/widget")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "getWidgetRoute" -> {
                        result.success(pendingWidgetRoute)
                        pendingWidgetRoute = null
                    }
                    else -> result.notImplemented()
                }
            }
    }

    override fun onResume() {
        super.onResume()
        applyHighRefreshRateHint()
    }
    
    override fun onWindowFocusChanged(hasFocus: Boolean) {
        super.onWindowFocusChanged(hasFocus)
        if (hasFocus && Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            window.setDecorFitsSystemWindows(false)
        }
        if (hasFocus) {
            applyHighRefreshRateHint()
        }
    }

    private fun applyHighRefreshRateHint() {
        try {
            val attrs = window.attributes

            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                val activeDisplay = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                    display
                } else {
                    @Suppress("DEPRECATION")
                    windowManager.defaultDisplay
                }

                val bestMode = activeDisplay?.supportedModes?.maxByOrNull { it.refreshRate }
                if (bestMode != null) {
                    // 去抖：模式未变化时跳过写入。每次 onResume/onWindowFocusChanged
                    // 都无条件写 window.attributes 会触发窗口重排/显示模式切换，
                    // 与长后台恢复时 Flutter Surface 重建竞态可致光栅线程死等
                    // （白屏/画面冻结）。仅在目标模式与已应用值不同时写一次
                    if (bestMode.modeId == lastAppliedModeId &&
                        attrs.preferredDisplayModeId == bestMode.modeId
                    ) return
                    attrs.preferredDisplayModeId = bestMode.modeId
                    attrs.preferredRefreshRate = bestMode.refreshRate
                    window.attributes = attrs
                    lastAppliedModeId = bestMode.modeId
                    Log.d("MainActivity", "Requested refresh mode=${bestMode.modeId}, rate=${bestMode.refreshRate}")
                    return
                }
            }

            attrs.preferredRefreshRate = 0f
            window.attributes = attrs
            lastAppliedModeId = -1
        } catch (e: Exception) {
            Log.w("MainActivity", "applyHighRefreshRateHint failed", e)
        }
    }

    private var lastAppliedModeId = -1
    
    private fun setMiuiStatusBarLightMode(lightMode: Boolean) {
        try {
            val clazz = Class.forName("android.view.MiuiWindowManager\$LayoutParams")
            val field = clazz.getField("EXTRA_FLAG_STATUS_BAR_TRANSPARENT")
            val value = field.getInt(null)
            
            val layoutParams = window.attributes.javaClass
            val extraFlagField = layoutParams.getMethod(
                "setExtraFlags",
                Int::class.java,
                Int::class.java
            )
            
            if (lightMode) {
                extraFlagField.invoke(window.attributes, value, value)
            } else {
                extraFlagField.invoke(window.attributes, 0, value)
            }
            
            val darkModeFlag = clazz.getField("EXTRA_FLAG_STATUS_BAR_DARK_MODE")
            val darkModeValue = darkModeFlag.getInt(null)
            
            if (lightMode) {
                extraFlagField.invoke(window.attributes, darkModeValue, darkModeValue)
            } else {
                extraFlagField.invoke(window.attributes, 0, darkModeValue)
            }
            
            window.attributes = window.attributes
        } catch (e: Exception) {
            e.printStackTrace()
        }
    }
}
