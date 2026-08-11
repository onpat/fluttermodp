package net.klovnin.fluttermodp

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.FlutterInjector
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    companion object {
        private const val CHANNEL = "net.klovnin.fluttermodp/libopenmpt"
        private const val MODULE_ASSET = "assets/cavern.mod"

        private val nativeLibraryError: String? = try {
            System.loadLibrary("openmpt_bridge")
            null
        } catch (error: UnsatisfiedLinkError) {
            error.message ?: "Unknown native library loading error"
        }
    }

    private external fun nativeInitializeModule(moduleData: ByteArray): Boolean
    private external fun nativeGetLastMessage(): String

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                if (call.method != "initialize") {
                    result.notImplemented()
                    return@setMethodCallHandler
                }

                nativeLibraryError?.let { error ->
                    result.success(
                        mapOf(
                            "success" to false,
                            "message" to "Could not load the native libraries: $error",
                        ),
                    )
                    return@setMethodCallHandler
                }

                try {
                    val assetKey = FlutterInjector.instance()
                        .flutterLoader()
                        .getLookupKeyForAsset(MODULE_ASSET)
                    val moduleData = assets.open(assetKey).use { it.readBytes() }
                    val success = nativeInitializeModule(moduleData)
                    result.success(
                        mapOf(
                            "success" to success,
                            "message" to nativeGetLastMessage(),
                        ),
                    )
                } catch (error: Exception) {
                    result.success(
                        mapOf(
                            "success" to false,
                            "message" to "Could not read $MODULE_ASSET: ${error.message}",
                        ),
                    )
                }
            }
    }
}
