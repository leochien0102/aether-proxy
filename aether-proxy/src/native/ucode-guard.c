#include <errno.h>
#include <string.h>
#include <ucode/lib.h>
#include <ucode/module.h>

#include "fd-guard.h"

static uc_value_t *guard(uc_vm_t *vm, size_t nargs)
{
	struct aether_fd_result result;
	uc_value_t *reply;

	if (nargs) {
		uc_vm_raise_exception(vm, EXCEPTION_TYPE, "guard takes no arguments");
		return NULL;
	}
	if (aether_fd_guard("/usr/share/rpcd/ucode/aetherproxy.uc",
	                    "/usr/share/ucode/aetherproxy/", &result) < 0) {
		int error = errno;
		uc_vm_raise_exception(vm, EXCEPTION_RUNTIME,
		                      "aether-proxy rpcd guard: %s (errno=%d)",
		                      strerror(error), error);
		return NULL;
	}
	reply = ucv_object_new(vm);
	ucv_object_add(reply, "matched", ucv_uint64_new(result.matched));
	ucv_object_add(reply, "changed", ucv_uint64_new(result.changed));
	return reply;
}

void uc_module_init(uc_vm_t *vm, uc_value_t *scope);

void uc_module_init(uc_vm_t *vm, uc_value_t *scope)
{
	(void)vm;
	uc_function_register(scope, "guard", guard);
}
