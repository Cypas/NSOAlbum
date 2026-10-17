#ifndef RUNNER_NATIVE_SINGLE_INSTANCE_H_
#define RUNNER_NATIVE_SINGLE_INSTANCE_H_

#include <windows.h>

#include <chrono>
#include <filesystem>
#include <string>

// Owns only process election and a payload-free window activation message.
// Construct before Flutter/COM; destroy after the application window/engine.
class NativeSingleInstance {
 public:
  enum class Outcome { Primary, Activated, Unavailable };
  explicit NativeSingleInstance(std::filesystem::path directory);
  ~NativeSingleInstance();
  NativeSingleInstance(const NativeSingleInstance&) = delete;
  NativeSingleInstance& operator=(const NativeSingleInstance&) = delete;

  static std::filesystem::path UserDirectory();
  static UINT ActivationMessage();
  Outcome AcquireOrActivate(std::chrono::milliseconds timeout =
                                std::chrono::seconds(5));
  bool Attach(HWND window);
  bool HandleActivation(HWND window, UINT message, WPARAM wparam,
                        LPARAM lparam, LRESULT* result) const;

 private:
  std::filesystem::path directory_;
  HANDLE file_ = INVALID_HANDLE_VALUE;
  OVERLAPPED overlap_{};
  bool locked_ = false;
  HWND window_ = nullptr;
  std::wstring marker_;
};

#endif  // RUNNER_NATIVE_SINGLE_INSTANCE_H_
