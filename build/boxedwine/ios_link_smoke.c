#include "embedded.h"

// Linking the API pulls the full interpreter, platform, SDL, and OSMesa graph.
// This executable does not claim to verify UIKit presentation or Wine startup.
int main(void) {
    if (madeira_wine32_start(0, 0)) return 1;
    return madeira_wine32_error()[0] ? 0 : 2;
}
