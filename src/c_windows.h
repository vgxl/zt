#ifndef ZT_C_WINDOWS_H
#define ZT_C_WINDOWS_H

/* Win32 headers used by the native Windows backend and ConPTY process layer. */
#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#ifndef UNICODE
#define UNICODE
#endif
#ifndef _UNICODE
#define _UNICODE
#endif

#include <windows.h>
#include <imm.h>
#include <shellapi.h>

#endif
