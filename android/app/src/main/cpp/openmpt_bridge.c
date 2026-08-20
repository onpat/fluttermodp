#include <jni.h>
#include <android/log.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <libopenmpt/libopenmpt.h>

#define LOG_TAG "fluttermodp/openmpt"
#define CHANNEL_COUNT 2

static openmpt_module *g_module = NULL;
static char g_last_message[1024] = "libopenmpt has not been initialized.";
static pthread_mutex_t g_module_mutex = PTHREAD_MUTEX_INITIALIZER;

static void openmpt_log_callback(const char *message, void *user) {
    (void)user;
    if (message != NULL) {
        __android_log_print(ANDROID_LOG_INFO, LOG_TAG, "%s", message);
    }
}

static int openmpt_error_callback(int error, void *user) {
    (void)error;
    (void)user;
    return OPENMPT_ERROR_FUNC_RESULT_STORE;
}

static const char *jstring_to_utf8(JNIEnv *env, jstring str) {
    if (str == NULL) {
        return NULL;
    }
    return (*env)->GetStringUTFChars(env, str, NULL);
}

JNIEXPORT jboolean JNICALL
Java_net_klovnin_fluttermodp_NativeOpenMpt_nativeInitializeModule(
        JNIEnv *env,
        jobject activity,
        jbyteArray module_data) {
    (void)activity;

    pthread_mutex_lock(&g_module_mutex);

    if (module_data == NULL) {
        snprintf(g_last_message, sizeof(g_last_message),
                 "Initialization failed: the module asset was null.");
        pthread_mutex_unlock(&g_module_mutex);
        return JNI_FALSE;
    }

    const jsize module_size = (*env)->GetArrayLength(env, module_data);
    if (module_size <= 0) {
        snprintf(g_last_message, sizeof(g_last_message),
                 "Initialization failed: the module asset was empty.");
        pthread_mutex_unlock(&g_module_mutex);
        return JNI_FALSE;
    }

    void *bytes = malloc((size_t)module_size);
    if (bytes == NULL) {
        snprintf(g_last_message, sizeof(g_last_message),
                 "Initialization failed: could not allocate %d bytes.", module_size);
        pthread_mutex_unlock(&g_module_mutex);
        return JNI_FALSE;
    }
    (*env)->GetByteArrayRegion(env, module_data, 0, module_size, (jbyte *)bytes);
    if ((*env)->ExceptionCheck(env)) {
        free(bytes);
        snprintf(g_last_message, sizeof(g_last_message),
                 "Initialization failed: could not copy the module asset.");
        pthread_mutex_unlock(&g_module_mutex);
        return JNI_FALSE;
    }

    if (g_module != NULL) {
        openmpt_module_destroy(g_module);
        g_module = NULL;
    }

    int error = OPENMPT_ERROR_OK;
    const char *error_message = NULL;
    g_module = openmpt_module_create_from_memory2(
            bytes,
            (size_t)module_size,
            openmpt_log_callback,
            NULL,
            openmpt_error_callback,
            NULL,
            &error,
            &error_message,
            NULL);
    free(bytes);

    if (g_module == NULL) {
        snprintf(g_last_message, sizeof(g_last_message),
                 "Initialization failed (error %d): %s",
                 error,
                 error_message != NULL ? error_message : "unknown libopenmpt error");
        if (error_message != NULL) {
            openmpt_free_string(error_message);
        }
        __android_log_print(ANDROID_LOG_ERROR, LOG_TAG, "%s", g_last_message);
        pthread_mutex_unlock(&g_module_mutex);
        return JNI_FALSE;
    }
    if (error_message != NULL) {
        openmpt_free_string(error_message);
    }

    const char *version = openmpt_get_string("library_version");
    const char *title = openmpt_module_get_metadata(g_module, "title");
    const char *type = openmpt_module_get_metadata(g_module, "type_long");
    const double duration = openmpt_module_get_duration_seconds(g_module);

    snprintf(g_last_message, sizeof(g_last_message),
             "Initialization succeeded: %s loaded by %s "
             "(title: %s, size: %d bytes, duration: %.2f sec).",
             type != NULL && type[0] != '\0' ? type : "module",
             version != NULL && version[0] != '\0' ? version : "libopenmpt",
             title != NULL && title[0] != '\0' ? title : "(untitled)",
             module_size,
             duration);

    if (version != NULL) {
        openmpt_free_string(version);
    }
    if (title != NULL) {
        openmpt_free_string(title);
    }
    if (type != NULL) {
        openmpt_free_string(type);
    }

    __android_log_print(ANDROID_LOG_INFO, LOG_TAG, "%s", g_last_message);
    pthread_mutex_unlock(&g_module_mutex);
    return JNI_TRUE;
}

JNIEXPORT jstring JNICALL
Java_net_klovnin_fluttermodp_NativeOpenMpt_nativeGetLastMessage(
        JNIEnv *env,
        jobject activity) {
    (void)activity;
    pthread_mutex_lock(&g_module_mutex);
    jstring result = (*env)->NewStringUTF(env, g_last_message);
    pthread_mutex_unlock(&g_module_mutex);
    return result;
}

JNIEXPORT void JNICALL
Java_net_klovnin_fluttermodp_NativeOpenMpt_nativeSetRepeatCount(
        JNIEnv *env,
        jobject object,
        jint repeat_count) {
    (void)env;
    (void)object;

    pthread_mutex_lock(&g_module_mutex);
    if (g_module != NULL) {
        openmpt_module_set_repeat_count(g_module, repeat_count);
    }
    pthread_mutex_unlock(&g_module_mutex);
}

JNIEXPORT jboolean JNICALL
Java_net_klovnin_fluttermodp_NativeOpenMpt_nativeSetRenderParam(
        JNIEnv *env,
        jobject object,
        jint param,
        jint value) {
    (void)env;
    (void)object;

    pthread_mutex_lock(&g_module_mutex);
    int ok = 0;
    if (g_module != NULL) {
        ok = openmpt_module_set_render_param(g_module, param, value);
    }
    pthread_mutex_unlock(&g_module_mutex);
    return ok ? JNI_TRUE : JNI_FALSE;
}

JNIEXPORT jboolean JNICALL
Java_net_klovnin_fluttermodp_NativeOpenMpt_nativeSetCtlBoolean(
        JNIEnv *env,
        jobject object,
        jstring ctl,
        jboolean value) {
    (void)object;

    const char *ctl_utf8 = jstring_to_utf8(env, ctl);
    if (ctl_utf8 == NULL) {
        return JNI_FALSE;
    }

    pthread_mutex_lock(&g_module_mutex);
    int ok = 0;
    if (g_module != NULL) {
        ok = openmpt_module_ctl_set_boolean(g_module, ctl_utf8, value ? 1 : 0);
    }
    pthread_mutex_unlock(&g_module_mutex);

    (*env)->ReleaseStringUTFChars(env, ctl, ctl_utf8);
    return ok ? JNI_TRUE : JNI_FALSE;
}

JNIEXPORT jboolean JNICALL
Java_net_klovnin_fluttermodp_NativeOpenMpt_nativeSetCtlInteger(
        JNIEnv *env,
        jobject object,
        jstring ctl,
        jlong value) {
    (void)object;

    const char *ctl_utf8 = jstring_to_utf8(env, ctl);
    if (ctl_utf8 == NULL) {
        return JNI_FALSE;
    }

    pthread_mutex_lock(&g_module_mutex);
    int ok = 0;
    if (g_module != NULL) {
        ok = openmpt_module_ctl_set_integer(g_module, ctl_utf8, (int64_t)value);
    }
    pthread_mutex_unlock(&g_module_mutex);

    (*env)->ReleaseStringUTFChars(env, ctl, ctl_utf8);
    return ok ? JNI_TRUE : JNI_FALSE;
}

JNIEXPORT jboolean JNICALL
Java_net_klovnin_fluttermodp_NativeOpenMpt_nativeSetCtlFloatingPoint(
        JNIEnv *env,
        jobject object,
        jstring ctl,
        jdouble value) {
    (void)object;

    const char *ctl_utf8 = jstring_to_utf8(env, ctl);
    if (ctl_utf8 == NULL) {
        return JNI_FALSE;
    }

    pthread_mutex_lock(&g_module_mutex);
    int ok = 0;
    if (g_module != NULL) {
        ok = openmpt_module_ctl_set_floatingpoint(g_module, ctl_utf8, (double)value);
    }
    pthread_mutex_unlock(&g_module_mutex);

    (*env)->ReleaseStringUTFChars(env, ctl, ctl_utf8);
    return ok ? JNI_TRUE : JNI_FALSE;
}

JNIEXPORT jboolean JNICALL
Java_net_klovnin_fluttermodp_NativeOpenMpt_nativeSetCtlText(
        JNIEnv *env,
        jobject object,
        jstring ctl,
        jstring value) {
    (void)object;

    const char *ctl_utf8 = jstring_to_utf8(env, ctl);
    if (ctl_utf8 == NULL) {
        return JNI_FALSE;
    }
    const char *value_utf8 = jstring_to_utf8(env, value);
    if (value_utf8 == NULL) {
        (*env)->ReleaseStringUTFChars(env, ctl, ctl_utf8);
        return JNI_FALSE;
    }

    pthread_mutex_lock(&g_module_mutex);
    int ok = 0;
    if (g_module != NULL) {
        ok = openmpt_module_ctl_set_text(g_module, ctl_utf8, value_utf8);
    }
    pthread_mutex_unlock(&g_module_mutex);

    (*env)->ReleaseStringUTFChars(env, value, value_utf8);
    (*env)->ReleaseStringUTFChars(env, ctl, ctl_utf8);
    return ok ? JNI_TRUE : JNI_FALSE;
}

JNIEXPORT jbyteArray JNICALL
Java_net_klovnin_fluttermodp_NativeOpenMpt_nativeRenderPcm(
        JNIEnv *env,
        jobject activity,
        jint frame_count,
        jint sample_rate,
        jboolean float_output) {
    (void)activity;

    pthread_mutex_lock(&g_module_mutex);

    if (g_module == NULL || frame_count <= 0 || sample_rate <= 0) {
        pthread_mutex_unlock(&g_module_mutex);
        return (*env)->NewByteArray(env, 0);
    }

    const size_t sample_capacity = (size_t)frame_count * CHANNEL_COUNT;
    const size_t bytes_per_sample = float_output ? sizeof(float) : sizeof(int16_t);
    void *buffer = malloc(sample_capacity * bytes_per_sample);
    if (buffer == NULL) {
        __android_log_print(ANDROID_LOG_ERROR, LOG_TAG,
                            "PCM allocation failed for %d frames.", frame_count);
        pthread_mutex_unlock(&g_module_mutex);
        return (*env)->NewByteArray(env, 0);
    }

    size_t rendered_frames = 0;
    if (float_output) {
        rendered_frames = openmpt_module_read_interleaved_float_stereo(
                g_module,
                sample_rate,
                (size_t)frame_count,
                (float *)buffer);
    } else {
        rendered_frames = openmpt_module_read_interleaved_stereo(
                g_module,
                sample_rate,
                (size_t)frame_count,
                (int16_t *)buffer);
    }
    const size_t rendered_bytes = rendered_frames * CHANNEL_COUNT * bytes_per_sample;

    jbyteArray result = (*env)->NewByteArray(env, (jsize)rendered_bytes);
    if (result != NULL && rendered_bytes > 0) {
        (*env)->SetByteArrayRegion(
                env,
                result,
                0,
                (jsize)rendered_bytes,
                (const jbyte *)buffer);
    }
    free(buffer);

    if (rendered_frames == 0) {
        __android_log_print(ANDROID_LOG_INFO, LOG_TAG, "Playback reached the end.");
    }
    pthread_mutex_unlock(&g_module_mutex);
    return result;
}

JNIEXPORT jdouble JNICALL
Java_net_klovnin_fluttermodp_NativeOpenMpt_nativeSeekToSeconds(
        JNIEnv *env,
        jobject object,
        jdouble seconds) {
    (void)env;
    (void)object;

    pthread_mutex_lock(&g_module_mutex);
    double result = 0.0;
    if (g_module != NULL) {
        result = openmpt_module_set_position_seconds(
                g_module,
                seconds < 0.0 ? 0.0 : seconds);
    }
    pthread_mutex_unlock(&g_module_mutex);
    return result;
}

JNIEXPORT jdouble JNICALL
Java_net_klovnin_fluttermodp_NativeOpenMpt_nativeGetPositionSeconds(
        JNIEnv *env,
        jobject object) {
    (void)env;
    (void)object;

    pthread_mutex_lock(&g_module_mutex);
    const double result = g_module != NULL
            ? openmpt_module_get_position_seconds(g_module)
            : 0.0;
    pthread_mutex_unlock(&g_module_mutex);
    return result;
}

JNIEXPORT jdouble JNICALL
Java_net_klovnin_fluttermodp_NativeOpenMpt_nativeGetDurationSeconds(
        JNIEnv *env,
        jobject object) {
    (void)env;
    (void)object;

    pthread_mutex_lock(&g_module_mutex);
    const double result = g_module != NULL
            ? openmpt_module_get_duration_seconds(g_module)
            : 0.0;
    pthread_mutex_unlock(&g_module_mutex);
    return result;
}

JNIEXPORT void JNICALL
Java_net_klovnin_fluttermodp_NativeOpenMpt_nativeDestroyModule(
        JNIEnv *env,
        jobject object) {
    (void)env;
    (void)object;

    pthread_mutex_lock(&g_module_mutex);
    if (g_module != NULL) {
        openmpt_module_destroy(g_module);
        g_module = NULL;
    }
    pthread_mutex_unlock(&g_module_mutex);
}
