#include "flutter_window.h"

#include <commctrl.h>
#include <imm.h>
#include <optional>
#include <variant>

#include "flutter/generated_plugin_registrant.h"

FlutterWindow::FlutterWindow(const flutter::DartProject& project)
    : project_(project) {}

FlutterWindow::~FlutterWindow() {}

namespace {

constexpr UINT_PTR kImeWindowSubclassId = 1;

}  // namespace

bool FlutterWindow::OnCreate() {
  if (!Win32Window::OnCreate()) {
    return false;
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
