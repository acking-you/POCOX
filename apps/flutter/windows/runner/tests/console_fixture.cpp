#include <windows.h>
#include <shellapi.h>

#include <cstdio>
#include <string>

#include "../console.h"

// A real GUI process with the release runner's console policy. Its parent is a
// separate, hidden console belonging only to this test, safe to close or kill.
int WINAPI wWinMain(HINSTANCE, HINSTANCE, wchar_t*, int) {
  int argc = 0;
  wchar_t** argv = ::CommandLineToArgvW(::GetCommandLineW(), &argc);
  if (argv == nullptr || argc != 3) {
    return 2;
  }
  const std::wstring mode(argv[1]);
  const std::wstring report(argv[2]);
  ::LocalFree(argv);
  DWORD child_pid = 0;
  if (mode == L"parent") {
    if (!::AllocConsole()) {
      return 3;
    }
    wchar_t executable[MAX_PATH];
    if (!::GetModuleFileNameW(nullptr, executable, MAX_PATH)) {
      return 4;
    }
    std::wstring command = L"\"" + std::wstring(executable) + L"\" child \"" +
                           report + L".child\"";
    STARTUPINFOW startup{};
    startup.cb = sizeof(startup);
    PROCESS_INFORMATION child{};
    if (!::CreateProcessW(executable, command.data(), nullptr, nullptr, FALSE,
                          0, nullptr, nullptr, &startup, &child)) {
      return 5;
    }
    child_pid = child.dwProcessId;
    ::CloseHandle(child.hThread);
    ::CloseHandle(child.hProcess);
  } else if (mode == L"child") {
    ConfigureConsole();
  } else {
    return 6;
  }
  FILE* file = nullptr;
  const std::wstring pending = report + L".tmp";
  if (_wfopen_s(&file, pending.c_str(), L"w") != 0) {
    return 7;
  }
  const HWND console = ::GetConsoleWindow();
  std::fprintf(file, "%llu %lu %d\n",
               static_cast<unsigned long long>(reinterpret_cast<UINT_PTR>(console)),
               child_pid, ::IsWindowVisible(console) != FALSE);
  std::fclose(file);
  if (!::MoveFileExW(pending.c_str(), report.c_str(), MOVEFILE_REPLACE_EXISTING)) {
    return 8;
  }
  ::Sleep(20000);
  return 0;
}
