#include "texture_asset.h"

#include <windows.h>
#include <d3d9.h>
#include <wincodec.h>

#include <algorithm>
#include <cstring>
#include <limits>
#include <vector>

namespace d3d9_texture_asset {
namespace {

constexpr uint32_t fourcc(char a, char b, char c, char d)
{
    return static_cast<uint32_t>(static_cast<uint8_t>(a))
        | (static_cast<uint32_t>(static_cast<uint8_t>(b)) << 8)
        | (static_cast<uint32_t>(static_cast<uint8_t>(c)) << 16)
        | (static_cast<uint32_t>(static_cast<uint8_t>(d)) << 24);
}

constexpr uint32_t kBlp1 = fourcc('B', 'L', 'P', '1');
constexpr uint32_t kBlp2 = fourcc('B', 'L', 'P', '2');
constexpr uint32_t kDds = fourcc('D', 'D', 'S', ' ');
constexpr uint32_t kMaxDimension = 16384;

#pragma pack(push, 1)
struct Blp1Header {
    uint32_t magic;
    uint32_t compression;
    uint32_t alpha_bits;
    uint32_t width;
    uint32_t height;
    uint32_t picture_type;
    uint32_t picture_subtype;
    uint32_t offsets[16];
    uint32_t sizes[16];
};

struct Blp2Header {
    uint32_t magic;
    uint32_t type;
    uint8_t encoding;
    uint8_t alpha_depth;
    uint8_t alpha_encoding;
    uint8_t has_mips;
    uint32_t width;
    uint32_t height;
    uint32_t offsets[16];
    uint32_t sizes[16];
};

struct DdsPixelFormat {
    uint32_t size;
    uint32_t flags;
    uint32_t four_cc;
    uint32_t rgb_bit_count;
    uint32_t red_mask;
    uint32_t green_mask;
    uint32_t blue_mask;
    uint32_t alpha_mask;
};

struct DdsHeader {
    uint32_t size;
    uint32_t flags;
    uint32_t height;
    uint32_t width;
    uint32_t pitch_or_linear_size;
    uint32_t depth;
    uint32_t mip_map_count;
    uint32_t reserved1[11];
    DdsPixelFormat pixel_format;
    uint32_t caps;
    uint32_t caps2;
    uint32_t caps3;
    uint32_t caps4;
    uint32_t reserved2;
};
#pragma pack(pop)

static_assert(sizeof(Blp1Header) == 156, "unexpected BLP1 header layout");
static_assert(sizeof(Blp2Header) == 148, "unexpected BLP2 header layout");
static_assert(sizeof(DdsHeader) == 124, "unexpected DDS header layout");

using CreateTextureFromMemoryFn = HRESULT (WINAPI *)(
    IDirect3DDevice9*, LPCVOID, UINT, IDirect3DTexture9**);

HMODULE g_d3dx_module = nullptr;
bool g_d3dx_attempted = false;
CreateTextureFromMemoryFn g_create_texture_from_memory = nullptr;

bool range_inside(size_t offset, size_t length, size_t total)
{
    return offset <= total && length <= total - offset;
}

bool dimensions_valid(uint32_t width, uint32_t height)
{
    return width > 0 && height > 0
        && width <= kMaxDimension && height <= kMaxDimension;
}

bool pixel_count(uint32_t width, uint32_t height, size_t* out)
{
    if (!dimensions_valid(width, height) || !out) return false;
    const uint64_t count = static_cast<uint64_t>(width) * height;
    if (count > (std::numeric_limits<size_t>::max)()) return false;
    *out = static_cast<size_t>(count);
    return true;
}

void ensure_d3dx_loaded()
{
    if (g_d3dx_attempted) return;
    g_d3dx_attempted = true;
    const char* candidates[] = { "d3dx9_42.dll", "d3dx9_43.dll", "d3dx9_33.dll" };
    for (const char* name : candidates) {
        g_d3dx_module = LoadLibraryA(name);
        if (g_d3dx_module) break;
    }
    if (g_d3dx_module) {
        g_create_texture_from_memory =
            reinterpret_cast<CreateTextureFromMemoryFn>(
                GetProcAddress(g_d3dx_module, "D3DXCreateTextureFromFileInMemory"));
    }
}

DecodeResult load_d3dx(
    IDirect3DDevice9* device, const void* data, size_t size,
    IDirect3DTexture9** out_texture)
{
    if (!device || !out_texture || size > (std::numeric_limits<UINT>::max)()) {
        return DecodeResult::DeviceError;
    }
    ensure_d3dx_loaded();
    if (!g_create_texture_from_memory) return DecodeResult::DecoderUnavailable;
    IDirect3DTexture9* texture = nullptr;
    const HRESULT hr = g_create_texture_from_memory(
        device, data, static_cast<UINT>(size), &texture);
    if (FAILED(hr) || !texture) {
        if (texture) texture->Release();
        return DecodeResult::InvalidData;
    }
    *out_texture = texture;
    return DecodeResult::Ok;
}

DecodeResult inspect_standard(const uint8_t* data, size_t size)
{
    static const uint8_t png_magic[8] = { 0x89, 'P', 'N', 'G', 0x0D, 0x0A, 0x1A, 0x0A };
    if (size >= 24 && std::memcmp(data, png_magic, sizeof(png_magic)) == 0) {
        const uint32_t width = (static_cast<uint32_t>(data[16]) << 24)
            | (static_cast<uint32_t>(data[17]) << 16)
            | (static_cast<uint32_t>(data[18]) << 8) | data[19];
        const uint32_t height = (static_cast<uint32_t>(data[20]) << 24)
            | (static_cast<uint32_t>(data[21]) << 16)
            | (static_cast<uint32_t>(data[22]) << 8) | data[23];
        return dimensions_valid(width, height)
            ? DecodeResult::Ok : DecodeResult::InvalidData;
    }
    if (size >= 4 && data[0] == 0xFF && data[1] == 0xD8
        && data[size - 2] == 0xFF && data[size - 1] == 0xD9) {
        return DecodeResult::Ok;
    }
    if (size >= 26 && data[0] == 'B' && data[1] == 'M') {
        return DecodeResult::Ok;
    }
    if (size >= 128 && std::memcmp(data, "DDS ", 4) == 0) {
        return DecodeResult::Ok;
    }
    if (size >= 18) {
        const uint8_t image_type = data[2];
        const uint32_t width = static_cast<uint32_t>(data[12])
            | (static_cast<uint32_t>(data[13]) << 8);
        const uint32_t height = static_cast<uint32_t>(data[14])
            | (static_cast<uint32_t>(data[15]) << 8);
        if ((image_type == 1 || image_type == 2 || image_type == 3
            || image_type == 9 || image_type == 10 || image_type == 11)
            && dimensions_valid(width, height)) {
            return DecodeResult::Ok;
        }
    }
    return DecodeResult::UnsupportedFormat;
}

DecodeResult inspect_blp1(const uint8_t* data, size_t size, Blp1Header* out)
{
    if (size < sizeof(Blp1Header)) return DecodeResult::InvalidData;
    Blp1Header header{};
    std::memcpy(&header, data, sizeof(header));
    if (header.magic != kBlp1 || !dimensions_valid(header.width, header.height)) {
        return DecodeResult::InvalidData;
    }
    if (!range_inside(header.offsets[0], header.sizes[0], size)
        || header.sizes[0] == 0) {
        return DecodeResult::InvalidData;
    }
    if (header.compression == 0) {
        uint32_t jpeg_header_size = 0;
        if (!range_inside(sizeof(header), sizeof(jpeg_header_size), size)) {
            return DecodeResult::InvalidData;
        }
        std::memcpy(&jpeg_header_size, data + sizeof(header), sizeof(jpeg_header_size));
        if (jpeg_header_size == 0
            || !range_inside(sizeof(header) + sizeof(jpeg_header_size), jpeg_header_size, size)
            || header.offsets[0] < sizeof(header) + sizeof(jpeg_header_size) + jpeg_header_size) {
            return DecodeResult::InvalidData;
        }
    } else if (header.compression == 1) {
        size_t pixels = 0;
        if (!pixel_count(header.width, header.height, &pixels)
            || !range_inside(sizeof(header), 256u * 4u, size)
            || header.offsets[0] < sizeof(header) + 256u * 4u
            || header.sizes[0] < pixels) {
            return DecodeResult::InvalidData;
        }
        size_t alpha_bytes = 0;
        if (header.alpha_bits == 1) alpha_bytes = (pixels + 7u) / 8u;
        else if (header.alpha_bits == 4) alpha_bytes = (pixels + 1u) / 2u;
        else if (header.alpha_bits == 8) alpha_bytes = pixels;
        else if (header.alpha_bits != 0) return DecodeResult::UnsupportedFormat;
        if (header.sizes[0] < pixels + alpha_bytes) return DecodeResult::InvalidData;
    } else {
        return DecodeResult::UnsupportedFormat;
    }
    if (out) *out = header;
    return DecodeResult::Ok;
}

DecodeResult inspect_blp2(const uint8_t* data, size_t size, Blp2Header* out)
{
    if (size < sizeof(Blp2Header)) return DecodeResult::InvalidData;
    Blp2Header header{};
    std::memcpy(&header, data, sizeof(header));
    if (header.magic != kBlp2 || !dimensions_valid(header.width, header.height)
        || !range_inside(header.offsets[0], header.sizes[0], size)
        || header.sizes[0] == 0) {
        return DecodeResult::InvalidData;
    }
    size_t pixels = 0;
    if (!pixel_count(header.width, header.height, &pixels)) {
        return DecodeResult::InvalidData;
    }
    if (header.encoding == 1) {
        if (!range_inside(sizeof(header), 256u * 4u, size)
            || header.offsets[0] < sizeof(header) + 256u * 4u
            || header.sizes[0] < pixels) return DecodeResult::InvalidData;
        size_t alpha_bytes = 0;
        if (header.alpha_depth == 1) alpha_bytes = (pixels + 7u) / 8u;
        else if (header.alpha_depth == 4) alpha_bytes = (pixels + 1u) / 2u;
        else if (header.alpha_depth == 8) alpha_bytes = pixels;
        else if (header.alpha_depth != 0) return DecodeResult::UnsupportedFormat;
        if (header.sizes[0] < pixels + alpha_bytes) return DecodeResult::InvalidData;
    } else if (header.encoding == 2) {
        const bool dxt1 = header.alpha_encoding == 0;
        const bool dxt3 = header.alpha_encoding == 1;
        const bool dxt5 = header.alpha_encoding == 7;
        if (!dxt1 && !dxt3 && !dxt5) return DecodeResult::UnsupportedFormat;
        const uint64_t blocks_x = (static_cast<uint64_t>(header.width) + 3u) / 4u;
        const uint64_t blocks_y = (static_cast<uint64_t>(header.height) + 3u) / 4u;
        const uint64_t expected = blocks_x * blocks_y * (dxt1 ? 8u : 16u);
        if (expected > header.sizes[0]) return DecodeResult::InvalidData;
    } else if (header.encoding == 3) {
        if (static_cast<uint64_t>(pixels) * 4u > header.sizes[0]) {
            return DecodeResult::InvalidData;
        }
    } else {
        return DecodeResult::UnsupportedFormat;
    }
    if (out) *out = header;
    return DecodeResult::Ok;
}

uint8_t read_alpha(const uint8_t* alpha, size_t index, uint8_t bits)
{
    if (bits == 0) return 255;
    if (bits == 1) return (alpha[index >> 3] & (1u << (index & 7))) ? 255 : 0;
    if (bits == 4) {
        const uint8_t value = (index & 1)
            ? static_cast<uint8_t>(alpha[index >> 1] >> 4)
            : static_cast<uint8_t>(alpha[index >> 1] & 0x0F);
        return static_cast<uint8_t>(value * 17u);
    }
    return alpha[index];
}

DecodeResult create_bgra_texture(
    IDirect3DDevice9* device, uint32_t width, uint32_t height,
    const uint8_t* bgra, size_t source_pitch,
    IDirect3DTexture9** out_texture)
{
    if (!device || !out_texture) return DecodeResult::DeviceError;
    IDirect3DTexture9* texture = nullptr;
    const HRESULT created = device->CreateTexture(
        width, height, 1, 0, D3DFMT_A8R8G8B8, D3DPOOL_MANAGED, &texture, nullptr);
    if (FAILED(created) || !texture) return DecodeResult::DeviceError;
    D3DLOCKED_RECT locked{};
    if (FAILED(texture->LockRect(0, &locked, nullptr, 0))) {
        texture->Release();
        return DecodeResult::DeviceError;
    }
    for (uint32_t y = 0; y < height; ++y) {
        std::memcpy(static_cast<uint8_t*>(locked.pBits) + y * locked.Pitch,
            bgra + static_cast<size_t>(y) * source_pitch,
            static_cast<size_t>(width) * 4u);
    }
    texture->UnlockRect(0);
    *out_texture = texture;
    return DecodeResult::Ok;
}

DecodeResult decode_wic_bgra(
    const void* data, size_t size, std::vector<uint8_t>* pixels,
    uint32_t* out_width, uint32_t* out_height)
{
    if (!data || !pixels || !out_width || !out_height
        || size > (std::numeric_limits<DWORD>::max)()) {
        return DecodeResult::InvalidData;
    }
    const HRESULT initialized = CoInitializeEx(nullptr, COINIT_MULTITHREADED);
    const bool uninitialize = SUCCEEDED(initialized);

    IWICImagingFactory* factory = nullptr;
    IWICStream* stream = nullptr;
    IWICBitmapDecoder* decoder = nullptr;
    IWICBitmapFrameDecode* frame = nullptr;
    IWICFormatConverter* converter = nullptr;
    DecodeResult result = DecodeResult::InvalidData;

    HRESULT hr = CoCreateInstance(CLSID_WICImagingFactory, nullptr,
        CLSCTX_INPROC_SERVER, IID_PPV_ARGS(&factory));
    if (SUCCEEDED(hr)) hr = factory->CreateStream(&stream);
    if (SUCCEEDED(hr)) hr = stream->InitializeFromMemory(
        const_cast<BYTE*>(static_cast<const BYTE*>(data)), static_cast<DWORD>(size));
    if (SUCCEEDED(hr)) hr = factory->CreateDecoderFromStream(
        stream, nullptr, WICDecodeMetadataCacheOnLoad, &decoder);
    if (SUCCEEDED(hr)) hr = decoder->GetFrame(0, &frame);
    if (SUCCEEDED(hr)) hr = factory->CreateFormatConverter(&converter);
    if (SUCCEEDED(hr)) hr = converter->Initialize(
        frame, GUID_WICPixelFormat32bppBGRA, WICBitmapDitherTypeNone,
        nullptr, 0.0, WICBitmapPaletteTypeCustom);

    UINT width = 0;
    UINT height = 0;
    if (SUCCEEDED(hr)) hr = converter->GetSize(&width, &height);
    size_t count = 0;
    if (SUCCEEDED(hr) && pixel_count(width, height, &count)
        && count <= (std::numeric_limits<UINT>::max)() / 4u) {
        pixels->resize(count * 4u);
        hr = converter->CopyPixels(nullptr, width * 4u,
            static_cast<UINT>(pixels->size()), pixels->data());
        if (SUCCEEDED(hr)) {
            *out_width = width;
            *out_height = height;
            result = DecodeResult::Ok;
        }
    }

    if (converter) converter->Release();
    if (frame) frame->Release();
    if (decoder) decoder->Release();
    if (stream) stream->Release();
    if (factory) factory->Release();
    if (uninitialize) CoUninitialize();
    return result;
}

DecodeResult create_paletted(
    IDirect3DDevice9* device, const uint8_t* data,
    uint32_t width, uint32_t height, uint32_t mip_offset,
    uint8_t alpha_bits, size_t palette_offset,
    IDirect3DTexture9** out_texture)
{
    size_t pixels = 0;
    if (!pixel_count(width, height, &pixels)) return DecodeResult::InvalidData;
    const uint8_t* palette = data + palette_offset;
    const uint8_t* indices = data + mip_offset;
    const uint8_t* alpha = indices + pixels;
    std::vector<uint8_t> bgra(pixels * 4u);
    for (size_t i = 0; i < pixels; ++i) {
        const uint8_t* color = palette + static_cast<size_t>(indices[i]) * 4u;
        bgra[i * 4u + 0] = color[0];
        bgra[i * 4u + 1] = color[1];
        bgra[i * 4u + 2] = color[2];
        bgra[i * 4u + 3] = read_alpha(alpha, i, alpha_bits);
    }
    return create_bgra_texture(
        device, width, height, bgra.data(), static_cast<size_t>(width) * 4u,
        out_texture);
}

DecodeResult create_blp1(
    IDirect3DDevice9* device, const uint8_t* data, size_t size,
    IDirect3DTexture9** out_texture, uint32_t* out_width, uint32_t* out_height)
{
    Blp1Header header{};
    DecodeResult result = inspect_blp1(data, size, &header);
    if (result != DecodeResult::Ok) return result;
    if (header.compression == 0) {
        uint32_t jpeg_header_size = 0;
        std::memcpy(&jpeg_header_size, data + sizeof(header), sizeof(jpeg_header_size));
        std::vector<uint8_t> jpeg(static_cast<size_t>(jpeg_header_size) + header.sizes[0]);
        std::memcpy(jpeg.data(), data + sizeof(header) + sizeof(jpeg_header_size), jpeg_header_size);
        std::memcpy(jpeg.data() + jpeg_header_size, data + header.offsets[0], header.sizes[0]);
        std::vector<uint8_t> pixels;
        uint32_t width = 0;
        uint32_t height = 0;
        result = decode_wic_bgra(
            jpeg.data(), jpeg.size(), &pixels, &width, &height);
        if (result == DecodeResult::Ok
            && (width != header.width || height != header.height)) {
            result = DecodeResult::InvalidData;
        }
        if (result == DecodeResult::Ok) {
            result = create_bgra_texture(device, width, height,
                pixels.data(), static_cast<size_t>(width) * 4u, out_texture);
        }
    } else {
        result = create_paletted(device, data, header.width, header.height,
            header.offsets[0], static_cast<uint8_t>(header.alpha_bits),
            sizeof(header), out_texture);
    }
    if (result == DecodeResult::Ok) {
        *out_width = header.width;
        *out_height = header.height;
    }
    return result;
}

DecodeResult create_blp2(
    IDirect3DDevice9* device, const uint8_t* data, size_t size,
    IDirect3DTexture9** out_texture, uint32_t* out_width, uint32_t* out_height)
{
    Blp2Header header{};
    DecodeResult result = inspect_blp2(data, size, &header);
    if (result != DecodeResult::Ok) return result;
    if (header.encoding == 1) {
        result = create_paletted(device, data, header.width, header.height,
            header.offsets[0], header.alpha_depth, sizeof(header), out_texture);
    } else if (header.encoding == 2) {
        const uint32_t format = header.alpha_encoding == 0
            ? fourcc('D', 'X', 'T', '1')
            : (header.alpha_encoding == 1
                ? fourcc('D', 'X', 'T', '3') : fourcc('D', 'X', 'T', '5'));
        DdsHeader dds{};
        dds.size = sizeof(DdsHeader);
        dds.flags = 0x00081007u;
        dds.height = header.height;
        dds.width = header.width;
        dds.pitch_or_linear_size = header.sizes[0];
        dds.mip_map_count = 1;
        dds.pixel_format.size = sizeof(DdsPixelFormat);
        dds.pixel_format.flags = 0x4u;
        dds.pixel_format.four_cc = format;
        dds.caps = 0x1000u;
        std::vector<uint8_t> encoded(4u + sizeof(dds) + header.sizes[0]);
        const uint32_t magic = kDds;
        std::memcpy(encoded.data(), &magic, sizeof(magic));
        std::memcpy(encoded.data() + 4u, &dds, sizeof(dds));
        std::memcpy(encoded.data() + 4u + sizeof(dds),
            data + header.offsets[0], header.sizes[0]);
        result = load_d3dx(device, encoded.data(), encoded.size(), out_texture);
    } else {
        result = create_bgra_texture(device, header.width, header.height,
            data + header.offsets[0], static_cast<size_t>(header.width) * 4u,
            out_texture);
    }
    if (result == DecodeResult::Ok) {
        *out_width = header.width;
        *out_height = header.height;
    }
    return result;
}

}  // namespace

DecodeResult validate(const void* data, size_t size)
{
    if (!data || size < 4) return DecodeResult::InvalidData;
    const auto* bytes = static_cast<const uint8_t*>(data);
    uint32_t magic = 0;
    std::memcpy(&magic, bytes, sizeof(magic));
    if (magic == kBlp1) return inspect_blp1(bytes, size, nullptr);
    if (magic == kBlp2) return inspect_blp2(bytes, size, nullptr);
    return inspect_standard(bytes, size);
}

DecodeResult create_texture(
    IDirect3DDevice9* device, const void* data, size_t size,
    IDirect3DTexture9** out_texture, uint32_t* out_width, uint32_t* out_height)
{
    if (!out_texture || !out_width || !out_height) return DecodeResult::InvalidData;
    *out_texture = nullptr;
    *out_width = 0;
    *out_height = 0;
    const DecodeResult inspected = validate(data, size);
    if (inspected != DecodeResult::Ok) return inspected;
    if (!device) return DecodeResult::DeviceError;

    const auto* bytes = static_cast<const uint8_t*>(data);
    uint32_t magic = 0;
    std::memcpy(&magic, bytes, sizeof(magic));
    DecodeResult result = DecodeResult::Ok;
    if (magic == kBlp1) {
        return create_blp1(device, bytes, size, out_texture, out_width, out_height);
    }
    if (magic == kBlp2) {
        return create_blp2(device, bytes, size, out_texture, out_width, out_height);
    }
    result = load_d3dx(device, data, size, out_texture);
    if (result == DecodeResult::Ok) {
        D3DSURFACE_DESC desc{};
        if (FAILED((*out_texture)->GetLevelDesc(0, &desc))) {
            (*out_texture)->Release();
            *out_texture = nullptr;
            return DecodeResult::DeviceError;
        }
        *out_width = desc.Width;
        *out_height = desc.Height;
    }
    return result;
}

}  // namespace d3d9_texture_asset
