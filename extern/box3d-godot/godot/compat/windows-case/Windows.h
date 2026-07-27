// Case-folding shim for cross-compiling to Windows from a case-sensitive host.
//
// Upstream's src/timer.c includes <Windows.h> with a capital W. MSVC's SDK
// ships that spelling, and Windows filesystems are case-insensitive, so it
// resolves there. MinGW-w64 ships only lowercase <windows.h>, so the include
// fails outright when cross-compiling from Linux or macOS.
//
// Fork discipline forbids patching upstream's src/, so the
// missing spelling is supplied additively instead: ../../SConstruct prepends
// this directory to CPPPATH for MinGW cross builds only. Windows hosts never
// need it and never see it.
//
// #include_next rather than #include, so this file can never include itself
// should the shim directory ever be searched on a case-insensitive filesystem.

#pragma once

#include_next <windows.h>
