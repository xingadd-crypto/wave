#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>
#include <shellapi.h>

#include "flutter_window.h"
#include "utils.h"

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
  if (!::AttachConsole(ATTACH_PARENT_PROCESS) && ::IsDebuggerPresent()) {
    CreateAndAttachConsole();
  }

  ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);

  wchar_t exeDir[MAX_PATH];
  GetModuleFileNameW(nullptr, exeDir, MAX_PATH);
  wchar_t* lastSlash = wcsrchr(exeDir, L'\\');
  if (lastSlash) *lastSlash = L'\0';
  SetCurrentDirectoryW(exeDir);

  flutter::DartProject project(L"data");

  std::vector<std::string> command_line_arguments =
      GetCommandLineArguments();

  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  FlutterWindow window(project);
  Win32Window::Size size(780, 620);
  const HDC screen_dc = GetDC(nullptr);
  const double dpi_scale =
      GetDeviceCaps(screen_dc, LOGPIXELSX) / 96.0;
  ReleaseDC(nullptr, screen_dc);
  int origin_x = static_cast<int>(
      (GetSystemMetrics(SM_CXSCREEN) / dpi_scale - size.width) / 2);
  int origin_y = static_cast<int>(
      (GetSystemMetrics(SM_CYSCREEN) / dpi_scale - size.height) / 2);
  if (origin_x < 0) {
    origin_x = 0;
  }
  if (origin_y < 0) {
    origin_y = 0;
  }
  Win32Window::Point origin(origin_x, origin_y);
  if (!window.Create(L"Wave", origin, size)) {
    return EXIT_FAILURE;
  }
  window.SetQuitOnClose(true);
  window.SetMinimizeToTray(true);
  window.AddTrayIcon();

  ::MSG msg;
  while (::GetMessage(&msg, nullptr, 0, 0)) {
    ::TranslateMessage(&msg);
    ::DispatchMessage(&msg);
  }

  ::CoUninitialize();
  return EXIT_SUCCESS;
}
