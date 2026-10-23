#include "nso_webview_com.h"

#include <atomic>
#include <cassert>
#include <thread>

int main() {
  std::atomic<HRESULT> fresh_thread_result = E_FAIL;
  std::thread fresh_thread([&]() {
    const HRESULT initialized = nsoalbum::EnsureWebViewComApartment();
    APTTYPE apartment = APTTYPE_CURRENT;
    APTTYPEQUALIFIER qualifier = APTTYPEQUALIFIER_NONE;
    const HRESULT inspected = ::CoGetApartmentType(&apartment, &qualifier);
    fresh_thread_result =
        SUCCEEDED(initialized) && SUCCEEDED(inspected) &&
                (apartment == APTTYPE_STA || apartment == APTTYPE_MAINSTA)
            ? S_OK
            : initialized;
  });
  fresh_thread.join();
  assert(fresh_thread_result.load() == S_OK);

  std::atomic<HRESULT> changed_mode_result = S_OK;
  std::thread mta_thread([&]() {
    const HRESULT initialized =
        ::CoInitializeEx(nullptr, COINIT_MULTITHREADED);
    assert(SUCCEEDED(initialized));
    changed_mode_result = nsoalbum::EnsureWebViewComApartment();
    ::CoUninitialize();
  });
  mta_thread.join();
  assert(changed_mode_result.load() == RPC_E_CHANGED_MODE);
  return 0;
}
