#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>

#include "console.h"
#include "flutter_window.h"
#include "utils.h"

// Single-instance plumbing (definitions; FlutterWindow::MessageHandler reads
// the message id via an extern). The strings are namespaced to the app's
// bundle id so they never collide with another app on the machine.
//
// kSingleInstanceMutex: a named mutex whose pre-existence means an instance is
//   already running.
// g_pocox_show_msg: a process-wide RegisterWindowMessage id. A second
//   launch broadcasts it (then exits) and the running instance, on receiving
//   it, surfaces its window - even if it was hidden to the system tray.
constexpr const wchar_t kSingleInstanceMutex[] =
    L"io.github.acking_you.pocox.singleton";
UINT g_pocox_show_msg = 0;

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
  // Enforce a single instance before doing any real work. If the mutex already
  // exists, another copy is running: ask it to surface (a broadcast that only
  // our own windows recognise, since the message id is unique to this app) and
  // exit instead of spawning a second process / second tray icon.
  g_pocox_show_msg =
      ::RegisterWindowMessageW(L"io.github.acking_you.pocox.show");
  HANDLE single_instance_mutex =
      ::CreateMutexW(nullptr, TRUE, kSingleInstanceMutex);
  if (single_instance_mutex != nullptr &&
      ::GetLastError() == ERROR_ALREADY_EXISTS) {
    // Let the already-running instance steal focus, then nudge it to show.
    ::AllowSetForegroundWindow(ASFW_ANY);
    ::PostMessageW(HWND_BROADCAST, g_pocox_show_msg, 0, 0);
    ::CloseHandle(single_instance_mutex);
    return EXIT_SUCCESS;
  }

  ConfigureConsole();

  // Initialize COM, so that it is available for use in the library and/or
  // plugins.
  ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);

  int exit_code = EXIT_SUCCESS;
  {
    // Keep the single-instance handle until the engine and its plugins have
    // finished shutting down. A new launch must not overlap their teardown.
    flutter::DartProject project(L"data");

    std::vector<std::string> command_line_arguments =
        GetCommandLineArguments();

    project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

    FlutterWindow window(project);
    Win32Window::Point origin(10, 10);
    Win32Window::Size size(1280, 720);
    if (window.Create(L"POCOX", origin, size)) {
      window.SetQuitOnClose(true);

      ::MSG msg;
      while (::GetMessage(&msg, nullptr, 0, 0)) {
        ::TranslateMessage(&msg);
        ::DispatchMessage(&msg);
      }
    } else {
      exit_code = EXIT_FAILURE;
    }
  }

  ::CoUninitialize();
  if (single_instance_mutex != nullptr) {
    ::CloseHandle(single_instance_mutex);
  }
  return exit_code;
}
