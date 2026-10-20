package io.github.acking_you.pocket_codex

import android.app.Activity
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.pm.PackageInstaller
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File

/**
 * Hands a verified update package to the system installer.
 *
 * The bridge has already checked the package against the signed release
 * manifest. Android then shows its own confirmation and refuses a package
 * signed with a different certificate, so nothing installs silently and a
 * substituted package cannot replace this app.
 */
class UpdateInstaller(private val activity: Activity, messenger: BinaryMessenger) {
    private val channel = MethodChannel(messenger, CHANNEL).also {
        it.setMethodCallHandler(::handle)
    }
    private val main = Handler(Looper.getMainLooper())

    fun dispose() = channel.setMethodCallHandler(null)

    private fun handle(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "canInstall" -> result.success(
                Build.VERSION.SDK_INT < Build.VERSION_CODES.O ||
                    activity.packageManager.canRequestPackageInstalls(),
            )
            "openInstallSettings" -> {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                    activity.startActivity(
                        Intent(
                            Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES,
                            Uri.parse("package:${activity.packageName}"),
                        ),
                    )
                }
                result.success(null)
            }
            "install" -> {
                val path = call.argument<String>("path")
                if (path == null) {
                    result.error("bad_arguments", "Missing package path", null)
                    return
                }
                // Copying a package into the session takes a moment; keep it
                // off the UI thread.
                Thread {
                    try {
                        install(File(path))
                        main.post { result.success(null) }
                    } catch (error: Exception) {
                        main.post { result.error("install_failed", error.message, null) }
                    }
                }.start()
            }
            else -> result.notImplemented()
        }
    }

    private fun install(file: File) {
        val installer = activity.packageManager.packageInstaller
        val params = PackageInstaller.SessionParams(
            PackageInstaller.SessionParams.MODE_FULL_INSTALL,
        ).apply { setAppPackageName(activity.packageName) }
        val sessionId = installer.createSession(params)
        installer.openSession(sessionId).use { session ->
            file.inputStream().use { input ->
                session.openWrite("update.apk", 0, file.length()).use { output ->
                    input.copyTo(output)
                    session.fsync(output)
                }
            }
            val flags = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_MUTABLE
            } else {
                PendingIntent.FLAG_UPDATE_CURRENT
            }
            val status = PendingIntent.getBroadcast(
                activity,
                sessionId,
                Intent(activity, UpdateInstallReceiver::class.java),
                flags,
            )
            session.commit(status.intentSender)
        }
    }

    private companion object {
        const val CHANNEL = "pocket_codex/updates"
    }
}

/** Shows the system's confirmation when the installer asks for it. */
class UpdateInstallReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val status = intent.getIntExtra(
            PackageInstaller.EXTRA_STATUS,
            PackageInstaller.STATUS_FAILURE,
        )
        if (status != PackageInstaller.STATUS_PENDING_USER_ACTION) return
        @Suppress("DEPRECATION")
        val confirm = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            intent.getParcelableExtra(Intent.EXTRA_INTENT, Intent::class.java)
        } else {
            intent.getParcelableExtra(Intent.EXTRA_INTENT)
        } ?: return
        context.startActivity(confirm.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
    }
}
