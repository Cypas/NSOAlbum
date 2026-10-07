#ifndef RUNNER_FLUTTER_WINDOW_H_
#define RUNNER_FLUTTER_WINDOW_H_

#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>
#include <imm.h>

#include <memory>

#include "win32_window.h"

// A window that does nothing but host a Flutter view.
class FlutterWindow : public Win32Window {
 public:
  // Creates a new FlutterWindow hosting a Flutter view running |project|.
  explicit FlutterWindow(const flutter::DartProject& project);
  virtual ~FlutterWindow();

 protected:
  // Win32Window:
  bool OnCreate() override;
  void OnDestroy() override;
  LRESULT MessageHandler(HWND window, UINT const message, WPARAM const wparam,
                         LPARAM const lparam) noexcept override;

 private:
  static LRESULT CALLBACK ImeWindowSubclassProc(
      HWND window, UINT message, WPARAM wparam, LPARAM lparam,
      UINT_PTR subclass_id, DWORD_PTR reference_data);

  void InstallImeCompatibility(HWND window);
  void RemoveImeCompatibility();
  void SetTextClientActive(bool active);
  void AttachImeContext();
  void DetachImeContext();

  // The project to run.
  flutter::DartProject project_;

  // The Flutter instance hosted by this window.
  std::unique_ptr<flutter::FlutterViewController> flutter_controller_;
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>>
      ime_context_channel_;
  HWND flutter_view_ = nullptr;

  // Third-party TSF/IMM32 IMEs such as Sogou need an IME context whose lifetime
  // follows Flutter's active text client instead of arbitrary pointer events.
  HWND ime_window_ = nullptr;
  HIMC ime_context_ = nullptr;
  bool text_client_active_ = false;
  BOOL ime_open_status_ = FALSE;
  DWORD ime_conversion_mode_ = 0;
  DWORD ime_sentence_mode_ = 0;
};

#endif  // RUNNER_FLUTTER_WINDOW_H_
