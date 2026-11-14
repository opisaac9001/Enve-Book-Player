#include <dlfcn.h>
#include <jni.h>
#include <pthread.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdlib.h>

typedef struct PttsHandle PttsHandle;
typedef struct {
    uint32_t frames;
    size_t samples;
    double ttfa_ms;
    double total_ms;
} PttsResult;
typedef bool (*PttsFrameFn)(const float *, size_t, void *);

static PttsHandle *(*ptts_new)(const char *, int, const char *);
static bool (*ptts_set_voice)(PttsHandle *, const char *);
static bool (*ptts_speak)(PttsHandle *, const char *, PttsFrameFn, void *, PttsResult *);
static const char *(*ptts_last_error)(const PttsHandle *);
static void (*ptts_free)(PttsHandle *);
static pthread_once_t library_once = PTHREAD_ONCE_INIT;

static void load_library(void) {
    setenv("RAYON_NUM_THREADS", "2", 0);
    void *library = dlopen("libptts_ffi.so", RTLD_NOW | RTLD_LOCAL);
    if (library == NULL) return;
    ptts_new = dlsym(library, "ptts_new");
    ptts_set_voice = dlsym(library, "ptts_set_voice");
    ptts_speak = dlsym(library, "ptts_speak");
    ptts_last_error = dlsym(library, "ptts_last_error");
    ptts_free = dlsym(library, "ptts_free");
}

static void fail(JNIEnv *env, const char *message) {
    if ((*env)->ExceptionCheck(env)) return;
    jclass type = (*env)->FindClass(env, "java/lang/IllegalStateException");
    if (type != NULL) (*env)->ThrowNew(env, type, message ? message : "Phonon synthesis failed");
}

static char *utf8(JNIEnv *env, jbyteArray bytes) {
    jsize length = (*env)->GetArrayLength(env, bytes);
    char *result = malloc((size_t) length + 1);
    if (result != NULL) {
        (*env)->GetByteArrayRegion(env, bytes, 0, length, (jbyte *) result);
        result[length] = 0;
    } else {
        fail(env, "Could not allocate Phonon input");
    }
    return result;
}

typedef struct {
    JNIEnv *env;
    jobject audio;
    jmethodID append;
} FrameSink;

static bool on_frame(const float *pcm, size_t count, void *user) {
    FrameSink *sink = user;
    JNIEnv *env = sink->env;
    jfloatArray frame = (*env)->NewFloatArray(env, (jsize) count);
    if (frame == NULL) return false;
    (*env)->SetFloatArrayRegion(env, frame, 0, (jsize) count, pcm);
    bool keep_going = (*env)->CallBooleanMethod(env, sink->audio, sink->append, frame);
    (*env)->DeleteLocalRef(env, frame);
    return keep_going && !(*env)->ExceptionCheck(env);
}

JNIEXPORT jlong JNICALL
Java_com_enve_app_readium_narrator_PhononBackend_open(JNIEnv *env, jobject self, jbyteArray directory) {
    pthread_once(&library_once, load_library);
    if (!ptts_new || !ptts_set_voice || !ptts_speak || !ptts_last_error || !ptts_free) {
        fail(env, "Could not load the Phonon runtime");
        return 0;
    }
    char *path = utf8(env, directory);
    if (path == NULL) return 0;
    PttsHandle *handle = ptts_new(path, 0, "en");
    free(path);
    if (handle == NULL) fail(env, ptts_last_error(NULL));
    return (jlong) (intptr_t) handle;
}

JNIEXPORT void JNICALL
Java_com_enve_app_readium_narrator_PhononBackend_speak(
    JNIEnv *env, jobject self, jlong native_handle, jbyteArray text, jstring voice, jobject audio
) {
    PttsHandle *handle = (PttsHandle *) (intptr_t) native_handle;
    const char *name = (*env)->GetStringUTFChars(env, voice, NULL);
    if (name == NULL) return;
    bool selected = ptts_set_voice(handle, name);
    (*env)->ReleaseStringUTFChars(env, voice, name);
    if (!selected) {
        fail(env, ptts_last_error(handle));
        return;
    }
    jclass type = (*env)->GetObjectClass(env, audio);
    jmethodID append = (*env)->GetMethodID(env, type, "append", "([F)Z");
    if (append == NULL) return;
    char *input = utf8(env, text);
    if (input == NULL) return;
    FrameSink sink = { env, audio, append };
    PttsResult result;
    bool ok = ptts_speak(handle, input, on_frame, &sink, &result);
    free(input);
    if (!ok) fail(env, ptts_last_error(handle));
}

JNIEXPORT void JNICALL
Java_com_enve_app_readium_narrator_PhononBackend_free(JNIEnv *env, jobject self, jlong handle) {
    ptts_free((PttsHandle *) (intptr_t) handle);
}
