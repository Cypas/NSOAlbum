#include <windows.h>

#include <chrono>
#include <iostream>
#include <string>
#include <thread>

#include "native_single_instance.h"

NativeSingleInstance* owner = nullptr;
LRESULT CALLBACK FixtureWindow(HWND window, UINT message, WPARAM w, LPARAM l) {
  LRESULT response = 0;
  if (owner && owner->HandleActivation(window, message, w, l, &response)) {
    std::cout << "activated" << std::endl;
    std::cout << (IsWindowVisible(window) && !IsIconic(window)
                      ? "restored" : "not-restored") << std::endl;
    return response;
  }
  if (message == WM_CLOSE) {
    DestroyWindow(window);
    return 0;
  }
  if (message == WM_DESTROY) {
    PostQuitMessage(0);
    return 0;
  }
  return DefWindowProcW(window, message, w, l);
}

int wmain(int count, wchar_t** arguments) {
  if (count != 3) return 64;
  NativeSingleInstance instance(arguments[1]);
  auto result = instance.AcquireOrActivate();
  if (result == NativeSingleInstance::Outcome::Activated) {
    std::cout << "secondary" << std::endl;
    return 0;
  }
  if (result != NativeSingleInstance::Outcome::Primary) return 73;
  const std::wstring mode(arguments[2]);
  std::cout << "primary" << std::endl;
  if (mode == L"holder") {
    std::string command;
    std::getline(std::cin, command);
    return 0;
  }
  if (mode == L"delayed") {
    std::this_thread::sleep_for(std::chrono::milliseconds(250));
  }
  owner = &instance;
  WNDCLASSW type{};
  type.lpfnWndProc = FixtureWindow;
  type.hInstance = GetModuleHandleW(nullptr);
  type.lpszClassName = L"NSOAlbumSyntheticInstanceFixture";
  if (!RegisterClassW(&type)) return 74;
  auto window = CreateWindowW(type.lpszClassName, L"Synthetic instance fixture",
                             WS_OVERLAPPEDWINDOW, 0, 0, 320, 240,
                             nullptr, nullptr, type.hInstance, nullptr);
  if (!window || !instance.Attach(window)) return 74;
  if (mode == L"minimized") ShowWindow(window, SW_MINIMIZE);
  std::cout << "business-started" << std::endl;
  std::thread input([window]() {
    std::string command;
    std::getline(std::cin, command);
    PostMessageW(window, WM_CLOSE, 0, 0);
  });
  MSG message{};
  while (GetMessageW(&message, nullptr, 0, 0) > 0) {
    TranslateMessage(&message);
    DispatchMessageW(&message);
  }
  input.join();
  owner = nullptr;
  return 0;
}
