#include "button_icon.h"

#include "pas_button_data.h"

#include <algorithm>
#include <cctype>
#include <vector>

namespace japi::image {

namespace {

uint8_t clamp_channel(int value)
{
    if (value > 255) return 255;
    if (value < 0) return 0;
    return static_cast<uint8_t>(value);
}

void set_error(std::string* error, const char* message)
{
    if (error) *error = message ? message : "";
}

bool require_icon(const Image& image, const char* name, std::string* error)
{
    if (!image.valid() || image.width != kButtonIconSize
        || image.height != kButtonIconSize) {
        if (error) {
            *error = std::string(name) + " must be a valid 64x64 BGRA image";
        }
        return false;
    }
    return true;
}

bool is_reserved_component(const std::string& component)
{
    // Windows treats CON, PRN, AUX, NUL, COM1..9 and LPT1..9 (with or without
    // an extension) as devices. A map-relative icon path must never resolve to
    // one when the staging file is written.
    std::string stem = component.substr(0, component.find('.'));
    for (char& c : stem) {
        c = static_cast<char>(std::toupper(static_cast<unsigned char>(c)));
    }
    if (stem == "CON" || stem == "PRN" || stem == "AUX" || stem == "NUL"
        || stem == "CONIN$" || stem == "CONOUT$") {
        return true;
    }
    if (stem.size() == 4
        && (stem.compare(0, 3, "COM") == 0 || stem.compare(0, 3, "LPT") == 0)
        && stem[3] >= '1' && stem[3] <= '9') {
        return true;
    }
    return false;
}

}  // namespace

bool make_disabled_icon(const Image& input, Image& output, std::string* error)
{
    if (!require_icon(input, "input", error)) return false;
    output.width = kButtonIconSize;
    output.height = kButtonIconSize;
    output.bgra.assign(static_cast<size_t>(kButtonIconSize) * kButtonIconSize * 4u, 0);

    bool enable = false;
    for (size_t i = 0; i < static_cast<size_t>(kButtonIconSize) * kButtonIconSize; ++i) {
        const uint32_t overlay = kPasButton[i];
        const int overlay_b = static_cast<int>(overlay & 0xFFu);
        const int overlay_g = static_cast<int>((overlay >> 8) & 0xFFu);
        const int overlay_r = static_cast<int>((overlay >> 16) & 0xFFu);
        const int overlay_a = static_cast<int>((overlay >> 24) & 0xFFu);
        const uint8_t* source = input.bgra.data() + i * 4u;
        uint8_t* target = output.bgra.data() + i * 4u;

        target[0] = clamp_channel(
            ((255 - overlay_a) * source[0] + overlay_b) / (255 * 2));
        if (target[0] > 63) enable = true;
        target[1] = clamp_channel(
            ((255 - overlay_a) * source[1] + overlay_g) / (255 * 2));
        if (target[1] > 63) enable = true;
        target[2] = clamp_channel(
            ((255 - overlay_a) * source[2] + overlay_r) / (255 * 2));
        if (target[2] > 63) enable = true;
        target[3] = clamp_channel(
            255 - (255 - overlay_a) * (255 - source[3]) / 255);
    }

    if (!enable) {
        for (size_t i = 0; i < static_cast<size_t>(kButtonIconSize) * kButtonIconSize; ++i) {
            uint8_t* target = output.bgra.data() + i * 4u;
            target[0] = clamp_channel(static_cast<int>(target[0]) * 2);
            target[1] = clamp_channel(static_cast<int>(target[1]) * 2);
            target[2] = clamp_channel(static_cast<int>(target[2]) * 2);
        }
    }
    return true;
}

bool blend_button_icons(const Image& input_a, const Image& input_b,
                        Image& output, std::string* error)
{
    if (!require_icon(input_a, "input_a", error)) return false;
    if (!require_icon(input_b, "input_b", error)) return false;
    output.width = kButtonIconSize;
    output.height = kButtonIconSize;
    output.bgra.assign(static_cast<size_t>(kButtonIconSize) * kButtonIconSize * 4u, 0);

    for (size_t i = 0; i < static_cast<size_t>(kButtonIconSize) * kButtonIconSize; ++i) {
        const uint8_t* a = input_a.bgra.data() + i * 4u;
        const uint8_t* b = input_b.bgra.data() + i * 4u;
        uint8_t* target = output.bgra.data() + i * 4u;
        const int alpha = a[3];
        target[0] = clamp_channel(((255 - alpha) * b[0] + alpha * a[0]) / 255);
        target[1] = clamp_channel(((255 - alpha) * b[1] + alpha * a[1]) / 255);
        target[2] = clamp_channel(((255 - alpha) * b[2] + alpha * a[2]) / 255);
        target[3] = clamp_channel(255 - (255 - alpha) * (255 - b[3]) / 255);
    }
    return true;
}

std::string archive_basename(const std::string& path)
{
    const size_t slash = path.find_last_of("\\/");
    if (slash == std::string::npos) return path;
    return path.substr(slash + 1);
}

bool normalize_archive_path(const std::string& path, std::string& out,
                            std::string* error)
{
    if (path.empty()) {
        set_error(error, "archive path is empty");
        return false;
    }
    std::string normalized;
    normalized.reserve(path.size());
    for (unsigned char c : path) {
        if (c < 0x20 || c == 0x7F) {
            set_error(error, "archive path contains a control character");
            return false;
        }
        if (c == '*' || c == '?' || c == '"'
            || c == '<' || c == '>' || c == '|' || c == ':') {
            set_error(error, "archive path contains a reserved character");
            return false;
        }
        normalized.push_back(c == '/' ? '\\' : static_cast<char>(c));
    }
    if (normalized.front() == '\\') {
        set_error(error, "absolute archive paths are not allowed");
        return false;
    }

    std::vector<std::string> components;
    size_t start = 0;
    while (start <= normalized.size()) {
        const size_t slash = normalized.find('\\', start);
        const size_t end = (slash == std::string::npos) ? normalized.size() : slash;
        std::string component = normalized.substr(start, end - start);
        if (!component.empty() && component != ".") {
            if (component == "..") {
                set_error(error, "archive path contains a '..' component");
                return false;
            }
            if (component.back() == '.' || component.back() == ' ') {
                set_error(error, "archive path component ends with a dot or space");
                return false;
            }
            if (is_reserved_component(component)) {
                set_error(error, "archive path uses a Windows reserved device name");
                return false;
            }
            components.push_back(std::move(component));
        }
        if (slash == std::string::npos) break;
        start = slash + 1;
    }
    if (components.empty()) {
        set_error(error, "archive path has no file component");
        return false;
    }
    out.clear();
    for (size_t i = 0; i < components.size(); ++i) {
        if (i) out.push_back('\\');
        out += components[i];
    }
    return true;
}

bool has_blp_extension(const std::string& path)
{
    if (path.size() < 4) return false;
    const std::string suffix = path.substr(path.size() - 4);
    return suffix[0] == '.' && std::tolower(static_cast<unsigned char>(suffix[1])) == 'b'
        && std::tolower(static_cast<unsigned char>(suffix[2])) == 'l'
        && std::tolower(static_cast<unsigned char>(suffix[3])) == 'p';
}

bool disabled_icon_archive_path(const std::string& enabled_path,
                                std::string& out, std::string* error)
{
    std::string normalized;
    if (!normalize_archive_path(enabled_path, normalized, error)) return false;
    const std::string basename = archive_basename(normalized);
    if (basename.empty() || basename == "." || basename == "..") {
        set_error(error, "icon path has no usable basename");
        return false;
    }
    if (!has_blp_extension(basename)) {
        set_error(error, "icon path must end in .blp");
        return false;
    }
    out = "ReplaceableTextures\\CommandButtonsDisabled\\DIS" + basename;
    return true;
}

}  // namespace japi::image
