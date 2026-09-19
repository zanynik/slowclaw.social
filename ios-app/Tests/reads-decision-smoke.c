#include <stdio.h>
#include <string.h>
#include <assert.h>
#include "slowclaw_feed.h"
int main(int argc, char **argv) {
    assert(argc == 2);
    void *model = slowclaw_feed_reads_model_open(argv[1], strlen(argv[1]));
    assert(model);
    const char *query = "I want to learn how to compost kitchen scraps for a small vegetable garden.";
    const char *related = "Composting vegetable peels with dry leaves makes a balanced compost for a home vegetable garden. Keep the pile moist and aerated.";
    const char *unrelated = "The football championship ended with a penalty shootout. The winning team celebrated their trophy.";
    double a = -1, b = -1;
    assert(slowclaw_feed_reads_score(model, query, strlen(query), related, strlen(related), &a) == 0);
    assert(slowclaw_feed_reads_score(model, query, strlen(query), unrelated, strlen(unrelated), &b) == 0);
    printf("related=%.6f unrelated=%.6f\n", a, b);
    assert(a >= 0.8 && b < 0.8);
    // Empty and oversized input must abstain, never inherit a prior score.
    assert(slowclaw_feed_reads_score(model, "", 0, related, strlen(related), &a) != 0);
    assert(a == -1);
    char oversized[12001]; memset(oversized, 'a', sizeof(oversized));
    assert(slowclaw_feed_reads_score(model, query, strlen(query), oversized, sizeof(oversized), &a) != 0);
    assert(a == -1);
    slowclaw_feed_reads_model_close(model);
    assert(slowclaw_feed_reads_score(NULL, query, strlen(query), related, strlen(related), &a) != 0);
    assert(a == -1);
    return 0;
}
