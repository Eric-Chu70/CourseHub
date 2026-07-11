package com.coursehub.app.widget

import android.content.Context
import android.net.Uri
import androidx.compose.runtime.Composable
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
import androidx.glance.text.TextAlign
import androidx.glance.text.TextStyle
import com.coursehub.app.MainActivity
import com.coursehub.app.R
import es.antonborri.home_widget.HomeWidgetGlanceStateDefinition
import es.antonborri.home_widget.actionStartActivity

/** 2x2 小组件：下节课/当前课程 */
class TodaySmallWidget : GlanceAppWidget() {

    override val stateDefinition = HomeWidgetGlanceStateDefinition()

    override suspend fun provideGlance(context: Context, id: GlanceId) {
        val data = WidgetData.loadTodayDataAuto(context)
        provideContent {
            Content(context, data)
        }
    }

    @Composable
    private fun Content(context: Context, data: WidgetData.TodayData) {
        val course = data.nextCourse

        Box(
            modifier = GlanceModifier
                .fillMaxSize()
                .cornerRadius(20.dp)
                .background(WidgetTheme.bgProvider())
                .clickable(actionStartActivity<MainActivity>(
                    context, Uri.parse("coursehub://widget/timetable")
                ))
        ) {
            if (course != null) {
                // 层1：标题行（顶部对齐）
                Box(
                    modifier = GlanceModifier.fillMaxSize().padding(10.dp),
                    contentAlignment = Alignment.TopStart
                ) {
                    Row(
                        modifier = GlanceModifier.fillMaxWidth(),
                        verticalAlignment = Alignment.Vertical.CenterVertically
                    ) {
                        Image(
                            provider = ImageProvider(R.drawable.ic_launcher_foreground),
                            modifier = GlanceModifier.size(14.dp),
                            contentDescription = null
                        )
                        Spacer(GlanceModifier.width(4.dp))
                        Text(
                            text = if (course.isCurrent) "正在上课" else "下节课",
                            style = TextStyle(
                                color = WidgetTheme.hintProvider(),
                                fontSize = 11.sp
                            )
                        )
                        Text(
                            text = data.label,
                            modifier = GlanceModifier.fillMaxWidth(),
                            style = TextStyle(
                                color = WidgetTheme.hintProvider(),
                                fontSize = 10.sp,
                                textAlign = TextAlign.End
                            )
                        )
                    }
                }

                // 层2：课程信息（垂直居中）
                Box(
                    modifier = GlanceModifier.fillMaxSize().padding(10.dp),
                    contentAlignment = Alignment.Center
                ) {
                    Column(
                        modifier = GlanceModifier.fillMaxWidth()
                    ) {
                        Text(
                            text = course.name,
                            style = TextStyle(
                                color = WidgetTheme.primaryProvider(),
                                fontSize = 15.sp,
                                fontWeight = FontWeight.Bold
                            ),
                            maxLines = 1
                        )
                        Spacer(GlanceModifier.height(3.dp))
                        Row(verticalAlignment = Alignment.Vertical.CenterVertically) {
                            Image(
                                provider = ImageProvider(R.drawable.widget_ic_clock),
                                modifier = GlanceModifier.size(11.dp),
                                contentDescription = null
                            )
                            Spacer(GlanceModifier.width(3.dp))
                            Text(
                                text = if (course.startTime.isNotEmpty()) "${course.startTime}-${course.endTime}" else "第${course.periodStart}-${course.periodEnd}节",
                                style = TextStyle(
                                    color = WidgetTheme.secondaryProvider(),
                                    fontSize = 11.sp
                                ),
                                maxLines = 1
                            )
                        }
                        Spacer(GlanceModifier.height(2.dp))
                        if (course.location.isNotEmpty()) {
                            Row(verticalAlignment = Alignment.Vertical.CenterVertically) {
                                Image(
                                    provider = ImageProvider(R.drawable.widget_ic_location),
                                    modifier = GlanceModifier.size(11.dp),
                                    contentDescription = null
                                )
                                Spacer(GlanceModifier.width(3.dp))
                                Text(
                                    text = course.location,
                                    style = TextStyle(
                                        color = WidgetTheme.secondaryProvider(),
                                        fontSize = 11.sp
                                    ),
                                    maxLines = 1
                                )
                            }
                        }
                        data.followingCourse?.let { following ->
                            Spacer(GlanceModifier.height(3.dp))
                            Text(
                                text = "接下来是 ${following.name}",
                                style = TextStyle(
                                    color = WidgetTheme.hintProvider(),
                                    fontSize = 10.sp
                                ),
                                maxLines = 1
                            )
                        }
                    }
                }

                // 层3：底部圆点行（底部对齐，稍微上移）
                Box(
                    modifier = GlanceModifier.fillMaxSize().padding(10.dp, 10.dp, 10.dp, 16.dp),
                    contentAlignment = Alignment.BottomCenter
                ) {
                    BottomDotsRow(data, course)
                }
            } else if (data.hasFinished) {
                // 今日已上完：保留标题栏（左侧图标 + 右侧周几第几周），中间居中提示
                // 层1：标题行（顶部对齐）
                Box(
                    modifier = GlanceModifier.fillMaxSize().padding(10.dp),
                    contentAlignment = Alignment.TopStart
                ) {
                    Row(
                        modifier = GlanceModifier.fillMaxWidth(),
                        verticalAlignment = Alignment.Vertical.CenterVertically
                    ) {
                        Image(
                            provider = ImageProvider(R.drawable.ic_launcher_foreground),
                            modifier = GlanceModifier.size(14.dp),
                            contentDescription = null
                        )
                        Text(
                            text = data.label,
                            modifier = GlanceModifier.fillMaxWidth(),
                            style = TextStyle(
                                color = WidgetTheme.hintProvider(),
                                fontSize = 10.sp,
                                textAlign = TextAlign.End
                            )
                        )
                    }
                }
                // 层2：居中提示
                Box(
                    modifier = GlanceModifier.fillMaxSize().padding(10.dp),
                    contentAlignment = Alignment.Center
                ) {
                    Text(
                        text = "今日课程已上完",
                        style = TextStyle(
                            color = WidgetTheme.secondaryProvider(),
                            fontSize = 13.sp
                        )
                    )
                }
            } else {
                // 无课程/假期：保留标题栏（左侧图标 + 右侧周几第几周），中间居中提示
                // 层1：标题行（顶部对齐）
                Box(
                    modifier = GlanceModifier.fillMaxSize().padding(10.dp),
                    contentAlignment = Alignment.TopStart
                ) {
                    Row(
                        modifier = GlanceModifier.fillMaxWidth(),
                        verticalAlignment = Alignment.Vertical.CenterVertically
                    ) {
                        Image(
                            provider = ImageProvider(R.drawable.ic_launcher_foreground),
                            modifier = GlanceModifier.size(14.dp),
                            contentDescription = null
                        )
                        Text(
                            text = data.label,
                            modifier = GlanceModifier.fillMaxWidth(),
                            style = TextStyle(
                                color = WidgetTheme.hintProvider(),
                                fontSize = 10.sp,
                                textAlign = TextAlign.End
                            )
                        )
                    }
                }
                // 层2：居中提示
                Box(
                    modifier = GlanceModifier.fillMaxSize().padding(10.dp),
                    contentAlignment = Alignment.Center
                ) {
                    Text(
                        text = when {
                            data.isHoliday -> "享受休息时光"
                            else -> "没有课程安排"
                        },
                        style = TextStyle(
                            color = WidgetTheme.secondaryProvider(),
                            fontSize = 13.sp
                        )
                    )
                }
            }
        }
    }

    /** 底部彩色圆点行：剩余节次的课程颜色圆点 + 还剩x节课 */
    @Composable
    private fun BottomDotsRow(data: WidgetData.TodayData, current: WidgetData.Course) {
        val remainingCourses = data.courses.filter { it.periodStart > current.periodStart }
        val remaining = remainingCourses.size

        Row(
            modifier = GlanceModifier.fillMaxWidth(),
            verticalAlignment = Alignment.Vertical.CenterVertically
        ) {
            if (remaining == 0) {
                Text(
                    text = "没有其它课程了",
                    modifier = GlanceModifier.fillMaxWidth(),
                    style = TextStyle(
                        color = WidgetTheme.hintProvider(),
                        fontSize = 10.sp,
                        textAlign = TextAlign.Center
                    )
                )
            } else {
                // 圆点行：每个圆点之间留间距，最后一个不加
                remainingCourses.forEachIndexed { index, c ->
                    Box(
                        modifier = GlanceModifier
                            .size(5.dp)
                            .cornerRadius(3.dp)
                            .background(WidgetTheme.colorProvider(c.color))
                    ) {}
                    if (index < remainingCourses.size - 1) {
                        Spacer(GlanceModifier.width(3.dp))
                    }
                }
                Spacer(GlanceModifier.width(6.dp))
                Text(
                    text = "还剩${remaining}节课",
                    style = TextStyle(
                        color = WidgetTheme.hintProvider(),
                        fontSize = 10.sp
                    ),
                    maxLines = 1
                )
            }
        }
    }
}

class TodaySmallWidgetReceiver : CourseHubWidgetReceiver<TodaySmallWidget>() {
    override val glanceAppWidget = TodaySmallWidget()
}
