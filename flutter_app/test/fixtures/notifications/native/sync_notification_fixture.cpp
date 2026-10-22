#include "sync_notifications.h"
#include "native_single_instance.h"

#include <notificationactivationcallback.h>
#include <winrt/Windows.Foundation.Collections.h>
#include <winrt/Windows.UI.Notifications.h>
#include <chrono>
#include <filesystem>
#include <iostream>
#include <stdexcept>
#include <thread>
#include <vector>

using winrt::Windows::Data::Xml::Dom::XmlDocument;

namespace {
NativeSingleInstance* owner = nullptr;
DWORD owner_thread = 0;
bool wrong_thread = false;
int activations = 0;

LRESULT CALLBACK FixtureWindowProc(HWND window, UINT message, WPARAM wparam,
                                   LPARAM lparam) {
  LRESULT result = 0;
  if (owner && owner->HandleActivation(window, message, wparam, lparam, &result)) {
    wrong_thread = GetCurrentThreadId() != owner_thread;
    activations++;
    return result;
  }
  return DefWindowProcW(window, message, wparam, lparam);
}

HWND CreateFixtureWindow() {
  WNDCLASSW window_class{};
  window_class.lpfnWndProc = FixtureWindowProc;
  window_class.hInstance = GetModuleHandleW(nullptr);
  window_class.lpszClassName = L"NSOAlbum.Notification.Fixture";
  if (!RegisterClassW(&window_class)) {
    throw std::runtime_error("Could not register fixture window");
  }
  const auto window = CreateWindowExW(
      0, window_class.lpszClassName, L"Synthetic notification activation",
      WS_OVERLAPPEDWINDOW, 0, 0, 200, 100, nullptr, nullptr,
      window_class.hInstance, nullptr);
  if (!window) throw std::runtime_error("Could not create fixture window");
  return window;
}

winrt::com_ptr<INotificationActivationCallback> CreateCallback(
    const SyncNotificationActivation& activation) {
  winrt::com_ptr<INotificationActivationCallback> callback;
  winrt::check_hresult(activation.Factory()->CreateInstance(
      nullptr, __uuidof(INotificationActivationCallback), callback.put_void()));
  return callback;
}
}  // namespace

int wmain(int argc, wchar_t** argv) {
  try {
    winrt::init_apartment(winrt::apartment_type::single_threaded);
    if (argc < 2) return 2;
    const auto scenario = winrt::to_string(argv[1]);
    if (scenario == "content") {
      const std::string title = u8"NSOAlbum · A & <B>";
      const std::string body = u8"新增 2 · 已存在 5 · 失败 1 · 2 个账号";
      const auto document = BuildSyncNotificationDocument(title, body);
      const auto nodes = document.GetElementsByTagName(L"text");
      if (nodes.Length() != 2 ||
          nodes.Item(0).InnerText() != winrt::to_hstring(title) ||
          nodes.Item(1).InnerText() != winrt::to_hstring(body)) {
        throw std::runtime_error("Notification text was missing or changed");
      }
      XmlDocument round_trip;
      round_trip.LoadXml(document.GetXml());
      if (round_trip.GetElementsByTagName(L"B").Length() != 0 ||
          round_trip.GetElementsByTagName(L"text").Item(0).InnerText() !=
              winrt::to_hstring(title)) {
        throw std::runtime_error("Notification text became XML markup");
      }
    } else if (scenario == "invalid") {
      const std::vector<std::pair<std::string, std::string>> cases = {
          {"", "body"},
          {"title", ""},
          {std::string(4097, 'x'), "body"},
          {"title", std::string(4097, 'x')},
          {"title", std::string("a\0b", 3)},
          {std::string("\xc3", 1), "body"},
          {"title", std::string("a\x01" "b", 3)},
      };
      for (const auto& content : cases) {
        bool rejected = false;
        try {
          BuildSyncNotificationDocument(content.first, content.second);
        } catch (const winrt::hresult_error&) {
          rejected = true;
        }
        if (!rejected) {
          throw std::runtime_error("Invalid notification content was accepted");
        }
      }
    } else if (scenario == "activation" || scenario == "retired") {
      if (argc != 3) return 2;
      NativeSingleInstance instance{std::filesystem::path(argv[2])};
      if (instance.AcquireOrActivate() != NativeSingleInstance::Outcome::Primary) {
        throw std::runtime_error("Fixture could not own its synthetic scope");
      }
      const auto window = CreateFixtureWindow();
      if (!instance.Attach(window)) throw std::runtime_error("Fixture attach failed");
      owner = &instance;
      owner_thread = GetCurrentThreadId();
      if (scenario == "activation") {
        SyncNotificationActivation activation(window);
        auto callback = CreateCallback(activation);
        HRESULT worker_status = E_FAIL;
        std::thread worker([&] {
          worker_status = callback->Activate(
              L"Cypas.NSOAlbum.SyncNotifications", nullptr, nullptr, 0);
        });
        worker.join();
        if (FAILED(worker_status) || IsWindowVisible(window) || activations != 0) {
          throw std::runtime_error("Worker callback directly touched the window");
        }
        MSG message{};
        if (!PeekMessageW(&message, window,
                          NativeSingleInstance::ActivationMessage(),
                          NativeSingleInstance::ActivationMessage(), PM_REMOVE)) {
          throw std::runtime_error("Activation did not queue the owner message");
        }
        if (message.wParam != 0 || message.lParam != 0) {
          throw std::runtime_error("Activation included an unexpected payload");
        }
        DispatchMessageW(&message);
        if (wrong_thread || activations != 1 || !IsWindowVisible(window)) {
          throw std::runtime_error("Owner thread did not restore its window");
        }
        if (callback->Activate(L"other.application", L"ignored", nullptr, 0) !=
                E_INVALIDARG ||
            callback->Activate(nullptr, nullptr, nullptr, 0) != E_INVALIDARG) {
          throw std::runtime_error("Activation accepted an unrelated identity");
        }
        if (PeekMessageW(&message, window,
                         NativeSingleInstance::ActivationMessage(),
                         NativeSingleInstance::ActivationMessage(), PM_REMOVE)) {
          throw std::runtime_error("Unrelated identity still queued an activation");
        }
      } else {
        winrt::com_ptr<INotificationActivationCallback> late_callback;
        {
          SyncNotificationActivation activation(window);
          late_callback = CreateCallback(activation);
        }
        if (SUCCEEDED(late_callback->Activate(
                L"Cypas.NSOAlbum.SyncNotifications", nullptr, nullptr, 0))) {
          throw std::runtime_error("Retired activation accepted a late callback");
        }
        MSG message{};
        if (PeekMessageW(&message, window,
                         NativeSingleInstance::ActivationMessage(),
                         NativeSingleInstance::ActivationMessage(), PM_REMOVE) ||
            IsWindowVisible(window)) {
          throw std::runtime_error("Retired callback affected the window");
        }
      }
      owner = nullptr;
      DestroyWindow(window);
    } else if (scenario == "system-history" ||
               scenario == "system-remove-owned") {
      // Explicit live probe only. Never print any system notification content.
      if (argc != 4) return 2;
      using winrt::Windows::UI::Notifications::ToastNotificationManager;
      const winrt::hstring expected_title(argv[2]);
      const winrt::hstring expected_body(argv[3]);
      bool found = false;
      for (const auto& toast : ToastNotificationManager::History().GetHistory(
               L"Cypas.NSOAlbum.SyncNotifications")) {
        if (toast.Tag() != L"auto-sync" || toast.Group() != L"nsoalbum") continue;
        const auto nodes = toast.Content().GetElementsByTagName(L"text");
        if (nodes.Length() == 2 &&
            nodes.Item(0).InnerText() == expected_title &&
            nodes.Item(1).InnerText() == expected_body) {
          found = true;
          break;
        }
      }
      if (!found) return 3;
      if (scenario == "system-remove-owned") {
        ToastNotificationManager::History().Remove(
            L"auto-sync", L"nsoalbum", L"Cypas.NSOAlbum.SyncNotifications");
      }
    } else if (scenario == "system-activate") {
      if (argc != 3) return 2;
      const auto expected_pid = std::stoul(argv[2]);
      bool owned_window = false;
      struct Target {
        DWORD pid;
        bool* found;
      } target{static_cast<DWORD>(expected_pid), &owned_window};
      EnumWindows(
          [](HWND window, LPARAM data) -> BOOL {
            auto* value = reinterpret_cast<Target*>(data);
            DWORD pid = 0;
            GetWindowThreadProcessId(window, &pid);
            wchar_t title[64]{};
            GetWindowTextW(window, title, 64);
            if (pid == value->pid && wcscmp(title, L"NSOAlbum") == 0) {
              *value->found = true;
              return FALSE;
            }
            return TRUE;
          },
          reinterpret_cast<LPARAM>(&target));
      if (!owned_window) throw std::runtime_error("Owned probe window missing");
      CLSID clsid{};
      winrt::check_hresult(CLSIDFromString(
          L"{D8101B18-1E37-4CE4-9FC8-D2D8BDF28325}", &clsid));
      winrt::com_ptr<INotificationActivationCallback> callback;
      winrt::check_hresult(CoCreateInstance(
          clsid, nullptr, CLSCTX_LOCAL_SERVER,
          __uuidof(INotificationActivationCallback), callback.put_void()));
      winrt::check_hresult(callback->Activate(
          L"Cypas.NSOAlbum.SyncNotifications", nullptr, nullptr, 0));
    } else {
      return 2;
    }
    std::cout << "SYNC_NOTIFICATION_NATIVE_PASS " << scenario << std::endl;
    return 0;
  } catch (const winrt::hresult_error& error) {
    std::cerr << "Native notification HRESULT=0x" << std::hex
              << static_cast<unsigned long>(error.code().value) << std::endl;
    return 1;
  } catch (const std::exception& error) {
    std::cerr << error.what() << std::endl;
    return 1;
  } catch (...) {
    std::cerr << "Native notification content failed" << std::endl;
    return 1;
  }
}
