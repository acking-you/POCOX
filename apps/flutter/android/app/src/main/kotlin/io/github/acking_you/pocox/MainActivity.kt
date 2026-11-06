package io.github.acking_you.pocox

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine

class MainActivity : FlutterActivity() {
    private var updateInstaller: UpdateInstaller? = null
    private var deviceStore: DeviceStoreChannel? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        updateInstaller = UpdateInstaller(this, flutterEngine.dartExecutor.binaryMessenger)
        // A new engine runs main() again, which installs this channel as the pairing
        // engine's store and replaces one an old engine left unanswered.
        deviceStore = DeviceStoreChannel(this, flutterEngine.dartExecutor.binaryMessenger)
    }

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        updateInstaller?.dispose()
        updateInstaller = null
        deviceStore?.dispose()
        deviceStore = null
        super.cleanUpFlutterEngine(flutterEngine)
    }
}
