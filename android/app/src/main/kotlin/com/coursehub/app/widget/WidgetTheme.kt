package com.coursehub.app.widget

import android.content.Context
import android.content.Intent
import androidx.compose.ui.graphics.Color
import androidx.glance.appwidget.GlanceAppWidget
import androidx.glance.appwidget.updateAll
import androidx.glance.color.ColorProvider
import es.antonborri.home_widget.HomeWidgetGlanceWidgetReceiver
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch

/**
 * 小组件主题颜色工具
 *
 * 使用 Glance 的 ColorProvider(day, night) 自动适配日间/夜间模式
 */
object WidgetTheme {

    private val LightBg = Color(0xFFFFFFFF)
    private val DarkBg = Color(0xFF1E1E1E)
    private val LightCardBg = Color(0xFFF5F5F7)
    private val DarkCardBg = Color(0xFF2A2A2A)
    private val LightPrimary = Color(0xFF1A1A1A)
    private val DarkPrimary = Color(0xFFEEEEEE)
    private val LightSecondary = Color(0xFF888888)
    private val DarkSecondary = Color(0xFFAAAAAA)
    private val LightHint = Color(0xFFBBBBBB)
    private val DarkHint = Color(0xFF666666)
    private val LightDivider = Color(0xFFE8E8E8)
    private val DarkDivider = Color(0xFF333333)

    fun bgProvider() = ColorProvider(LightBg, DarkBg)
    fun cardProvider() = ColorProvider(LightCardBg, DarkCardBg)
    fun primaryProvider() = ColorProvider(LightPrimary, DarkPrimary)
    fun secondaryProvider() = ColorProvider(LightSecondary, DarkSecondary)
    fun hintProvider() = ColorProvider(LightHint, DarkHint)
    fun dividerProvider() = ColorProvider(LightDivider, DarkDivider)

    /** 课程颜色（固定，不随暗色模式变化） */
    fun colorProvider(color: Color) = ColorProvider(color, color)
    fun colorProvider(color: Int) = ColorProvider(Color(color), Color(color))
}

/**
 * 所有小组件 Receiver 的基类
 *
 * 继承 HomeWidgetGlanceWidgetReceiver<T>（官方推荐），保留其标准 onUpdate 逻辑。
 * 数据读取在 provideGlance 中通过 WidgetData.loadTodayDataFiltered(context) 直接从
 * SharedPreferences 读取并根据当前时间过滤，不依赖 Glance state 缓存。
 *
 * 额外处理：
 * - MY_PACKAGE_REPLACED：App 更新后系统广播此 action，触发更新 + 重新调度闹钟
 * - APPWIDGET_UPDATE：每次系统/app 触发更新时，重新调度下一次自动更新
 */
abstract class CourseHubWidgetReceiver<T : GlanceAppWidget> : HomeWidgetGlanceWidgetReceiver<T>() {

    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action == Intent.ACTION_MY_PACKAGE_REPLACED) {
            val pendingResult = goAsync()
            CoroutineScope(Dispatchers.Default).launch {
                try {
                    glanceAppWidget.updateAll(context.applicationContext)
                    WidgetUpdateScheduler.scheduleNextUpdate(context.applicationContext)
                    // 同时注册 WorkManager 周期任务作为兜底
                    WidgetUpdateWorker.enqueuePeriodic(context.applicationContext)
                } catch (e: Exception) {
                    // 忽略更新失败
                } finally {
                    pendingResult.finish()
                }
            }
        } else {
            super.onReceive(context, intent)
            // 每次 APPWIDGET_UPDATE 后重新调度自动更新
            if (intent.action == "android.appwidget.action.APPWIDGET_UPDATE") {
                WidgetUpdateScheduler.scheduleNextUpdate(context.applicationContext)
                // 注册 WorkManager 周期任务作为兜底
                WidgetUpdateWorker.enqueuePeriodic(context.applicationContext)
            }
        }
    }
}
