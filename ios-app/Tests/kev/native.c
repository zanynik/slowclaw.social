#include <stdio.h>
#include <string.h>
#include "slowclaw_feed.h"
// Synthetic JSON requests only. The production app never logs source text.
int main(int argc, char **argv) {
    if (argc != 2) return 2;
    double out[64];
    if (slowclaw_feed_kev_evaluate(NULL, "{}", 2, out, 64) != -1 || out[0] != -1) return 3;
    void *model = slowclaw_feed_kev_open(argv[1], strlen(argv[1]));
    if (!model) return 4;
    char line[65536];
    while (fgets(line, sizeof(line), stdin)) {
        int n = slowclaw_feed_kev_evaluate(model, line, strlen(line), out, 64);
        if (n < 0) { puts("null"); fflush(stdout); continue; }
        putchar('[');
        for (int i=0; i<n; ++i) printf("%s%.9f", i ? "," : "", out[i]);
        puts("]"); fflush(stdout);
    }
    slowclaw_feed_kev_close(model);
    return 0;
}
