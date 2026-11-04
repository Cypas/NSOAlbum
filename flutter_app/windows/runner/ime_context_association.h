#ifndef RUNNER_IME_CONTEXT_ASSOCIATION_H_
#define RUNNER_IME_CONTEXT_ASSOCIATION_H_

#include <imm.h>
#include <windows.h>

namespace nsoalbum {

struct WindowsImeContextApi {
  static HIMC Associate(HWND window, HIMC context) {
    return ::ImmAssociateContext(window, context);
  }

  static void Destroy(HIMC context) { ::ImmDestroyContext(context); }
};

// Owns a temporary HIMC associated with a Flutter text client and restores the
// HWND's previous context before destroying the temporary one. Api is
// injectable so this lifetime can be tested without an installed input method.
template <typename Api>
class ImeContextAssociation {
 public:
  ImeContextAssociation() = default;
  ImeContextAssociation(const ImeContextAssociation&) = delete;
  ImeContextAssociation& operator=(const ImeContextAssociation&) = delete;

  bool Associate(HWND window, HIMC owned_context) {
    if (window == nullptr || owned_context == nullptr || active_) {
      return false;
    }
    window_ = window;
    owned_context_ = owned_context;
    previous_context_ = Api::Associate(window_, owned_context_);
    active_ = true;
    return true;
  }

  void Restore(bool window_is_valid = true) {
    if (!active_) return;
    if (window_is_valid) {
      Api::Associate(window_, previous_context_);
    }
    Api::Destroy(owned_context_);
    window_ = nullptr;
    previous_context_ = nullptr;
    owned_context_ = nullptr;
    active_ = false;
  }

  bool active() const { return active_; }
  HIMC owned_context() const { return owned_context_; }

 private:
  HWND window_ = nullptr;
  HIMC previous_context_ = nullptr;
  HIMC owned_context_ = nullptr;
  bool active_ = false;
};

}  // namespace nsoalbum

#endif  // RUNNER_IME_CONTEXT_ASSOCIATION_H_
