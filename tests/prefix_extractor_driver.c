#include "../app/Madeira/PrefixExtractor.h"
#include <string.h>
int main(int argc, char **argv) {
    if (argc != 3) return 2;
    if (!strcmp(argv[1], "--ready")) return madeira_prefix_is_ready(argv[2]) ? 0 : 1;
    return madeira_extract_prefix_tgz(argv[1], argv[2]) == 0 ? 0 : 1;
}
