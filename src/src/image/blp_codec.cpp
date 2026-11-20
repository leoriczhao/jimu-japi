#include "blp_codec.h"

#include "blp_format.h"
#include "wic_decode.h"

#include <algorithm>
#include <array>
#include <cstring>
#include <limits>
#include <unordered_map>

namespace japi::image {

namespace {

using blp::Blp1Header;
using blp::Blp2Header;

void set_error(std::string* error, const char* message)
{
    if (error) *error = message ? message : "";
}

Status invalid(std::string* error, const char* message)
{
    set_error(error, message);
    return Status::InvalidData;
}

Status unsupported(std::string* error, const char* message)
{
    set_error(error, message);
    return Status::UnsupportedFormat;
}

Status decode_paletted(const uint8_t* data, size_t size,
                       uint32_t width, uint32_t height, uint32_t alpha_bits,
                       size_t palette_offset, uint32_t mip_offset,
                       uint32_t mip_size, Image& out, std::string* error)
{
    if (alpha_bits != 0 && alpha_bits != 1 && alpha_bits != 4 && alpha_bits != 8) {
        return unsupported(error, "BLP palette alpha depth is not 0/1/4/8");
    }
    size_t pixels = 0;
    if (!blp::pixel_count(width, height, &pixels)) {
        return invalid(error, "BLP dimensions are out of range");
    }
    if (!blp::range_inside(palette_offset, 256u * 4u, size)) {
        return invalid(error, "BLP palette is truncated");
    }
    const size_t alpha_bytes = blp::alpha_byte_count(pixels, alpha_bits);
    if (mip_size < pixels + alpha_bytes
        || !blp::range_inside(mip_offset, mip_size, size)) {
        return invalid(error, "BLP pixel/alpha data is truncated");
    }
    const uint8_t* palette = data + palette_offset;
    const uint8_t* indices = data + mip_offset;
    const uint8_t* alpha = indices + pixels;
    std::vector<uint8_t> bgra(pixels * 4u);
    for (size_t i = 0; i < pixels; ++i) {
        const uint8_t* color = palette + static_cast<size_t>(indices[i]) * 4u;
        bgra[i * 4u + 0] = color[0];
        bgra[i * 4u + 1] = color[1];
        bgra[i * 4u + 2] = color[2];
        bgra[i * 4u + 3] = blp::read_alpha(alpha, i, alpha_bits);
    }
    out.width = width;
    out.height = height;
    out.bgra.swap(bgra);
    return Status::Ok;
}

Status decode_blp1(const uint8_t* data, size_t size, Image& out,
                   std::string* error)
{
    if (size < sizeof(Blp1Header)) {
        return invalid(error, "BLP1 header is truncated");
    }
    Blp1Header header{};
    std::memcpy(&header, data, sizeof(header));
    if (header.magic != blp::kBlp1) {
        return invalid(error, "not a BLP1 file");
    }
    if (!blp::dimensions_valid(header.width, header.height)) {
        return invalid(error, "BLP1 dimensions are out of range");
    }
    if (header.compression == 0) {
        uint32_t jpeg_header_size = 0;
        if (!blp::range_inside(sizeof(header), sizeof(jpeg_header_size), size)) {
            return invalid(error, "BLP1 JPEG header size is truncated");
        }
        std::memcpy(&jpeg_header_size, data + sizeof(header),
                    sizeof(jpeg_header_size));
        if (!blp::range_inside(sizeof(header) + sizeof(jpeg_header_size),
                               jpeg_header_size, size)
            || !blp::range_inside(header.offsets[0], header.sizes[0], size)) {
            return invalid(error, "BLP1 JPEG payload is truncated");
        }
        const uint64_t jpeg_size = static_cast<uint64_t>(jpeg_header_size)
            + static_cast<uint64_t>(header.sizes[0]);
        if (jpeg_size > (std::numeric_limits<size_t>::max)()) {
            return invalid(error, "BLP1 JPEG payload size overflows size_t");
        }
        std::vector<uint8_t> jpeg(static_cast<size_t>(jpeg_size));
        std::memcpy(jpeg.data(), data + sizeof(header) + sizeof(jpeg_header_size),
                    jpeg_header_size);
        std::memcpy(jpeg.data() + jpeg_header_size, data + header.offsets[0],
                    header.sizes[0]);
        std::vector<uint8_t> pixels;
        uint32_t width = 0;
        uint32_t height = 0;
        const wic::Status decoded = wic::decode_bgra(
            jpeg.data(), jpeg.size(), pixels, width, height);
        if (decoded == wic::Status::DecoderUnavailable) {
            set_error(error, "WIC JPEG decoder is unavailable");
            return Status::DecoderUnavailable;
        }
        if (decoded != wic::Status::Ok) {
            return invalid(error, "BLP1 JPEG payload did not decode");
        }
        if (width != header.width || height != header.height) {
            return invalid(error, "BLP1 JPEG dimensions disagree with the header");
        }
        out.width = width;
        out.height = height;
        out.bgra.swap(pixels);
        return Status::Ok;
    }
    if (header.compression == 1) {
        return decode_paletted(data, size, header.width, header.height,
                               header.alpha_bits, sizeof(header),
                               header.offsets[0], header.sizes[0], out, error);
    }
    return unsupported(error, "BLP1 compression is not 0 (JPEG) or 1 (palette)");
}

Status decode_blp2(const uint8_t* data, size_t size, Image& out,
                   std::string* error)
{
    if (size < sizeof(Blp2Header)) {
        return invalid(error, "BLP2 header is truncated");
    }
    Blp2Header header{};
    std::memcpy(&header, data, sizeof(header));
    if (header.magic != blp::kBlp2) {
        return invalid(error, "not a BLP2 file");
    }
    if (!blp::dimensions_valid(header.width, header.height)
        || !blp::range_inside(header.offsets[0], header.sizes[0], size)) {
        return invalid(error, "BLP2 dimensions or mip data are out of range");
    }
    if (header.encoding == 1) {
        return decode_paletted(data, size, header.width, header.height,
                               header.alpha_depth, sizeof(header),
                               header.offsets[0], header.sizes[0], out, error);
    }
    if (header.encoding == 2) {
        return unsupported(error, "BLP2 DXT data is not supported by the icon codec");
    }
    size_t pixels = 0;
    if (!blp::pixel_count(header.width, header.height, &pixels)
        || header.sizes[0] < pixels * 4u) {
        return invalid(error, "BLP2 raw BGRA data is truncated");
    }
    out.width = header.width;
    out.height = header.height;
    out.bgra.assign(data + header.offsets[0],
                    data + header.offsets[0] + pixels * 4u);
    return Status::Ok;
}

struct Rgb {
    uint8_t r = 0;
    uint8_t g = 0;
    uint8_t b = 0;
};

uint32_t rgb_key(const uint8_t* bgra)
{
    return (static_cast<uint32_t>(bgra[2]) << 16)
        | (static_cast<uint32_t>(bgra[1]) << 8)
        | static_cast<uint32_t>(bgra[0]);
}

uint32_t rgb_key(const Rgb& color)
{
    return (static_cast<uint32_t>(color.r) << 16)
        | (static_cast<uint32_t>(color.g) << 8)
        | static_cast<uint32_t>(color.b);
}

struct Palette {
    std::array<Rgb, 256> colors{};
    size_t count = 0;
    std::unordered_map<uint32_t, uint8_t> exact;
    std::unordered_map<uint32_t, uint8_t> nearest_cache;
};

uint8_t nearest_color(const Palette& palette, const Rgb& color)
{
    uint32_t best_distance = (std::numeric_limits<uint32_t>::max)();
    uint8_t best = 0;
    for (size_t i = 0; i < palette.count; ++i) {
        const int dr = static_cast<int>(color.r) - palette.colors[i].r;
        const int dg = static_cast<int>(color.g) - palette.colors[i].g;
        const int db = static_cast<int>(color.b) - palette.colors[i].b;
        const uint32_t distance = static_cast<uint32_t>(dr * dr + dg * dg + db * db);
        if (distance < best_distance) {
            best_distance = distance;
            best = static_cast<uint8_t>(i);
            if (distance == 0) break;
        }
    }
    return best;
}

uint8_t map_color(Palette& palette, const uint8_t* bgra)
{
    const uint32_t key = rgb_key(bgra);
    auto exact = palette.exact.find(key);
    if (exact != palette.exact.end()) return exact->second;
    auto cached = palette.nearest_cache.find(key);
    if (cached != palette.nearest_cache.end()) return cached->second;
    const Rgb color{ bgra[2], bgra[1], bgra[0] };
    const uint8_t index = nearest_color(palette, color);
    palette.nearest_cache.emplace(key, index);
    return index;
}

void add_palette_entry(Palette& palette, const Rgb& color)
{
    if (palette.count >= palette.colors.size()) return;
    palette.colors[palette.count] = color;
    palette.exact.emplace(rgb_key(color), static_cast<uint8_t>(palette.count));
    ++palette.count;
}

Palette build_palette(const Image& image)
{
    Palette palette;
    std::vector<const uint8_t*> sample;
    sample.reserve(image.pixel_count());
    for (size_t i = 0; i < image.pixel_count(); ++i) {
        const uint8_t* pixel = image.bgra.data() + i * 4u;
        if (pixel[3] != 0) sample.push_back(pixel);
    }
    if (sample.empty()) {
        for (size_t i = 0; i < image.pixel_count(); ++i) {
            sample.push_back(image.bgra.data() + i * 4u);
        }
    }

    // Exact palette when the image already has at most 256 colours. This is
    // the common case for hand-authored 64x64 icons and keeps fixtures exact.
    {
        std::unordered_map<uint32_t, Rgb> unique;
        unique.reserve(sample.size());
        for (const uint8_t* pixel : sample) {
            const uint32_t key = rgb_key(pixel);
            if (unique.find(key) == unique.end()) {
                unique.emplace(key, Rgb{ pixel[2], pixel[1], pixel[0] });
            }
        }
        if (unique.size() <= palette.colors.size()) {
            // Deterministic order: first appearance in the image.
            std::unordered_map<uint32_t, bool> seen;
            for (const uint8_t* pixel : sample) {
                const uint32_t key = rgb_key(pixel);
                if (seen.find(key) != seen.end()) continue;
                seen.emplace(key, true);
                add_palette_entry(palette, Rgb{ pixel[2], pixel[1], pixel[0] });
            }
            return palette;
        }
    }

    // Median cut over RGB. Duplicate pixels carry weight, so the boxes are
    // built from the sampled pixels rather than from a unique-colour set.
    std::vector<Rgb> points;
    points.reserve(sample.size());
    for (const uint8_t* pixel : sample) {
        points.push_back(Rgb{ pixel[2], pixel[1], pixel[0] });
    }
    struct Box {
        std::vector<uint32_t> indices;
    };
    std::vector<Box> boxes;
    Box initial;
    initial.indices.resize(points.size());
    for (size_t i = 0; i < points.size(); ++i) {
        initial.indices[i] = static_cast<uint32_t>(i);
    }
    boxes.push_back(std::move(initial));

    auto channel_value = [&points](uint32_t index, int channel) {
        const Rgb& color = points[index];
        if (channel == 0) return static_cast<int>(color.r);
        if (channel == 1) return static_cast<int>(color.g);
        return static_cast<int>(color.b);
    };
    auto box_range = [&points, &boxes, &channel_value](size_t box_index,
                                                      int* best_channel) {
        const Box& box = boxes[box_index];
        int best = -1;
        *best_channel = 0;
        for (int channel = 0; channel < 3; ++channel) {
            int low = 255;
            int high = 0;
            for (uint32_t index : box.indices) {
                const int value = channel_value(index, channel);
                low = (std::min)(low, value);
                high = (std::max)(high, value);
            }
            if (high - low > best) {
                best = high - low;
                *best_channel = channel;
            }
        }
        return best;
    };

    while (boxes.size() < palette.colors.size()) {
        int best_range = -1;
        size_t best_box = 0;
        int best_channel = 0;
        for (size_t i = 0; i < boxes.size(); ++i) {
            if (boxes[i].indices.size() < 2) continue;
            int channel = 0;
            const int range = box_range(i, &channel);
            if (range > best_range) {
                best_range = range;
                best_box = i;
                best_channel = channel;
            }
        }
        if (best_range <= 0) break;
        Box& box = boxes[best_box];
        std::stable_sort(box.indices.begin(), box.indices.end(),
            [&points, best_channel](uint32_t lhs, uint32_t rhs) {
                const int lv = best_channel == 0 ? points[lhs].r
                    : (best_channel == 1 ? points[lhs].g : points[lhs].b);
                const int rv = best_channel == 0 ? points[rhs].r
                    : (best_channel == 1 ? points[rhs].g : points[rhs].b);
                if (lv != rv) return lv < rv;
                return lhs < rhs;
            });
        const size_t middle = box.indices.size() / 2;
        Box right;
        right.indices.assign(box.indices.begin() + middle, box.indices.end());
        box.indices.erase(box.indices.begin() + middle, box.indices.end());
        boxes.push_back(std::move(right));
    }

    for (const Box& box : boxes) {
        uint64_t r = 0;
        uint64_t g = 0;
        uint64_t b = 0;
        for (uint32_t index : box.indices) {
            r += points[index].r;
            g += points[index].g;
            b += points[index].b;
        }
        const uint64_t count = box.indices.empty() ? 1 : box.indices.size();
        add_palette_entry(palette, Rgb{
            static_cast<uint8_t>(r / count),
            static_cast<uint8_t>(g / count),
            static_cast<uint8_t>(b / count) });
    }
    if (palette.count == 0) {
        add_palette_entry(palette, Rgb{ 0, 0, 0 });
    }
    return palette;
}

Image downsample(const Image& source)
{
    Image result;
    result.width = (std::max)(1u, source.width / 2u);
    result.height = (std::max)(1u, source.height / 2u);
    result.bgra.resize(result.pixel_count() * 4u, 0);
    for (uint32_t y = 0; y < result.height; ++y) {
        const uint32_t sy0 = y * 2u;
        const uint32_t sy1 = (std::min)(source.height, sy0 + 2u);
        for (uint32_t x = 0; x < result.width; ++x) {
            const uint32_t sx0 = x * 2u;
            const uint32_t sx1 = (std::min)(source.width, sx0 + 2u);
            uint32_t sum[4] = { 0, 0, 0, 0 };
            uint32_t count = 0;
            for (uint32_t sy = sy0; sy < sy1; ++sy) {
                for (uint32_t sx = sx0; sx < sx1; ++sx) {
                    const uint8_t* pixel = source.bgra.data()
                        + (static_cast<size_t>(sy) * source.width + sx) * 4u;
                    sum[0] += pixel[0];
                    sum[1] += pixel[1];
                    sum[2] += pixel[2];
                    sum[3] += pixel[3];
                    ++count;
                }
            }
            uint8_t* target = result.bgra.data()
                + (static_cast<size_t>(y) * result.width + x) * 4u;
            for (int channel = 0; channel < 4; ++channel) {
                target[channel] = static_cast<uint8_t>(
                    (sum[channel] + count / 2u) / count);
            }
        }
    }
    return result;
}

}  // namespace

const char* status_name(Status status)
{
    switch (status) {
    case Status::Ok: return "ok";
    case Status::InvalidData: return "invalid-data";
    case Status::UnsupportedFormat: return "unsupported-format";
    case Status::DecoderUnavailable: return "decoder-unavailable";
    }
    return "unknown";
}

Status decode_blp(const void* data, size_t size, Image& out,
                  std::string* error)
{
    if (!data || size < 4) {
        return invalid(error, "file is shorter than a BLP magic");
    }
    uint32_t magic = 0;
    std::memcpy(&magic, data, sizeof(magic));
    const auto* bytes = static_cast<const uint8_t*>(data);
    if (magic == blp::kBlp1) return decode_blp1(bytes, size, out, error);
    if (magic == blp::kBlp2) return decode_blp2(bytes, size, out, error);
    return unsupported(error, "only BLP1/BLP2 input is supported");
}

Status encode_blp1_palette(const Image& in, std::vector<uint8_t>& out,
                           std::string* error)
{
    if (!in.valid()) {
        return invalid(error, "input image is not a valid BGRA buffer");
    }
    size_t input_pixels = 0;
    if (!blp::pixel_count(in.width, in.height, &input_pixels)) {
        return invalid(error, "input image exceeds the 16M-pixel codec limit");
    }
    (void)input_pixels;
    Palette palette = build_palette(in);

    struct Level {
        uint32_t width = 0;
        uint32_t height = 0;
        std::vector<uint8_t> indices;
        std::vector<uint8_t> alpha;
    };
    std::vector<Level> levels;
    Image current = in;
    for (size_t level_index = 0; level_index < 16; ++level_index) {
        Level level;
        level.width = current.width;
        level.height = current.height;
        const size_t pixels = current.pixel_count();
        level.indices.resize(pixels);
        level.alpha.resize(pixels);
        for (size_t i = 0; i < pixels; ++i) {
            const uint8_t* pixel = current.bgra.data() + i * 4u;
            level.indices[i] = map_color(palette, pixel);
            level.alpha[i] = pixel[3];
        }
        levels.push_back(std::move(level));
        if (current.width == 1 && current.height == 1) break;
        current = downsample(current);
    }

    uint64_t total = sizeof(Blp1Header) + 256u * 4u;
    for (const Level& level : levels) {
        total += static_cast<uint64_t>(level.width) * level.height * 2u;
    }
    if (total > (std::numeric_limits<uint32_t>::max)()
        || total > (std::numeric_limits<size_t>::max)()) {
        return invalid(error, "encoded BLP would exceed the 32-bit size fields");
    }

    Blp1Header header{};
    header.magic = blp::kBlp1;
    header.compression = 1;
    header.alpha_bits = 8;
    header.width = in.width;
    header.height = in.height;
    header.picture_type = 5;
    header.picture_subtype = 0;
    uint32_t offset = static_cast<uint32_t>(sizeof(Blp1Header) + 256u * 4u);
    for (size_t i = 0; i < levels.size(); ++i) {
        const uint32_t size = static_cast<uint32_t>(
            levels[i].width * levels[i].height * 2u);
        header.offsets[i] = offset;
        header.sizes[i] = size;
        offset += size;
    }

    out.assign(static_cast<size_t>(total), 0);
    std::memcpy(out.data(), &header, sizeof(header));
    uint8_t* palette_bytes = out.data() + sizeof(header);
    for (size_t i = 0; i < 256; ++i) {
        const Rgb color = i < palette.count ? palette.colors[i] : Rgb{ 0, 0, 0 };
        palette_bytes[i * 4u + 0] = color.b;
        palette_bytes[i * 4u + 1] = color.g;
        palette_bytes[i * 4u + 2] = color.r;
        palette_bytes[i * 4u + 3] = 255;
    }
    for (size_t i = 0; i < levels.size(); ++i) {
        uint8_t* target = out.data() + header.offsets[i];
        std::memcpy(target, levels[i].indices.data(), levels[i].indices.size());
        std::memcpy(target + levels[i].indices.size(), levels[i].alpha.data(),
                    levels[i].alpha.size());
    }
    return Status::Ok;
}

}  // namespace japi::image
