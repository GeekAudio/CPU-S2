// Regression tests exercise parsing/statistics/process cleanup only.
// Abort if a test accidentally enters a CPU load or hardware sampling path.
#include <stdio.h>
#include <stdlib.h>

static void unexpected_probe(void) {
    fputs("FAIL: a regression test entered a hardware/CPU load path\n", stderr);
    abort();
}

double cpus2_measure_mhz(double ms) {
    (void)ms;
    unexpected_probe();
    return 0;
}

void cpus2_burn(double ms) {
    (void)ms;
    unexpected_probe();
}

double cpus2_cpu_temp(void) {
    unexpected_probe();
    return 0;
}
