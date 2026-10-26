#ifndef KILN_INDEX_BRIDGE_H
#define KILN_INDEX_BRIDGE_H
#include <stdint.h>
// Kiln's adapter to the installed compiler's public IndexStore ABI. It contains
// no IndexStore implementation and performs no dependency loading from projects.
typedef int (*kiln_index_receiver)(void *, const char *, const char *, const char *, unsigned, unsigned, unsigned, uint64_t);
int kiln_index_read(const char *library, const char *store, const char *source_prefix, void *context, kiln_index_receiver receiver);
int kiln_index_spawn(const char *executable, char *const *arguments, char *const *environment, const char *working_directory, const char *log_path, int *pid);
int kiln_index_poll(int pid, int *exit_code);
#endif
