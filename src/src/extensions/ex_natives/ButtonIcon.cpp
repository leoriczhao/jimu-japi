// ButtonIcon.cpp - YDWE EXDclareButtonIcon / EXBlendButtonIcon.
//
// Historical names are preserved exactly (including YDWE's "Dclare" typo).
//
// Runtime flow:
//   * EXDclareButtonIcon(path) registers basename -> normalized archive path in
//     g_icon_history, and (when the source is already readable) eagerly builds
//     the disabled BLP1 palette image into g_virtual_blp so both in-session
//     EXBlendButtonIcon and Storm#279 can serve it directly from memory.
//   * EXBlendButtonIcon(a, b, out) reads 64x64 BLP sources from g_virtual_blp
//     or Storm (ordinal 281 SFileLoadFileEx, bypassing the #279 detour), blends
//     A over B, encodes BLP1 palette, and stores the bytes in g_virtual_blp.
//   * BuiltinCompat.cpp's Storm.dll ordinal 279 (SFileLoadFile) IAT detour
//     calls button_icon_try_load_virtual() before real SFileLoadFile and
//     button_icon_try_generate_disabled() when a CommandButtonsDisabled\DIS*
//     request misses, allocating the returned buffer via Storm ordinal 401
//     (SMemAlloc) so the engine can free it with SFileUnloadFile.
//   * Disk staging under <map dir>\japi-button-icons\ is kept as a fallback
//     when the Storm#279 detour is inactive (e.g. coexistence mode) or when
//     JAPI_BUTTON_ICON_STAGE=1 is set explicitly.
#include <windows.h>

#include <algorithm>
#include <atomic>
#include <cctype>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <exception>
#include <filesystem>
#include <fstream>
#include <limits>
#include <map>
#include <mutex>
#include <string>
#include <system_error>
#include <vector>

#include <base/hook/fp_call.h>
#include <image/blp_codec.h>
#include <image/button_icon.h>
#include <lua_engine/lua_engine/storm.h>
#include <warcraft3/jass.h>
#include <warcraft3/jass/hook.h>

#include "debug_log.h"

namespace warcraft3::japi {

	// The standalone image module lives in the global japi::image namespace.
	namespace image = ::japi::image;

	namespace {

		constexpr size_t kMaxIconFileSize = 16u * 1024u * 1024u;
		constexpr const char kDisPrefix[] = "replaceabletextures\\commandbuttonsdisabled\\dis";
		constexpr size_t kDisPrefixLen = sizeof(kDisPrefix) - 1;

		struct CaseInsensitiveLess {
			bool operator()(const std::string& a, const std::string& b) const
			{
				const size_t n = (a.size() < b.size()) ? a.size() : b.size();
				for (size_t i = 0; i < n; ++i) {
					const unsigned char ca = static_cast<unsigned char>(
						std::tolower(static_cast<unsigned char>(a[i])));
					const unsigned char cb = static_cast<unsigned char>(
						std::tolower(static_cast<unsigned char>(b[i])));
					if (ca != cb) return ca < cb;
				}
				return a.size() < b.size();
			}
		};

		std::mutex g_icon_mutex;
		std::map<std::string, std::string, CaseInsensitiveLess> g_icon_history;
		std::map<std::string, std::vector<uint8_t>, CaseInsensitiveLess> g_virtual_blp;
		std::string g_last_filepath;
		std::atomic<bool> g_storm_hook_active{ false };
		uint32_t g_virtual_hit_logs = 0;
		uint32_t g_dis_gen_logs = 0;

		std::string canonical_lookup_key(const char* raw)
		{
			if (!raw || !*raw) return std::string();
			std::string out(raw);
			for (char& c : out) {
				if (c == '/') c = '\\';
			}
			// Collapse accidental double backslashes so Storm lookup matches
			// normalize_archive_path keys.
			std::string compact;
			compact.reserve(out.size());
			for (char c : out) {
				if (c == '\\' && !compact.empty() && compact.back() == '\\') continue;
				compact.push_back(c);
			}
			return compact;
		}

		bool iequals_ascii(const std::string& a, const std::string& b)
		{
			if (a.size() != b.size()) return false;
			for (size_t i = 0; i < a.size(); ++i) {
				if (std::tolower(static_cast<unsigned char>(a[i]))
					!= std::tolower(static_cast<unsigned char>(b[i]))) {
					return false;
				}
			}
			return true;
		}

		bool istarts_with_ascii(const std::string& text, const char* prefix, size_t prefix_len)
		{
			if (text.size() < prefix_len) return false;
			for (size_t i = 0; i < prefix_len; ++i) {
				if (std::tolower(static_cast<unsigned char>(text[i]))
					!= std::tolower(static_cast<unsigned char>(prefix[i]))) {
					return false;
				}
			}
			return true;
		}

		bool should_stage_to_disk()
		{
			if (!g_storm_hook_active.load(std::memory_order_acquire)) {
				return true;
			}
			char flag[8] = { 0 };
			const DWORD n = ::GetEnvironmentVariableA("JAPI_BUTTON_ICON_STAGE", flag, sizeof(flag));
			return (n > 0 && flag[0] == '1');
		}

		std::wstring utf8_to_wide(const std::string& text)
		{
			if (text.empty()) return std::wstring();
			const int needed = ::MultiByteToWideChar(CP_UTF8, 0, text.c_str(),
				static_cast<int>(text.size()), nullptr, 0);
			if (needed <= 0) return std::wstring();
			std::wstring wide(static_cast<size_t>(needed), L'\0');
			::MultiByteToWideChar(CP_UTF8, 0, text.c_str(),
				static_cast<int>(text.size()), wide.data(), needed);
			return wide;
		}

		std::string wide_to_utf8(const std::wstring& text)
		{
			if (text.empty()) return std::string();
			const int needed = ::WideCharToMultiByte(CP_UTF8, 0, text.c_str(),
				static_cast<int>(text.size()), nullptr, 0, nullptr, nullptr);
			if (needed <= 0) return std::string();
			std::string utf8(static_cast<size_t>(needed), '\0');
			::WideCharToMultiByte(CP_UTF8, 0, text.c_str(),
				static_cast<int>(text.size()), utf8.data(), needed, nullptr, nullptr);
			return utf8;
		}

		std::wstring game_directory()
		{
			wchar_t exe[MAX_PATH] = { 0 };
			::GetModuleFileNameW(nullptr, exe, MAX_PATH);
			wchar_t* slash = wcsrchr(exe, L'\\');
			if (slash) *slash = L'\0';
			return std::wstring(exe);
		}

		// Same resolution rule as jass.storm.save: the directory of the map
		// archive, with a game-directory fallback when SFileGetArchiveName is
		// unavailable (editor or unusual launch).
		std::wstring map_side_directory()
		{
			char archive[MAX_PATH * 2] = { 0 };
			storm_dll& storm = storm_s::instance();
			if (storm.valid() && storm.get_mpq_name(archive, sizeof(archive))) {
				std::wstring wide = utf8_to_wide(archive);
				for (wchar_t& c : wide) {
					if (c == L'/') c = L'\\';
				}
				const size_t slash = wide.find_last_of(L'\\');
				std::wstring directory =
					(slash == std::wstring::npos) ? std::wstring() : wide.substr(0, slash);
				if (!directory.empty()) {
					const bool absolute = directory.size() > 1 && directory[1] == L':';
					const bool unc = directory.size() > 1 && directory[0] == L'\\'
						&& directory[1] == L'\\';
					if (absolute || unc) return directory;
					return game_directory() + L'\\' + directory;
				}
			}
			return game_directory();
		}

		bool read_disk_file(const std::filesystem::path& path,
			std::vector<uint8_t>& bytes)
		{
			std::error_code ec;
			const uint64_t size = std::filesystem::file_size(path, ec);
			if (ec || size > kMaxIconFileSize) return false;
			std::ifstream stream(path, std::ios::binary);
			if (!stream) return false;
			bytes.resize(static_cast<size_t>(size));
			if (!bytes.empty()) {
				stream.read(reinterpret_cast<char*>(bytes.data()),
					static_cast<std::streamsize>(bytes.size()));
				if (!stream) {
					bytes.clear();
					return false;
				}
			}
			return true;
		}

		bool read_virtual_copy(const std::string& archive_path, std::vector<uint8_t>& bytes)
		{
			std::lock_guard<std::mutex> lock(g_icon_mutex);
			auto it = g_virtual_blp.find(archive_path);
			if (it == g_virtual_blp.end()) return false;
			bytes = it->second;
			return true;
		}

		bool read_archive_file(const std::string& archive_path,
			std::vector<uint8_t>& bytes, std::string* error)
		{
			// Prefer in-memory virtual icons generated earlier in this session
			// (e.g. EXBlendButtonIcon consuming another blended/disabled icon).
			if (read_virtual_copy(archive_path, bytes)) {
				return true;
			}

			storm_dll& storm = storm_s::instance();
			if (storm.valid()) {
				const void* buffer = nullptr;
				size_t size = 0;
				// storm.load_file calls Storm ordinal 281 (SFileLoadFileEx)
				// directly via GetProcAddress, bypassing Game.dll's #279 IAT.
				if (storm.load_file(archive_path.c_str(), &buffer, &size)) {
					if (!buffer || size == 0 || size > kMaxIconFileSize) {
						if (buffer) storm.unload_file(buffer);
						if (error) *error = "MPQ file is empty or larger than 16 MiB: " + archive_path;
						return false;
					}
					bytes.assign(static_cast<const uint8_t*>(buffer),
						static_cast<const uint8_t*>(buffer) + size);
					storm.unload_file(buffer);
					return true;
				}
			}

			const std::filesystem::path staged =
				std::filesystem::path(map_side_directory()) / L"japi-button-icons"
				/ std::filesystem::path(utf8_to_wide(archive_path));
			if (read_disk_file(staged, bytes)) {
				DBG_LOG("[ButtonIcon] read staged file %s", archive_path.c_str());
				return true;
			}
			if (error) *error = "MPQ file not found: " + archive_path;
			return false;
		}

		bool write_staging_file(const std::string& normalized,
			const std::vector<uint8_t>& bytes, std::string* written_path,
			std::string* error)
		{
			const std::filesystem::path root =
				std::filesystem::path(map_side_directory()) / L"japi-button-icons";
			const std::filesystem::path target =
				root / std::filesystem::path(utf8_to_wide(normalized));
			std::error_code ec;
			std::filesystem::create_directories(target.parent_path(), ec);
			if (ec) {
				if (error) *error = "cannot create icon staging directory: " + ec.message();
				return false;
			}
			std::ofstream stream(target, std::ios::binary | std::ios::trunc);
			if (!stream) {
				if (error) *error = "cannot open icon staging file";
				return false;
			}
			if (!bytes.empty()) {
				stream.write(reinterpret_cast<const char*>(bytes.data()),
					static_cast<std::streamsize>(bytes.size()));
			}
			if (!stream) {
				if (error) *error = "cannot write icon staging file";
				return false;
			}
			if (written_path) *written_path = wide_to_utf8(target.wstring());
			return true;
		}

		std::string jstring_to_utf8(jass::jstring_t value)
		{
			const char* raw = jass::from_string(value);
			if (!raw) return std::string();
			const char* expanded = jass::from_trigstring(raw);
			return std::string(expanded ? expanded : raw);
		}

		bool load_icon(const std::string& archive_path, image::Image& icon,
			std::string* error)
		{
			std::string normalized;
			if (!image::normalize_archive_path(archive_path, normalized, error)) {
				return false;
			}
			std::vector<uint8_t> bytes;
			if (!read_archive_file(normalized, bytes, error)) return false;
			const image::Status status =
				image::decode_blp(bytes.data(), bytes.size(), icon, error);
			if (status != image::Status::Ok) {
				if (error) {
					*error = std::string("cannot decode ") + normalized + ": "
						+ image::status_name(status) + ": " + *error;
				}
				return false;
			}
			return true;
		}

		bool encode_icon_bytes(const image::Image& icon, std::vector<uint8_t>& encoded,
			std::string* error)
		{
			const image::Status status =
				image::encode_blp1_palette(icon, encoded, error);
			if (status != image::Status::Ok) {
				if (error) {
					*error = std::string("cannot encode icon: ")
						+ image::status_name(status) + ": " + *error;
				}
				return false;
			}
			return true;
		}

		bool serve_storm_buffer(const std::vector<uint8_t>& data,
			const void** buffer_ptr, uint32_t* size_ptr,
			uint32_t reserve_size, OVERLAPPED* overlapped_ptr)
		{
			if (!buffer_ptr) return false;
			storm_dll& storm = storm_s::instance();
			if (!storm.valid()) return false;
			static uintptr_t fn_smem_alloc = storm.get_proc(401);
			if (!fn_smem_alloc) {
				fn_smem_alloc = storm.get_proc(401);
				if (!fn_smem_alloc) return false;
			}
			if (reserve_size > (std::numeric_limits<size_t>::max)() - data.size()) {
				return false;
			}
			void* result = base::std_call<void*>(
				fn_smem_alloc, data.size() + reserve_size, ".\\SFile.cpp", 4072, 0);
			if (!result) return false;
			if (!data.empty()) {
				std::memcpy(result, data.data(), data.size());
			}
			if (reserve_size) {
				std::memset(static_cast<uint8_t*>(result) + data.size(), 0, reserve_size);
			}
			*buffer_ptr = result;
			if (size_ptr) *size_ptr = static_cast<uint32_t>(data.size());
			if (overlapped_ptr && overlapped_ptr->hEvent) {
				::SetEvent(overlapped_ptr->hEvent);
			}
			return true;
		}

		void store_virtual_and_maybe_stage(const std::string& normalized,
			const std::vector<uint8_t>& encoded, std::string* written_path)
		{
			{
				std::lock_guard<std::mutex> lock(g_icon_mutex);
				g_virtual_blp[normalized] = encoded;
			}
			if (should_stage_to_disk()) {
				std::string stage_error;
				if (!write_staging_file(normalized, encoded, written_path, &stage_error)) {
					DBG_LOG("[ButtonIcon] staging %s skipped: %s",
						normalized.c_str(), stage_error.c_str());
				}
			}
		}

		bool declare_button_icon(const std::string& source_path,
			std::string* written_path, std::string* error)
		{
			std::string normalized;
			if (!image::normalize_archive_path(source_path, normalized, error)) {
				return false;
			}
			const std::string basename = image::archive_basename(normalized);
			if (!basename.empty()) {
				std::lock_guard<std::mutex> lock(g_icon_mutex);
				g_icon_history[basename] = normalized;
			}

			// Eagerly build the disabled BLP if the source is already available.
			// If the source has not been generated yet (e.g. EXBlendButtonIcon
			// will produce it later), keep the g_icon_history registration so
			// Storm#279 can generate DIS<basename> on demand.
			image::Image source;
			std::string load_err;
			if (!load_icon(normalized, source, &load_err)) {
				if (g_storm_hook_active.load(std::memory_order_acquire)) {
					DBG_LOG("[ButtonIcon] EXDclareButtonIcon(%s) registered for lazy generation (%s)",
						normalized.c_str(), load_err.c_str());
					return true;
				}
				if (error) *error = load_err;
				return false;
			}

			image::Image disabled;
			if (!image::make_disabled_icon(source, disabled, error)) return false;
			std::string disabled_archive;
			if (!image::disabled_icon_archive_path(normalized, disabled_archive, error)) {
				return false;
			}
			std::vector<uint8_t> encoded;
			if (!encode_icon_bytes(disabled, encoded, error)) return false;
			store_virtual_and_maybe_stage(disabled_archive, encoded, written_path);
			return true;
		}

		bool blend_button_icons_impl(const std::string& input_a, const std::string& input_b,
			const std::string& output_path, std::string* written_path,
			std::string* error)
		{
			std::string normalized_output;
			if (!image::normalize_archive_path(output_path, normalized_output, error)) {
				return false;
			}
			if (!image::has_blp_extension(normalized_output)) {
				if (error) *error = "EXBlendButtonIcon output must end in .blp";
				return false;
			}

			image::Image a;
			image::Image b;
			if (!load_icon(input_a, a, error)) return false;
			if (!load_icon(input_b, b, error)) return false;
			image::Image blended;
			if (!image::blend_button_icons(a, b, blended, error)) return false;

			std::vector<uint8_t> encoded;
			if (!encode_icon_bytes(blended, encoded, error)) return false;
			store_virtual_and_maybe_stage(normalized_output, encoded, written_path);
			return true;
		}

		bool generate_disabled_from_source(const std::string& source_path,
			const std::string& dis_key, std::vector<uint8_t>& out_encoded)
		{
			image::Image source;
			std::string err;
			if (!load_icon(source_path, source, &err)) {
				return false;
			}
			image::Image disabled;
			if (!image::make_disabled_icon(source, disabled, &err)) {
				return false;
			}
			if (!encode_icon_bytes(disabled, out_encoded, &err)) {
				return false;
			}
			{
				std::lock_guard<std::mutex> lock(g_icon_mutex);
				g_virtual_blp[dis_key] = out_encoded;
			}
			return true;
		}

	}  // namespace

	void clear_button_icons()
	{
		std::lock_guard<std::mutex> lock(g_icon_mutex);
		const size_t virt_n = g_virtual_blp.size();
		const size_t hist_n = g_icon_history.size();
		g_virtual_blp.clear();
		g_icon_history.clear();
		g_last_filepath.clear();
		g_virtual_hit_logs = 0;
		g_dis_gen_logs = 0;
		if (virt_n > 0 || hist_n > 0) {
			char buf[160];
			snprintf(buf, sizeof(buf),
				"[ButtonIcon] cleared %u virtual BLP(s) and %u history entry(ies) on map boot",
				static_cast<unsigned>(virt_n), static_cast<unsigned>(hist_n));
			japi_log::sync_write(buf);
		}
	}

	void set_button_icon_storm_hook_active(bool active)
	{
		g_storm_hook_active.store(active, std::memory_order_release);
	}

	void button_icon_note_loaded_path(const char* filepath)
	{
		if (!filepath || !*filepath) return;
		std::string key = canonical_lookup_key(filepath);
		if (key.empty()) return;
		std::lock_guard<std::mutex> lock(g_icon_mutex);
		g_last_filepath = std::move(key);
	}

	bool button_icon_try_load_virtual(const char* filepath,
		const void** buffer_ptr, uint32_t* size_ptr,
		uint32_t reserve_size, OVERLAPPED* overlapped_ptr)
	{
		if (!filepath || !*filepath || !buffer_ptr) return false;
		const std::string key = canonical_lookup_key(filepath);
		if (key.empty()) return false;

		std::vector<uint8_t> data;
		uint32_t log_idx = 0;
		{
			std::lock_guard<std::mutex> lock(g_icon_mutex);
			auto it = g_virtual_blp.find(key);
			if (it == g_virtual_blp.end()) return false;
			data = it->second;
			log_idx = ++g_virtual_hit_logs;
		}

		if (!serve_storm_buffer(data, buffer_ptr, size_ptr, reserve_size, overlapped_ptr)) {
			return false;
		}
		if (log_idx <= 30) {
			char buf[320];
			snprintf(buf, sizeof(buf), "[ButtonIcon] virtual BLP hit: \"%s\" (%u bytes)",
				key.c_str(), static_cast<unsigned>(data.size()));
			japi_log::sync_write(buf);
		}
		return true;
	}

	bool button_icon_try_generate_disabled(const char* filepath,
		const void** buffer_ptr, uint32_t* size_ptr,
		uint32_t reserve_size, OVERLAPPED* overlapped_ptr)
	{
		if (!filepath || !*filepath || !buffer_ptr) return false;
		const std::string key = canonical_lookup_key(filepath);
		if (!istarts_with_ascii(key, kDisPrefix, kDisPrefixLen)) {
			return false;
		}

		const std::string filename = key.substr(kDisPrefixLen);
		if (filename.empty()) return false;

		// Mirror YDWE DisableButtonBlp.cpp lookup order:
		//   1. If g_last_filepath's basename matches filename, try g_last_filepath.
		//   2. Otherwise (or if g_last_filepath itself was a DIS path), walk
		//      g_icon_history stripping repeated "dis" prefixes.
		std::vector<std::string> candidates;
		{
			std::lock_guard<std::mutex> lock(g_icon_mutex);
			const std::string last_base = image::archive_basename(g_last_filepath);
			if (!g_last_filepath.empty() && iequals_ascii(last_base, filename)) {
				if (!istarts_with_ascii(g_last_filepath, kDisPrefix, kDisPrefixLen)) {
					candidates.push_back(g_last_filepath);
				} else {
					const std::string last_dis = g_last_filepath.substr(kDisPrefixLen);
					for (size_t off = 0; off < last_dis.size(); off += 3) {
						auto it = g_icon_history.find(last_dis.substr(off));
						if (it != g_icon_history.end()) {
							candidates.push_back(it->second);
							break;
						}
						if (last_dis.size() - off < 3
							|| !istarts_with_ascii(last_dis.substr(off), "dis", 3)) {
							break;
						}
					}
				}
			}

			for (size_t off = 0; off < filename.size(); off += 3) {
				auto it = g_icon_history.find(filename.substr(off));
				if (it != g_icon_history.end()) {
					if (std::find(candidates.begin(), candidates.end(), it->second) == candidates.end()) {
						candidates.push_back(it->second);
					}
					break;
				}
				if (filename.size() - off < 3
					|| !istarts_with_ascii(filename.substr(off), "dis", 3)) {
					break;
				}
			}
		}

		for (const std::string& source_path : candidates) {
			std::vector<uint8_t> encoded;
			if (!generate_disabled_from_source(source_path, key, encoded)) {
				continue;
			}
			{
				std::lock_guard<std::mutex> lock(g_icon_mutex);
				g_icon_history[filename] = source_path;
			}
			if (!serve_storm_buffer(encoded, buffer_ptr, size_ptr, reserve_size, overlapped_ptr)) {
				return false;
			}
			uint32_t log_idx = 0;
			{
				std::lock_guard<std::mutex> lock(g_icon_mutex);
				log_idx = ++g_dis_gen_logs;
			}
			if (log_idx <= 30) {
				char buf[384];
				snprintf(buf, sizeof(buf),
					"[ButtonIcon] on-demand DIS generated: \"%s\" <- \"%s\" (%u bytes)",
					key.c_str(), source_path.c_str(), static_cast<unsigned>(encoded.size()));
				japi_log::sync_write(buf);
			}
			return true;
		}

		return false;
	}

	// Real JASS natives (registered via jass::japi_add, matching YDWE signatures)
	void __cdecl EXDclareButtonIcon(jass::jstring_t path_handle)
	{
		const std::string path = jstring_to_utf8(path_handle);
		if (path.empty()) {
			DBG_LOG("[ButtonIcon] EXDclareButtonIcon: empty path");
			return;
		}
		try {
			std::string written;
			std::string error;
			if (!declare_button_icon(path, &written, &error)) {
				DBG_LOG("[ButtonIcon] EXDclareButtonIcon(%s) failed: %s",
					path.c_str(), error.c_str());
				return;
			}
			if (!written.empty()) {
				DBG_LOG("[ButtonIcon] EXDclareButtonIcon(%s) virtual+staged %s",
					path.c_str(), written.c_str());
			} else {
				DBG_LOG("[ButtonIcon] EXDclareButtonIcon(%s) ready in virtual BLP",
					path.c_str());
			}
		} catch (const std::exception& error) {
			DBG_LOG("[ButtonIcon] EXDclareButtonIcon(%s) exception: %s",
				path.c_str(), error.what());
		}
	}

	jass::jboolean_t __cdecl EXBlendButtonIcon(jass::jstring_t input_a_handle,
		jass::jstring_t input_b_handle, jass::jstring_t output_handle)
	{
		const std::string input_a = jstring_to_utf8(input_a_handle);
		const std::string input_b = jstring_to_utf8(input_b_handle);
		const std::string output = jstring_to_utf8(output_handle);
		if (input_a.empty() || input_b.empty() || output.empty()) {
			DBG_LOG("[ButtonIcon] EXBlendButtonIcon: empty path argument");
			return 0;
		}
		try {
			std::string written;
			std::string error;
			if (!blend_button_icons_impl(input_a, input_b, output, &written, &error)) {
				DBG_LOG("[ButtonIcon] EXBlendButtonIcon(%s, %s, %s) failed: %s",
					input_a.c_str(), input_b.c_str(), output.c_str(), error.c_str());
				return 0;
			}
			if (!written.empty()) {
				DBG_LOG("[ButtonIcon] EXBlendButtonIcon virtual+staged %s", written.c_str());
			} else {
				DBG_LOG("[ButtonIcon] EXBlendButtonIcon ready in virtual BLP: %s", output.c_str());
			}
		} catch (const std::exception& error) {
			DBG_LOG("[ButtonIcon] EXBlendButtonIcon exception: %s", error.what());
			return 0;
		}
		return 1;
	}

	void InitializeButtonIcon()
	{
		jass::japi_add((uintptr_t)EXDclareButtonIcon, "EXDclareButtonIcon", "(S)V");
		jass::japi_add((uintptr_t)EXBlendButtonIcon,  "EXBlendButtonIcon",  "(SSS)B");
	}

	uint32_t EXDclareButtonIcon_handler(const uint32_t* args, size_t)
	{
		EXDclareButtonIcon(static_cast<jass::jstring_t>(args[0]));
		return 0;
	}

	uint32_t EXBlendButtonIcon_handler(const uint32_t* args, size_t)
	{
		return EXBlendButtonIcon(
			static_cast<jass::jstring_t>(args[0]),
			static_cast<jass::jstring_t>(args[1]),
			static_cast<jass::jstring_t>(args[2])) ? 1u : 0u;
	}

}  // namespace warcraft3::japi
