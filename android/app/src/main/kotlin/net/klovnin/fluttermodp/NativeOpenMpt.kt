package net.klovnin.fluttermodp

object NativeOpenMpt {
    val loadError: String? = try {
        System.loadLibrary("openmpt_bridge")
        null
    } catch (error: UnsatisfiedLinkError) {
        error.message ?: "Unknown native library loading error"
    }

    external fun nativeInitializeModule(moduleData: ByteArray): Boolean
    external fun nativeSetRepeatCount(repeatCount: Int)
    external fun nativeGetLastMessage(): String
    external fun nativeRenderPcm(frameCount: Int, sampleRate: Int): ByteArray
    external fun nativeSeekToSeconds(seconds: Double): Double
    external fun nativeGetPositionSeconds(): Double
    external fun nativeGetDurationSeconds(): Double
    external fun nativeDestroyModule()
}
