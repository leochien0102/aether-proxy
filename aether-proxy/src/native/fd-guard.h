#ifndef AETHER_T16119_FD_GUARD_H
#define AETHER_T16119_FD_GUARD_H

#include <stddef.h>

struct aether_fd_result {
	size_t matched;
	size_t changed;
};

/* Paths are absolute; module_dir must end in '/'.
 * Operates in the caller, borrowing existing descriptors without owning them.
 * Caller must serialize descriptor opens/closes and renames during this call.
 * Returns 0 or -1 with errno; failures may leave earlier changes applied.
 */
int aether_fd_guard(const char *entry, const char *module_dir,
                    struct aether_fd_result *result);

#endif
