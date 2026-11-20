/*
 * MSIEC — kernel module metadata.
 *
 * A kext built by Xcode always carries a `kmod_info` symbol, but a binary
 * linked by hand with `clang -kext -r` does not.  OpenCore refuses to inject
 * a kext without it ("OC: Prelinked injection MSIEC.kext - Invalid Parameter"),
 * so the structure is emitted here from a plain C translation unit (the
 * macro's string-literal initialiser is not valid C++).
 *
 * Part of YAMDCC for macOS. GPL-3.0-or-later.
 */

#include <mach/kmod.h>

static kern_return_t msiecModuleStart(kmod_info_t *ki, void *data);
static kern_return_t msiecModuleStop(kmod_info_t *ki, void *data);

KMOD_EXPLICIT_DECL(com.yamdcc.MSIEC, "1.1.0", msiecModuleStart, msiecModuleStop)

static kern_return_t
msiecModuleStart(kmod_info_t *ki, void *data)
{
	(void)ki;
	(void)data;
	return KERN_SUCCESS;
}

static kern_return_t
msiecModuleStop(kmod_info_t *ki, void *data)
{
	(void)ki;
	(void)data;
	return KERN_SUCCESS;
}
