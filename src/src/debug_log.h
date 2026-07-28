// debug_log.h — Lightweight debug logging for japi.dll
//
// Features:
//   - AllocConsole for real-time console output
//   - Async file writing via background thread + lock-free ring buffer
//   - Compile-time toggle: define JAPI_DEBUG to enable, otherwise all macros are no-ops
//
// Usage:
//   DBG_INIT();              // call once in DllMain or Initialize
//   DBG_LOG("msg %d", val);  // printf-style logging
//
// Build:
//   CMake: target_compile_definitions(yd_japi PRIVATE JAPI_DEBUG)

#pragma once

#include <windows.h>
#include <cstdio>
#include <cstdarg>
#include <cstring>
#include <string>

namespace japi_log {
// Diagnostics helper: direct synchronous append to japi_sync.log.
// Always compiled (SYNC_LOG in dllmain.cpp / bridge_dispatch.cpp uses it,
// independent of JAPI_DEBUG).
inline void sync_write(const char* msg) {
    HANDLE h = CreateFileA("C:\\ProgramData\\japi_sync.log",
        FILE_APPEND_DATA, FILE_SHARE_READ|FILE_SHARE_WRITE|FILE_SHARE_DELETE,
        NULL, OPEN_ALWAYS, FILE_ATTRIBUTE_NORMAL, NULL);
    if (h != INVALID_HANDLE_VALUE) {
        char line[600];
        SYSTEMTIME st;
        GetLocalTime(&st);
        int n = snprintf(line, sizeof(line), "[%02d:%02d:%02d pid=%lu] %s",
            st.wHour, st.wMinute, st.wSecond, (unsigned long)GetCurrentProcessId(), msg);
        DWORD bw;
        WriteFile(h, line, (DWORD)(n > 0 ? n : 0), &bw, NULL);
        WriteFile(h, "\r\n", 2, &bw, NULL);
        CloseHandle(h);
    }
}
}

#ifdef JAPI_DEBUG

#include <windows.h>
#include <cstdio>
#include <cstdarg>
#include <cstring>
#include <string>

namespace japi_log {

// ── Console ─────────────────────────────────────────────────
inline void init_console() {
    AllocConsole();
    freopen("CONOUT$", "w", stdout);
    freopen("CONOUT$", "w", stderr);
    SetConsoleTitleA("japi debug");
}

// ── Async file writer ───────────────────────────────────────
// Single producer (DBG_LOG calls), single consumer (background thread).
// Ring buffer of fixed-size entries, flushed periodically.

struct LogEntry {
    char buf[512];
    int  len;
};

static const int RING_SIZE = 256;

struct LogRing {
    LogEntry entries[RING_SIZE];
    volatile LONG write_idx = 0;
    volatile LONG read_idx  = 0;

    // File + sync
    HANDLE  file       = INVALID_HANDLE_VALUE;
    HANDLE  thread     = NULL;
    HANDLE  stop_event = NULL;
    CRITICAL_SECTION cs;

    bool push(const char* data, int len) {
        LONG next = (write_idx + 1) % RING_SIZE;
        if (next == read_idx) return false;  // full, drop
        LogEntry& e = entries[write_idx];
        int n = len < 511 ? len : 511;
        memcpy(e.buf, data, n);
        e.buf[n] = '\0';
        e.len = n;
        InterlockedExchange(&write_idx, next);
        return true;
    }

    bool pop(LogEntry& out) {
        if (read_idx == write_idx) return false;
        out = entries[read_idx];
        InterlockedExchange(&read_idx, (read_idx + 1) % RING_SIZE);
        return true;
    }
};

inline LogRing& ring() {
    // Function-local static in an INLINE function (external linkage): the
    // linker folds all instantiations into one, so there is exactly ONE ring
    // across all translation units. NOTE: declaring this function `static`
    // would give every TU its own copy — which is why japi_debug.txt stayed
    // empty (each TU pushed into its own ring, the flush thread popped another).
    static LogRing r;
    return r;
}

static DWORD WINAPI flush_thread(LPVOID) {
    sync_write("flush_thread: alive");
    while (WaitForSingleObject(ring().stop_event, 50) == WAIT_TIMEOUT) {
        LogEntry e;
        while (ring().pop(e)) {
            if (ring().file != INVALID_HANDLE_VALUE) {
                DWORD written;
                WriteFile(ring().file, e.buf, e.len, &written, NULL);
                WriteFile(ring().file, "\r\n", 2, &written, NULL);
            }
        }
    }
    // Final flush
    LogEntry e;
    while (ring().pop(e)) {
        if (ring().file != INVALID_HANDLE_VALUE) {
            DWORD written;
            WriteFile(ring().file, e.buf, e.len, &written, NULL);
            WriteFile(ring().file, "\r\n", 2, &written, NULL);
        }
    }
    return 0;
}

inline void init_file() {
    // Share flags include DELETE/WRITE: a stale game instance holding this file
    // must not make it undeletable for deploy.ps1 (a leftover with a Results
    // line in an undeletable log makes every future deploy false-match instantly).
    ring().file = CreateFileA(
        "C:\\ProgramData\\japi_debug.txt",
        GENERIC_WRITE, FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, NULL,
        CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, NULL);

    if (ring().file == INVALID_HANDLE_VALUE) {
        // Primary is locked by a stale instance running an OLD binary (opened
        // without DELETE share). Fall back to a per-pid log so this run still
        // has output; deploy.ps1 polls both paths.
        char alt[128];
        snprintf(alt, sizeof(alt), "C:\\ProgramData\\japi_debug_%lu.txt",
            (unsigned long)GetCurrentProcessId());
        ring().file = CreateFileA(alt,
            GENERIC_WRITE, FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, NULL,
            CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, NULL);
    }

    ring().stop_event = CreateEventA(NULL, TRUE, FALSE, NULL);
    ring().thread = CreateThread(NULL, 0, flush_thread, NULL, 0, NULL);

    char dbg[128];
    snprintf(dbg, sizeof(dbg), "init_file: file=%p event=%p thread=%p",
        ring().file, ring().stop_event, ring().thread);
    sync_write(dbg);
}

inline void shutdown() {
    if (ring().thread) {
        SetEvent(ring().stop_event);
        WaitForSingleObject(ring().thread, 2000);
        CloseHandle(ring().thread);
        ring().thread = NULL;
    }
    if (ring().stop_event) {
        CloseHandle(ring().stop_event);
        ring().stop_event = NULL;
    }
    if (ring().file != INVALID_HANDLE_VALUE) {
        CloseHandle(ring().file);
        ring().file = INVALID_HANDLE_VALUE;
    }
    FreeConsole();
}

inline void log(const char* fmt, ...) {
    char buf[512];
    va_list args;
    va_start(args, fmt);
    int len = vsnprintf(buf, sizeof(buf) - 1, fmt, args);
    va_end(args);
    if (len <= 0) return;
    if (len > 511) len = 511;

    // Console (immediate)
    printf("%s\n", buf);

    // Ring buffer (async file)
    ring().push(buf, len);
}

}  // namespace japi_log

#define DBG_INIT()   do { japi_log::init_console(); japi_log::init_file(); } while(0)
#define DBG_LOG(...)  japi_log::log(__VA_ARGS__)
#define DBG_SHUTDOWN() japi_log::shutdown()

#else  // JAPI_DEBUG not defined

#define DBG_INIT()      ((void)0)
#define DBG_LOG(...)    ((void)0)
#define DBG_SHUTDOWN()  ((void)0)

#endif
