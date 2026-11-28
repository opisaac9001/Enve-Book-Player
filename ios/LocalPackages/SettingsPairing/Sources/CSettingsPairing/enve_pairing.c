#include "enve_pairing.h"
#include "mbedtls/ecjpake.h"
#include <stdlib.h>

struct EnvePairing {
    mbedtls_ecjpake_context context;
};

static int random_bytes(void *context, unsigned char *output, size_t length) {
    (void) context;
    arc4random_buf(output, length);
    return 0;
}

EnvePairing *enve_pairing_create(const uint8_t code[6], bool sender) {
    for (size_t i = 0; i < 6; i++) {
        if (code[i] < '0' || code[i] > '9') return NULL;
    }
    EnvePairing *pairing = calloc(1, sizeof(*pairing));
    if (pairing == NULL) return NULL;
    mbedtls_ecjpake_init(&pairing->context);
    if (mbedtls_ecjpake_setup(&pairing->context,
                             sender ? MBEDTLS_ECJPAKE_SERVER : MBEDTLS_ECJPAKE_CLIENT,
                             MBEDTLS_MD_SHA256, MBEDTLS_ECP_DP_SECP256R1, code, 6) != 0) {
        enve_pairing_free(pairing);
        return NULL;
    }
    return pairing;
}

void enve_pairing_free(EnvePairing *pairing) {
    if (pairing == NULL) return;
    mbedtls_ecjpake_free(&pairing->context);
    free(pairing);
}

size_t enve_pairing_write(EnvePairing *pairing, int round, uint8_t *output, size_t capacity) {
    size_t length = 0;
    int status = round == 1
        ? mbedtls_ecjpake_write_round_one(&pairing->context, output, capacity, &length, random_bytes, NULL)
        : mbedtls_ecjpake_write_round_two(&pairing->context, output, capacity, &length, random_bytes, NULL);
    return status == 0 ? length : 0;
}

bool enve_pairing_read(EnvePairing *pairing, int round, const uint8_t *input, size_t length) {
    int status = round == 1
        ? mbedtls_ecjpake_read_round_one(&pairing->context, input, length)
        : mbedtls_ecjpake_read_round_two(&pairing->context, input, length);
    return status == 0;
}

bool enve_pairing_derive(EnvePairing *pairing, uint8_t key[32]) {
    size_t length = 0;
    return mbedtls_ecjpake_derive_secret(&pairing->context, key, 32, &length, random_bytes, NULL) == 0
        && length == 32;
}
