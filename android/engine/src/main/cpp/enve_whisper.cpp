



#include <jni.h>
#include <android/log.h>
#include <string>
#include "whisper.h"

#define TAG "EnveWhisper"
#define LOGI(...) __android_log_print(ANDROID_LOG_INFO, TAG, __VA_ARGS__)
#define LOGW(...) __android_log_print(ANDROID_LOG_WARN, TAG, __VA_ARGS__)

extern "C" {

JNIEXPORT jlong JNICALL
Java_com_enve_app_storyalign_transcribe_WhisperLib_00024Companion_initContext(
        JNIEnv *env, jobject, jstring model_path) {
    const char *path = env->GetStringUTFChars(model_path, nullptr);
    whisper_context_params cparams = whisper_context_default_params();
    cparams.use_gpu = false;
    whisper_context *ctx = whisper_init_from_file_with_params(path, cparams);
    env->ReleaseStringUTFChars(model_path, path);
    if (ctx == nullptr) LOGW("Failed to init whisper context from %s", path);
    return (jlong) ctx;
}

JNIEXPORT void JNICALL
Java_com_enve_app_storyalign_transcribe_WhisperLib_00024Companion_freeContext(
        JNIEnv *, jobject, jlong ptr) {
    if (ptr != 0) whisper_free((whisper_context *) ptr);
}

JNIEXPORT jint JNICALL
Java_com_enve_app_storyalign_transcribe_WhisperLib_00024Companion_fullTranscribe(
        JNIEnv *env, jobject, jlong ptr, jint num_threads, jstring language, jfloatArray audio) {
    auto *ctx = (whisper_context *) ptr;
    const jsize n_samples = env->GetArrayLength(audio);
    jfloat *samples = env->GetFloatArrayElements(audio, nullptr);

    whisper_full_params params = whisper_full_default_params(WHISPER_SAMPLING_GREEDY);
    params.n_threads = num_threads;
    params.token_timestamps = true;
    params.translate = false;
    params.no_timestamps = false;
    params.print_realtime = false;
    params.print_progress = false;
    params.print_timestamps = false;
    params.print_special = false;
    params.single_segment = false;

    std::string lang;
    if (language != nullptr) {
        const char *l = env->GetStringUTFChars(language, nullptr);
        lang.assign(l);
        env->ReleaseStringUTFChars(language, l);
        params.language = lang.c_str();
    }

    const int result = whisper_full(ctx, params, samples, n_samples);
    env->ReleaseFloatArrayElements(audio, samples, JNI_ABORT);
    return result;
}

JNIEXPORT jint JNICALL
Java_com_enve_app_storyalign_transcribe_WhisperLib_00024Companion_getSegmentCount(
        JNIEnv *, jobject, jlong ptr) {
    return whisper_full_n_segments((whisper_context *) ptr);
}

JNIEXPORT jstring JNICALL
Java_com_enve_app_storyalign_transcribe_WhisperLib_00024Companion_getSegmentText(
        JNIEnv *env, jobject, jlong ptr, jint i) {
    return env->NewStringUTF(whisper_full_get_segment_text((whisper_context *) ptr, i));
}

JNIEXPORT jlong JNICALL
Java_com_enve_app_storyalign_transcribe_WhisperLib_00024Companion_getSegmentT0(
        JNIEnv *, jobject, jlong ptr, jint i) {
    return whisper_full_get_segment_t0((whisper_context *) ptr, i);
}

JNIEXPORT jlong JNICALL
Java_com_enve_app_storyalign_transcribe_WhisperLib_00024Companion_getSegmentT1(
        JNIEnv *, jobject, jlong ptr, jint i) {
    return whisper_full_get_segment_t1((whisper_context *) ptr, i);
}

JNIEXPORT jint JNICALL
Java_com_enve_app_storyalign_transcribe_WhisperLib_00024Companion_getTokenCount(
        JNIEnv *, jobject, jlong ptr, jint seg) {
    return whisper_full_n_tokens((whisper_context *) ptr, seg);
}

JNIEXPORT jstring JNICALL
Java_com_enve_app_storyalign_transcribe_WhisperLib_00024Companion_getTokenText(
        JNIEnv *env, jobject, jlong ptr, jint seg, jint tok) {
    return env->NewStringUTF(whisper_full_get_token_text((whisper_context *) ptr, seg, tok));
}

JNIEXPORT jlong JNICALL
Java_com_enve_app_storyalign_transcribe_WhisperLib_00024Companion_getTokenT0(
        JNIEnv *, jobject, jlong ptr, jint seg, jint tok) {
    return whisper_full_get_token_data((whisper_context *) ptr, seg, tok).t0;
}

JNIEXPORT jlong JNICALL
Java_com_enve_app_storyalign_transcribe_WhisperLib_00024Companion_getTokenT1(
        JNIEnv *, jobject, jlong ptr, jint seg, jint tok) {
    return whisper_full_get_token_data((whisper_context *) ptr, seg, tok).t1;
}

JNIEXPORT jfloat JNICALL
Java_com_enve_app_storyalign_transcribe_WhisperLib_00024Companion_getTokenP(
        JNIEnv *, jobject, jlong ptr, jint seg, jint tok) {
    return whisper_full_get_token_p((whisper_context *) ptr, seg, tok);
}

}
