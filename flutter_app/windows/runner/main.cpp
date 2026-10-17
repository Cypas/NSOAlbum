#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>

#include <fstream>
#include <cstdio>
#include <string>

#include "flutter_window.h"
#include "utils.h"
#include "native_single_instance.h"

namespace {

bool HasArgument(const std::vector<std::string>& arguments,
                 const std::string& value) {
  for (const auto& argument : arguments) {
    if (argument == value) {
      return true;
    }
  }
  return false;
}

LONG WINAPI NativeCrashFilter(EXCEPTION_POINTERS* exception) {
  wchar_t temp_path[MAX_PATH] = {};
  constexpr DWORD kTempPathCapacity =
      static_cast<DWORD>(sizeof(temp_path) / sizeof(temp_path[0]));
  const DWORD length = ::GetTempPathW(kTempPathCapacity, temp_path);
  if (length == 0 || length >= kTempPathCapacity) {
    return EXCEPTION_CONTINUE_SEARCH;
  }

  std::wstring path(temp_path);
  path += L"squid_album_native_crash.log";
  std::wofstream output(path, std::ios::app);
  if (output.is_open()) {
    output << L"Unhandled native exception code=0x" << std::hex
           << exception->ExceptionRecord->ExceptionCode << L" address=0x"
           << reinterpret_cast<uintptr_t>(
                  exception->ExceptionRecord->ExceptionAddress)
           << std::endl;
  }
  return EXCEPTION_CONTINUE_SEARCH;
}

}  // namespace

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
  ::SetUnhandledExceptionFilter(NativeCrashFilter);

  // Attach to console when present (e.g., 'flutter run') or create a
  // new console when running with a debugger.
  if (!::AttachConsole(ATTACH_PARENT_PROCESS) && ::IsDebuggerPresent()) {
    CreateAndAttachConsole();
  }

  std::vector<std::string> command_line_arguments = GetCommandLineArguments();
  // Invalid smoke arguments are still rejected by Dart before any core opens.
  const bool smoke = HasArgument(command_line_arguments, "--ci-smoke");
  NativeSingleInstance desktop_instance(
      smoke ? std::filesystem::path{} : NativeSingleInstance::UserDirectory());
  if (!smoke) {
    const auto outcome = desktop_instance.AcquireOrActivate();
    if (outcome == NativeSingleInstance::Outcome::Activated) {
      std::fputs("NSOAlbum: activated existing desktop window\n", stdout);
      return EXIT_SUCCESS;
    }
    if (outcome != NativeSingleInstance::Outcome::Primary) {
      std::fputs("NSOAlbum: desktop instance unavailable\n", stderr);
      return 73;
    }
  }

  // Initialize COM, so that it is available for use in the library and/or
  // plugins.
  ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);

  flutter::DartProject project(L"data");

  // Keep the renderer on the stable Skia path. Do not force a GPU adapter or
  // move the UI isolate onto the platform thread: both options change plugin
  // callback threading/adapter selection and have caused more instability on
  // Windows 11 26200 machines. The explicit software safe mode below remains
  // available for machines with a broken graphics driver.
  project.set_impeller_switch(flutter::ImpellerSwitch::Disabled);

  if (HasArgument(command_line_arguments, "--safe-mode=software")) {
    _putenv_s("FLUTTER_ENGINE_SWITCHES", "1");
    _putenv_s("FLUTTER_ENGINE_SWITCH_1", "enable-software-rendering=true");
  }

  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  FlutterWindow window(project, smoke ? nullptr : &desktop_instance);
  Win32Window::Point origin(10, 10);
  Win32Window::Size size(1280, 720);
  if (!window.Create(L"NSOAlbum", origin, size)) {
    return EXIT_FAILURE;
  }
  if (!smoke && !desktop_instance.Attach(window.GetHandle())) {
    window.Destroy();
    ::CoUninitialize();
    return 73;
  }
  window.SetQuitOnClose(true);

  ::MSG msg;
  while (::GetMessage(&msg, nullptr, 0, 0)) {
    ::TranslateMessage(&msg);
    ::DispatchMessage(&msg);
  }

  ::CoUninitialize();
  return EXIT_SUCCESS;
}
