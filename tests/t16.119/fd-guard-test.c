#define _GNU_SOURCE
#include "fd-guard.h"

#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/resource.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <unistd.h>

#define CHECK(test) do { if (!(test)) { \
	fprintf(stderr, "FAIL line %d: %s (errno=%d: %s)\n", \
	        __LINE__, #test, errno, strerror(errno)); exit(1); \
} } while (0)

struct record {
	int fd, ours, fdflags, status;
	struct stat st;
};

static void same_limit(struct rlimit expected)
{
	struct rlimit now;
	CHECK(getrlimit(RLIMIT_NOFILE, &now) == 0);
	CHECK(now.rlim_cur == expected.rlim_cur);
	CHECK(now.rlim_max == expected.rlim_max);
}

static void wait_ok(pid_t pid)
{
	int status;
	CHECK(pid > 0);
	CHECK(waitpid(pid, &status, 0) == pid);
	CHECK(WIFEXITED(status) && WEXITSTATUS(status) == 0);
}

static void limit_case(rlim_t soft, rlim_t hard, rlim_t expected,
                       const char *entry, const char *modules)
{
	pid_t pid = fork();
	CHECK(pid >= 0);
	if (pid == 0) {
		struct rlimit limit = {soft, hard};
		struct aether_fd_result result;
		CHECK(setrlimit(RLIMIT_NOFILE, &limit) == 0);
		CHECK(aether_fd_guard(entry, modules, &result) == 0);
		limit.rlim_cur = expected;
		same_limit(limit);
		CHECK(aether_fd_guard(entry, modules, &result) == 0);
		same_limit(limit);
		printf("PASS limit soft=%llu hard=%llu -> soft=%llu\n",
		       (unsigned long long)soft, (unsigned long long)hard,
		       (unsigned long long)expected);
		exit(0);
	}
	wait_ok(pid);
}

static struct record remember(int fd, int ours)
{
	struct record r = {.fd = fd, .ours = ours};
	CHECK(fd >= 0);
	r.fdflags = fcntl(fd, F_GETFD);
	r.status = fcntl(fd, F_GETFL);
	CHECK(r.fdflags >= 0 && r.status >= 0);
	CHECK(fstat(fd, &r.st) == 0);
	return r;
}

static int open_fixture(const char *root, const char *name, int flags)
{
	char path[PATH_MAX];
	int fd;
	CHECK(snprintf(path, sizeof(path), "%s/%s", root, name) < (int)sizeof(path));
	fd = open(path, O_CREAT | O_RDWR | flags, 0600);
	CHECK(fd >= 0);
	CHECK(write(fd, "source\n", 7) == 7);
	return fd;
}

static void remove_fixture(const char *root, const char *name)
{
	char path[PATH_MAX];
	CHECK(snprintf(path, sizeof(path), "%s/%s", root, name) < (int)sizeof(path));
	CHECK(unlink(path) == 0);
}

static int after_exec(int argc, char **argv)
{
	for (int i = 2; i < argc; i++) {
		int fd, closed, flags, status;
		unsigned long long dev, ino;
		struct stat st;
		CHECK(sscanf(argv[i], "%d:%d:%d:%d:%llu:%llu",
		             &fd, &closed, &flags, &status, &dev, &ino) == 6);
		errno = 0;
		if (closed) {
			CHECK(fcntl(fd, F_GETFD) == -1 && errno == EBADF);
		} else {
			CHECK(fcntl(fd, F_GETFD) == flags);
			CHECK(fcntl(fd, F_GETFL) == status);
			CHECK(fstat(fd, &st) == 0);
			CHECK((unsigned long long)st.st_dev == dev);
			CHECK((unsigned long long)st.st_ino == ino);
		}
	}
	puts("PASS re-exec: old/new app inodes closed; other descriptors unchanged");
	return 0;
}

static void fd_case(const char *root, const char *entry, const char *modules)
{
	struct record records[12];
	size_t n = 0;
	struct aether_fd_result result;
	int pipefd[2];
	char directory[PATH_MAX];
	char encoded[12][160];
	char *args[15] = {"fd-guard-test", "--after-exec"};

	records[n++] = remember(open_fixture(root, "entry.uc", 0), 1);
	records[n++] = remember(open_fixture(root, "modules/live.uc", O_APPEND), 1);
	records[n++] = remember(open_fixture(root, "modules/old.uc", 0), 1);
	remove_fixture(root, "modules/old.uc");
	CHECK(fstat(records[2].fd, &records[2].st) == 0);
	CHECK(records[2].st.st_nlink == 0);
	records[n++] = remember(open_fixture(root, "modules/old.uc", 0), 1);
	CHECK(records[2].st.st_ino != records[3].st.st_ino);
	records[n++] = remember(open_fixture(root, "modules/already.uc", O_CLOEXEC), 1);
	records[n++] = remember(open_fixture(root, "other.uc", O_APPEND), 0);
	remove_fixture(root, "other.uc");
	records[n++] = remember(open_fixture(root, "modules-other/no.uc", 0), 0);
	records[n++] = remember(open_fixture(root, "modules/data.txt", 0), 0);
	records[n++] = remember(open_fixture(root, "entry.uc.extra", O_CLOEXEC), 0);
	CHECK(snprintf(directory, sizeof(directory), "%s/modules/dir.uc", root) < (int)sizeof(directory));
	records[n++] = remember(open(directory, O_RDONLY | O_DIRECTORY), 0);
	CHECK(pipe(pipefd) == 0);
	records[n++] = remember(pipefd[0], 0);
	records[n++] = remember(pipefd[1], 0);

	CHECK(aether_fd_guard(entry, modules, &result) == 0);
	CHECK(result.matched == 5 && result.changed == 4);
	CHECK(aether_fd_guard(entry, modules, &result) == 0);
	CHECK(result.matched == 5 && result.changed == 0);
	for (size_t i = 0; i < n; i++) {
		struct record *r = &records[i];
		struct stat now;
		int expected = r->fdflags | (r->ours ? FD_CLOEXEC : 0);
		CHECK(fcntl(r->fd, F_GETFD) == expected);
		CHECK(fcntl(r->fd, F_GETFL) == r->status);
		CHECK(fstat(r->fd, &now) == 0);
		CHECK(now.st_dev == r->st.st_dev && now.st_ino == r->st.st_ino);
		if (S_ISREG(now.st_mode)) {
			char data[7];
			CHECK(pread(r->fd, data, sizeof(data), 0) == 7);
			CHECK(memcmp(data, "source\n", 7) == 0);
			CHECK(now.st_size == r->st.st_size);
		}
		CHECK(snprintf(encoded[i], sizeof(encoded[i]), "%d:%d:%d:%d:%llu:%llu",
		               r->fd, !!(expected & FD_CLOEXEC), expected, r->status,
		               (unsigned long long)now.st_dev,
		               (unsigned long long)now.st_ino) < (int)sizeof(encoded[i]));
		args[i + 2] = encoded[i];
	}
	puts("PASS original fds: exact F_GETFD, F_GETFL, inode/content and idempotence");
	fflush(stdout);
	execv("/proc/self/exe", args);
	CHECK(0);
}

int main(int argc, char **argv)
{
	char root[] = "/tmp/aether-t16.119-XXXXXX";
	char entry[PATH_MAX], modules[PATH_MAX], path[PATH_MAX];
	const char *dirs[] = {"modules", "modules-other", "modules/dir.uc"};
	const char *files[] = {"entry.uc", "modules/live.uc", "modules/old.uc",
	                       "modules/already.uc", "modules-other/no.uc",
	                       "modules/data.txt", "entry.uc.extra"};
	struct rlimit original;
	struct aether_fd_result result;
	pid_t pid;

	if (argc >= 2 && !strcmp(argv[1], "--after-exec"))
		return after_exec(argc, argv);
	CHECK(getrlimit(RLIMIT_NOFILE, &original) == 0);
	if (original.rlim_max < 4096) {
		fprintf(stderr, "BLOCKED: host hard RLIMIT_NOFILE must be >=4096\n");
		return 1;
	}
	CHECK(mkdtemp(root) != NULL);
	CHECK(snprintf(entry, sizeof(entry), "%s/entry.uc", root) < (int)sizeof(entry));
	CHECK(snprintf(modules, sizeof(modules), "%s/modules/", root) < (int)sizeof(modules));
	for (size_t i = 0; i < sizeof(dirs) / sizeof(dirs[0]); i++) {
		CHECK(snprintf(path, sizeof(path), "%s/%s", root, dirs[i]) < (int)sizeof(path));
		CHECK(mkdir(path, 0700) == 0);
	}
	CHECK(aether_fd_guard("relative", modules, &result) == -1 && errno == EINVAL);
	same_limit(original);
	limit_case(1024, 4096, 2048, entry, modules);
	limit_case(512, 1536, 1536, entry, modules);
	limit_case(1024, 1024, 1024, entry, modules);
	limit_case(2048, 4096, 2048, entry, modules);
	limit_case(3072, 4096, 3072, entry, modules);
	if (original.rlim_max == RLIM_INFINITY)
		limit_case(1024, RLIM_INFINITY, 2048, entry, modules);
	else
		puts("NOT COVERED: infinite hard limit (host hard limit is finite)");
	fflush(stdout);
	pid = fork();
	CHECK(pid >= 0);
	if (pid == 0)
		fd_case(root, entry, modules);
	wait_ok(pid);
	same_limit(original);
	for (size_t i = 0; i < sizeof(files) / sizeof(files[0]); i++)
		remove_fixture(root, files[i]);
	for (size_t i = sizeof(dirs) / sizeof(dirs[0]); i > 0; i--) {
		CHECK(snprintf(path, sizeof(path), "%s/%s", root, dirs[i - 1]) < (int)sizeof(path));
		CHECK(rmdir(path) == 0);
	}
	CHECK(rmdir(root) == 0);
	puts("PASS parent soft/hard unchanged; isolated fixtures removed");
	return 0;
}
