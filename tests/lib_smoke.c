/* E-06b smoke: link libifnh.a, print the version, create and free a runtime. */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "ifnh.h"

int main(int argc, char **argv) {
    const char *dir = argc > 1 ? argv[1] : ".";
    printf("libifnh %s\n", ifnh_version());

    char *err = NULL;
    ifnh_runtime *rt = ifnh_runtime_new(dir, NULL, &err);
    if (!rt) {
        fprintf(stderr, "ifnh_runtime_new failed: %s\n", err ? err : "(no message)");
        ifnh_string_free(err);
        return 1;
    }
    ifnh_runtime_free(rt);

    /* A bad config is an error message and no runtime. */
    rt = ifnh_runtime_new(dir, "{not json", &err);
    if (rt || !err || strstr(err, "config_json") == NULL) {
        fprintf(stderr, "bad config was not rejected\n");
        return 1;
    }
    ifnh_string_free(err);
    return 0;
}
