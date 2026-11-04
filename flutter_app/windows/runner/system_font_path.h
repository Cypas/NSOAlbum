#pragma once

#include <filesystem>
#include <optional>
#include <string>

namespace nsoalbum {

inline std::optional<std::filesystem::path> ResolveSystemFontPath(
    const std::wstring& registry_value, bool current_user,
    const std::filesystem::path& system_fonts,
    const std::filesystem::path& user_fonts) {
  const std::filesystem::path registered_path(registry_value);
  const auto is_regular_file = [](const std::filesystem::path& path) {
    std::error_code error;
    return std::filesystem::is_regular_file(path, error);
  };

  if (registered_path.is_absolute()) {
    return is_regular_file(registered_path)
        ? std::optional<std::filesystem::path>(registered_path)
        : std::nullopt;
  }
  if (current_user && !user_fonts.empty()) {
    const std::filesystem::path user_path = user_fonts / registered_path;
    if (is_regular_file(user_path)) return user_path;
  }
  const std::filesystem::path system_path = system_fonts / registered_path;
  if (is_regular_file(system_path)) return system_path;
  return std::nullopt;
}

}  // namespace nsoalbum
