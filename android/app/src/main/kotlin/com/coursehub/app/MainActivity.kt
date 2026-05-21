package com.coursehub.app

import android.os.Build
import android.os.Bundle
import android.view.WindowManager
import android.graphics.Color
import android.util.Log
import androidx.core.view.WindowCompat
import io.flutter.embedding.android.FlutterActivity

class MainActivity : FlutterActivity() {
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
                    attrs.preferredDisplayModeId = bestMode.modeId
                    attrs.preferredRefreshRate = bestMode.refreshRate
                    window.attributes = attrs
                    Log.d("MainActivity", "Requested refresh mode=${bestMode.modeId}, rate=${bestMode.refreshRate}")
                    return
                }
            }

            attrs.preferredRefreshRate = 0f
            window.attributes = attrs
        } catch (e: Exception) {
            Log.w("MainActivity", "applyHighRefreshRateHint failed", e)
        }
    }
    
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
