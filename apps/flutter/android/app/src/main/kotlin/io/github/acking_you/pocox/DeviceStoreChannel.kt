package io.github.acking_you.pocox

import android.content.Context
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import android.util.Log
import com.google.android.gms.auth.blockstore.Blockstore
import com.google.android.gms.auth.blockstore.RetrieveBytesRequest
import com.google.android.gms.auth.blockstore.StoreBytesData
import com.google.android.gms.common.ConnectionResult
import com.google.android.gms.common.GoogleApiAvailability
import com.google.android.gms.tasks.Tasks
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.FileOutputStream
import java.io.IOException
import java.security.MessageDigest
import java.util.UUID
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import org.json.JSONObject

/**
 * The pairing device store's bytes, for the Rust engine (`pairingInstallNativeStore`).
 *
 * The record lives in the app's `no_backup` directory, which neither cloud backup nor
 * device transfer copies. A copy also goes to Block Store, local only, so a reinstall can
 * find it where Play services keeps Block Store data. Block Store also travels in a
 * device-to-device restore, so its copy carries a hash of this device's ANDROID_ID and is
 * ignored anywhere else. Block Store is best effort: without Play services, or when it
 * fails, the file is all there is.
 *
 * Records and slot names are opaque, and neither is ever logged: a record holds the
 * device secret.
 */
class DeviceStoreChannel(context: Context, messenger: BinaryMessenger) :
    MethodChannel.MethodCallHandler {
    private val context = context.applicationContext
    private val channel = MethodChannel(messenger, "pocox/device_store")
    private val io: ExecutorService = Executors.newSingleThreadExecutor()
    private val main = Handler(Looper.getMainLooper())

    init {
        channel.setMethodCallHandler(this)
    }

    fun dispose() {
        channel.setMethodCallHandler(null)
        io.shutdown()
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "lockDir" -> result.success(storeDir().absolutePath)
            "hardwareId" -> result.success(androidId())
            "read" -> {
                val slot = call.argument<String>("slot")
                if (slot == null || !SLOT.matches(slot)) {
                    result.success(mapOf("error" to "not a device store slot"))
                    return
                }
                io.execute { answer(result) { read(slot) } }
            }
            "write" -> {
                val slot = call.argument<String>("slot")
                val value = call.argument<String>("value")
                if (slot == null || value == null || !SLOT.matches(slot)) {
                    result.success("not a device store record")
                    return
                }
                io.execute {
                    val failure = try {
                        writeFile(slot, value)
                        null
                    } catch (error: Exception) {
                        error.javaClass.simpleName + ": " + (error.message ?: "")
                    }
                    main.post { result.success(failure) }
                    if (failure == null) {
                        saveToBlockStore(slot, value)
                    }
                }
            }
            else -> result.notImplemented()
        }
    }

    private fun answer(result: MethodChannel.Result, work: () -> Map<String, String?>) {
        val reply = try {
            work()
        } catch (error: Exception) {
            mapOf("error" to (error.javaClass.simpleName + ": " + (error.message ?: "")))
        }
        main.post { result.success(reply) }
    }

    private fun storeDir(): File =
        File(context.noBackupFilesDir, "device-store").apply { mkdirs() }

    private fun recordFile(slot: String) = File(storeDir(), "$slot.json")

    /** The record, or Block Store's copy when this device's own file is gone. */
    private fun read(slot: String): Map<String, String?> {
        val file = recordFile(slot)
        if (file.exists()) {
            return mapOf("value" to file.readText(Charsets.UTF_8))
        }
        val restored = readFromBlockStore(slot) ?: return mapOf("value" to null)
        // Back where it belongs. A failure here leaves the next read to try again.
        try {
            writeFile(slot, restored)
        } catch (_: Exception) {
        }
        return mapOf("value" to restored)
    }

    /** Replace the record and return only once it is on disk. */
    private fun writeFile(slot: String, value: String) {
        val dir = storeDir()
        val pending = File(dir, ".$slot.${UUID.randomUUID()}.tmp")
        try {
            FileOutputStream(pending).use { out ->
                out.write(value.toByteArray(Charsets.UTF_8))
                out.fd.sync()
            }
            if (!pending.renameTo(recordFile(slot))) {
                throw IOException("the device store could not be replaced")
            }
        } finally {
            pending.delete()
        }
    }

    private fun blockStoreAvailable(): Boolean =
        GoogleApiAvailability.getInstance().isGooglePlayServicesAvailable(context) ==
            ConnectionResult.SUCCESS

    private fun saveToBlockStore(slot: String, value: String) {
        val hardware = hardwareHash() ?: return
        if (!blockStoreAvailable()) return
        val bytes = JSONObject()
            .put("v", 1)
            .put("hw", hardware)
            .put("record", value)
            .toString()
            .toByteArray(Charsets.UTF_8)
        if (bytes.size > BLOCK_STORE_LIMIT) return
        try {
            val data = StoreBytesData.Builder()
                .setKey(KEY_PREFIX + slot)
                .setBytes(bytes)
                .setShouldBackupToCloud(false)
                .build()
            Tasks.await(Blockstore.getClient(context).storeBytes(data), WAIT_SECONDS, TimeUnit.SECONDS)
        } catch (error: Exception) {
            Log.w(TAG, "Block Store kept no copy: " + error.javaClass.simpleName)
        }
    }

    /** Block Store's copy, only if it was written on this very device. */
    private fun readFromBlockStore(slot: String): String? {
        val hardware = hardwareHash() ?: return null
        if (!blockStoreAvailable()) return null
        return try {
            val key = KEY_PREFIX + slot
            val request = RetrieveBytesRequest.Builder().setKeys(listOf(key)).build()
            val response = Tasks.await(
                Blockstore.getClient(context).retrieveBytes(request),
                WAIT_SECONDS,
                TimeUnit.SECONDS,
            )
            val bytes = response.blockstoreDataMap[key]?.bytes ?: return null
            val copy = JSONObject(String(bytes, Charsets.UTF_8))
            if (copy.optInt("v") != 1 || copy.optString("hw") != hardware) {
                // Another device's, carried here by a transfer.
                return null
            }
            copy.optString("record").takeIf { it.isNotEmpty() }
        } catch (error: Exception) {
            Log.w(TAG, "Block Store was not read: " + error.javaClass.simpleName)
            null
        }
    }

    /**
     * This app's ANDROID_ID, which Android 8 and later scope to the signing key, user and
     * device. Read only when the user just confirmed an action that sends a hint.
     */
    private fun androidId(): String? {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return null
        return Settings.Secure.getString(context.contentResolver, Settings.Secure.ANDROID_ID)
    }

    private fun hardwareHash(): String? {
        val id = androidId()?.takeIf { it.isNotBlank() } ?: return null
        val digest = MessageDigest.getInstance("SHA-256")
            .digest("pocox.block-store.v1:$id".toByteArray(Charsets.UTF_8))
        return digest.joinToString("") { "%02x".format(it) }
    }

    private companion object {
        const val TAG = "PocoxDeviceStore"
        const val KEY_PREFIX = "pocox-device-"
        const val WAIT_SECONDS = 10L
        // Block Store's limit per entry.
        const val BLOCK_STORE_LIMIT = 4096
        val SLOT = Regex("^[0-9a-f]{1,64}$")
    }
}
