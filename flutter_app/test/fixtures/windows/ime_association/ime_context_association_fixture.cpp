#include <windows.h>

#include <iostream>
#include <vector>

#include "ime_context_association.h"

namespace {

HIMC current_context = reinterpret_cast<HIMC>(static_cast<uintptr_t>(1));
std::vector<HIMC> association_history;
std::vector<HIMC> destroyed_contexts;
std::vector<HIMC> context_when_destroyed;

struct FakeImeContextApi {
  static HIMC Associate(HWND, HIMC next) {
    const HIMC previous = current_context;
    current_context = next;
    association_history.push_back(next);
    return previous;
  }

  static void Destroy(HIMC context) {
    destroyed_contexts.push_back(context);
    context_when_destroyed.push_back(current_context);
  }
};

bool RunAssociationRestoreScenario() {
  constexpr uintptr_t window_value = 1;
  const auto original = current_context;
  const auto owned = reinterpret_cast<HIMC>(static_cast<uintptr_t>(2));
  nsoalbum::ImeContextAssociation<FakeImeContextApi> association;
  if (!association.Associate(reinterpret_cast<HWND>(window_value), owned)) {
    return false;
  }
  if (current_context != owned) return false;

  association.Restore();
  if (current_context != original || association.active()) return false;
  if (destroyed_contexts.size() != 1 || destroyed_contexts.front() != owned) {
    return false;
  }
  if (context_when_destroyed.size() != 1 ||
      context_when_destroyed.front() != original) {
    return false;
  }
  if (association_history.size() != 2 ||
      association_history[0] != owned ||
      association_history[1] != original) {
    return false;
  }

  // Explicit restoration must be idempotent.
  association.Restore();
  return destroyed_contexts.size() == 1;
}

}  // namespace

int wmain() {
  if (!RunAssociationRestoreScenario()) {
    std::cerr << "IME_ASSOCIATION_FAIL restore" << std::endl;
    return 1;
  }
  std::cout << "IME_ASSOCIATION_PASS restore" << std::endl;
  return 0;
}
