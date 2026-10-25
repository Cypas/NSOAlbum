#include "flutter_window.h"

#include <commctrl.h>
#include <imm.h>
#include <algorithm>
#include <array>
#include <cwctype>
#include <filesystem>
#include <map>
#include <optional>
#include <shlobj.h>
#include <variant>
#include <vector>
#include <shellapi.h>

#include "flutter/generated_plugin_registrant.h"
#include "system_font_path.h"
#include "sync_notifications.h"
#include "utils.h"

FlutterWindow::FlutterWindow(const flutter::DartProject& project,
                             NativeSingleInstance* instance)
    : project_(project), instance_(instance) {}

FlutterWindow::~FlutterWindow() {}

namespace {

constexpr UINT_PTR kImeWindowSubclassId = 1;

std::vector<flutter::EncodableValue> EnumerateSystemFonts() {
  std::map<std::wstring, std::wstring> entries;
  wchar_t windows_directory[MAX_PATH] = {};
  const UINT length = GetWindowsDirectoryW(
      windows_directory, static_cast<UINT>(std::size(windows_directory)));
  if (length == 0 || length >= std::size(windows_directory)) return {};
  const std::filesystem::path fonts_directory =
      std::filesystem::path(windows_directory) / L"Fonts";
  std::filesystem::path user_fonts_directory;
  PWSTR local_app_data = nullptr;
  if (SUCCEEDED(SHGetKnownFolderPath(
          FOLDERID_LocalAppData, KF_FLAG_DEFAULT, nullptr, &local_app_data))) {
    user_fonts_directory =
        std::filesystem::path(local_app_data) / L"Microsoft" / L"Windows" /
        L"Fonts";
    CoTaskMemFree(local_app_data);
  }

  const std::array<HKEY, 2> hives = {HKEY_LOCAL_MACHINE, HKEY_CURRENT_USER};
  for (const HKEY hive : hives) {
    HKEY key = nullptr;
    if (RegOpenKeyExW(
            hive, L"SOFTWARE\\Microsoft\\Windows NT\\CurrentVersion\\Fonts",
            0, KEY_READ, &key) != ERROR_SUCCESS) {
      continue;
    }
    for (DWORD index = 0;; ++index) {
      wchar_t name[512] = {};
      wchar_t value[1024] = {};
      DWORD name_length = std::size(name);
      DWORD value_length = sizeof(value);
      DWORD type = 0;
      const LSTATUS status = RegEnumValueW(
          key, index, name, &name_length, nullptr, &type,
          reinterpret_cast<LPBYTE>(value), &value_length);
      if (status == ERROR_NO_MORE_ITEMS) break;
      if (status != ERROR_SUCCESS ||
          (type != REG_SZ && type != REG_EXPAND_SZ)) {
        continue;
      }
      std::wstring file(value, value_length / sizeof(wchar_t));
      file.erase(std::find(file.begin(), file.end(), L'\0'), file.end());
      if (file.empty()) continue;
      if (type == REG_EXPAND_SZ) {
        wchar_t expanded[2048] = {};
        const DWORD expanded_length = ExpandEnvironmentStringsW(
            file.c_str(), expanded, std::size(expanded));
        if (expanded_length > 0 && expanded_length < std::size(expanded)) {
          file.assign(expanded, expanded_length - 1);
        }
      }
      const auto resolved = nsoalbum::ResolveSystemFontPath(
          file, hive == HKEY_CURRENT_USER, fonts_directory,
          user_fonts_directory);
      if (!resolved.has_value()) continue;
      const std::filesystem::path path = *resolved;
      auto extension = path.extension().wstring();
      std::transform(extension.begin(), extension.end(), extension.begin(),
                     towlower);
      if (extension != L".ttf" && extension != L".otf" &&
          extension != L".ttc" && extension != L".otc") {
        continue;
      }
      std::error_code error;
      if (!std::filesystem::is_regular_file(path, error)) continue;
      entries.emplace(path.wstring(), std::wstring(name, name_length));
    }
    RegCloseKey(key);
  }

  std::vector<flutter::EncodableValue> result;
  for (const auto& [path, name] : entries) {
    flutter::EncodableMap item;
    item[flutter::EncodableValue("name")] =
        flutter::EncodableValue(Utf8FromUtf16(name.c_str()));
    item[flutter::EncodableValue("path")] =
        flutter::EncodableValue(Utf8FromUtf16(path.c_str()));
    result.emplace_back(item);
  }
  return result;
}

}  // namespace

bool FlutterWindow::OnCreate() {
  if (!Win32Window::OnCreate()) {
    return false;
  }
  if (instance_ != nullptr) {
    sync_notifications_ =
        std::make_unique<SyncNotificationRegistration>(GetHandle());
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
  HWND flutter_view = flutter_controller_->view()->GetNativeWindow();
  flutter_view_ = flutter_view;
  ime_context_channel_ =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          flutter_controller_->engine()->messenger(),
          "io.squidalbum/ime_context",
          &flutter::StandardMethodCodec::GetInstance());
  ime_context_channel_->SetMethodCallHandler(
      [this](const flutter::MethodCall<flutter::EncodableValue>& call,
             std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>
                 result) {
        if (call.method_name() != "setTextClientActive") {
          result->NotImplemented();
          return;
        }
        const auto* active =
            call.arguments() == nullptr
                ? nullptr
                : std::get_if<bool>(call.arguments());
        if (active == nullptr) {
          result->Error("invalid_argument", "Expected a boolean state");
          return;
        }
        SetTextClientActive(*active);
        result->Success();
      });
  sync_notification_channel_ =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          flutter_controller_->engine()->messenger(),
          "io.github.cypas.nsoalbum/notifications",
          &flutter::StandardMethodCodec::GetInstance());
  sync_notification_channel_->SetMethodCallHandler(
      [this](const flutter::MethodCall<flutter::EncodableValue>& call,
         std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
        if (call.method_name() != "syncCompleted") {
          result->NotImplemented();
          return;
        }
        const auto* arguments =
            call.arguments() == nullptr
                ? nullptr
                : std::get_if<flutter::EncodableMap>(call.arguments());
        const auto text = [arguments](const char* key) -> const std::string* {
          if (arguments == nullptr) return nullptr;
          const auto item = arguments->find(flutter::EncodableValue(key));
          return item == arguments->end()
                     ? nullptr
                     : std::get_if<std::string>(&item->second);
        };
        const auto* title = text("title");
        const auto* body = text("body");
        if (title == nullptr || body == nullptr) {
          result->Error("invalid_argument", "Expected notification summary");
          return;
        }
        const HRESULT status = sync_notifications_ == nullptr
                                   ? E_UNEXPECTED
                                   : sync_notifications_->Show(*title, *body);
        if (FAILED(status)) {
          result->Error("notification_failed",
                        "The notification could not be shown");
          return;
        }
        result->Success();
      });
  system_font_channel_ =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          flutter_controller_->engine()->messenger(),
          "io.github.cypas.nsoalbum/system_fonts",
          &flutter::StandardMethodCodec::GetInstance());
  system_font_channel_->SetMethodCallHandler(
      [](const flutter::MethodCall<flutter::EncodableValue>& call,
         std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>
             result) {
        if (call.method_name() != "list") {
          result->NotImplemented();
          return;
        }
        const auto fonts = EnumerateSystemFonts();
        flutter::EncodableList values;
        values.reserve(fonts.size());
        for (const auto& value : fonts) values.emplace_back(value);
        result->Success(values);
      });
  desktop_media_clipboard_channel_ =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          flutter_controller_->engine()->messenger(),
          "io.github.cypas.nsoalbum/desktop_media_clipboard",
          &flutter::StandardMethodCodec::GetInstance());
  desktop_media_clipboard_channel_->SetMethodCallHandler(
      [](const flutter::MethodCall<flutter::EncodableValue>& call,
         std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
        if (call.method_name() != "copyFile") {
          result->NotImplemented();
          return;
        }
        const auto* arguments =
            call.arguments() == nullptr
                ? nullptr
                : std::get_if<flutter::EncodableMap>(call.arguments());
        if (arguments == nullptr) {
          result->Error("invalid_argument", "Expected a file path");
          return;
        }
        const auto item = arguments->find(flutter::EncodableValue("path"));
        const auto* path = item == arguments->end()
                               ? nullptr
                               : std::get_if<std::string>(&item->second);
        if (path == nullptr || path->empty()) {
          result->Error("invalid_argument", "Expected a file path");
          return;
        }
        const int wide_length = MultiByteToWideChar(
            CP_UTF8, 0, path->c_str(), static_cast<int>(path->size()), nullptr, 0);
        if (wide_length <= 0) {
          result->Error("invalid_argument", "The file path is not valid UTF-8");
          return;
        }
        std::wstring wide_path(wide_length, L'\0');
        MultiByteToWideChar(CP_UTF8, 0, path->c_str(),
                            static_cast<int>(path->size()), wide_path.data(),
                            wide_length);
        const SIZE_T bytes =
            sizeof(DROPFILES) + (wide_path.size() + 2) * sizeof(wchar_t);
        HGLOBAL memory = GlobalAlloc(GHND | GMEM_SHARE, bytes);
        if (memory == nullptr) {
          result->Error("clipboard_failed", "Unable to allocate clipboard data");
          return;
        }
        auto* drop = static_cast<DROPFILES*>(GlobalLock(memory));
        drop->pFiles = sizeof(DROPFILES);
        drop->fWide = TRUE;
        auto* target = reinterpret_cast<wchar_t*>(
            reinterpret_cast<BYTE*>(drop) + sizeof(DROPFILES));
        std::copy(wide_path.begin(), wide_path.end(), target);
        target[wide_path.size()] = L'\0';
        target[wide_path.size() + 1] = L'\0';
        GlobalUnlock(memory);
        if (!OpenClipboard(nullptr)) {
          GlobalFree(memory);
          result->Error("clipboard_failed", "Unable to open the clipboard");
          return;
        }
        EmptyClipboard();
        if (SetClipboardData(CF_HDROP, memory) == nullptr) {
          GlobalFree(memory);
          CloseClipboard();
          result->Error("clipboard_failed", "Unable to set clipboard data");
          return;
        }
        CloseClipboard();
        result->Success();
      });
  SetChildContent(flutter_view);

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
  sync_notifications_.reset();
  sync_notification_channel_.reset();
  system_font_channel_.reset();
  desktop_media_clipboard_channel_.reset();
  ime_context_channel_.reset();
  RemoveImeCompatibility();
  flutter_view_ = nullptr;
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  if (message == SyncNotificationGalleryMessage()) {
    if (sync_notification_channel_) {
      sync_notification_channel_->InvokeMethod("openGallery", nullptr);
    }
    return 0;
  }
  LRESULT activation = 0;
  if (instance_ &&
      instance_->HandleActivation(hwnd, message, wparam, lparam, &activation)) {
    return activation;
  }
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

LRESULT CALLBACK FlutterWindow::ImeWindowSubclassProc(
    HWND window, UINT message, WPARAM wparam, LPARAM lparam,
    UINT_PTR subclass_id, DWORD_PTR reference_data) {
  auto* self = reinterpret_cast<FlutterWindow*>(reference_data);
  if (self == nullptr || subclass_id != kImeWindowSubclassId) {
    return ::DefSubclassProc(window, message, wparam, lparam);
  }

  if (message == WM_KILLFOCUS) {
    self->DetachImeContext();
  }

  const LRESULT result = ::DefSubclassProc(window, message, wparam, lparam);

  if (message == WM_SETFOCUS) {
    self->AttachImeContext();
  } else if (message == WM_INPUTLANGCHANGE) {
    self->DetachImeContext();
    self->AttachImeContext();
  } else if (message == WM_NCDESTROY) {
    self->DetachImeContext();
    ::RemoveWindowSubclass(window, ImeWindowSubclassProc, subclass_id);
    self->ime_window_ = nullptr;
  }
  return result;
}

void FlutterWindow::InstallImeCompatibility(HWND window) {
  if (window == nullptr || ime_window_ == window) {
    return;
  }
  RemoveImeCompatibility();
  if (::SetWindowSubclass(window, ImeWindowSubclassProc,
                          kImeWindowSubclassId,
                          reinterpret_cast<DWORD_PTR>(this)) != FALSE) {
    ime_window_ = window;
    AttachImeContext();
  }
}

void FlutterWindow::RemoveImeCompatibility() {
  if (ime_window_ == nullptr) {
    return;
  }
  DetachImeContext();
  if (::IsWindow(ime_window_) != FALSE) {
    ::RemoveWindowSubclass(ime_window_, ImeWindowSubclassProc,
                           kImeWindowSubclassId);
  }
  ime_window_ = nullptr;
}

void FlutterWindow::SetTextClientActive(bool active) {
  if (text_client_active_ == active) {
    return;
  }
  text_client_active_ = active;
  if (active) {
    InstallImeCompatibility(flutter_view_);
  } else {
    RemoveImeCompatibility();
  }
}

void FlutterWindow::AttachImeContext() {
  if (!text_client_active_ || ime_context_ != nullptr ||
      ime_window_ == nullptr || ::IsWindow(ime_window_) == FALSE ||
      ::GetFocus() != ime_window_) {
    return;
  }

  HIMC current = ::ImmGetContext(ime_window_);
  if (current != nullptr) {
    ime_open_status_ = ::ImmGetOpenStatus(current);
    ::ImmGetConversionStatus(current, &ime_conversion_mode_,
                             &ime_sentence_mode_);
    ::ImmReleaseContext(ime_window_, current);
  }

  HIMC created = ::ImmCreateContext();
  if (created == nullptr) {
    return;
  }
  ::ImmSetOpenStatus(created, ime_open_status_);
  ::ImmSetConversionStatus(created, ime_conversion_mode_,
                           ime_sentence_mode_);
  ::ImmAssociateContext(ime_window_, created);
  ime_context_ = created;
}

void FlutterWindow::DetachImeContext() {
  if (ime_context_ == nullptr) {
    return;
  }
  HIMC owned = ime_context_;
  ime_context_ = nullptr;
  ime_open_status_ = ::ImmGetOpenStatus(owned);
  ::ImmGetConversionStatus(owned, &ime_conversion_mode_,
                           &ime_sentence_mode_);
  if (ime_window_ != nullptr && ::IsWindow(ime_window_) != FALSE) {
    ::ImmAssociateContext(ime_window_, nullptr);
  }
  ::ImmDestroyContext(owned);
}
