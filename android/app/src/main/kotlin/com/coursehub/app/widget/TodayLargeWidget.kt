package com.coursehub.app.widget

import android.content.Context
import android.net.Uri
import androidx.compose.runtime.Composable
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.glance.GlanceId
import androidx.glance.GlanceModifier
import androidx.glance.Image
import androidx.glance.ImageProvider
import androidx.glance.action.clickable
import androidx.glance.appwidget.GlanceAppWidget
import androidx.glance.appwidget.cornerRadius
import androidx.glance.appwidget.lazy.LazyColumn
import androidx.glance.appwidget.provideContent
import androidx.glance.background
import androidx.glance.color.ColorProvider
import androidx.glance.layout.Alignment
import androidx.glance.layout.Box
import androidx.glance.layout.Column
import androidx.glance.layout.Row
import androidx.glance.layout.Spacer
import androidx.glance.layout.fillMaxSize
import androidx.glance.layout.fillMaxWidth
import androidx.glance.layout.height
import androidx.glance.layout.padding
import androidx.glance.layout.size
import androidx.glance.layout.width
import androidx.glance.text.FontWeight
import androidx.glance.text.Text
import androidx.glance.text.TextStyle
import com.coursehub.app.MainActivity
import com.coursehub.app.R
import es.antonborri.home_widget.HomeWidgetGlanceStateDefinition
import es.antonborri.home_widget.actionStartActivity

/** 4x4 小组件（今日课程完整列表，上完后显示明日课程） */
class TodayLargeWidget : GlanceAppWidget() {

    override val stateDefinition = HomeWidgetGlanceStateDefinition()

    override suspend fun provideGlance(context: Context, id: GlanceId) {
        val data = WidgetData.loadTodayDataAuto(context)
        provideContent {
            Content(context, data)
        }
    }

    @Composable
    private fun Content(context: Context, data: WidgetData.TodayData) {
        // 今日无课/已上完且明日有课 → 显示明日课程
        val showTomorrow = (data.hasFinished || data.courses.isEmpty()) && data.tomorrowCourses.isNotEmpty()
        val displayCourses = if (showTomorrow) data.tomorrowCourses else data.courses
        val courses = displayCourses.take(4)
        val title = when {
            showTomorrow -> "明日课程"
            data.isHoliday -> "假期中"
            else -> "今日课程"
        }
        val subtitle = when {
            data.isHoliday -> ""
            showTomorrow -> data.tomorrowLabel
            else -> data.label
        }

        // 点击 action（LazyColumn 的每个 item 都需要单独加 clickable）
        val clickAction = actionStartActivity<MainActivity>(
            context, Uri.parse("coursehub://widget/timetable")
        )

        Box(
            modifier = GlanceModifier
                .fillMaxSize()
                .cornerRadius(24.dp)
                .background(WidgetTheme.bgProvider())
                .clickable(clickAction)
        ) {
            LazyColumn(
                modifier = GlanceModifier.fillMaxSize().padding(16.dp)
            ) {
                // 标题行
                item {
                    Row(
                        modifier = GlanceModifier
                            .fillMaxWidth()
                            .clickable(clickAction),
                        verticalAlignment = Alignment.Vertical.CenterVertically
                    ) {
                        Image(
                            provider = ImageProvider(R.drawable.ic_launcher_foreground),
                            modifier = GlanceModifier.size(18.dp),
                            contentDescription = null
                        )
                        Spacer(GlanceModifier.width(6.dp))
                        Text(
                            text = title,
                            style = TextStyle(
                                color = WidgetTheme.primaryProvider(),
                                fontSize = 18.sp,
                                fontWeight = FontWeight.Bold
                            )
                        )
                        if (subtitle.isNotEmpty()) {
                            Spacer(GlanceModifier.width(8.dp))
                            Text(
                                text = subtitle,
                                style = TextStyle(
                                    color = WidgetTheme.hintProvider(),
                                    fontSize = 13.sp
                                )
                            )
                        }
                    }
                }
                // 分隔线
                item {
                    Column(
                        modifier = GlanceModifier.clickable(clickAction)
                    ) {
                        Spacer(GlanceModifier.height(4.dp))
                        Box(
                            modifier = GlanceModifier
                                .fillMaxWidth()
                                .height(1.dp)
                                .background(WidgetTheme.dividerProvider())
                        ) {}
                        Spacer(GlanceModifier.height(8.dp))
                    }
                }

                if (courses.isEmpty()) {
                    // 空状态：居中显示（去掉重复的周次副标题，标题栏已有）
                    item {
                        Box(
                            modifier = GlanceModifier
                                .fillMaxWidth()
                                .height(220.dp)
                                .clickable(clickAction),
                            contentAlignment = Alignment.Center
                        ) {
                            Text(
                                text = when {
                                    data.isHoliday -> "享受休息时光"
                                    data.hasFinished -> "今日课程已上完"
                                    else -> "今日无课"
                                },
                                style = TextStyle(
                                    color = WidgetTheme.primaryProvider(),
                                    fontSize = 16.sp,
                                    fontWeight = FontWeight.Medium
                                )
                            )
                        }
                    }
                } else {
                    // 课程列表
                    courses.forEach { course ->
                        item {
                            Column(
                                modifier = GlanceModifier.clickable(clickAction)
                            ) {
                                CourseCard(course)
                                Spacer(GlanceModifier.height(10.dp))
                            }
                        }
                    }
                    // "还有x节课"提示
                    if (displayCourses.size > 4) {
                        item {
                            Text(
                                text = "还有 ${displayCourses.size - 4} 节课…",
                                modifier = GlanceModifier.clickable(clickAction),
                                style = TextStyle(
                                    color = WidgetTheme.hintProvider(),
                                    fontSize = 12.sp
                                )
                            )
                        }
                    }
                }
            }
        }
    }

    @Composable
    private fun CourseCard(course: WidgetData.Course) {
        Row(
            modifier = GlanceModifier
                .fillMaxWidth()
                .cornerRadius(12.dp)
                .background(WidgetTheme.cardProvider())
                .padding(10.dp),
            verticalAlignment = Alignment.Vertical.CenterVertically
        ) {
            Box(
                modifier = GlanceModifier
                    .width(4.dp)
                    .height(36.dp)
                    .cornerRadius(2.dp)
                    .background(WidgetTheme.colorProvider(course.color))
            ) {}
            Spacer(GlanceModifier.width(8.dp))
            Column(modifier = GlanceModifier.fillMaxWidth()) {
                Row(
                    modifier = GlanceModifier.fillMaxWidth(),
                    verticalAlignment = Alignment.Vertical.CenterVertically
                ) {
                    Text(
                        text = course.name,
                        style = TextStyle(
                            color = WidgetTheme.primaryProvider(),
                            fontSize = 15.sp,
                            fontWeight = FontWeight.Medium
                        ),
                        maxLines = 1
                    )
                    // 当前上课中：显示"xx分钟后下课"
                    if (course.isCurrent && course.endTime.isNotEmpty() && course.endTime != "00:00") {
                        val remainingMin = WidgetData.timeToMinutes(course.endTime) - WidgetData.getCurrentMinutes()
                        if (remainingMin > 0) {
                            Spacer(GlanceModifier.width(6.dp))
                            Text(
                                text = "${remainingMin}分钟后下课",
                                style = TextStyle(
                                    color = ColorProvider(Color(0xFF2196F3), Color(0xFF64B5F6)),
                                    fontSize = 11.sp
                                ),
                                maxLines = 1
                            )
                        }
                    }
                }
                Spacer(GlanceModifier.height(2.dp))
                Text(
                    text = buildString {
                        if (course.location.isNotEmpty()) append(course.location)
                        if (course.teacher.isNotEmpty()) {
                            if (isNotEmpty()) append(" · ")
                            append(course.teacher)
                        }
                        if (course.startTime.isNotEmpty()) {
                            if (isNotEmpty()) append(" · ")
                            append("${course.startTime}-${course.endTime}")
                        }
                    },
                    style = TextStyle(
                        color = WidgetTheme.secondaryProvider(),
                        fontSize = 12.sp
                    ),
                    maxLines = 1
                )
            }
        }
    }
}

class TodayLargeWidgetReceiver : CourseHubWidgetReceiver<TodayLargeWidget>() {
    override val glanceAppWidget = TodayLargeWidget()
}
