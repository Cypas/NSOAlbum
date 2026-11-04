// SDK-only characterization of composition resources surviving until DLL detach.
// No Flutter, WebView navigation, accounts or application storage are opened.
#include <windows.h>
#include <dispatcherqueue.h>
#include <roapi.h>
#include <windows.system.h>
#include <winrt/Windows.Foundation.h>
#include <winrt/Windows.System.h>
#include <winrt/Windows.UI.Composition.h>

#include <iostream>
#include <string>

#ifdef NSOALBUM_COMPOSITION_MODULE
namespace {
winrt::Windows::System::DispatcherQueueController queue{nullptr};
winrt::Windows::UI::Composition::Compositor compositor{nullptr};
bool initialized = false;
HMODULE core_messaging = nullptr;
}

extern "C" __declspec(dllexport) HRESULT __stdcall CreateResources() noexcept {
  try {
    winrt::check_hresult(RoInitialize(RO_INIT_SINGLETHREADED));
    initialized = true;
    const DispatcherQueueOptions options{
        sizeof(DispatcherQueueOptions), DQTYPE_THREAD_CURRENT, DQTAT_COM_STA};
    core_messaging = LoadLibraryW(L"CoreMessaging.dll");
    if (!core_messaging) return HRESULT_FROM_WIN32(GetLastError());
    using CreateQueue = HRESULT(WINAPI*)(
        DispatcherQueueOptions,
        ABI::Windows::System::IDispatcherQueueController**);
    const auto create_queue = reinterpret_cast<CreateQueue>(
        GetProcAddress(core_messaging, "CreateDispatcherQueueController"));
    if (!create_queue) return HRESULT_FROM_WIN32(GetLastError());
    winrt::check_hresult(create_queue(
        options,
        reinterpret_cast<ABI::Windows::System::IDispatcherQueueController**>(
            winrt::put_abi(queue))));
    constexpr wchar_t name[] = L"Windows.UI.Composition.Compositor";
    HSTRING_HEADER header{};
    HSTRING class_name = nullptr;
    winrt::check_hresult(WindowsCreateStringReference(
        name, ARRAYSIZE(name) - 1, &header, &class_name));
    winrt::com_ptr<IActivationFactory> factory;
    winrt::check_hresult(RoGetActivationFactory(
        class_name, __uuidof(IActivationFactory), factory.put_void()));
    winrt::check_hresult(factory->ActivateInstance(
        reinterpret_cast<IInspectable**>(winrt::put_abi(compositor))));
    return S_OK;
  } catch (...) {
    return winrt::to_hresult();
  }
}

extern "C" __declspec(dllexport) HRESULT __stdcall CloseResources(
    BOOL drain) noexcept {
  try {
    if (drain && compositor) {
      compositor.as<winrt::Windows::Foundation::IClosable>().Close();
    }
    compositor = nullptr;
    if (drain && queue) {
      const auto shutdown = queue.ShutdownQueueAsync();
      const auto deadline = GetTickCount64() + 10000;
      while (shutdown.Status() == winrt::Windows::Foundation::AsyncStatus::Started) {
        if (GetTickCount64() >= deadline) return HRESULT_FROM_WIN32(WAIT_TIMEOUT);
        MSG message{};
        while (PeekMessageW(&message, nullptr, 0, 0, PM_REMOVE)) {
          TranslateMessage(&message);
          DispatchMessageW(&message);
        }
        MsgWaitForMultipleObjectsEx(
            0, nullptr, 10, QS_ALLINPUT, MWMO_INPUTAVAILABLE);
      }
      shutdown.GetResults();
    }
    queue = nullptr;
    if (initialized) {
      RoUninitialize();
      initialized = false;
    }
    if (core_messaging) {
      FreeLibrary(core_messaging);
      core_messaging = nullptr;
    }
    return S_OK;
  } catch (...) {
    return winrt::to_hresult();
  }
}
#else
int wmain(int argc, wchar_t** argv) {
  SetErrorMode(SEM_FAILCRITICALERRORS | SEM_NOGPFAULTERRORBOX);
  if (argc != 3 && argc != 4) return 64;
  const std::wstring mode(argv[2]);
  if (mode != L"static-detach" && mode != L"release" && mode != L"close-drain") {
    return 64;
  }
  if (argc == 4) {
    if (std::wstring(argv[3]) != L"preload-provider") return 64;
    if (!LoadLibraryExW(
            L"CoreMessaging.dll", nullptr, LOAD_LIBRARY_SEARCH_SYSTEM32)) {
      return 69;
    }
  }
  const auto module = LoadLibraryW(argv[1]);
  if (!module) return 65;
  using Create = HRESULT(__stdcall*)();
  using Close = HRESULT(__stdcall*)(BOOL);
  const auto create = reinterpret_cast<Create>(
      GetProcAddress(module, "CreateResources"));
  const auto close = reinterpret_cast<Close>(
      GetProcAddress(module, "CloseResources"));
  if (!create || !close) return 66;
  const auto created = create();
  if (FAILED(created)) {
    std::cout << "COMPOSITION_PROBE initialization_failed=0x" << std::hex
              << static_cast<unsigned long>(created) << std::endl;
    return 67;
  }
  std::cout << "COMPOSITION_PROBE created=true" << std::endl;
  if (mode != L"static-detach") {
    const auto closed = close(mode == L"close-drain");
    if (FAILED(closed)) {
      std::cout << "COMPOSITION_PROBE close_failed=0x" << std::hex
                << static_cast<unsigned long>(closed) << std::endl;
      return 68;
    }
    std::cout << "COMPOSITION_PROBE released=true" << std::endl;
  }
  // Model a process exit initiated by the runtime, rather than unwinding an
  // executable's C++ stack. The DLL still runs its global COM destructors.
  ExitProcess(0);
}
#endif
