#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>

#include <vector>

#include "flutter_window.h"
#include "utils.h"

// Unique mutex name for single instance check
static const wchar_t* kMutexName = L"Global\\FinalRoundAppMutex_SingleInstance";
static const wchar_t* kWindowClassName = L"FLUTTER_RUNNER_WIN32_WINDOW";
static const wchar_t* kWindowTitle = L"FinalRound";

// Callback to collect existing FinalRound windows
BOOL CALLBACK EnumWindowsCallback(HWND hwnd, LPARAM lParam) {
  wchar_t className[256];
  if (::GetClassNameW(hwnd, className, 256) &&
      wcscmp(className, kWindowClassName) == 0) {
    auto* windows = reinterpret_cast<std::vector<HWND>*>(lParam);
    windows->push_back(hwnd);
  }
  return TRUE;
}

// Show a window (including one hidden to the tray) and bring it to the front.
void ActivateExistingWindow(HWND hwnd) {
  if (!::IsWindow(hwnd)) {
    return;
  }

  if (::IsIconic(hwnd) || !::IsWindowVisible(hwnd)) {
    ::ShowWindow(hwnd, SW_RESTORE);
  } else {
    ::ShowWindow(hwnd, SW_SHOW);
  }

  HWND foreground = ::GetForegroundWindow();
  const DWORD this_thread = ::GetCurrentThreadId();
  DWORD foreground_thread = 0;
  if (foreground) {
    foreground_thread = ::GetWindowThreadProcessId(foreground, nullptr);
  }
  const DWORD target_thread = ::GetWindowThreadProcessId(hwnd, nullptr);

  if (foreground_thread != 0 && foreground_thread != this_thread) {
    ::AttachThreadInput(this_thread, foreground_thread, TRUE);
  }
  if (target_thread != 0 && target_thread != this_thread) {
    ::AttachThreadInput(this_thread, target_thread, TRUE);
  }

  ::BringWindowToTop(hwnd);
  ::SetForegroundWindow(hwnd);
  ::SetActiveWindow(hwnd);

  if (target_thread != 0 && target_thread != this_thread) {
    ::AttachThreadInput(this_thread, target_thread, FALSE);
  }
  if (foreground_thread != 0 && foreground_thread != this_thread) {
    ::AttachThreadInput(this_thread, foreground_thread, FALSE);
  }
}

// Bring existing windows to the foreground without showing a dialog.
void BringExistingWindowToFront() {
  std::vector<HWND> windows;
  ::EnumWindows(EnumWindowsCallback, reinterpret_cast<LPARAM>(&windows));
  for (HWND hwnd : windows) {
    ActivateExistingWindow(hwnd);
  }
}

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
  // Single instance check using mutex
  HANDLE hMutex = ::CreateMutexW(nullptr, TRUE, kMutexName);
  if (hMutex == nullptr) {
    return EXIT_FAILURE;
  }
  
  if (::GetLastError() == ERROR_ALREADY_EXISTS) {
    ::CloseHandle(hMutex);
    BringExistingWindowToFront();
    return EXIT_SUCCESS;
  }

  // Attach to console when present (e.g., 'flutter run') or create a
  // new console when running with a debugger.
  if (!::AttachConsole(ATTACH_PARENT_PROCESS) && ::IsDebuggerPresent()) {
    CreateAndAttachConsole();
  }

  // Initialize COM, so that it is available for use in the library and/or
  // plugins.
  ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);

  flutter::DartProject project(L"data");

  std::vector<std::string> command_line_arguments =
      GetCommandLineArguments();

  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  FlutterWindow window(project);
  Win32Window::Point origin(10, 10);
  Win32Window::Size size(1280, 720);
  if (!window.Create(kWindowTitle, origin, size)) {
    ::CloseHandle(hMutex);
    return EXIT_FAILURE;
  }
  window.SetQuitOnClose(true);

  ::MSG msg;
  while (::GetMessage(&msg, nullptr, 0, 0)) {
    ::TranslateMessage(&msg);
    ::DispatchMessage(&msg);
  }

  ::CoUninitialize();
  ::CloseHandle(hMutex);
  return EXIT_SUCCESS;
}
