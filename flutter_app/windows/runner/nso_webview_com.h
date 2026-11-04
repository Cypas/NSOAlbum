#pragma once

#include <windows.h>

namespace nsoalbum {

// WebView2 environments must be created on an STA thread. Initialize the
// callback thread explicitly and keep the matching CoUninitialize balanced.
class WebViewComApartment {
 public:
  HRESULT Ensure() {
    if (initialized_) {
      return S_OK;
    }
    const HRESULT result = ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);
    if (FAILED(result)) {
      return result;
    }
    initialized_ = true;

    APTTYPE apartment = APTTYPE_CURRENT;
    APTTYPEQUALIFIER qualifier = APTTYPEQUALIFIER_NONE;
    const HRESULT inspected = ::CoGetApartmentType(&apartment, &qualifier);
    if (FAILED(inspected)) {
      ::CoUninitialize();
      initialized_ = false;
      return inspected;
    }
    if (apartment != APTTYPE_STA && apartment != APTTYPE_MAINSTA) {
      ::CoUninitialize();
      initialized_ = false;
      return RPC_E_CHANGED_MODE;
    }
    return S_OK;
  }

  ~WebViewComApartment() {
    if (initialized_) {
      ::CoUninitialize();
    }
  }

 private:
  bool initialized_ = false;
};

inline HRESULT EnsureWebViewComApartment() {
  thread_local WebViewComApartment apartment;
  return apartment.Ensure();
}

}  // namespace nsoalbum
