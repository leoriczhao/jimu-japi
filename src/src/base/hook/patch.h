#pragma once

#include <base/config.h>
#include <string>
#include <cassert>
#include <cstdint>
#include <cstddef>

namespace base { namespace hook {
	_BASE_API bool patch(uintptr_t address, const char* value, size_t value_size);

	// patch_guard — a byte patch that remembers what it overwrote.
	//
	// patch() above writes and forgets: fine for a process-lifetime tweak, wrong
	// for anything tied to a map session (enter map -> hook, leave map -> unhook).
	// builtin-japi's jass.dll keeps exactly this record per patch
	// (target / original bytes / length / old protection, see
	// docs/re-builtin-japi/10-tables-hooks-and-game-side.md), so a second entry
	// into the map re-patches instead of double-patching.
	//
	// Non-copyable: the backup belongs to the single patch it describes.
	class _BASE_API patch_guard
	{
	public:
		static const size_t kMaxSize = 64;

		patch_guard() = default;
		patch_guard(uintptr_t address, const void* value, size_t size) { apply(address, value, size); }
		~patch_guard() { restore(); }

		patch_guard(const patch_guard&) = delete;
		patch_guard& operator=(const patch_guard&) = delete;

		// Back up `size` bytes at `address`, then overwrite them with `value`.
		// Fails (and leaves nothing installed) when size > kMaxSize or the
		// protection change fails.
		bool apply(uintptr_t address, const void* value, size_t size);
		bool apply(uintptr_t address, const char* value) { return apply(address, value, std::string::traits_type::length(value)); }

		// Put the original bytes back and forget them. Idempotent.
		bool restore();

		bool active() const { return address_ != 0; }
		uintptr_t address() const { return address_; }
		size_t size() const { return size_; }
		const uint8_t* original() const { return original_; }

	private:
		uintptr_t address_ = 0;
		size_t size_ = 0;
		uint8_t original_[kMaxSize] = {};
	};


	template <size_t n>
	bool patch(uintptr_t address, const char(&value)[n])
	{
		assert(n > 1);
		return patch(address, value, n - 1);
	}

	template <size_t n>
	bool patch(uintptr_t address, char(&value)[n])
	{
		return patch(address, value, std::string::traits_type::length(value));
	}
}}
