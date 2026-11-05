/*
 * ifnh.h - C interface of libifnh, the ifnh agent runtime as a static library.
 *
 *   zig build lib                 -> zig-out/lib/libifnh.a, zig-out/include/ifnh.h
 *   cc app.c -Izig-out/include zig-out/lib/libifnh.a
 *
 * Link with a C runtime (libc); no other dependency. The library reads no
 * config files: `config_json` is the whole configuration (over the builtin
 * defaults). API keys and HOME are read from the process environment.
 *
 * Threading: a runtime is single-threaded and NOT reentrant. Use one runtime
 * from one thread at a time, and never call into it from an event callback.
 * Distinct runtimes may be used from different threads.
 *
 * Working directory: shell commands and hooks run in the process working
 * directory; chdir to the project before prompting if it differs from the
 * `cwd` given to ifnh_runtime_new.
 *
 * Strings are UTF-8 and NUL-terminated.
 */
#ifndef IFNH_H
#define IFNH_H

#ifdef __cplusplus
extern "C" {
#endif

/* An opaque conversation. Create with ifnh_runtime_new, release with ifnh_runtime_free. */
typedef struct ifnh_runtime ifnh_runtime;

/* Event kinds passed to ifnh_event_cb. */
enum {
    IFNH_EVENT_TEXT = 0,        /* assistant text delta */
    IFNH_EVENT_STATUS = 1,      /* status line; `status` is the level: 0 plain, 1 warn, 2 error */
    IFNH_EVENT_NOTICE = 2,      /* non-fatal notice */
    IFNH_EVENT_TOOL_START = 3,  /* a tool call begins; `text` is the tool name */
    IFNH_EVENT_TOOL_RESULT = 4  /* a tool call ended; `text` is its output, `status`: 0 ok, 1 denied, 2 failed, 3 timeout */
};

/* Return codes of ifnh_runtime_prompt (same precedence as `ifnh ask`). */
enum {
    IFNH_OK = 0,         /* the turn completed */
    IFNH_FAILED = 1,     /* the turn failed or never ran (for example, no model configured) */
    IFNH_CANCELLED = 2,  /* the turn was cancelled */
    IFNH_DENIED = 3,     /* a tool call was refused: permission asks are always refused here */
    IFNH_BUDGET = 4      /* agents.budget_usd is spent */
};

/*
 * Event callback. `text` is owned by the call: copy it to keep it. Do not
 * call back into ifnh from here.
 */
typedef void (*ifnh_event_cb)(void *user, int kind, const char *text, int status);

/*
 * Create a runtime rooted at directory `cwd`. `config_json` may be NULL or a
 * JSON object such as {"model":{"provider":"openai","model":"gpt-5"}}; it is
 * validated like any ifnh config. Tools that would ask for permission are
 * refused, so allow them in config_json ("permissions") when the host wants
 * them to run.
 *
 * Returns NULL on failure and, if `err` is not NULL, stores a malloc'd
 * message there (release it with ifnh_string_free). On success *err is NULL.
 */
ifnh_runtime *ifnh_runtime_new(const char *cwd, const char *config_json, char **err);

/*
 * Run one turn: send `text` and block until the turn ends, calling `cb`
 * for
 * each event, in order. Returns one of the IFNH_* codes above. On IFNH_FAILED,
 * *err (if not NULL) holds a message to release with ifnh_string_free.
 */
int ifnh_runtime_prompt(ifnh_runtime *rt, const char *text, ifnh_event_cb cb, void *user, char **err);

/* Release a runtime. NULL is ignored. */
void ifnh_runtime_free(ifnh_runtime *rt);

/* The library version, a static string (the same as `ifnh version`). */
const char *ifnh_version(void);

/* Release a string returned through an `err` out-parameter. NULL is ignored. */
void ifnh_string_free(char *s);

#ifdef __cplusplus
}
#endif

#endif /* IFNH_H */
