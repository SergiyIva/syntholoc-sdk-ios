#include "COtaCrypto.h"
#include <openssl/sha.h>
void ota_sha256(const unsigned char *bytes, size_t count, unsigned char *output) {
    SHA256(bytes, count, output);
}
