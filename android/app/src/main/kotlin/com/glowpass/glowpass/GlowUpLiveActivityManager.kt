package com.glowpass.glowpass

import android.app.Notification
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.widget.RemoteViews
import com.istornz.live_activities.LiveActivityManager

class GlowUpLiveActivityManager(context: Context) : LiveActivityManager(context) {
    private val appContext: Context = context.applicationContext

    private val pendingIntent: PendingIntent = PendingIntent.getActivity(
        appContext,
        9001,
        Intent(appContext, MainActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_REORDER_TO_FRONT or Intent.FLAG_ACTIVITY_SINGLE_TOP
        },
        PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
    )

    private val remoteViews: RemoteViews = RemoteViews(
        appContext.packageName,
        R.layout.glow_up_live_notification,
    )

    private fun bindRemoteViews(data: Map<String, Any>) {
        val brand = data["brand"] as? String ?: "Glow Up AI"
        val headline = data["headline"] as? String ?: "Creating your glow-up"
        val detail = data["detail"] as? String ?: ""
        val eta = data["eta"] as? String ?: ""
        val progress = when (val p = data["progress"]) {
            is Int -> p
            is Long -> p.toInt()
            is Double -> p.toInt()
            else -> 0
        }.coerceIn(0, 100)

        remoteViews.setTextViewText(R.id.glow_brand, brand)
        remoteViews.setTextViewText(R.id.glow_headline, headline)
        remoteViews.setTextViewText(R.id.glow_detail, detail)
        remoteViews.setTextViewText(R.id.glow_eta, eta)
        remoteViews.setProgressBar(R.id.glow_progress, 100, progress, false)
    }

    override suspend fun buildNotification(
        notification: Notification.Builder,
        event: String,
        data: Map<String, Any>,
    ): Notification {
        bindRemoteViews(data)

        return notification
            .setSmallIcon(R.mipmap.ic_launcher)
            .setOngoing(true)
            .setContentTitle(data["headline"] as? String ?: "Glow Up AI")
            .setContentText(data["detail"] as? String ?: "")
            .setContentIntent(pendingIntent)
            .setStyle(Notification.DecoratedCustomViewStyle())
            .setCustomContentView(remoteViews)
            .setCustomBigContentView(remoteViews)
            .setPriority(Notification.PRIORITY_LOW)
            .setCategory(Notification.CATEGORY_PROGRESS)
            .setVisibility(Notification.VISIBILITY_PUBLIC)
            .setOnlyAlertOnce(true)
            .build()
    }
}
