#include "flutter_window.h"

#include <optional>
#include <string>
#include <vector>

#include <flutter/encodable_value.h>
#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>
#include <windows.h>
#include <winuser.h>
#include <dwmapi.h>

#include "flutter/generated_plugin_registrant.h"
#include "audio_capture.h"
#include "win32_window.h"

#ifndef WDA_EXCLUDEFROMCAPTURE
#define WDA_EXCLUDEFROMCAPTURE 0x00000011
#endif
#ifndef WDA_NONE
#define WDA_NONE 0x00000000
#endif

// Global audio capture instance
std::unique_ptr<AudioCapture> g_audio_capture;

namespace {
#ifndef PW_RENDERFULLCONTENT
#define PW_RENDERFULLCONTENT 0x00000002
#endif

#pragma comment(lib, "dwmapi.lib")

// Some Windows SDKs don't declare these DWM APIs depending on target macros.
// To stay compatible, resolve them dynamically from dwmapi.dll.
using DwmGetIconicLivePreviewBitmapFn = HRESULT(WINAPI*)(HWND, HBITMAP*, POINT*, DWORD);
using DwmGetIconicThumbnailFn = HRESULT(WINAPI*)(HWND, UINT, UINT, HBITMAP*, DWORD);

DwmGetIconicLivePreviewBitmapFn ResolveDwmGetIconicLivePreviewBitmap() {
  static DwmGetIconicLivePreviewBitmapFn fn = []() -> DwmGetIconicLivePreviewBitmapFn {
    HMODULE mod = LoadLibraryW(L"dwmapi.dll");
    if (!mod) return nullptr;
    return reinterpret_cast<DwmGetIconicLivePreviewBitmapFn>(
        GetProcAddress(mod, "DwmGetIconicLivePreviewBitmap"));
  }();
  return fn;
}

DwmGetIconicThumbnailFn ResolveDwmGetIconicThumbnail() {
  static DwmGetIconicThumbnailFn fn = []() -> DwmGetIconicThumbnailFn {
    HMODULE mod = LoadLibraryW(L"dwmapi.dll");
    if (!mod) return nullptr;
    return reinterpret_cast<DwmGetIconicThumbnailFn>(
        GetProcAddress(mod, "DwmGetIconicThumbnail"));
  }();
  return fn;
}

std::string WideToUtf8(const wchar_t* w) {
  if (!w) return std::string();
  const int needed = WideCharToMultiByte(CP_UTF8, 0, w, -1, nullptr, 0, nullptr, nullptr);
  if (needed <= 1) return std::string();
  std::string out;
  out.resize(static_cast<size_t>(needed));
  WideCharToMultiByte(CP_UTF8, 0, w, -1, out.data(), needed, nullptr, nullptr);
  // Drop null terminator
  if (!out.empty() && out.back() == '\0') out.pop_back();
  return out;
}

void ScaleToFit(int src_w, int src_h, int max_w, int max_h, int& out_w, int& out_h) {
  if (src_w <= 0 || src_h <= 0) {
    out_w = out_h = 0;
    return;
  }
  if (max_w <= 0) max_w = src_w;
  if (max_h <= 0) max_h = src_h;
  double scale = 1.0;
  if (src_w > max_w || src_h > max_h) {
    const double sx = static_cast<double>(max_w) / static_cast<double>(src_w);
    const double sy = static_cast<double>(max_h) / static_cast<double>(src_h);
    scale = sx < sy ? sx : sy;
  }
  out_w = static_cast<int>(src_w * scale);
  out_h = static_cast<int>(src_h * scale);
  if (out_w < 1) out_w = 1;
  if (out_h < 1) out_h = 1;
}

bool ReadHBitmapToBgra(HBITMAP hbmp, std::vector<uint8_t>& out, int& width, int& height) {
  if (!hbmp) return false;

  BITMAP bm{};
  if (GetObject(hbmp, sizeof(bm), &bm) == 0) return false;
  if (bm.bmWidth <= 0 || bm.bmHeight <= 0) return false;

  width = bm.bmWidth;
  height = bm.bmHeight;

  BITMAPINFO bmi{};
  bmi.bmiHeader.biSize = sizeof(BITMAPINFOHEADER);
  bmi.bmiHeader.biWidth = width;
  bmi.bmiHeader.biHeight = -height;  // top-down
  bmi.bmiHeader.biPlanes = 1;
  bmi.bmiHeader.biBitCount = 32;
  bmi.bmiHeader.biCompression = BI_RGB;

  const size_t size = static_cast<size_t>(width) * static_cast<size_t>(height) * 4u;
  out.resize(size);

  HDC dc = GetDC(nullptr);
  if (!dc) return false;
  const int lines = GetDIBits(dc, hbmp, 0, static_cast<UINT>(height), out.data(), &bmi, DIB_RGB_COLORS);
  ReleaseDC(nullptr, dc);
  return lines == height;
}

void ForceDwmIconicBitmaps(HWND hwnd) {
  if (!hwnd) return;
  // Best-effort: ask DWM to use iconic representation/bitmaps for this window.
  // Some apps only start producing thumbnails after invalidation.
  BOOL on = TRUE;
  // These calls may fail for some windows/processes; ignore failures.
  DwmSetWindowAttribute(hwnd, DWMWA_FORCE_ICONIC_REPRESENTATION, &on, sizeof(on));
  DwmSetWindowAttribute(hwnd, DWMWA_HAS_ICONIC_BITMAP, &on, sizeof(on));
  DwmInvalidateIconicBitmaps(hwnd);
}

bool IsShareableTopLevelWindow(HWND hwnd, HWND self) {
  if (!hwnd) return false;
  if (self && (hwnd == self || IsChild(self, hwnd))) return false;
  if (!IsWindowVisible(hwnd)) return false;
  if (IsIconic(hwnd)) {
    // still shareable; Google Meet shows minimized windows too
  }
  // Exclude owned windows/tool windows (not shown in Alt+Tab)
  if (GetWindow(hwnd, GW_OWNER) != nullptr) return false;
  const LONG ex = GetWindowLong(hwnd, GWL_EXSTYLE);
  if (ex & WS_EX_TOOLWINDOW) return false;

  wchar_t title[512];
  title[0] = L'\0';
  const int len = GetWindowTextW(hwnd, title, 512);
  if (len <= 0) return false;
  return true;
}

bool CaptureWindowBgra(HWND hwnd, std::vector<uint8_t>& out, int& width, int& height) {
  RECT rc{};
  if (!GetWindowRect(hwnd, &rc)) return false;
  width = rc.right - rc.left;
  height = rc.bottom - rc.top;
  if (width <= 0 || height <= 0) return false;

  // For some minimized apps, DWM only provides an icon-like snapshot. We'll prefer
  // a real restored capture when possible, and only fall back to DWM if restore
  // capture fails.
  std::vector<uint8_t> dwm_fallback_bytes;
  int dwm_fallback_w = 0;
  int dwm_fallback_h = 0;
  bool have_dwm_fallback = false;

  const bool was_iconic = IsIconic(hwnd) ? true : false;
  if (was_iconic) {
    ForceDwmIconicBitmaps(hwnd);

    // For minimized windows, PrintWindow/BitBlt often return blank.
    // Prefer DWM "iconic" bitmaps (works for many apps even when minimized).
    HBITMAP hbmp = nullptr;
    if (auto live_fn = ResolveDwmGetIconicLivePreviewBitmap()) {
      HRESULT hr = live_fn(hwnd, &hbmp, nullptr, 0);
    if (SUCCEEDED(hr) && hbmp) {
      int bw = 0, bh = 0;
      if (ReadHBitmapToBgra(hbmp, dwm_fallback_bytes, bw, bh)) {
        DeleteObject(hbmp);
        dwm_fallback_w = bw;
        dwm_fallback_h = bh;
        have_dwm_fallback = true;
      }
      DeleteObject(hbmp);
    }
    }

    hbmp = nullptr;
    const UINT tw = static_cast<UINT>(width > 0 ? width : 1);
    const UINT th = static_cast<UINT>(height > 0 ? height : 1);
    if (auto thumb_fn = ResolveDwmGetIconicThumbnail()) {
      for (int attempt = 0; attempt < 3; attempt++) {
        HRESULT hr = thumb_fn(hwnd, tw, th, &hbmp, 0);
        if (SUCCEEDED(hr) && hbmp) {
          int bw = 0, bh = 0;
          if (ReadHBitmapToBgra(hbmp, dwm_fallback_bytes, bw, bh)) {
            DeleteObject(hbmp);
            dwm_fallback_w = bw;
            dwm_fallback_h = bh;
            have_dwm_fallback = true;
            // Keep trying restored capture for best fidelity.
            break;
          }
          DeleteObject(hbmp);
          hbmp = nullptr;
        }
        // Some apps need a tick after invalidation before DWM produces a bitmap.
        Sleep(30);
        ForceDwmIconicBitmaps(hwnd);
      }
    }
  }

  bool restored_from_iconic = false;
  if (was_iconic) {
    // Last resort: temporarily restore without activation and capture.
    // This can cause a brief visual change, but avoids blank captures.
    ShowWindowAsync(hwnd, SW_SHOWNOACTIVATE);
    restored_from_iconic = true;
    RedrawWindow(hwnd, nullptr, nullptr, RDW_INVALIDATE | RDW_UPDATENOW | RDW_ALLCHILDREN);
    DwmFlush();
    Sleep(120);

    // Recompute dimensions after restore: minimized windows can report tiny rects.
    RECT rc2{};
    if (GetWindowRect(hwnd, &rc2)) {
      const int w2 = rc2.right - rc2.left;
      const int h2 = rc2.bottom - rc2.top;
      if (w2 > 0 && h2 > 0) {
        width = w2;
        height = h2;
      }
    }
  }

  HDC screen_dc = GetDC(nullptr);
  if (!screen_dc) return false;
  HDC mem_dc = CreateCompatibleDC(screen_dc);
  if (!mem_dc) {
    ReleaseDC(nullptr, screen_dc);
    return false;
  }

  BITMAPINFO bmi{};
  bmi.bmiHeader.biSize = sizeof(BITMAPINFOHEADER);
  bmi.bmiHeader.biWidth = width;
  bmi.bmiHeader.biHeight = -height;  // top-down
  bmi.bmiHeader.biPlanes = 1;
  bmi.bmiHeader.biBitCount = 32;
  bmi.bmiHeader.biCompression = BI_RGB;

  void* bits = nullptr;
  HBITMAP dib = CreateDIBSection(screen_dc, &bmi, DIB_RGB_COLORS, &bits, nullptr, 0);
  if (!dib || !bits) {
    if (dib) DeleteObject(dib);
    DeleteDC(mem_dc);
    ReleaseDC(nullptr, screen_dc);
    return false;
  }

  HGDIOBJ old = SelectObject(mem_dc, dib);

  // Prefer PrintWindow for correct content even if covered.
  BOOL ok = PrintWindow(hwnd, mem_dc, PW_RENDERFULLCONTENT);
  if (!ok) {
    // Fallback: try BitBlt from window DC (may miss occluded content).
    HDC win_dc = GetWindowDC(hwnd);
    if (win_dc) {
      ok = BitBlt(mem_dc, 0, 0, width, height, win_dc, 0, 0, SRCCOPY) ? TRUE : FALSE;
      ReleaseDC(hwnd, win_dc);
    }
  }

  if (!ok) {
    SelectObject(mem_dc, old);
    DeleteObject(dib);
    DeleteDC(mem_dc);
    ReleaseDC(nullptr, screen_dc);
    if (restored_from_iconic) ShowWindowAsync(hwnd, SW_MINIMIZE);
    if (have_dwm_fallback) {
      out = std::move(dwm_fallback_bytes);
      width = dwm_fallback_w;
      height = dwm_fallback_h;
      return true;
    }
    return false;
  }

  const size_t size = static_cast<size_t>(width) * static_cast<size_t>(height) * 4u;
  out.resize(size);
  memcpy(out.data(), bits, size);

  SelectObject(mem_dc, old);
  DeleteObject(dib);
  DeleteDC(mem_dc);
  ReleaseDC(nullptr, screen_dc);
  if (restored_from_iconic) ShowWindowAsync(hwnd, SW_MINIMIZE);
  return true;
}

bool CaptureWindowBgraScaled(HWND hwnd, int target_w, int target_h, std::vector<uint8_t>& out, int& width, int& height) {
  RECT rc{};
  if (!GetWindowRect(hwnd, &rc)) return false;
  const int src_w = rc.right - rc.left;
  const int src_h = rc.bottom - rc.top;
  if (src_w <= 0 || src_h <= 0) return false;

  width = target_w > 0 ? target_w : src_w;
  height = target_h > 0 ? target_h : src_h;
  if (width <= 0 || height <= 0) return false;

  if (IsIconic(hwnd)) {
    ForceDwmIconicBitmaps(hwnd);

    // Thumbnail preview for minimized windows via DWM.
    HBITMAP hbmp = nullptr;
    const UINT tw = static_cast<UINT>(width);
    const UINT th = static_cast<UINT>(height);
    if (auto thumb_fn = ResolveDwmGetIconicThumbnail()) {
      for (int attempt = 0; attempt < 3; attempt++) {
        const HRESULT hr = thumb_fn(hwnd, tw, th, &hbmp, 0);
        if (SUCCEEDED(hr) && hbmp) {
          int bw = 0, bh = 0;
          if (ReadHBitmapToBgra(hbmp, out, bw, bh)) {
            DeleteObject(hbmp);
            width = bw;
            height = bh;
            return true;
          }
          DeleteObject(hbmp);
          hbmp = nullptr;
        }
        Sleep(30);
        ForceDwmIconicBitmaps(hwnd);
      }
    }
    // If DWM thumbnail isn't available, avoid restoring windows just for previews.
    return false;
  }

  HDC screen_dc = GetDC(nullptr);
  if (!screen_dc) return false;
  HDC mem_full = CreateCompatibleDC(screen_dc);
  HDC mem_thumb = CreateCompatibleDC(screen_dc);
  if (!mem_full || !mem_thumb) {
    if (mem_full) DeleteDC(mem_full);
    if (mem_thumb) DeleteDC(mem_thumb);
    ReleaseDC(nullptr, screen_dc);
    return false;
  }

  // Full-size DIB (src_w x src_h)
  BITMAPINFO bmi_full{};
  bmi_full.bmiHeader.biSize = sizeof(BITMAPINFOHEADER);
  bmi_full.bmiHeader.biWidth = src_w;
  bmi_full.bmiHeader.biHeight = -src_h;  // top-down
  bmi_full.bmiHeader.biPlanes = 1;
  bmi_full.bmiHeader.biBitCount = 32;
  bmi_full.bmiHeader.biCompression = BI_RGB;

  void* bits_full = nullptr;
  HBITMAP dib_full = CreateDIBSection(screen_dc, &bmi_full, DIB_RGB_COLORS, &bits_full, nullptr, 0);
  if (!dib_full || !bits_full) {
    if (dib_full) DeleteObject(dib_full);
    DeleteDC(mem_full);
    DeleteDC(mem_thumb);
    ReleaseDC(nullptr, screen_dc);
    return false;
  }

  // Thumbnail DIB (width x height)
  BITMAPINFO bmi_thumb{};
  bmi_thumb.bmiHeader.biSize = sizeof(BITMAPINFOHEADER);
  bmi_thumb.bmiHeader.biWidth = width;
  bmi_thumb.bmiHeader.biHeight = -height;  // top-down
  bmi_thumb.bmiHeader.biPlanes = 1;
  bmi_thumb.bmiHeader.biBitCount = 32;
  bmi_thumb.bmiHeader.biCompression = BI_RGB;

  void* bits_thumb = nullptr;
  HBITMAP dib_thumb = CreateDIBSection(screen_dc, &bmi_thumb, DIB_RGB_COLORS, &bits_thumb, nullptr, 0);
  if (!dib_thumb || !bits_thumb) {
    if (dib_thumb) DeleteObject(dib_thumb);
    DeleteObject(dib_full);
    DeleteDC(mem_full);
    DeleteDC(mem_thumb);
    ReleaseDC(nullptr, screen_dc);
    return false;
  }

  HGDIOBJ old_full = SelectObject(mem_full, dib_full);
  HGDIOBJ old_thumb = SelectObject(mem_thumb, dib_thumb);

  // Step 1: render full window (PrintWindow does NOT scale; it clips to DC size)
  BOOL ok_full = PrintWindow(hwnd, mem_full, PW_RENDERFULLCONTENT);
  if (!ok_full) {
    HDC win_dc = GetWindowDC(hwnd);
    if (win_dc) {
      ok_full = BitBlt(mem_full, 0, 0, src_w, src_h, win_dc, 0, 0, SRCCOPY) ? TRUE : FALSE;
      ReleaseDC(hwnd, win_dc);
    }
  }

  if (!ok_full) {
    SelectObject(mem_full, old_full);
    SelectObject(mem_thumb, old_thumb);
    DeleteObject(dib_full);
    DeleteObject(dib_thumb);
    DeleteDC(mem_full);
    DeleteDC(mem_thumb);
    ReleaseDC(nullptr, screen_dc);
    return false;
  }

  // Step 2: scale down to thumbnail
  SetStretchBltMode(mem_thumb, HALFTONE);
  BOOL ok_thumb = StretchBlt(mem_thumb, 0, 0, width, height, mem_full, 0, 0, src_w, src_h, SRCCOPY) ? TRUE : FALSE;

  if (!ok_thumb) {
    SelectObject(mem_full, old_full);
    SelectObject(mem_thumb, old_thumb);
    DeleteObject(dib_full);
    DeleteObject(dib_thumb);
    DeleteDC(mem_full);
    DeleteDC(mem_thumb);
    ReleaseDC(nullptr, screen_dc);
    return false;
  }

  const size_t size = static_cast<size_t>(width) * static_cast<size_t>(height) * 4u;
  out.resize(size);
  memcpy(out.data(), bits_thumb, size);

  SelectObject(mem_full, old_full);
  SelectObject(mem_thumb, old_thumb);
  DeleteObject(dib_full);
  DeleteObject(dib_thumb);
  DeleteDC(mem_full);
  DeleteDC(mem_thumb);
  ReleaseDC(nullptr, screen_dc);
  return true;
}

bool CaptureRectBgra(int x, int y, int src_w, int src_h, std::vector<uint8_t>& out, int& width, int& height) {
  width = src_w;
  height = src_h;
  if (width <= 0 || height <= 0) return false;

  HDC screen_dc = GetDC(nullptr);
  if (!screen_dc) return false;
  HDC mem_dc = CreateCompatibleDC(screen_dc);
  if (!mem_dc) {
    ReleaseDC(nullptr, screen_dc);
    return false;
  }

  BITMAPINFO bmi{};
  bmi.bmiHeader.biSize = sizeof(BITMAPINFOHEADER);
  bmi.bmiHeader.biWidth = width;
  bmi.bmiHeader.biHeight = -height;  // top-down
  bmi.bmiHeader.biPlanes = 1;
  bmi.bmiHeader.biBitCount = 32;
  bmi.bmiHeader.biCompression = BI_RGB;

  void* bits = nullptr;
  HBITMAP dib = CreateDIBSection(screen_dc, &bmi, DIB_RGB_COLORS, &bits, nullptr, 0);
  if (!dib || !bits) {
    if (dib) DeleteObject(dib);
    DeleteDC(mem_dc);
    ReleaseDC(nullptr, screen_dc);
    return false;
  }

  HGDIOBJ old = SelectObject(mem_dc, dib);
  BOOL ok = BitBlt(mem_dc, 0, 0, width, height, screen_dc, x, y, SRCCOPY | CAPTUREBLT);
  if (!ok) {
    SelectObject(mem_dc, old);
    DeleteObject(dib);
    DeleteDC(mem_dc);
    ReleaseDC(nullptr, screen_dc);
    return false;
  }

  const size_t size = static_cast<size_t>(width) * static_cast<size_t>(height) * 4u;
  out.resize(size);
  memcpy(out.data(), bits, size);

  SelectObject(mem_dc, old);
  DeleteObject(dib);
  DeleteDC(mem_dc);
  ReleaseDC(nullptr, screen_dc);
  return true;
}

bool CaptureRectBgraScaled(int x, int y, int src_w, int src_h, int max_w, int max_h, std::vector<uint8_t>& out, int& width, int& height) {
  int tw = 0, th = 0;
  ScaleToFit(src_w, src_h, max_w, max_h, tw, th);
  width = tw;
  height = th;
  if (width <= 0 || height <= 0) return false;

  HDC screen_dc = GetDC(nullptr);
  if (!screen_dc) return false;
  HDC mem_dc = CreateCompatibleDC(screen_dc);
  if (!mem_dc) {
    ReleaseDC(nullptr, screen_dc);
    return false;
  }

  BITMAPINFO bmi{};
  bmi.bmiHeader.biSize = sizeof(BITMAPINFOHEADER);
  bmi.bmiHeader.biWidth = width;
  bmi.bmiHeader.biHeight = -height;  // top-down
  bmi.bmiHeader.biPlanes = 1;
  bmi.bmiHeader.biBitCount = 32;
  bmi.bmiHeader.biCompression = BI_RGB;

  void* bits = nullptr;
  HBITMAP dib = CreateDIBSection(screen_dc, &bmi, DIB_RGB_COLORS, &bits, nullptr, 0);
  if (!dib || !bits) {
    if (dib) DeleteObject(dib);
    DeleteDC(mem_dc);
    ReleaseDC(nullptr, screen_dc);
    return false;
  }

  HGDIOBJ old = SelectObject(mem_dc, dib);
  SetStretchBltMode(mem_dc, HALFTONE);
  BOOL ok = StretchBlt(mem_dc, 0, 0, width, height, screen_dc, x, y, src_w, src_h, SRCCOPY | CAPTUREBLT) ? TRUE : FALSE;
  if (!ok) {
    SelectObject(mem_dc, old);
    DeleteObject(dib);
    DeleteDC(mem_dc);
    ReleaseDC(nullptr, screen_dc);
    return false;
  }

  const size_t size = static_cast<size_t>(width) * static_cast<size_t>(height) * 4u;
  out.resize(size);
  memcpy(out.data(), bits, size);

  SelectObject(mem_dc, old);
  DeleteObject(dib);
  DeleteDC(mem_dc);
  ReleaseDC(nullptr, screen_dc);
  return true;
}

bool CaptureScreenBgra(std::vector<uint8_t>& out, int& width, int& height) {
  const int x = GetSystemMetrics(SM_XVIRTUALSCREEN);
  const int y = GetSystemMetrics(SM_YVIRTUALSCREEN);
  width = GetSystemMetrics(SM_CXVIRTUALSCREEN);
  height = GetSystemMetrics(SM_CYVIRTUALSCREEN);
  if (width <= 0 || height <= 0) return false;
  return CaptureRectBgra(x, y, width, height, out, width, height);
}
}  // namespace

FlutterWindow::FlutterWindow(const flutter::DartProject& project)
    : project_(project) {}

FlutterWindow::~FlutterWindow() {}

bool FlutterWindow::OnCreate() {
  if (!Win32Window::OnCreate()) {
    return false;
  }

  RECT frame = GetClientArea();

  // The size here must match the window dimensions to avoid unnecessary surface
  // creation / destruction in the startup path.
  flutter_controller_ = std::make_unique<flutter::FlutterViewController>(
      frame.right - frame.left, frame.bottom - frame.top, project_);
  // Ensure that basic setup of the controller was successful.
  if (!flutter_controller_->engine() || !flutter_controller_->view()) {
    return false;
  }
  RegisterPlugins(flutter_controller_->engine());
  SetChildContent(flutter_controller_->view()->GetNativeWindow());

  // Setup method channel for audio
  auto audioChannel =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          flutter_controller_->engine()->messenger(), "com.hearnow/audio",
          &flutter::StandardMethodCodec::GetInstance());

  audioChannel->SetMethodCallHandler(
      [](const flutter::MethodCall<flutter::EncodableValue>& call,
         std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>
             result) {
        if (call.method_name().compare("startSystemAudio") == 0) {
          if (!g_audio_capture) {
            g_audio_capture = std::make_unique<AudioCapture>();
          }
          bool success = g_audio_capture->StartSystemAudio();
          result->Success(flutter::EncodableValue(success));
        } else if (call.method_name().compare("stopSystemAudio") == 0) {
          if (g_audio_capture) {
            g_audio_capture->StopSystemAudio();
          }
          result->Success();
        } else if (call.method_name().compare("getSystemAudioFrame") == 0) {
          if (g_audio_capture) {
            size_t requested = 0;
            if (call.arguments()) {
              // Expect either an int directly or a map {"length": int}
              if (std::holds_alternative<int32_t>(*call.arguments())) {
                requested = static_cast<size_t>(std::get<int32_t>(*call.arguments()));
              } else if (std::holds_alternative<flutter::EncodableMap>(*call.arguments())) {
                const auto& args = std::get<flutter::EncodableMap>(*call.arguments());
                auto it = args.find(flutter::EncodableValue("length"));
                if (it != args.end() && std::holds_alternative<int32_t>(it->second)) {
                  requested = static_cast<size_t>(std::get<int32_t>(it->second));
                }
              }
            }

            if (requested == 0) {
              // Default to 1280 bytes (~40ms @ 16k mono PCM16) if caller doesn't specify.
              requested = 1280;
            }

            auto frame = g_audio_capture->GetSystemAudioFrame(requested);
            result->Success(flutter::EncodableValue(frame));
          } else {
            result->Success(flutter::EncodableValue(std::vector<uint8_t>()));
          }
        } else {
          result->NotImplemented();
        }
      });

  // Setup method channel for window settings
  auto windowChannel =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          flutter_controller_->engine()->messenger(), "com.hearnow/window",
          &flutter::StandardMethodCodec::GetInstance());

  windowChannel->SetMethodCallHandler(
      [this](const flutter::MethodCall<flutter::EncodableValue>& call,
         std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>
             result) {
        if (call.method_name().compare("setUndetectable") == 0) {
          bool value = false;
          if (call.arguments()) {
            if (std::holds_alternative<bool>(*call.arguments())) {
              value = std::get<bool>(*call.arguments());
            }
          }
          HWND hwnd = GetHandle();
          if (hwnd) {
            if (value) {
              SetWindowDisplayAffinity(hwnd, WDA_EXCLUDEFROMCAPTURE);
            } else {
              SetWindowDisplayAffinity(hwnd, WDA_NONE);
            }
            result->Success(flutter::EncodableValue(true));
          } else {
            result->Error("NO_WINDOW", "Window handle not available");
          }
        } else if (call.method_name().compare("setTitleBarTheme") == 0) {
          bool isDark = true;
          if (call.arguments()) {
            if (std::holds_alternative<bool>(*call.arguments())) {
              isDark = std::get<bool>(*call.arguments());
            }
          }
          HWND hwnd = GetHandle();
          if (hwnd) {
            Win32Window::UpdateTheme(hwnd, isDark);
            result->Success(flutter::EncodableValue(true));
          } else {
            result->Error("NO_WINDOW", "Window handle not available");
          }
        } else if (call.method_name().compare("captureActiveWindowPixels") == 0) {
          HWND self = GetHandle();
          HWND fg = GetForegroundWindow();
          bool minimized_self = false;

          // If our app is foreground, minimize briefly so the real target becomes foreground.
          if (self && (fg == self || IsChild(self, fg))) {
            minimized_self = true;
            ShowWindow(self, SW_MINIMIZE);
            Sleep(120);
            for (int i = 0; i < 10; i++) {
              fg = GetForegroundWindow();
              if (fg && fg != self && !IsChild(self, fg)) break;
              Sleep(50);
            }
          }

          if (!fg || (self && (fg == self || IsChild(self, fg)))) {
            if (minimized_self && self) {
              ShowWindow(self, SW_RESTORE);
              SetForegroundWindow(self);
            }
            result->Error("NO_TARGET", "No active window to capture (focus another window and try again).");
            return;
          }

          std::vector<uint8_t> bytes;
          int w = 0, h = 0;
          const bool ok = CaptureWindowBgra(fg, bytes, w, h);

          if (minimized_self && self) {
            ShowWindow(self, SW_RESTORE);
            SetForegroundWindow(self);
          }

          if (!ok) {
            result->Error("CAPTURE_FAILED", "Failed to capture active window.");
            return;
          }

          flutter::EncodableMap map;
          map[flutter::EncodableValue("width")] = flutter::EncodableValue(w);
          map[flutter::EncodableValue("height")] = flutter::EncodableValue(h);
          map[flutter::EncodableValue("bytes")] = flutter::EncodableValue(bytes);
          result->Success(flutter::EncodableValue(map));
        } else if (call.method_name().compare("listShareableWindows") == 0) {
          HWND self = GetHandle();
          flutter::EncodableList list;

          struct Ctx {
            HWND self;
            flutter::EncodableList* out;
          } ctx{self, &list};

          EnumWindows(
              [](HWND hwnd, LPARAM lparam) -> BOOL {
                auto* c = reinterpret_cast<Ctx*>(lparam);
                if (!IsShareableTopLevelWindow(hwnd, c->self)) return TRUE;

                wchar_t title[512];
                title[0] = L'\0';
                GetWindowTextW(hwnd, title, 512);

                flutter::EncodableMap m;
                m[flutter::EncodableValue("hwnd")] =
                    flutter::EncodableValue(static_cast<int64_t>(reinterpret_cast<intptr_t>(hwnd)));
                m[flutter::EncodableValue("title")] =
                    flutter::EncodableValue(WideToUtf8(title));
                m[flutter::EncodableValue("isMinimized")] = flutter::EncodableValue(IsIconic(hwnd) ? true : false);

                c->out->push_back(flutter::EncodableValue(m));
                return TRUE;
              },
              reinterpret_cast<LPARAM>(&ctx));

          result->Success(flutter::EncodableValue(list));
        } else if (call.method_name().compare("captureWindowPixels") == 0) {
          HWND self = GetHandle();
          int64_t hwnd_val = 0;
          if (call.arguments()) {
            if (std::holds_alternative<int64_t>(*call.arguments())) {
              hwnd_val = std::get<int64_t>(*call.arguments());
            } else if (std::holds_alternative<int32_t>(*call.arguments())) {
              hwnd_val = static_cast<int64_t>(std::get<int32_t>(*call.arguments()));
            } else if (std::holds_alternative<flutter::EncodableMap>(*call.arguments())) {
              const auto& args = std::get<flutter::EncodableMap>(*call.arguments());
              auto it = args.find(flutter::EncodableValue("hwnd"));
              if (it != args.end()) {
                if (std::holds_alternative<int64_t>(it->second)) hwnd_val = std::get<int64_t>(it->second);
                else if (std::holds_alternative<int32_t>(it->second)) hwnd_val = static_cast<int64_t>(std::get<int32_t>(it->second));
              }
            }
          }
          if (hwnd_val == 0) {
            result->Error("BAD_ARGS", "Missing hwnd");
            return;
          }
          HWND target = reinterpret_cast<HWND>(static_cast<intptr_t>(hwnd_val));
          if (!IsWindow(target)) {
            result->Error("NO_WINDOW", "Window no longer exists");
            return;
          }
          if (self && (target == self || IsChild(self, target))) {
            result->Error("BAD_TARGET", "Cannot capture this app window");
            return;
          }

          std::vector<uint8_t> bytes;
          int w = 0, h = 0;
          const bool ok = CaptureWindowBgra(target, bytes, w, h);
          if (!ok) {
            result->Error("CAPTURE_FAILED", "Failed to capture window.");
            return;
          }
          flutter::EncodableMap map;
          map[flutter::EncodableValue("width")] = flutter::EncodableValue(w);
          map[flutter::EncodableValue("height")] = flutter::EncodableValue(h);
          map[flutter::EncodableValue("bytes")] = flutter::EncodableValue(bytes);
          result->Success(flutter::EncodableValue(map));
        } else if (call.method_name().compare("captureWindowThumbnailPixels") == 0) {
          int64_t hwnd_val = 0;
          int max_w = 320;
          int max_h = 200;
          if (call.arguments() && std::holds_alternative<flutter::EncodableMap>(*call.arguments())) {
            const auto& args = std::get<flutter::EncodableMap>(*call.arguments());
            auto it = args.find(flutter::EncodableValue("hwnd"));
            if (it != args.end()) {
              if (std::holds_alternative<int64_t>(it->second)) hwnd_val = std::get<int64_t>(it->second);
              else if (std::holds_alternative<int32_t>(it->second)) hwnd_val = static_cast<int64_t>(std::get<int32_t>(it->second));
            }
            auto itw = args.find(flutter::EncodableValue("maxWidth"));
            if (itw != args.end()) {
              if (std::holds_alternative<int32_t>(itw->second)) max_w = std::get<int32_t>(itw->second);
              else if (std::holds_alternative<int64_t>(itw->second)) max_w = static_cast<int>(std::get<int64_t>(itw->second));
            }
            auto ith = args.find(flutter::EncodableValue("maxHeight"));
            if (ith != args.end()) {
              if (std::holds_alternative<int32_t>(ith->second)) max_h = std::get<int32_t>(ith->second);
              else if (std::holds_alternative<int64_t>(ith->second)) max_h = static_cast<int>(std::get<int64_t>(ith->second));
            }
          }
          if (hwnd_val == 0) {
            result->Error("BAD_ARGS", "Missing hwnd");
            return;
          }
          HWND self = GetHandle();
          HWND target = reinterpret_cast<HWND>(static_cast<intptr_t>(hwnd_val));
          if (!IsWindow(target)) {
            result->Error("NO_WINDOW", "Window no longer exists");
            return;
          }
          if (self && (target == self || IsChild(self, target))) {
            result->Error("BAD_TARGET", "Cannot capture this app window");
            return;
          }

          RECT rc{};
          if (!GetWindowRect(target, &rc)) {
            result->Error("CAPTURE_FAILED", "Failed to get window rect.");
            return;
          }
          const int src_w = rc.right - rc.left;
          const int src_h = rc.bottom - rc.top;
          int tw = 0, th = 0;
          ScaleToFit(src_w, src_h, max_w, max_h, tw, th);

          std::vector<uint8_t> bytes;
          int w = 0, h = 0;
          const bool ok = CaptureWindowBgraScaled(target, tw, th, bytes, w, h);
          if (!ok) {
            result->Error("CAPTURE_FAILED", "Failed to capture window thumbnail.");
            return;
          }
          flutter::EncodableMap map;
          map[flutter::EncodableValue("width")] = flutter::EncodableValue(w);
          map[flutter::EncodableValue("height")] = flutter::EncodableValue(h);
          map[flutter::EncodableValue("bytes")] = flutter::EncodableValue(bytes);
          result->Success(flutter::EncodableValue(map));
        } else if (call.method_name().compare("captureScreenPixels") == 0) {
          HWND self = GetHandle();
          bool minimized_self = false;

          // If our app is foreground, minimize briefly so it doesn't appear in the capture.
          HWND fg = GetForegroundWindow();
          if (self && (fg == self || IsChild(self, fg))) {
            minimized_self = true;
            ShowWindow(self, SW_MINIMIZE);
            Sleep(120);
          }

          std::vector<uint8_t> bytes;
          int w = 0, h = 0;
          const bool ok = CaptureScreenBgra(bytes, w, h);

          if (minimized_self && self) {
            ShowWindow(self, SW_RESTORE);
            SetForegroundWindow(self);
          }

          if (!ok) {
            result->Error("CAPTURE_FAILED", "Failed to capture screen.");
            return;
          }

          flutter::EncodableMap map;
          map[flutter::EncodableValue("width")] = flutter::EncodableValue(w);
          map[flutter::EncodableValue("height")] = flutter::EncodableValue(h);
          map[flutter::EncodableValue("bytes")] = flutter::EncodableValue(bytes);
          result->Success(flutter::EncodableValue(map));
        } else if (call.method_name().compare("captureScreenThumbnailPixels") == 0) {
          int max_w = 320;
          int max_h = 200;
          if (call.arguments() && std::holds_alternative<flutter::EncodableMap>(*call.arguments())) {
            const auto& args = std::get<flutter::EncodableMap>(*call.arguments());
            auto itw = args.find(flutter::EncodableValue("maxWidth"));
            if (itw != args.end()) {
              if (std::holds_alternative<int32_t>(itw->second)) max_w = std::get<int32_t>(itw->second);
              else if (std::holds_alternative<int64_t>(itw->second)) max_w = static_cast<int>(std::get<int64_t>(itw->second));
            }
            auto ith = args.find(flutter::EncodableValue("maxHeight"));
            if (ith != args.end()) {
              if (std::holds_alternative<int32_t>(ith->second)) max_h = std::get<int32_t>(ith->second);
              else if (std::holds_alternative<int64_t>(ith->second)) max_h = static_cast<int>(std::get<int64_t>(ith->second));
            }
          }

          const int x = GetSystemMetrics(SM_XVIRTUALSCREEN);
          const int y = GetSystemMetrics(SM_YVIRTUALSCREEN);
          const int sw = GetSystemMetrics(SM_CXVIRTUALSCREEN);
          const int sh = GetSystemMetrics(SM_CYVIRTUALSCREEN);
          if (sw <= 0 || sh <= 0) {
            result->Error("CAPTURE_FAILED", "Invalid virtual screen metrics.");
            return;
          }

          std::vector<uint8_t> bytes;
          int w = 0, h = 0;
          const bool ok = CaptureRectBgraScaled(x, y, sw, sh, max_w, max_h, bytes, w, h);
          if (!ok) {
            result->Error("CAPTURE_FAILED", "Failed to capture screen thumbnail.");
            return;
          }
          flutter::EncodableMap map;
          map[flutter::EncodableValue("width")] = flutter::EncodableValue(w);
          map[flutter::EncodableValue("height")] = flutter::EncodableValue(h);
          map[flutter::EncodableValue("bytes")] = flutter::EncodableValue(bytes);
          result->Success(flutter::EncodableValue(map));
        } else if (call.method_name().compare("listMonitors") == 0) {
          flutter::EncodableList list;
          struct MonCtx {
            int index;
            flutter::EncodableList* out;
          } ctx{0, &list};
          EnumDisplayMonitors(
              nullptr,
              nullptr,
              [](HMONITOR hmon, HDC, LPRECT, LPARAM lparam) -> BOOL {
                auto* ctx = reinterpret_cast<MonCtx*>(lparam);
                MONITORINFOEXW mi{};
                mi.cbSize = sizeof(mi);
                if (!GetMonitorInfoW(hmon, &mi)) return TRUE;

                const RECT r = mi.rcMonitor;
                const int w = r.right - r.left;
                const int h = r.bottom - r.top;
                if (w <= 0 || h <= 0) return TRUE;

                ctx->index += 1;
                const bool primary = (mi.dwFlags & MONITORINFOF_PRIMARY) != 0;

                flutter::EncodableMap m;
                m[flutter::EncodableValue("id")] =
                    flutter::EncodableValue(static_cast<int64_t>(reinterpret_cast<intptr_t>(hmon)));
                m[flutter::EncodableValue("index")] = flutter::EncodableValue(ctx->index);
                m[flutter::EncodableValue("width")] = flutter::EncodableValue(w);
                m[flutter::EncodableValue("height")] = flutter::EncodableValue(h);
                m[flutter::EncodableValue("isPrimary")] = flutter::EncodableValue(primary);
                m[flutter::EncodableValue("device")] = flutter::EncodableValue(WideToUtf8(mi.szDevice));
                ctx->out->push_back(flutter::EncodableValue(m));
                return TRUE;
              },
              reinterpret_cast<LPARAM>(&ctx));
          result->Success(flutter::EncodableValue(list));
        } else if (call.method_name().compare("captureMonitorPixels") == 0) {
          int64_t id = 0;
          if (call.arguments() && std::holds_alternative<flutter::EncodableMap>(*call.arguments())) {
            const auto& args = std::get<flutter::EncodableMap>(*call.arguments());
            auto it = args.find(flutter::EncodableValue("monitorId"));
            if (it != args.end()) {
              if (std::holds_alternative<int64_t>(it->second)) id = std::get<int64_t>(it->second);
              else if (std::holds_alternative<int32_t>(it->second)) id = static_cast<int64_t>(std::get<int32_t>(it->second));
            }
          }
          if (id == 0) {
            result->Error("BAD_ARGS", "Missing monitorId");
            return;
          }
          HMONITOR target = reinterpret_cast<HMONITOR>(static_cast<intptr_t>(id));
          MONITORINFO mi{};
          mi.cbSize = sizeof(mi);
          if (!GetMonitorInfoW(target, &mi)) {
            result->Error("NO_MONITOR", "Monitor not found");
            return;
          }
          const RECT r = mi.rcMonitor;
          const int sw = r.right - r.left;
          const int sh = r.bottom - r.top;
          std::vector<uint8_t> bytes;
          int w = 0, h = 0;
          const bool ok = CaptureRectBgra(r.left, r.top, sw, sh, bytes, w, h);
          if (!ok) {
            result->Error("CAPTURE_FAILED", "Failed to capture monitor.");
            return;
          }
          flutter::EncodableMap map;
          map[flutter::EncodableValue("width")] = flutter::EncodableValue(w);
          map[flutter::EncodableValue("height")] = flutter::EncodableValue(h);
          map[flutter::EncodableValue("bytes")] = flutter::EncodableValue(bytes);
          result->Success(flutter::EncodableValue(map));
        } else if (call.method_name().compare("captureMonitorThumbnailPixels") == 0) {
          int64_t id = 0;
          int max_w = 320;
          int max_h = 200;
          if (call.arguments() && std::holds_alternative<flutter::EncodableMap>(*call.arguments())) {
            const auto& args = std::get<flutter::EncodableMap>(*call.arguments());
            auto it = args.find(flutter::EncodableValue("monitorId"));
            if (it != args.end()) {
              if (std::holds_alternative<int64_t>(it->second)) id = std::get<int64_t>(it->second);
              else if (std::holds_alternative<int32_t>(it->second)) id = static_cast<int64_t>(std::get<int32_t>(it->second));
            }
            auto itw = args.find(flutter::EncodableValue("maxWidth"));
            if (itw != args.end()) {
              if (std::holds_alternative<int32_t>(itw->second)) max_w = std::get<int32_t>(itw->second);
              else if (std::holds_alternative<int64_t>(itw->second)) max_w = static_cast<int>(std::get<int64_t>(itw->second));
            }
            auto ith = args.find(flutter::EncodableValue("maxHeight"));
            if (ith != args.end()) {
              if (std::holds_alternative<int32_t>(ith->second)) max_h = std::get<int32_t>(ith->second);
              else if (std::holds_alternative<int64_t>(ith->second)) max_h = static_cast<int>(std::get<int64_t>(ith->second));
            }
          }
          if (id == 0) {
            result->Error("BAD_ARGS", "Missing monitorId");
            return;
          }
          HMONITOR target = reinterpret_cast<HMONITOR>(static_cast<intptr_t>(id));
          MONITORINFO mi{};
          mi.cbSize = sizeof(mi);
          if (!GetMonitorInfoW(target, &mi)) {
            result->Error("NO_MONITOR", "Monitor not found");
            return;
          }
          const RECT r = mi.rcMonitor;
          const int sw = r.right - r.left;
          const int sh = r.bottom - r.top;
          std::vector<uint8_t> bytes;
          int w = 0, h = 0;
          const bool ok = CaptureRectBgraScaled(r.left, r.top, sw, sh, max_w, max_h, bytes, w, h);
          if (!ok) {
            result->Error("CAPTURE_FAILED", "Failed to capture monitor thumbnail.");
            return;
          }
          flutter::EncodableMap map;
          map[flutter::EncodableValue("width")] = flutter::EncodableValue(w);
          map[flutter::EncodableValue("height")] = flutter::EncodableValue(h);
          map[flutter::EncodableValue("bytes")] = flutter::EncodableValue(bytes);
          result->Success(flutter::EncodableValue(map));
        } else {
          result->NotImplemented();
        }
      });

  flutter_controller_->engine()->SetNextFrameCallback([&]() {
    this->Show();
  });

  // Flutter can complete the first frame before the "show window" callback is
  // registered. The following call ensures a frame is pending to ensure the
  // window is shown. It is a no-op if the first frame hasn't completed yet.
  flutter_controller_->ForceRedraw();

  return true;
}

void FlutterWindow::OnDestroy() {
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  // Give Flutter, including plugins, an opportunity to handle window messages.
  if (flutter_controller_) {
    std::optional<LRESULT> result =
        flutter_controller_->HandleTopLevelWindowProc(hwnd, message, wparam,
                                                      lparam);
    if (result) {
      return *result;
    }
  }

  switch (message) {
    case WM_FONTCHANGE:
      flutter_controller_->engine()->ReloadSystemFonts();
      break;
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}
