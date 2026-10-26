// framegap SECONDS HZ OUT.json - polls debug.nvaccel_iop_flips every 250 us for SECONDS and writes when each flip landed,
// the gaps between them and a histogram in refresh periods of an HZ panel. A gap over two periods (11.1 ms at 180 Hz)
// is a visible stall; 1-2 periods is a missed refresh. The counter is cumulative, so several flips inside one poll
// count once: at 250 us against a 5.6 ms period that does not happen.
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <unistd.h>
#include <sys/sysctl.h>
#include <mach/mach_time.h>

static uint64_t flips(void) {
    uint64_t v = 0; size_t n = sizeof v;
    if (sysctlbyname("debug.nvaccel_iop_flips", &v, &n, NULL, 0) != 0) return UINT64_MAX;
    return n == 4 ? (uint32_t)v : v;
}

int main(int argc, char **argv) {
    if (argc != 4) { fprintf(stderr, "usage: framegap SECONDS HZ OUT.json\n"); return 2; }
    const double secs = atof(argv[1]), hz = atof(argv[2]), period = 1000.0 / hz;
    mach_timebase_info_data_t tb; mach_timebase_info(&tb);
    const uint64_t t0 = mach_absolute_time();
    uint64_t last = flips();
    if (last == UINT64_MAX) { fprintf(stderr, "framegap: no debug.nvaccel_iop_flips\n"); return 1; }
    size_t cap = (size_t)(secs * 1000) + 64, n = 0, lost = 0;
    double *t = malloc(cap * sizeof *t);
    for (;;) {
        const uint64_t now = mach_absolute_time();
        const double ms = (double)(now - t0) * tb.numer / tb.denom / 1e6;
        if (ms >= secs * 1000) break;
        const uint64_t f = flips();
        if (f != last) {
            if (f - last > 1) lost += f - last - 1;
            if (n < cap) t[n++] = ms;
            last = f;
        }
        usleep(250);
    }
    // buckets in periods: on time (<1.5), one refresh missed (1.5-2), over two periods (>2) is the 10/10 failure
    size_t ontime = 0, missed = 0, stall = 0; double maxgap = 0, sum = 0;
    for (size_t i = 1; i < n; i++) {
        const double g = t[i] - t[i - 1]; sum += g;
        if (g > maxgap) maxgap = g;
        if (g > 2 * period) stall++; else if (g > 1.5 * period) missed++; else ontime++;
    }
    FILE *o = fopen(argv[3], "w");
    if (!o) { perror(argv[3]); return 1; }
    fprintf(o, "{\"seconds\": %.3f, \"panel_hz\": %.2f, \"flips\": %zu, \"flips_merged\": %zu, \"fps\": %.2f, "
            "\"gap_max_ms\": %.3f, \"gap_mean_ms\": %.3f, \"gaps_ontime\": %zu, \"gaps_missed_one\": %zu, "
            "\"gaps_over_two_periods\": %zu, \"flip_ms\": [", secs, hz, n, lost, n / secs, maxgap,
            n > 1 ? sum / (n - 1) : 0.0, ontime, missed, stall);
    for (size_t i = 0; i < n; i++) fprintf(o, "%s%.3f", i ? "," : "", t[i]);
    fprintf(o, "]}\n");
    fclose(o);
    return 0;
}
