// button_icon.h - YDWE command-button icon algorithms and archive paths.
//
// The pixel math is the algorithm from YDWE's
// yd_jass_api/DisableButtonBlp.cpp (BlpDisable / BlpBlend). The codec is ours
// (blp_codec.h): BLP1 palette output instead of YDWE's BLP1 JPEG.
#pragma once

#include "blp_codec.h"

#include <cstdint>
#include <string>

namespace japi::image {

inline constexpr uint32_t kButtonIconSize = 64;

// Both functions require valid 64x64 BGRA input, matching YDWE's
// kBlpSize check. They never write a partial result.
bool make_disabled_icon(const Image& input, Image& output,
                        std::string* error = nullptr);
bool blend_button_icons(const Image& input_a, const Image& input_b,
                        Image& output, std::string* error = nullptr);

// Basename after the last '/' or '\\'.
std::string archive_basename(const std::string& path);

// Normalizes a map-relative path to backslashes, rejecting absolute paths,
// drive/ADS colons, "..", empty components and control characters.
bool normalize_archive_path(const std::string& path, std::string& out,
                            std::string* error = nullptr);

bool has_blp_extension(const std::string& path);

// ReplaceableTextures\CommandButtonsDisabled\DIS<basename>
bool disabled_icon_archive_path(const std::string& enabled_path,
                                std::string& out,
                                std::string* error = nullptr);

}  // namespace japi::image
