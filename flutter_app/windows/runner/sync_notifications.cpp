#include "sync_notifications.h"
#include "native_single_instance.h"

#include <notificationactivationcallback.h>
#include <winrt/Windows.UI.Notifications.h>

#include <filesystem>
#include <mutex>

struct SyncNotificationActivationState {
  explicit SyncNotificationActivationState(HWND target) : window(target) {}
  std::mutex mutex;
  HWND window;
};

namespace {

constexpr wchar_t kNotificationIdentity[] = L"Cypas.NSOAlbum.SyncNotifications";
constexpr wchar_t kNotificationActivator[] =
    L"{D8101B18-1E37-4CE4-9FC8-D2D8BDF28325}";

struct NotificationActivator
    : winrt::implements<NotificationActivator, INotificationActivationCallback> {
  explicit NotificationActivator(
      std::shared_ptr<SyncNotificationActivationState> state)
      : state_(std::move(state)) {}

  HRESULT __stdcall Activate(
      LPCWSTR identity, LPCWSTR, NOTIFICATION_USER_INPUT_DATA const*,
      ULONG) noexcept {
    if (identity == nullptr || wcscmp(identity, kNotificationIdentity) != 0) {
      return E_INVALIDARG;
    }
    std::lock_guard<std::mutex> lock(state_->mutex);
    if (state_->window == nullptr) {
      return HRESULT_FROM_WIN32(ERROR_CANCELLED);
    }
    // This callback can run on any COM thread. Only the existing window thread
    // restores the current instance; no Dart channel or user payload is used.
    const auto message = NativeSingleInstance::ActivationMessage();
    if (message == 0) return E_FAIL;
    if (!PostMessageW(state_->window, message, 0, 0)) {
      return HRESULT_FROM_WIN32(GetLastError());
    }
    return S_OK;
  }
  std::shared_ptr<SyncNotificationActivationState> state_;
};

void WriteNotificationRegistryString(const std::wstring& path,
                                     const wchar_t* name,
                                     const std::wstring& value) {
  HKEY key = nullptr;
  auto status = RegCreateKeyExW(HKEY_CURRENT_USER, path.c_str(), 0, nullptr, 0,
                                KEY_SET_VALUE, nullptr, &key, nullptr);
  if (status != ERROR_SUCCESS) {
    winrt::throw_hresult(HRESULT_FROM_WIN32(status));
  }
  status = RegSetValueExW(
      key, name, 0, REG_SZ, reinterpret_cast<const BYTE*>(value.c_str()),
      static_cast<DWORD>((value.size() + 1) * sizeof(wchar_t)));
  RegCloseKey(key);
  if (status != ERROR_SUCCESS) {
    winrt::throw_hresult(HRESULT_FROM_WIN32(status));
  }
}

void RegisterNotificationMetadata() {
  std::wstring executable(32768, L'\0');
  const auto length = GetModuleFileNameW(
      nullptr, executable.data(), static_cast<DWORD>(executable.size()));
  if (length == 0 || length >= executable.size()) {
    winrt::throw_hresult(HRESULT_FROM_WIN32(ERROR_BAD_PATHNAME));
  }
  executable.resize(length);
  const auto icon =
      std::filesystem::path(executable).parent_path() / L"data" /
      L"flutter_assets" / L"assets" / L"tray" / L"app_icon.ico";
  const std::wstring identity_key =
      L"SOFTWARE\\Classes\\AppUserModelId\\" +
      std::wstring(kNotificationIdentity);
  WriteNotificationRegistryString(identity_key, L"DisplayName", L"NSOAlbum");
  WriteNotificationRegistryString(identity_key, L"IconUri", icon.native());
  WriteNotificationRegistryString(identity_key, L"CustomActivator",
                                   kNotificationActivator);
  WriteNotificationRegistryString(
      L"SOFTWARE\\Classes\\CLSID\\" + std::wstring(kNotificationActivator) +
          L"\\LocalServer32",
      nullptr, L"\"" + executable + L"\" --toast-activated");
}

struct NotificationActivatorFactory
    : winrt::implements<NotificationActivatorFactory, IClassFactory> {
  explicit NotificationActivatorFactory(
      std::shared_ptr<SyncNotificationActivationState> state)
      : state_(std::move(state)) {}
  HRESULT __stdcall CreateInstance(IUnknown* outer, REFIID iid,
                                    void** result) noexcept {
    if (result == nullptr) return E_POINTER;
    *result = nullptr;
    if (outer != nullptr) return CLASS_E_NOAGGREGATION;
    try {
      return winrt::make<NotificationActivator>(state_)->QueryInterface(iid, result);
    } catch (...) {
      return E_OUTOFMEMORY;
    }
  }
  HRESULT __stdcall LockServer(BOOL) noexcept { return S_OK; }
  std::shared_ptr<SyncNotificationActivationState> state_;
};

winrt::hstring NotificationText(const std::string& value) {
  if (value.empty() || value.size() > 4096) {
    throw winrt::hresult_invalid_argument();
  }
  const auto length = MultiByteToWideChar(
      CP_UTF8, MB_ERR_INVALID_CHARS, value.data(),
      static_cast<int>(value.size()), nullptr, 0);
  if (length == 0) throw winrt::hresult_invalid_argument();
  std::wstring decoded(static_cast<size_t>(length), L'\0');
  if (MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, value.data(),
                          static_cast<int>(value.size()), decoded.data(),
                          length) != length) {
    throw winrt::hresult_invalid_argument();
  }
  for (const auto character : decoded) {
    if ((character < 0x20 && character != L'\t' && character != L'\n' &&
         character != L'\r') ||
        character == 0xfffe || character == 0xffff) {
      throw winrt::hresult_invalid_argument();
    }
  }
  return winrt::hstring(decoded);
}

}  // namespace

SyncNotificationActivation::SyncNotificationActivation(HWND window)
    : state_(std::make_shared<SyncNotificationActivationState>(window)),
      factory_(winrt::make<NotificationActivatorFactory>(state_)) {}

SyncNotificationActivation::~SyncNotificationActivation() { Close(); }

winrt::com_ptr<IClassFactory> SyncNotificationActivation::Factory() const {
  return factory_;
}

void SyncNotificationActivation::Close() noexcept {
  std::lock_guard<std::mutex> lock(state_->mutex);
  state_->window = nullptr;
}

SyncNotificationRegistration::SyncNotificationRegistration(HWND window)
    : activation_(window) {
  CLSID clsid{};
  registration_status_ = CLSIDFromString(kNotificationActivator, &clsid);
  if (SUCCEEDED(registration_status_)) {
    registration_status_ = CoRegisterClassObject(
        clsid, activation_.Factory().get(), CLSCTX_LOCAL_SERVER,
        REGCLS_MULTIPLEUSE, &registration_cookie_);
  }
}

SyncNotificationRegistration::~SyncNotificationRegistration() {
  activation_.Close();
  if (registration_cookie_ != 0) CoRevokeClassObject(registration_cookie_);
}

HRESULT SyncNotificationRegistration::Show(const std::string& title,
                                           const std::string& body) noexcept {
  if (FAILED(registration_status_)) return registration_status_;
  try {
    if (!metadata_ready_) {
      // Startup only registers the in-process COM factory. Persistent metadata
      // is needed when sending an actual notification, not on every launch.
      RegisterNotificationMetadata();
      metadata_ready_ = true;
    }
    return ShowSyncCompletedNotification(title, body);
  } catch (const winrt::hresult_error& error) {
    return error.code();
  } catch (...) {
    return E_FAIL;
  }
}

winrt::Windows::Data::Xml::Dom::XmlDocument BuildSyncNotificationDocument(
    const std::string& title, const std::string& body) {
  using namespace winrt::Windows::Data::Xml::Dom;
  const auto title_text = NotificationText(title);
  const auto body_text = NotificationText(body);
  XmlDocument document;
  document.LoadXml(
      L"<toast><visual><binding template=\"ToastGeneric\">"
      L"<text/><text/></binding></visual></toast>");
  const auto text_nodes = document.GetElementsByTagName(L"text");
  text_nodes.Item(0).AppendChild(document.CreateTextNode(title_text));
  text_nodes.Item(1).AppendChild(document.CreateTextNode(body_text));
  return document;
}

HRESULT ShowSyncCompletedNotification(const std::string& title,
                                      const std::string& body) noexcept {
  try {
    using namespace winrt::Windows::UI::Notifications;
    ToastNotification notification(BuildSyncNotificationDocument(title, body));
    notification.Tag(L"auto-sync");
    notification.Group(L"nsoalbum");
    // No event handlers: native callbacks must never enter a Dart channel from
    // a WinRT worker thread. Activation only posts the native owner message.
    ToastNotificationManager::CreateToastNotifier(
        kNotificationIdentity).Show(notification);
    return S_OK;
  } catch (const winrt::hresult_error& error) {
    return error.code();
  } catch (...) {
    return E_FAIL;
  }
}
