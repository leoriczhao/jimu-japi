// stubs.cpp — Provides missing symbols for the minimal build

#include <windows.h>
#include <cstdint>
#include <cstring>
#include <base/win/pe_reader.h>
#include <base/hook/patch.h>
#include <warcraft3/jass.h>

// === base::win::pe_reader ===
namespace base::win {
    pe_reader::pe_reader() : module_(0) {}
    pe_reader::pe_reader(HMODULE mod) : module_((uintptr_t)mod) {}
    void pe_reader::set_module(HMODULE mod) { module_ = (uintptr_t)mod; }
    HMODULE pe_reader::module() const { return (HMODULE)module_; }
    size_t pe_reader::module_size() const {
        if (!module_) return 0;
        auto dos = get_dos_header();
        auto nt = get_nt_headers();
        if (!dos || !nt) return 0;
        return nt->OptionalHeader.SizeOfImage;
    }
    uintptr_t pe_reader::rva_to_addr(uintptr_t rva) const {
        return module_ + rva;
    }
    PIMAGE_DOS_HEADER pe_reader::get_dos_header() const {
        return (PIMAGE_DOS_HEADER)module_;
    }
    PIMAGE_NT_HEADERS pe_reader::get_nt_headers() const {
        auto dos = get_dos_header();
        if (!dos || dos->e_magic != IMAGE_DOS_SIGNATURE) return nullptr;
        return (PIMAGE_NT_HEADERS)(module_ + dos->e_lfanew);
    }
    uintptr_t pe_reader::get_directory_entry(uint32_t directory) const {
        auto nt = get_nt_headers();
        if (!nt || directory >= IMAGE_NUMBEROF_DIRECTORY_ENTRIES) return 0;
        // Absolute address, matching base/win/pe_reader.cpp: callers
        // (import/export address tables) cast the result straight to a pointer.
        return rva_to_addr(nt->OptionalHeader.DataDirectory[directory].VirtualAddress);
    }
    uint32_t pe_reader::get_directory_entry_size(uint32_t directory) const {
        auto nt = get_nt_headers();
        if (!nt || directory >= IMAGE_NUMBEROF_DIRECTORY_ENTRIES) return 0;
        return nt->OptionalHeader.DataDirectory[directory].Size;
    }
    uint32_t pe_reader::get_num_sections() const {
        auto nt = get_nt_headers();
        if (!nt) return 0;
        return nt->FileHeader.NumberOfSections;
    }
    PIMAGE_SECTION_HEADER pe_reader::get_section_by_name(const char* name) const {
        auto nt = get_nt_headers();
        if (!nt) return nullptr;
        auto section = IMAGE_FIRST_SECTION(nt);
        for (unsigned i = 0; i < nt->FileHeader.NumberOfSections; ++i) {
            if (strncmp((const char*)section[i].Name, name, IMAGE_SIZEOF_SHORT_NAME) == 0)
                return &section[i];
        }
        return nullptr;
    }
}

// === base::hook::replace_pointer ===
namespace base::hook {
    uintptr_t replace_pointer(uintptr_t address, uintptr_t new_value) {
        DWORD old_protect;
        uintptr_t old_value = 0;
        if (VirtualProtect((void*)address, sizeof(uintptr_t), PAGE_EXECUTE_READWRITE, &old_protect)) {
            old_value = *(uintptr_t*)address;
            *(uintptr_t*)address = new_value;
            VirtualProtect((void*)address, sizeof(uintptr_t), old_protect, &old_protect);
        }
        return old_value;
    }
}

// === base::hook::patch_guard ===
// Backup-then-write byte patch. The free patch() above is one-shot; this one can
// be undone, which is what map-level hook lifetimes need (see patch.h).
namespace base::hook {
    bool patch_guard::apply(uintptr_t address, const void* value, size_t size)
    {
        if (!address || !value || size == 0 || size > kMaxSize) return false;
        if (active()) restore();

        DWORD old_protect = 0;
        if (!VirtualProtect((void*)address, size, PAGE_EXECUTE_READWRITE, &old_protect)) {
            return false;
        }
        memcpy(original_, (const void*)address, size);
        size_ = size;
        address_ = address;
        memcpy((void*)address, value, size);
        FlushInstructionCache(GetCurrentProcess(), (void*)address, size);
        VirtualProtect((void*)address, size, old_protect, &old_protect);
        return true;
    }

    bool patch_guard::restore()
    {
        if (!active()) return true;

        DWORD old_protect = 0;
        bool ok = false;
        if (VirtualProtect((void*)address_, size_, PAGE_EXECUTE_READWRITE, &old_protect)) {
            memcpy((void*)address_, original_, size_);
            FlushInstructionCache(GetCurrentProcess(), (void*)address_, size_);
            VirtualProtect((void*)address_, size_, old_protect, &old_protect);
            ok = true;
        }
        // Forget the record either way: a half-restored guard must not be
        // replayed, and a failed VirtualProtect means the page is gone.
        address_ = 0;
        size_ = 0;
        memset(original_, 0, sizeof(original_));
        return ok;
    }
}

// === base::console ===
namespace base::console {
    void enable() {
        AllocConsole();
    }
    void disable() {
        FreeConsole();
    }
    bool disable_close_button() {
        return true;
    }
}

// === base::hook::iat: the real implementation is compiled in (base/hook/iat.cpp) ===

// === warcraft3::jass::from_real / to_real ===
namespace warcraft3::jass {
    float from_real(jreal_t val) {
        float result;
        memcpy(&result, &val, sizeof(float));
        return result;
    }
    jreal_t to_real(float val) {
        jreal_t result;
        memcpy(&result, &val, sizeof(float));
        return result;
    }
}

// === base::hook::install ===
namespace base::hook {
    bool install(uintptr_t* target, uintptr_t new_func, void** old_func) {
        if (old_func) *old_func = (void*)*target;
        DWORD old_protect;
        if (VirtualProtect(target, sizeof(uintptr_t), PAGE_EXECUTE_READWRITE, &old_protect)) {
            *target = new_func;
            VirtualProtect(target, sizeof(uintptr_t), old_protect, &old_protect);
            return true;
        }
        return false;
    }
}

// warcraft3::japi::initialize is defined in extensions/custom_natives.cpp
