package com.b1101.tark.wear

import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.compose.animation.core.RepeatMode
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.tween
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.pager.HorizontalPager
import androidx.compose.foundation.pager.rememberPagerState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.Groups
import androidx.compose.material.icons.rounded.Logout
import androidx.compose.material.icons.rounded.Mic
import androidx.compose.material.icons.rounded.MicOff
import androidx.compose.material.icons.rounded.Refresh
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalLayoutDirection
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.LayoutDirection
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import kotlin.math.cos
import kotlin.math.sin

class MainActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContent { TarkWearApp() }
    }
}

private val TarkOrange = Color(0xFFFF7A32)
private val TarkOrangeDim = Color(0xFF7E3B1F)
private val TarkBackground = Color(0xFF090B0F)
private val TarkCard = Color(0xFF191E27)
private val TarkGreen = Color(0xFF59D36B)
private val TarkRed = Color(0xFFFF4E5C)
private val TarkText = Color(0xFFF4F5F7)
private val TarkMuted = Color(0xFF9AA0AA)

@Composable
private fun TarkWearApp() {
    val context = LocalContext.current
    val repository = remember { WearRoomRepository(context) }
    val room by repository.state
    val pager = rememberPagerState(pageCount = { 2 })

    DisposableEffect(repository) {
        repository.start()
        onDispose { repository.stop() }
    }

    val vazir = FontFamily(
        androidx.compose.ui.text.font.Font(
            resId = com.b1101.tark.wear.R.font.vazirmatn_regular,
            weight = FontWeight.Normal,
        ),
        androidx.compose.ui.text.font.Font(
            resId = com.b1101.tark.wear.R.font.vazirmatn_bold,
            weight = FontWeight.Bold,
        ),
    )

    CompositionLocalProvider(LocalLayoutDirection provides LayoutDirection.Rtl) {
        MaterialTheme(
            colorScheme = MaterialTheme.colorScheme.copy(
                primary = TarkOrange,
                secondary = TarkGreen,
                background = TarkBackground,
                surface = TarkCard,
                error = TarkRed,
                onBackground = TarkText,
                onSurface = TarkText,
            ),
            typography = MaterialTheme.typography.copy(
                bodyMedium = MaterialTheme.typography.bodyMedium.copy(fontFamily = vazir),
                titleMedium = MaterialTheme.typography.titleMedium.copy(fontFamily = vazir),
                labelMedium = MaterialTheme.typography.labelMedium.copy(fontFamily = vazir),
            ),
        ) {
            Box(
                modifier = Modifier
                    .fillMaxSize()
                    .background(TarkBackground),
            ) {
                StarField()
                HorizontalPager(
                    state = pager,
                    beyondViewportPageCount = 1,
                    userScrollEnabled = true,
                    modifier = Modifier.fillMaxSize(),
                ) { page ->
                    when (page) {
                        0 -> RoomControlScreen(room, repository)
                        else -> RoomStatusScreen(room, repository)
                    }
                }
                PageDots(
                    page = pager.currentPage,
                    modifier = Modifier
                        .align(Alignment.BottomCenter)
                        .padding(bottom = 8.dp),
                )
            }
        }
    }
}

@Composable
private fun RoomControlScreen(room: WearRoomState, repository: WearRoomRepository) {
    var confirmLeave by remember { mutableStateOf(false) }
    Column(
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.Center,
        modifier = Modifier
            .fillMaxSize()
            .padding(horizontal = 22.dp, vertical = 14.dp),
    ) {
        Text(
            text = "اتاق ترک",
            color = TarkText,
            fontWeight = FontWeight.Bold,
            fontSize = 15.sp,
        )
        Text(
            text = statusText(room),
            color = statusColor(room),
            fontSize = 10.sp,
            maxLines = 1,
        )
        Spacer(Modifier.height(5.dp))

        RadarControl(
            muted = room.isMuted,
            live = room.isLive,
            onClick = {
                if (room.isLive) repository.sendAction(WearRoomRepository.ACTION_TOGGLE_MUTE)
                else repository.requestState()
            },
        )

        Spacer(Modifier.height(7.dp))
        Row(
            horizontalArrangement = Arrangement.spacedBy(10.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            ActionCircle(
                label = if (room.isMuted) "باز کن" else "ساکت",
                tint = if (room.isMuted) TarkGreen else TarkText,
                onClick = { repository.sendAction(WearRoomRepository.ACTION_TOGGLE_MUTE) },
            ) {
                Icon(
                    imageVector = if (room.isMuted) Icons.Rounded.Mic else Icons.Rounded.MicOff,
                    contentDescription = null,
                    tint = if (room.isMuted) TarkGreen else TarkText,
                    modifier = Modifier.size(20.dp),
                )
            }
            ActionCircle(label = "اتصال", onClick = {
                repository.sendAction(WearRoomRepository.ACTION_RECONNECT)
            }) {
                Icon(Icons.Rounded.Refresh, null, tint = TarkOrange, modifier = Modifier.size(21.dp))
            }
            ActionCircle(label = "خروج", tint = TarkRed, onClick = { confirmLeave = true }) {
                Icon(Icons.Rounded.Logout, null, tint = TarkRed, modifier = Modifier.size(20.dp))
            }
        }
        Spacer(Modifier.height(5.dp))
        Row(verticalAlignment = Alignment.CenterVertically) {
            Icon(Icons.Rounded.Groups, null, tint = TarkMuted, modifier = Modifier.size(14.dp))
            Text(
                text = if (room.peerCount > 0) " ${room.peerCount} عضو" else " تنها هستی",
                color = TarkMuted,
                fontSize = 9.sp,
            )
        }
    }

    if (confirmLeave) {
        AlertDialog(
            onDismissRequest = { confirmLeave = false },
            title = { Text("داری میری؟", fontWeight = FontWeight.Bold) },
            text = { Text("اگه بری، ارتباطت با بچه‌های این کانال قطع میشه.") },
            confirmButton = {
                TextButton(onClick = {
                    confirmLeave = false
                    repository.sendAction(WearRoomRepository.ACTION_LEAVE)
                }) { Text("خروج", color = TarkRed) }
            },
            dismissButton = {
                TextButton(onClick = { confirmLeave = false }) { Text("بیخیال") }
            },
            containerColor = TarkCard,
            titleContentColor = TarkText,
            textContentColor = TarkMuted,
        )
    }
}

@Composable
private fun RoomStatusScreen(room: WearRoomState, repository: WearRoomRepository) {
    Column(
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.Center,
        modifier = Modifier
            .fillMaxSize()
            .padding(horizontal = 28.dp, vertical = 18.dp),
    ) {
        Text("وضعیت اتاق", color = TarkText, fontWeight = FontWeight.Bold, fontSize = 15.sp)
        Spacer(Modifier.height(8.dp))
        StatusCard(
            title = room.callsign.ifBlank { "تَرک" },
            subtitle = if (room.isMuted) "میکروفن ساکت" else "میکروفن روشن",
            accent = if (room.isMuted) TarkMuted else TarkGreen,
        )
        Spacer(Modifier.height(7.dp))
        StatusCard(
            title = if (room.talker.isNotBlank()) room.talker else "کانال آرام است",
            subtitle = if (room.talker.isNotBlank()) "در حال صحبت" else "در حال گوش دادن",
            accent = if (room.talker.isNotBlank()) TarkOrange else TarkMuted,
        )
        Spacer(Modifier.height(7.dp))
        StatusCard(
            title = "${room.peerCount} عضو",
            subtitle = room.modeLabel.ifBlank { "گوشی متصل" },
            accent = statusColor(room),
        )
        Spacer(Modifier.height(10.dp))
        ActionCircle(label = "تازه‌سازی", onClick = repository::requestState) {
            Icon(Icons.Rounded.Refresh, null, tint = TarkOrange, modifier = Modifier.size(20.dp))
        }
    }
}

@Composable
private fun RadarControl(muted: Boolean, live: Boolean, onClick: () -> Unit) {
    val pulse by rememberInfiniteTransition(label = "radar").animateFloat(
        initialValue = 0.82f,
        targetValue = 1f,
        animationSpec = infiniteRepeatable(tween(1_200), RepeatMode.Reverse),
        label = "pulse",
    )
    Box(
        contentAlignment = Alignment.Center,
        modifier = Modifier
            .size(126.dp)
            .clickable(onClick = onClick),
    ) {
        Canvas(Modifier.fillMaxSize()) {
            val center = Offset(size.width / 2f, size.height / 2f)
            val maxRadius = size.minDimension / 2f
            drawCircle(TarkOrange.copy(alpha = 0.10f), maxRadius * pulse)
            drawCircle(TarkOrange.copy(alpha = 0.30f), maxRadius * 0.92f, style = Stroke(1.dp.toPx()))
            drawCircle(TarkOrangeDim, maxRadius * 0.67f, style = Stroke(2.dp.toPx()))
            repeat(42) { i ->
                val angle = Math.toRadians(i * (360.0 / 42.0) - 90.0)
                val r = maxRadius * 0.73f
                val x = center.x + cos(angle).toFloat() * r
                val y = center.y + sin(angle).toFloat() * r
                drawCircle(TarkOrange, 1.8.dp.toPx(), Offset(x, y))
            }
            repeat(8) { i ->
                val angle = Math.toRadians(i * 45.0)
                val inner = maxRadius * 0.79f
                val outer = maxRadius * 0.9f
                drawLine(
                    TarkOrange.copy(alpha = 0.35f),
                    Offset(
                        center.x + cos(angle).toFloat() * inner,
                        center.y + sin(angle).toFloat() * inner,
                    ),
                    Offset(
                        center.x + cos(angle).toFloat() * outer,
                        center.y + sin(angle).toFloat() * outer,
                    ),
                    1.dp.toPx(),
                    StrokeCap.Round,
                )
            }
        }
        Column(horizontalAlignment = Alignment.CenterHorizontally) {
            Icon(
                imageVector = if (muted) Icons.Rounded.MicOff else Icons.Rounded.Mic,
                contentDescription = null,
                tint = if (live && !muted) TarkOrange else TarkMuted,
                modifier = Modifier.size(38.dp),
            )
            Text(
                text = when {
                    !live -> "اتاق فعال نیست"
                    muted -> "میکروفن ساکت"
                    else -> "آماده صحبت"
                },
                color = TarkText,
                fontSize = 10.sp,
                textAlign = TextAlign.Center,
            )
        }
    }
}

@Composable
private fun ActionCircle(
    label: String,
    tint: Color = TarkText,
    onClick: () -> Unit,
    icon: @Composable () -> Unit,
) {
    Column(horizontalAlignment = Alignment.CenterHorizontally) {
        Box(
            contentAlignment = Alignment.Center,
            modifier = Modifier
                .size(42.dp)
                .background(TarkCard, CircleShape)
                .border(1.dp, tint.copy(alpha = 0.45f), CircleShape)
                .clickable(onClick = onClick),
        ) { icon() }
        Text(label, color = tint, fontSize = 8.sp, maxLines = 1)
    }
}

@Composable
private fun StatusCard(title: String, subtitle: String, accent: Color) {
    Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier = Modifier
            .fillMaxWidth()
            .background(TarkCard, RoundedCornerShape(15.dp))
            .border(1.dp, accent.copy(alpha = 0.28f), RoundedCornerShape(15.dp))
            .padding(horizontal = 12.dp, vertical = 8.dp),
    ) {
        Box(Modifier.size(7.dp).background(accent, CircleShape))
        Column(Modifier.padding(start = 9.dp)) {
            Text(title, color = TarkText, fontSize = 11.sp, fontWeight = FontWeight.Bold, maxLines = 1)
            Text(subtitle, color = TarkMuted, fontSize = 8.sp, maxLines = 1)
        }
    }
}

@Composable
private fun PageDots(page: Int, modifier: Modifier = Modifier) {
    Row(horizontalArrangement = Arrangement.spacedBy(4.dp), modifier = modifier) {
        repeat(2) { index ->
            Box(
                Modifier
                    .size(if (page == index) 6.dp else 4.dp)
                    .background(if (page == index) TarkOrange else TarkMuted.copy(alpha = 0.45f), CircleShape),
            )
        }
    }
}

@Composable
private fun StarField() {
    Canvas(Modifier.fillMaxSize()) {
        val points = listOf(
            Offset(size.width * .18f, size.height * .18f),
            Offset(size.width * .82f, size.height * .22f),
            Offset(size.width * .12f, size.height * .71f),
            Offset(size.width * .76f, size.height * .78f),
        )
        points.forEach { drawCircle(TarkOrange.copy(alpha = .24f), 1.4.dp.toPx(), it) }
    }
}

private fun statusText(room: WearRoomState): String = when {
    room.isReconnecting -> "در حال اتصال مجدد"
    room.session == RoomSession.DOWN -> "ارتباط قطع است"
    room.session == RoomSession.ON_AIR -> "در حال ارسال"
    room.isLive -> room.statusLine.ifBlank { "متصل" }
    else -> "گوشی را باز کن"
}

private fun statusColor(room: WearRoomState): Color = when {
    room.isReconnecting -> TarkOrange
    room.session == RoomSession.DOWN -> TarkRed
    room.isLive -> TarkGreen
    else -> TarkMuted
}
