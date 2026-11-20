// ydwe_button_icon.cpp - offline command-button icon generator.
//
//   ydwe_button_icon probe <file.blp>
//   ydwe_button_icon disable <enabled.blp> <out-root> [archive-path]
//   ydwe_button_icon blend <a.blp> <b.blp> <out.blp>
//   ydwe_button_icon raw-disable <enabled.blp> <out.raw>
//   ydwe_button_icon raw-blend <a.blp> <b.blp> <out.raw>
//   ydwe_button_icon run <manifest.txt> <out-root>
//
// `disable` writes the standard
//   ReplaceableTextures\CommandButtonsDisabled\DIS<name>.blp
// below <out-root> and appends the path to <out-root>\(listfile), so the
// directory can be used directly as tools/pack.ps1 -BaseMap <out-root>.
//
// `disable`/`blend` never touch a game process, MPQ, or network. The manifest
// form is line based:
//   # comment
//   disable <source.blp> [archive-path]
//   blend   <a.blp> <b.blp> <archive-output-path>
// Relative manifest paths are resolved against the manifest's directory.
#include "blp_codec.h"
#include "button_icon.h"

#include <windows.h>

#include <algorithm>
#include <cctype>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <string>
#include <vector>

namespace fs = std::filesystem;

namespace {

constexpr const char kRawMagic[8] = { 'J', 'A', 'P', 'I', 'R', 'A', 'W', '1' };
constexpr uint64_t kMaxInputSize = 64ull * 1024ull * 1024ull;

std::string to_utf8(const std::wstring& text)
{
    if (text.empty()) return std::string();
    const int needed = WideCharToMultiByte(CP_UTF8, 0, text.c_str(),
        static_cast<int>(text.size()), nullptr, 0, nullptr, nullptr);
    if (needed <= 0) return std::string();
    std::string out(static_cast<size_t>(needed), '\0');
    WideCharToMultiByte(CP_UTF8, 0, text.c_str(), static_cast<int>(text.size()),
        out.data(), needed, nullptr, nullptr);
    return out;
}

std::string to_utf8(const wchar_t* text)
{
    return to_utf8(std::wstring(text ? text : L""));
}

std::string to_utf8(const fs::path& path)
{
    return to_utf8(path.wstring());
}

bool read_file(const fs::path& path, std::vector<uint8_t>& out, std::string& error)
{
    std::error_code ec;
    const uint64_t size = fs::file_size(path, ec);
    if (ec) {
        error = "cannot stat input: " + ec.message();
        return false;
    }
    if (size > kMaxInputSize) {
        error = "input is larger than 64 MiB";
        return false;
    }
    std::ifstream stream(path, std::ios::binary);
    if (!stream) {
        error = "cannot open input";
        return false;
    }
    out.resize(static_cast<size_t>(size));
    if (!out.empty()) {
        stream.read(reinterpret_cast<char*>(out.data()),
                    static_cast<std::streamsize>(out.size()));
        if (!stream) {
            error = "cannot read input";
            return false;
        }
    }
    return true;
}

bool write_file(const fs::path& path, const void* data, size_t size,
                std::string& error)
{
    std::error_code ec;
    if (!path.parent_path().empty()) {
        fs::create_directories(path.parent_path(), ec);
        if (ec) {
            error = "cannot create output directory: " + ec.message();
            return false;
        }
    }
    std::ofstream stream(path, std::ios::binary | std::ios::trunc);
    if (!stream) {
        error = "cannot open output";
        return false;
    }
    if (size) {
        stream.write(static_cast<const char*>(data),
                     static_cast<std::streamsize>(size));
    }
    if (!stream) {
        error = "cannot write output";
        return false;
    }
    return true;
}

bool load_icon(const fs::path& path, japi::image::Image& image, std::string& error)
{
    std::vector<uint8_t> bytes;
    if (!read_file(path, bytes, error)) return false;
    const japi::image::Status status = japi::image::decode_blp(
        bytes.data(), bytes.size(), image, &error);
    if (status != japi::image::Status::Ok) {
        error = std::string(japi::image::status_name(status)) + ": " + error;
        return false;
    }
    return true;
}

bool write_icon(const fs::path& path, const japi::image::Image& image,
                std::string& error)
{
    std::vector<uint8_t> encoded;
    const japi::image::Status status = japi::image::encode_blp1_palette(
        image, encoded, &error);
    if (status != japi::image::Status::Ok) {
        error = std::string(japi::image::status_name(status)) + ": " + error;
        return false;
    }
    return write_file(path, encoded.data(), encoded.size(), error);
}

bool write_raw(const fs::path& path, const japi::image::Image& image,
               std::string& error)
{
    if (image.width == 0 || image.height == 0 || !image.valid()) {
        error = "raw dump needs a valid image";
        return false;
    }
    std::vector<uint8_t> dump;
    dump.reserve(16 + image.bgra.size());
    dump.insert(dump.end(), kRawMagic, kRawMagic + sizeof(kRawMagic));
    for (int shift = 0; shift < 32; shift += 8) {
        dump.push_back(static_cast<uint8_t>((image.width >> shift) & 0xFF));
    }
    for (int shift = 0; shift < 32; shift += 8) {
        dump.push_back(static_cast<uint8_t>((image.height >> shift) & 0xFF));
    }
    dump.insert(dump.end(), image.bgra.begin(), image.bgra.end());
    return write_file(path, dump.data(), dump.size(), error);
}

bool append_listfile(const fs::path& root, const std::string& archive_path,
                     std::string& error)
{
    const fs::path listfile = root / "(listfile)";
    std::vector<uint8_t> bytes;
    std::error_code ec;
    if (fs::exists(listfile, ec) && !ec) {
        if (!read_file(listfile, bytes, error)) return false;
    }
    std::string text(bytes.begin(), bytes.end());
    std::string needle = archive_path;
    std::transform(needle.begin(), needle.end(), needle.begin(),
        [](unsigned char c) { return static_cast<char>(std::tolower(c)); });

    // Compare whole lines, not substrings: "BTNFoo.blp" must not match an
    // existing "DISBTNFoo.blp" line.
    size_t start = 0;
    while (start <= text.size()) {
        const size_t newline = text.find('\n', start);
        const size_t end = (newline == std::string::npos) ? text.size() : newline;
        std::string line = text.substr(start, end - start);
        if (!line.empty() && line.back() == '\r') line.pop_back();
        std::transform(line.begin(), line.end(), line.begin(),
            [](unsigned char c) { return static_cast<char>(std::tolower(c)); });
        if (line == needle) return true;
        if (newline == std::string::npos) break;
        start = newline + 1;
    }
    if (!text.empty() && text.back() != '\n') text += "\r\n";
    text += archive_path + "\r\n";
    return write_file(listfile, text.data(), text.size(), error);
}

bool write_archive_asset(const fs::path& root, const std::string& archive_path,
                         const japi::image::Image& image, bool update_listfile,
                         std::string& error)
{
    std::string normalized;
    if (!japi::image::normalize_archive_path(archive_path, normalized, &error)) {
        return false;
    }
    const fs::path target = root / fs::path(normalized);
    if (!write_icon(target, image, error)) return false;
    if (update_listfile && !append_listfile(root, normalized, error)) return false;
    std::cout << "OK " << to_utf8(target) << "\n";
    return true;
}

int usage()
{
    std::cerr
        << "usage:\n"
        << "  ydwe_button_icon probe <file.blp>\n"
        << "  ydwe_button_icon disable <enabled.blp> <out-root> [archive-path]\n"
        << "  ydwe_button_icon blend <a.blp> <b.blp> <out.blp>\n"
        << "  ydwe_button_icon raw-disable <enabled.blp> <out.raw>\n"
        << "  ydwe_button_icon raw-blend <a.blp> <b.blp> <out.raw>\n"
        << "  ydwe_button_icon run <manifest.txt> <out-root> [--no-listfile]\n";
    return 2;
}

bool run_manifest(const fs::path& manifest, const fs::path& root,
                  bool update_listfile)
{
    std::ifstream stream(manifest);
    if (!stream) {
        std::cerr << "FAIL cannot open manifest: " << to_utf8(manifest) << "\n";
        return false;
    }
    const fs::path base = manifest.parent_path();
    std::string line;
    size_t line_number = 0;
    size_t failures = 0;
    while (std::getline(stream, line)) {
        ++line_number;
        if (!line.empty() && line.back() == '\r') line.pop_back();
        const size_t comment = line.find('#');
        if (comment != std::string::npos) line.erase(comment);
        const size_t first = line.find_first_not_of(" \t");
        if (first == std::string::npos) continue;
        const size_t last = line.find_last_not_of(" \t");
        line = line.substr(first, last - first + 1);

        std::vector<std::string> words;
        size_t pos = 0;
        while (pos < line.size()) {
            const size_t space = line.find_first_of(" \t", pos);
            const size_t end = (space == std::string::npos) ? line.size() : space;
            if (end > pos) words.push_back(line.substr(pos, end - pos));
            if (space == std::string::npos) break;
            pos = space + 1;
        }
        if (words.empty()) continue;

        std::string error;
        const auto resolve = [&base](const std::string& name) {
            fs::path path = fs::path(name);
            if (path.is_relative()) path = base / path;
            return path;
        };

        if (words[0] == "disable" && (words.size() == 2 || words.size() == 3)) {
            japi::image::Image source;
            if (!load_icon(resolve(words[1]), source, error)) {
                std::cerr << "FAIL line " << line_number << ": " << error << "\n";
                ++failures;
                continue;
            }
            japi::image::Image disabled;
            if (!japi::image::make_disabled_icon(source, disabled, &error)) {
                std::cerr << "FAIL line " << line_number << ": " << error << "\n";
                ++failures;
                continue;
            }
            const std::string archive_source = words.size() == 3
                ? words[2] : japi::image::archive_basename(words[1]);
            std::string archive_out;
            if (!japi::image::disabled_icon_archive_path(
                    archive_source, archive_out, &error)) {
                std::cerr << "FAIL line " << line_number << ": " << error << "\n";
                ++failures;
                continue;
            }
            if (!write_archive_asset(root, archive_out, disabled,
                                     update_listfile, error)) {
                std::cerr << "FAIL line " << line_number << ": " << error << "\n";
                ++failures;
            }
        } else if (words[0] == "blend" && words.size() == 4) {
            japi::image::Image a;
            japi::image::Image b;
            if (!load_icon(resolve(words[1]), a, error)
                || !load_icon(resolve(words[2]), b, error)) {
                std::cerr << "FAIL line " << line_number << ": " << error << "\n";
                ++failures;
                continue;
            }
            japi::image::Image blended;
            if (!japi::image::blend_button_icons(a, b, blended, &error)) {
                std::cerr << "FAIL line " << line_number << ": " << error << "\n";
                ++failures;
                continue;
            }
            if (!write_archive_asset(root, words[3], blended,
                                     update_listfile, error)) {
                std::cerr << "FAIL line " << line_number << ": " << error << "\n";
                ++failures;
            }
        } else {
            std::cerr << "FAIL line " << line_number
                      << ": expected 'disable <source> [archive-path]' or "
                         "'blend <a> <b> <archive-output>'\n";
            ++failures;
        }
    }
    return failures == 0;
}

}  // namespace

int wmain(int argc, wchar_t** argv)
{
    if (argc < 2) return usage();
    const std::wstring command = argv[1];
    std::string error;

    if (command == L"probe") {
        if (argc != 3) return usage();
        japi::image::Image image;
        if (!load_icon(fs::path(argv[2]), image, error)) {
            std::cerr << "FAIL " << error << "\n";
            return 1;
        }
        std::cout << "OK " << image.width << "x" << image.height << "\n";
        return 0;
    }

    if (command == L"disable") {
        if (argc != 4 && argc != 5) return usage();
        japi::image::Image source;
        if (!load_icon(fs::path(argv[2]), source, error)) {
            std::cerr << "FAIL " << error << "\n";
            return 1;
        }
        japi::image::Image disabled;
        if (!japi::image::make_disabled_icon(source, disabled, &error)) {
            std::cerr << "FAIL " << error << "\n";
            return 1;
        }
        const std::string archive_source = argc == 5
            ? to_utf8(argv[4])
            : japi::image::archive_basename(to_utf8(argv[2]));
        std::string archive_out;
        if (!japi::image::disabled_icon_archive_path(
                archive_source, archive_out, &error)) {
            std::cerr << "FAIL " << error << "\n";
            return 1;
        }
        if (!write_archive_asset(fs::path(argv[3]), archive_out, disabled,
                                 true, error)) {
            std::cerr << "FAIL " << error << "\n";
            return 1;
        }
        return 0;
    }

    if (command == L"blend") {
        if (argc != 5) return usage();
        japi::image::Image a;
        japi::image::Image b;
        if (!load_icon(fs::path(argv[2]), a, error)
            || !load_icon(fs::path(argv[3]), b, error)) {
            std::cerr << "FAIL " << error << "\n";
            return 1;
        }
        japi::image::Image blended;
        if (!japi::image::blend_button_icons(a, b, blended, &error)
            || !write_icon(fs::path(argv[4]), blended, error)) {
            std::cerr << "FAIL " << error << "\n";
            return 1;
        }
        std::cout << "OK " << to_utf8(fs::path(argv[4])) << "\n";
        return 0;
    }

    if (command == L"raw-disable" || command == L"raw-blend") {
        if (argc != 4 && argc != 5) return usage();
        japi::image::Image output;
        if (command == L"raw-disable") {
            if (argc != 4) return usage();
            japi::image::Image source;
            if (!load_icon(fs::path(argv[2]), source, error)
                || !japi::image::make_disabled_icon(source, output, &error)) {
                std::cerr << "FAIL " << error << "\n";
                return 1;
            }
        } else {
            if (argc != 5) return usage();
            japi::image::Image a;
            japi::image::Image b;
            if (!load_icon(fs::path(argv[2]), a, error)
                || !load_icon(fs::path(argv[3]), b, error)
                || !japi::image::blend_button_icons(a, b, output, &error)) {
                std::cerr << "FAIL " << error << "\n";
                return 1;
            }
        }
        const fs::path target = command == L"raw-disable"
            ? fs::path(argv[3]) : fs::path(argv[4]);
        if (!write_raw(target, output, error)) {
            std::cerr << "FAIL " << error << "\n";
            return 1;
        }
        std::cout << "OK " << to_utf8(target) << "\n";
        return 0;
    }

    if (command == L"run") {
        if (argc != 4 && argc != 5) return usage();
        bool update_listfile = true;
        if (argc == 5) {
            if (std::wstring(argv[4]) != L"--no-listfile") return usage();
            update_listfile = false;
        }
        return run_manifest(fs::path(argv[2]), fs::path(argv[3]),
                            update_listfile) ? 0 : 1;
    }

    return usage();
}
