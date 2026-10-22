#ifndef RUNNER_SYNC_NOTIFICATIONS_H_
#define RUNNER_SYNC_NOTIFICATIONS_H_

#include <windows.h>
#include <winrt/Windows.Data.Xml.Dom.h>

#include <memory>
#include <string>

struct SyncNotificationActivationState;

// The COM factory can outlive this owner; Close makes all retained callbacks
// inert before the Flutter window or engine is destroyed.
class SyncNotificationActivation {
 public:
  explicit SyncNotificationActivation(HWND window);
  ~SyncNotificationActivation();
  SyncNotificationActivation(const SyncNotificationActivation&) = delete;
  SyncNotificationActivation& operator=(const SyncNotificationActivation&) = delete;
  winrt::com_ptr<IClassFactory> Factory() const;
  void Close() noexcept;

 private:
  std::shared_ptr<SyncNotificationActivationState> state_;
  winrt::com_ptr<IClassFactory> factory_;
};

class SyncNotificationRegistration {
 public:
  explicit SyncNotificationRegistration(HWND window);
  ~SyncNotificationRegistration();
  SyncNotificationRegistration(const SyncNotificationRegistration&) = delete;
  SyncNotificationRegistration& operator=(const SyncNotificationRegistration&) = delete;
  HRESULT Show(const std::string& title, const std::string& body) noexcept;

 private:
  SyncNotificationActivation activation_;
  HRESULT registration_status_ = E_FAIL;
  DWORD registration_cookie_ = 0;
  bool metadata_ready_ = false;
};

winrt::Windows::Data::Xml::Dom::XmlDocument BuildSyncNotificationDocument(
    const std::string& title, const std::string& body);

HRESULT ShowSyncCompletedNotification(const std::string& title,
                                      const std::string& body) noexcept;

#endif  // RUNNER_SYNC_NOTIFICATIONS_H_
