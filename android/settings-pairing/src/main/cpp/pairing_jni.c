#include "enve_pairing.h"
#include "mbedtls/platform_util.h"
#include <jni.h>

JNIEXPORT jlong JNICALL
Java_com_enve_pairing_SettingsPairing_create(JNIEnv *env, jobject self, jbyteArray code, jboolean sender) {
    (void) self;
    if ((*env)->GetArrayLength(env, code) != 6) return 0;
    uint8_t digits[6];
    (*env)->GetByteArrayRegion(env, code, 0, 6, (jbyte *) digits);
    EnvePairing *pairing = enve_pairing_create(digits, sender);
    mbedtls_platform_zeroize(digits, sizeof(digits));
    return (jlong) (intptr_t) pairing;
}

JNIEXPORT jbyteArray JNICALL
Java_com_enve_pairing_SettingsPairing_write(JNIEnv *env, jobject self, jlong handle, jint round) {
    (void) self;
    uint8_t message[512];
    size_t size = enve_pairing_write((EnvePairing *) (intptr_t) handle, round, message, sizeof(message));
    if (size == 0) return NULL;
    jbyteArray result = (*env)->NewByteArray(env, (jsize) size);
    if (result != NULL) (*env)->SetByteArrayRegion(env, result, 0, (jsize) size, (jbyte *) message);
    return result;
}

JNIEXPORT jboolean JNICALL
Java_com_enve_pairing_SettingsPairing_read(JNIEnv *env, jobject self, jlong handle, jint round, jbyteArray input) {
    (void) self;
    uint8_t message[512];
    jsize length = (*env)->GetArrayLength(env, input);
    if (length <= 0 || length > (jsize) sizeof(message)) return JNI_FALSE;
    (*env)->GetByteArrayRegion(env, input, 0, length, (jbyte *) message);
    return enve_pairing_read((EnvePairing *) (intptr_t) handle, round, message, (size_t) length);
}

JNIEXPORT jbyteArray JNICALL
Java_com_enve_pairing_SettingsPairing_derive(JNIEnv *env, jobject self, jlong handle) {
    (void) self;
    uint8_t key[32];
    jbyteArray result = NULL;
    if (enve_pairing_derive((EnvePairing *) (intptr_t) handle, key)) {
        result = (*env)->NewByteArray(env, sizeof(key));
        if (result != NULL) (*env)->SetByteArrayRegion(env, result, 0, sizeof(key), (jbyte *) key);
    }
    mbedtls_platform_zeroize(key, sizeof(key));
    return result;
}

JNIEXPORT void JNICALL
Java_com_enve_pairing_SettingsPairing_destroy(JNIEnv *env, jobject self, jlong handle) {
    (void) env;
    (void) self;
    enve_pairing_free((EnvePairing *) (intptr_t) handle);
}
