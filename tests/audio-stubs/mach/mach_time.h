/* Test-only Apple boundary declarations, not an SDK replacement. */
#ifndef MADEIRA_TEST_MACH_TIME_H
#define MADEIRA_TEST_MACH_TIME_H
#include <stdint.h>
typedef struct { uint32_t numer, denom; } mach_timebase_info_data_t;
uint64_t mach_absolute_time(void);
int mach_timebase_info(mach_timebase_info_data_t *info);
#endif
