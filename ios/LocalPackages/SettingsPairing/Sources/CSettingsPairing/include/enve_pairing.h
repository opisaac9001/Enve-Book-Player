#ifndef ENVE_PAIRING_H
#define ENVE_PAIRING_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

typedef struct EnvePairing EnvePairing;

EnvePairing *enve_pairing_create(const uint8_t code[6], bool sender);
void enve_pairing_free(EnvePairing *pairing);
size_t enve_pairing_write(EnvePairing *pairing, int round, uint8_t *output, size_t capacity);
bool enve_pairing_read(EnvePairing *pairing, int round, const uint8_t *input, size_t length);
bool enve_pairing_derive(EnvePairing *pairing, uint8_t key[32]);

#endif
