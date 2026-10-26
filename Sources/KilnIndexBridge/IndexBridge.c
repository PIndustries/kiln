#ifndef _GNU_SOURCE
#define _GNU_SOURCE
#endif
#include "KilnIndexBridge.h"
#include <stdbool.h>
#include <stddef.h>
#include <stdlib.h>
#include <string.h>
#include <dlfcn.h>
#include <spawn.h>
#include <fcntl.h>
#include <unistd.h>
#include <errno.h>
#include <sys/wait.h>

// Public ABI declarations only, checked against LLVM's indexstore/indexstore.h:
// https://github.com/swiftlang/llvm-project/blob/next/clang/include/indexstore/indexstore.h
typedef struct { const char *data; size_t length; } Ref;
typedef bool (*EachRef)(void *, Ref);
typedef bool (*EachPointer)(void *, void *);
typedef struct {
    unsigned (*version)(void);
    void *(*create)(const char *, void **);
    void (*dispose)(void *);
    void (*error_dispose)(void *);
    bool (*units)(void *, unsigned, void *, EachRef);
    void *(*unit)(void *, const char *, void **);
    void (*unit_dispose)(void *);
    bool (*dependencies)(void *, void *, EachPointer);
    int (*dependency_kind)(void *);
    Ref (*dependency_path)(void *);
    Ref (*dependency_name)(void *);
    void *(*record)(void *, const char *, void **);
    void (*record_dispose)(void *);
    bool (*occurrences)(void *, void *, EachPointer);
    void *(*symbol)(void *);
    Ref (*usr)(void *);
    Ref (*name)(void *);
    int (*kind)(void *);
    uint64_t (*roles)(void *);
    void (*location)(void *, unsigned *, unsigned *);
} API;
typedef struct {
    API *api; void *store; const char *prefix; void *context;
    kiln_index_receiver receiver; char *file;
    unsigned units, records, occurrences; int failed;
} Reader;
static char *copy_ref(Ref ref) {
    if (ref.length > 16384 || (!ref.data && ref.length)) return NULL;
    char *result = malloc(ref.length + 1);
    if (!result) return NULL;
    if (ref.length) memcpy(result, ref.data, ref.length);
    result[ref.length] = 0; return result;
}
static bool occurrence(void *context, void *value) {
    Reader *r = context;
    if (++r->occurrences > 200000) { r->failed = 4; return false; }
    void *symbol = r->api->symbol(value);
    if (!symbol) { r->failed = 2; return false; }
    char *usr = copy_ref(r->api->usr(symbol)), *name = copy_ref(r->api->name(symbol));
    if (!usr || !name) { free(usr); free(name); r->failed = 3; return false; }
    unsigned line = 0, column = 0;
    r->api->location(value, &line, &column);
    int keep = r->receiver(r->context, r->file, usr, name, (unsigned)r->api->kind(symbol), line, column, r->api->roles(value));
    free(usr); free(name);
    if (!keep) r->failed = 4;
    return keep != 0;
}
static bool dependency(void *context, void *value) {
    Reader *r = context;
    if (r->api->dependency_kind(value) != 2) return true; // record dependency
    char *path = copy_ref(r->api->dependency_path(value));
    if (!path) { r->failed = 3; return false; }
    if (strncmp(path, r->prefix, strlen(r->prefix)) != 0) { free(path); return true; }
    if (++r->records > 4096) { free(path); r->failed = 4; return false; }
    char *name = copy_ref(r->api->dependency_name(value));
    if (!name) { free(path); r->failed = 3; return false; }
    void *error = NULL, *record = r->api->record(r->store, name, &error);
    free(name);
    if (!record) { if (error) r->api->error_dispose(error); free(path); r->failed = 2; return false; }
    r->file = path;
    bool complete = r->api->occurrences(record, r, occurrence);
    r->api->record_dispose(record); r->file = NULL; free(path);
    if (!complete && !r->failed) r->failed = 2;
    return r->failed == 0;
}
static bool unit(void *context, Ref value) {
    Reader *r = context;
    if (++r->units > 4096) { r->failed = 4; return false; }
    char *name = copy_ref(value);
    if (!name) { r->failed = 3; return false; }
    void *error = NULL, *reader = r->api->unit(r->store, name, &error); free(name);
    if (!reader) { if (error) r->api->error_dispose(error); r->failed = 2; return false; }
    bool complete = r->api->dependencies(reader, r, dependency);
    r->api->unit_dispose(reader);
    if (!complete && !r->failed) r->failed = 2;
    return r->failed == 0;
}
int kiln_index_read(const char *library, const char *store_path, const char *prefix, void *context, kiln_index_receiver receiver) {
    if (!library || !store_path || !prefix || !receiver || !*prefix) return 1;
    void *handle = dlopen(library, RTLD_LOCAL | RTLD_NOW);
    if (!handle) return 1;
    API api = {0};
#define LOAD(field, symbol) do { api.field = (__typeof__(api.field))dlsym(handle, symbol); if (!api.field) { dlclose(handle); return 1; } } while (0)
    LOAD(version, "indexstore_version");
    LOAD(create, "indexstore_store_create"); LOAD(dispose, "indexstore_store_dispose");
    LOAD(error_dispose, "indexstore_error_dispose"); LOAD(units, "indexstore_store_units_apply_f");
    LOAD(unit, "indexstore_unit_reader_create"); LOAD(unit_dispose, "indexstore_unit_reader_dispose");
    LOAD(dependencies, "indexstore_unit_reader_dependencies_apply_f");
    LOAD(dependency_kind, "indexstore_unit_dependency_get_kind"); LOAD(dependency_path, "indexstore_unit_dependency_get_filepath"); LOAD(dependency_name, "indexstore_unit_dependency_get_name");
    LOAD(record, "indexstore_record_reader_create"); LOAD(record_dispose, "indexstore_record_reader_dispose"); LOAD(occurrences, "indexstore_record_reader_occurrences_apply_f");
    LOAD(symbol, "indexstore_occurrence_get_symbol"); LOAD(usr, "indexstore_symbol_get_usr"); LOAD(name, "indexstore_symbol_get_name"); LOAD(kind, "indexstore_symbol_get_kind");
    LOAD(roles, "indexstore_occurrence_get_roles"); LOAD(location, "indexstore_occurrence_get_line_col");
#undef LOAD
    if (api.version() / 10000 != 0) { dlclose(handle); return 1; }
    void *error = NULL, *store = api.create(store_path, &error);
    if (!store) { if (error) api.error_dispose(error); dlclose(handle); return 2; }
    Reader r = {.api=&api, .store=store, .prefix=prefix, .context=context, .receiver=receiver};
    bool complete = api.units(store, 1, &r, unit);
    api.dispose(store); dlclose(handle);
    return r.failed ? r.failed : complete ? 0 : 2;
}

// Spawn a compiler in its own process group so timeout/cancellation can contain
// its frontend descendants. No shell or inherited user environment is used.
int kiln_index_spawn(const char *exe, char *const *argv, char *const *env, const char *working_directory, const char *log_path, int *pid) {
    if (!exe || !argv || !env || !working_directory || !log_path || !pid) return EINVAL;
    int out = open(log_path, O_WRONLY | O_CREAT | O_TRUNC | O_NOFOLLOW | O_CLOEXEC, 0600);
    if (out < 0) return errno;
    int in = open("/dev/null", O_RDONLY | O_CLOEXEC);
    if (in < 0) { int error = errno; close(out); return error; }
    posix_spawn_file_actions_t actions; posix_spawnattr_t attributes;
    int error = posix_spawn_file_actions_init(&actions);
    if (error) { close(in); close(out); return error; }
    error = posix_spawnattr_init(&attributes);
    if (error) { posix_spawn_file_actions_destroy(&actions); close(in); close(out); return error; }
    short flags = POSIX_SPAWN_SETPGROUP;
#ifdef POSIX_SPAWN_CLOEXEC_DEFAULT
    flags |= POSIX_SPAWN_CLOEXEC_DEFAULT;
#endif
    if (!(error = posix_spawn_file_actions_addchdir_np(&actions, working_directory)) &&
        !(error = posix_spawn_file_actions_adddup2(&actions, in, STDIN_FILENO)) &&
        !(error = posix_spawn_file_actions_adddup2(&actions, out, STDOUT_FILENO)) &&
        !(error = posix_spawn_file_actions_adddup2(&actions, out, STDERR_FILENO)) &&
        !(error = posix_spawnattr_setflags(&attributes, flags)) &&
        !(error = posix_spawnattr_setpgroup(&attributes, 0))) {
        pid_t child = 0;
        error = posix_spawn(&child, exe, &actions, &attributes, argv, env);
        if (!error) *pid = (int)child;
    }
    posix_spawnattr_destroy(&attributes); posix_spawn_file_actions_destroy(&actions); close(in); close(out);
    return error;
}
int kiln_index_poll(int pid, int *exit_code) {
    int status; pid_t result;
    do { result = waitpid((pid_t)pid, &status, WNOHANG); } while (result < 0 && errno == EINTR);
    if (result < 0) return -1;
    if (result == 0) return 0;
    *exit_code = WIFEXITED(status) ? WEXITSTATUS(status) : WIFSIGNALED(status) ? 128 + WTERMSIG(status) : 255;
    return 1;
}
