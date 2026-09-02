package com.coursehub.app

import android.content.Intent
import android.os.Build
import android.os.Bundle
import android.provider.Settings
import android.view.WindowManager
import android.graphics.Color
import android.util.Log
import androidx.core.view.WindowCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import kotlin.system.exitProcess

class MainActivity : FlutterActivity() {

    companion object {
        @Volatile
        var pendingWidgetRoute: String? = null

        // 上次退出（onStop/onDestroy 计划杀进程）遗留的任务；进程被复用重进时
        // 由新实例 onCreate 取消，避免延迟的 exitProcess 杀掉复用进程里的新实例
        @Volatile
        private var pendingExitTask: Runnable? = null

        // 自定义退出动画基准时长（ms），必须与 res/anim/activity_close_exit.xml
        // 的 duration 一致。把品牌默认关闭动画统一成固定时长，杀进程延迟 =
        // 该时长 × 系统动画缩放系数，从而「动画播完立即杀」。
        private const val EXIT_ANIM_BASE_MS = 300L

        // 动画结束到杀进程之间的安全缓冲（ms），吸收缩放取整与首帧启动误差
        private const val EXIT_ANIM_BUFFER_MS = 50L

        // 必须是静态单例：Handler.removeCallbacks 按「Handler 实例 + Runnable」
        // 匹配消息，实例属性会导致新 Activity 实例取消不掉旧实例发出的
        // 延迟杀进程任务（进程复用重进时 exitProcess 误杀新实例 → 闪退）
        private val mainHandler = android.os.Handler(android.os.Looper.getMainLooper())
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        // 进程复用重进（上次退出后进程未死、用户立即重开）：取消遗留的杀进程
        // 任务，防止延迟 exitProcess 误杀刚启动的新实例导致闪退
        pendingExitTask?.let {
            mainHandler.removeCallbacks(it)
            pendingExitTask = null
        }

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
        // 冷启动首次高刷写入延迟：onCreate 阶段写 preferredDisplayModeId
        // 会触发显示模式切换，与 Flutter 首帧 Surface 创建竞态，低概率
        // 首帧永不上屏（白屏死机，多见于覆盖安装/重启后首次启动）。
        // 延迟到首帧渲染窗口之后再应用；onResume 等后续调用同样等待该标志
        mainHandler.postDelayed({
            allowRateApply = true
            applyHighRefreshRateHint()
        }, 400)

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
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "coursehub/app")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "exitApp" -> {
                        // 双击返回退出：应用自绘固定时长关闭动画（统一品牌差异），
                        // finish 后 onDestroy 按「动画时长 × 缩放系数」精确延迟杀进程
                        if (!isFinishing) {
                            finish()
                            overridePendingTransition(0, R.anim.activity_close_exit)
                        }
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }
    }

    override fun onDestroy() {
        // 正常退出（双击返回 / 从最近任务划掉）后延迟终止进程：
        // - 只 finish 不杀进程：进程驻留后台缓存，卡死的渲染/解码线程会
        //   留在进程里，再次进入复用同一进程会复现白屏死机；
        // - 立即杀进程（exit(0)）：会跳过系统关闭动画（闪现回桌面）。
        //   关闭动画由 system_server 基于窗口快照驱动，不依赖应用进程
        //   存活，finish 后延迟终止两者兼得。
        // 延迟时长 = 自定义退出动画时长 × 系统动画缩放系数（computeExitDelay），
        // 兼容不同品牌动画时长差异，保证「动画播完立即杀」；进程复用重进时
        // 由新实例 onCreate 取消遗留任务兜底，避免延迟 exitProcess 误杀新实例。
        if (isFinishing) {
            val exitTask = Runnable { exitProcess(0) }
            pendingExitTask = exitTask
            mainHandler.postDelayed(exitTask, computeExitDelay())
        }
        super.onDestroy()
    }

    /**
     * 退出动画播放完立即杀进程的延迟计算。
     *
     * 动画实际时长 = 自定义退出动画基准时长 × 系统动画缩放系数
     * （TRANSITION_ANIMATION_SCALE / WINDOW_ANIMATION_SCALE，开发者选项可调）。
     * 由此精确推算出动画结束时刻，避免：
     *  - 延迟不足：系统尚未捕获窗口快照/动画未播完进程即被杀，闪现回桌面；
     *  - 延迟过长：进程存活窗口拉长，复用误杀虽由 onCreate 兜底，但越短越稳。
     * 当动画缩放 = 0（用户关闭动画）时动画瞬时完成，立即杀进程。
     */
    private fun computeExitDelay(): Long {
        for (key in arrayOf(
            Settings.Global.TRANSITION_ANIMATION_SCALE,
            Settings.Global.WINDOW_ANIMATION_SCALE
        )) {
            try {
                val scale = Settings.Global.getFloat(contentResolver, key)
                if (scale <= 0f) return 0L // 动画已关闭：瞬时完成，立即杀
                return (EXIT_ANIM_BASE_MS * scale).toLong() + EXIT_ANIM_BUFFER_MS
            } catch (e: Exception) {
                // 该键未设置时继续尝试下一个；全部失败则用基准时长
            }
        }
        return EXIT_ANIM_BASE_MS + EXIT_ANIM_BUFFER_MS
    }

    override fun onResume() {
        super.onResume()
        if (allowRateApply) applyHighRefreshRateHint()
    }

    override fun onWindowFocusChanged(hasFocus: Boolean) {
        super.onWindowFocusChanged(hasFocus)
        if (hasFocus && Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            window.setDecorFitsSystemWindows(false)
        }
        if (hasFocus && allowRateApply) {
            applyHighRefreshRateHint()
        }
    }

    /// 冷启动首帧窗口内禁止写显示模式（onCreate 延迟 400ms 后放开）
    @Volatile
    private var allowRateApply = false

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
