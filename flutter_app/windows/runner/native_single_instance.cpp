#include "native_single_instance.h"

#include <shlobj.h>

#include <thread>
#include <utility>

namespace {
struct WindowSearch {
  const wchar_t* marker;
  HWND found = nullptr;
};
BOOL CALLBACK FindOwnerWindow(HWND window, LPARAM data) {
  auto* search = reinterpret_cast<WindowSearch*>(data);
  if (GetPropW(window, search->marker) == reinterpret_cast<HANDLE>(1)) {
    search->found = window;
    return FALSE;
  }
  return TRUE;
}
}  // namespace

NativeSingleInstance::NativeSingleInstance(std::filesystem::path directory)
    : directory_(std::move(directory)) {}

NativeSingleInstance::~NativeSingleInstance() {
  if (window_ && IsWindow(window_)) {
    DWORD process = 0;
    GetWindowThreadProcessId(window_, &process);
    if (process == GetCurrentProcessId()) RemovePropW(window_, marker_.c_str());
  }
  if (file_ != INVALID_HANDLE_VALUE) {
    if (locked_) UnlockFileEx(file_, 0, MAXDWORD, MAXDWORD, &overlap_);
    CloseHandle(file_);
  }
  // Never unlink the carrier: another process may already hold its handle.
}

std::filesystem::path NativeSingleInstance::UserDirectory() {
  PWSTR directory = nullptr;
  if (FAILED(SHGetKnownFolderPath(FOLDERID_LocalAppData, 0, nullptr, &directory))) {
    return {};
  }
  std::filesystem::path path(directory);
  CoTaskMemFree(directory);
  return path / L"NSOAlbum" / L"desktop-instance-native";
}

UINT NativeSingleInstance::ActivationMessage() {
  static const UINT message =
      RegisterWindowMessageW(L"io.github.cypas.nsoalbum.desktop.activate.v1");
  return message;
}

NativeSingleInstance::Outcome NativeSingleInstance::AcquireOrActivate(
    std::chrono::milliseconds timeout) {
  if (directory_.empty() || !directory_.is_absolute() ||
      file_ != INVALID_HANDLE_VALUE || ActivationMessage() == 0) {
    return Outcome::Unavailable;
  }
  std::error_code error;
  std::filesystem::create_directories(directory_, error);
  if (error) return Outcome::Unavailable;
  file_ = CreateFileW((directory_ / L"owner.lock").c_str(),
                     GENERIC_READ | GENERIC_WRITE,
                     FILE_SHARE_READ | FILE_SHARE_WRITE, nullptr, OPEN_ALWAYS,
                     FILE_ATTRIBUTE_NORMAL | FILE_FLAG_OPEN_REPARSE_POINT,
                     nullptr);
  if (file_ == INVALID_HANDLE_VALUE) return Outcome::Unavailable;
  BY_HANDLE_FILE_INFORMATION info{};
  if (!GetFileInformationByHandle(file_, &info) || info.nNumberOfLinks != 1 ||
      (info.dwFileAttributes &
       (FILE_ATTRIBUTE_DIRECTORY | FILE_ATTRIBUTE_REPARSE_POINT))) {
    return Outcome::Unavailable;
  }
  // The file identity scopes activation to this user's exact lock carrier,
  // including path aliases. No paths, arguments or account data cross IPC.
  marker_ = L"io.github.cypas.nsoalbum.instance." +
            std::to_wstring(info.dwVolumeSerialNumber) + L"." +
            std::to_wstring(info.nFileIndexHigh) + L"." +
            std::to_wstring(info.nFileIndexLow);
  const auto until = std::chrono::steady_clock::now() + timeout;
  do {
    if (LockFileEx(file_, LOCKFILE_EXCLUSIVE_LOCK | LOCKFILE_FAIL_IMMEDIATELY,
                   0, MAXDWORD, MAXDWORD, &overlap_)) {
      locked_ = true;
      return Outcome::Primary;
    }
    if (GetLastError() != ERROR_LOCK_VIOLATION) return Outcome::Unavailable;
    WindowSearch search{marker_.c_str()};
    EnumWindows(FindOwnerWindow, reinterpret_cast<LPARAM>(&search));
    if (search.found) {
      DWORD process = 0;
      GetWindowThreadProcessId(search.found, &process);
      if (process != 0) AllowSetForegroundWindow(process);
      DWORD_PTR response = 0;
      if (SendMessageTimeoutW(search.found, ActivationMessage(), 0, 0,
                              SMTO_ABORTIFHUNG | SMTO_BLOCK, 400, &response) &&
          response == 1) {
        return Outcome::Activated;
      }
    }
    std::this_thread::sleep_for(std::chrono::milliseconds(25));
  } while (std::chrono::steady_clock::now() < until);
  return Outcome::Unavailable;
}

bool NativeSingleInstance::Attach(HWND window) {
  DWORD process = 0;
  GetWindowThreadProcessId(window, &process);
  if (!locked_ || process != GetCurrentProcessId() ||
      !SetPropW(window, marker_.c_str(), reinterpret_cast<HANDLE>(1))) {
    return false;
  }
  window_ = window;
  return true;
}

bool NativeSingleInstance::HandleActivation(
    HWND window, UINT message, WPARAM wparam, LPARAM lparam,
    LRESULT* result) const {
  if (!locked_ || window != window_ || message != ActivationMessage() ||
      wparam != 0 || lparam != 0 ||
      GetPropW(window, marker_.c_str()) != reinterpret_cast<HANDLE>(1)) {
    return false;
  }
  ShowWindow(window, IsIconic(window) ? SW_RESTORE : SW_SHOW);
  SetForegroundWindow(window);
  *result = 1;
  return true;
}
