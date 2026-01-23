#include "flutter_window.h"

#include <optional>

#include <flutter/encodable_value.h>
#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>
#include <winuser.h>

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
