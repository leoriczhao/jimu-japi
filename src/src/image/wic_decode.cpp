#include "wic_decode.h"

#include "blp_format.h"

#include <windows.h>
#include <wincodec.h>

#include <limits>

namespace japi::image::wic {

Status decode_bgra(const void* data, size_t size, std::vector<uint8_t>& out,
                   uint32_t& width, uint32_t& height)
{
    if (!data || size > (std::numeric_limits<DWORD>::max)()) {
        return Status::InvalidData;
    }
    const HRESULT initialized = CoInitializeEx(nullptr, COINIT_MULTITHREADED);
    const bool uninitialize = SUCCEEDED(initialized);

    IWICImagingFactory* factory = nullptr;
    IWICStream* stream = nullptr;
    IWICBitmapDecoder* decoder = nullptr;
    IWICBitmapFrameDecode* frame = nullptr;
    IWICFormatConverter* converter = nullptr;
    Status result = Status::InvalidData;
    bool cmyk = false;

    HRESULT hr = CoCreateInstance(CLSID_WICImagingFactory, nullptr,
        CLSCTX_INPROC_SERVER, IID_PPV_ARGS(&factory));
    if (SUCCEEDED(hr)) hr = factory->CreateStream(&stream);
    if (SUCCEEDED(hr)) hr = stream->InitializeFromMemory(
        const_cast<BYTE*>(static_cast<const BYTE*>(data)),
        static_cast<DWORD>(size));
    if (SUCCEEDED(hr)) hr = factory->CreateDecoderFromStream(
        stream, nullptr, WICDecodeMetadataCacheOnLoad, &decoder);
    if (SUCCEEDED(hr)) hr = decoder->GetFrame(0, &frame);
    if (SUCCEEDED(hr)) hr = factory->CreateFormatConverter(&converter);

    // BLP1 JPEG with alpha is stored as a 4-component JPEG. WIC reports that
    // as 32bppCMYK: byte order C,M,Y,K, and JPEG's CMYK convention stores the
    // values inverted. Warcraft's fourth component is alpha, not black, so the
    // correct reconstruction is BGRA = 255 - (C,M,Y,K). Converting straight to
    // 32bppBGRA makes WIC treat C/M/Y as B/G/R and forces alpha to 255, which
    // visibly changes colours and drops transparency.
    WICPixelFormatGUID frame_format{};
    if (SUCCEEDED(hr)) hr = frame->GetPixelFormat(&frame_format);
    if (SUCCEEDED(hr)) {
        cmyk = ::IsEqualGUID(frame_format, GUID_WICPixelFormat32bppCMYK) != FALSE;
        const WICPixelFormatGUID target = cmyk
            ? GUID_WICPixelFormat32bppCMYK : GUID_WICPixelFormat32bppBGRA;
        hr = converter->Initialize(
            frame, target, WICBitmapDitherTypeNone,
            nullptr, 0.0, WICBitmapPaletteTypeCustom);
    }

    UINT wic_width = 0;
    UINT wic_height = 0;
    if (SUCCEEDED(hr)) hr = converter->GetSize(&wic_width, &wic_height);
    size_t count = 0;
    if (SUCCEEDED(hr)
        && blp::pixel_count(wic_width, wic_height, &count)
        && count <= (std::numeric_limits<UINT>::max)() / 4u) {
        std::vector<uint8_t> pixels(count * 4u);
        hr = converter->CopyPixels(nullptr, wic_width * 4u,
            static_cast<UINT>(pixels.size()), pixels.data());
        if (SUCCEEDED(hr)) {
            if (cmyk) {
                for (uint8_t& byte : pixels) {
                    byte = static_cast<uint8_t>(255u - byte);
                }
            }
            out.swap(pixels);
            width = wic_width;
            height = wic_height;
            result = Status::Ok;
        }
    } else if (!factory) {
        result = Status::DecoderUnavailable;
    }

    if (converter) converter->Release();
    if (frame) frame->Release();
    if (decoder) decoder->Release();
    if (stream) stream->Release();
    if (factory) factory->Release();
    if (uninitialize) CoUninitialize();
    return result;
}

}  // namespace japi::image::wic
