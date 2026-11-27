#define _GNU_SOURCE
#include "fd-guard.h"

#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <stdlib.h>
#include <string.h>
#include <sys/resource.h>
#include <sys/stat.h>
#include <unistd.h>

static int is_ours(char *path, const char *entry, const char *module_dir)
{
	static const char deleted[] = " (deleted)";
	size_t len = strlen(path), prefix = strlen(module_dir);

	/* procfs keeps the former name of an unlinked open source. */
	if (len >= sizeof(deleted) - 1 &&
	    !strcmp(path + len - (sizeof(deleted) - 1), deleted)) {
		len -= sizeof(deleted) - 1;
		path[len] = '\0';
	}
	if (!strcmp(path, entry))
		return 1;
	return len > prefix + 3 && !strncmp(path, module_dir, prefix) &&
	       !strcmp(path + len - 3, ".uc");
}

int aether_fd_guard(const char *entry, const char *module_dir,
                    struct aether_fd_result *result)
{
	struct rlimit limit;
	struct dirent *item;
	DIR *dir;
	int saved = 0;

	if (!entry || !module_dir || !result || entry[0] != '/' ||
	    module_dir[0] != '/' || module_dir[strlen(module_dir) - 1] != '/') {
		errno = EINVAL;
		return -1;
	}
	*result = (struct aether_fd_result){0};
	if (getrlimit(RLIMIT_NOFILE, &limit) < 0)
		return -1;
	if (limit.rlim_cur < 2048) {
		rlim_t target = limit.rlim_max < 2048 ? limit.rlim_max : 2048;
		if (target > limit.rlim_cur) {
			limit.rlim_cur = target;
			if (setrlimit(RLIMIT_NOFILE, &limit) < 0)
				return -1;
		}
	}

	dir = opendir("/proc/self/fd");
	if (!dir)
		return -1;
	for (;;) {
		struct stat st;
		char path[PATH_MAX + 1], *end;
		long number;
		ssize_t len;
		int fd, flags;

		errno = 0;
		item = readdir(dir);
		if (!item) {
			saved = errno;
			break;
		}
		if (item->d_name[0] == '.')
			continue;
		errno = 0;
		number = strtol(item->d_name, &end, 10);
		if (errno || *end || number < 0 || number > INT_MAX) {
			saved = EINVAL;
			break;
		}
		fd = (int)number;
		if (fd == dirfd(dir))
			continue;
		if (fstat(fd, &st) < 0) {
			saved = errno;
			break;
		}
		if (!S_ISREG(st.st_mode))
			continue;
		len = readlinkat(dirfd(dir), item->d_name, path, PATH_MAX);
		if (len < 0 || len == PATH_MAX) {
			saved = len < 0 ? errno : ENAMETOOLONG;
			break;
		}
		path[len] = '\0';
		if (!is_ours(path, entry, module_dir))
			continue;
		result->matched++;
		flags = fcntl(fd, F_GETFD);
		if (flags < 0 || (!(flags & FD_CLOEXEC) &&
		    fcntl(fd, F_SETFD, flags | FD_CLOEXEC) < 0)) {
			saved = errno;
			break;
		}
		if (!(flags & FD_CLOEXEC))
			result->changed++;
	}
	/* This is our enumeration fd, never a borrowed application fd. */
	if (closedir(dir) < 0 && !saved)
		saved = errno;
	if (saved) {
		errno = saved;
		return -1;
	}
	return 0;
}
