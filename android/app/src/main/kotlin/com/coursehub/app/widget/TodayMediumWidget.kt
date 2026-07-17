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

/** 4x2 小组件：今日课程列表（卡片式） */
class TodayMediumWidget : GlanceAppWidget() {

    override val stateDefinition = HomeWidgetGlanceStateDefinition()

    override suspend fun provideGlance(context: Context, id: GlanceId) {
        val data = WidgetData.loadTodayDataAuto(context)
        provideContent {
            Content(context, data)
        }
    }

    @Composable
    private fun Content(context: Context, data: WidgetData.TodayData) {
        val courses = data.courses.take(2)
        Box(
            modifier = GlanceModifier
                .fillMaxSize()
                .cornerRadius(20.dp)
                .background(WidgetTheme.bgProvider())
                .clickable(actionStartActivity<MainActivity>(
                    context, Uri.parse("coursehub://widget/timetable")
                ))
        ) {
            Column(
                modifier = GlanceModifier.fillMaxSize().padding(12.dp, 10.dp, 12.dp, 12.dp),
                horizontalAlignment = Alignment.Horizontal.Start
            ) {
                Row(
                    modifier = GlanceModifier.fillMaxWidth(),
                    verticalAlignment = Alignment.Vertical.CenterVertically
                ) {
                    Image(
                        provider = ImageProvider(R.drawable.ic_launcher_foreground),
                        modifier = GlanceModifier.size(16.dp),
                        contentDescription = null
                    )
                    Spacer(GlanceModifier.width(6.dp))
                    Text(
                        text = if (data.isHoliday) "假期中" else "今日课程",
                        style = TextStyle(
                            color = WidgetTheme.primaryProvider(),
                            fontSize = 16.sp,
                            fontWeight = FontWeight.Bold
                        )
                    )
                    Spacer(GlanceModifier.width(8.dp))
                    if (!data.isHoliday) {
                        Text(
                            text = data.label,
                            style = TextStyle(
                                color = WidgetTheme.hintProvider(),
                                fontSize = 12.sp
                            )
                        )
                    }
                }
                Spacer(GlanceModifier.height(4.dp))

                if (courses.isEmpty()) {
                    // 无课程：居中显示
                    Box(
                        modifier = GlanceModifier.fillMaxSize(),
                        contentAlignment = Alignment.Center
                    ) {
                        Text(
                            text = when {
                                data.isHoliday -> "享受休息时光"
                                data.hasFinished -> "今日课程已上完"
                                else -> "今日无课"
                            },
                            style = TextStyle(
                                color = WidgetTheme.hintProvider(),
                                fontSize = 14.sp
                            )
                        )
                    }
                } else {
                    courses.forEachIndexed { index, course ->
                        CourseCard(course)
                        // 最后一张卡片后不加间距
                        if (index < courses.size - 1) {
                            Spacer(GlanceModifier.height(4.dp))
                        }
                    }
                    if (data.courses.size > 2) {
                        Spacer(GlanceModifier.height(4.dp))
                        Text(
                            text = "还有 ${data.courses.size - 2} 节课…",
                            style = TextStyle(
                                color = WidgetTheme.hintProvider(),
                                fontSize = 11.sp
                            )
                        )
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
                .cornerRadius(10.dp)
                .background(WidgetTheme.cardProvider())
                .padding(7.dp),
            verticalAlignment = Alignment.Vertical.CenterVertically
        ) {
            Box(
                modifier = GlanceModifier
                    .width(4.dp)
                    .height(26.dp)
                    .cornerRadius(2.dp)
                    .background(WidgetTheme.colorProvider(course.color))
            ) {}
            Spacer(GlanceModifier.width(7.dp))
            Column(
                modifier = GlanceModifier.fillMaxWidth(),
                horizontalAlignment = Alignment.Horizontal.Start
            ) {
                Row(
                    modifier = GlanceModifier.fillMaxWidth(),
                    verticalAlignment = Alignment.Vertical.CenterVertically
                ) {
                    Text(
                        text = course.name,
                        style = TextStyle(
                            color = WidgetTheme.primaryProvider(),
                            fontSize = 13.sp,
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
                                    fontSize = 10.sp
                                ),
                                maxLines = 1
                            )
                        }
                    }
                }
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
                        fontSize = 11.sp
                    ),
                    maxLines = 1
                )
            }
        }
    }
}

class TodayMediumWidgetReceiver : CourseHubWidgetReceiver<TodayMediumWidget>() {
    override val glanceAppWidget = TodayMediumWidget()
}
