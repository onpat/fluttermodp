#include <jni.h>
#include <android/log.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <libopenmpt/libopenmpt.h>

#define LOG_TAG "fluttermodp/openmpt"

static openmpt_module *g_module = NULL;
static char g_last_message[1024] = "libopenmpt has not been initialized.";

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

JNIEXPORT jboolean JNICALL
Java_net_klovnin_fluttermodp_MainActivity_nativeInitializeModule(
        JNIEnv *env,
        jobject activity,
        jbyteArray module_data) {
    (void)activity;

    if (module_data == NULL) {
        snprintf(g_last_message, sizeof(g_last_message),
                 "Initialization failed: the module asset was null.");
        return JNI_FALSE;
    }

    const jsize module_size = (*env)->GetArrayLength(env, module_data);
    if (module_size <= 0) {
        snprintf(g_last_message, sizeof(g_last_message),
                 "Initialization failed: the module asset was empty.");
        return JNI_FALSE;
    }

    void *bytes = malloc((size_t)module_size);
    if (bytes == NULL) {
        snprintf(g_last_message, sizeof(g_last_message),
                 "Initialization failed: could not allocate %d bytes.", module_size);
        return JNI_FALSE;
    }
    (*env)->GetByteArrayRegion(env, module_data, 0, module_size, (jbyte *)bytes);
    if ((*env)->ExceptionCheck(env)) {
        free(bytes);
        snprintf(g_last_message, sizeof(g_last_message),
                 "Initialization failed: could not copy the module asset.");
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
    return JNI_TRUE;
}

JNIEXPORT jstring JNICALL
Java_net_klovnin_fluttermodp_MainActivity_nativeGetLastMessage(
        JNIEnv *env,
        jobject activity) {
    (void)activity;
    return (*env)->NewStringUTF(env, g_last_message);
}

