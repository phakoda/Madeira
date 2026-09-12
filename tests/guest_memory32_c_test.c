#include "../app/Madeira/GuestMemory32.h"
#include <stdio.h>

/* Compile as C and link against the C++ implementation to check its real ABI. */
int main(void) {
    gm32_space *space = NULL;
    gm32_address address = 0;
    unsigned char input = 42, output = 0;
    if (gm32_create(4096, &space).status != GM32_OK) return 1;
    int failed = gm32_reserve(space, 0, 4096, &address).status != GM32_OK ||
        gm32_commit(space, address, 4096, GM32_READ | GM32_WRITE).status != GM32_OK ||
        gm32_write(space, address, &input, 1).status != GM32_OK ||
        gm32_read(space, address, &output, 1).status != GM32_OK || output != input;
    gm32_destroy(space);
    if (!failed) puts("GuestMemory32 C ABI passed");
    return failed;
}
