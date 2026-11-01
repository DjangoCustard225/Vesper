#ifndef VESPER_USENET_CRYPTO_H
#define VESPER_USENET_CRYPTO_H
#include <stddef.h>
#include <stdint.h>
int vesper_rar3_key(const uint8_t *password, size_t length, const uint8_t *salt, size_t salt_length, uint8_t key[16], uint8_t iv[16]);
int vesper_rar5_key(const uint8_t *password, size_t length, const uint8_t salt[16], unsigned log_rounds, uint8_t key[32], uint8_t check[8]);
int vesper_aes_decrypt(const uint8_t *key, size_t key_length, const uint8_t iv[16], const uint8_t *input, size_t length, uint8_t *output);
int vesper_sha256(const uint8_t *input, size_t length, uint8_t output[32]);
#endif
