#include <filesystem>
#include <fstream>
#include <iostream>
#include <string>

#include "system_font_path.h"

namespace fs = std::filesystem;

bool WriteFixture(const fs::path& path) {
  std::error_code error;
  fs::create_directories(path.parent_path(), error);
  if (error) return false;
  std::ofstream output(path, std::ios::binary);
  output << "font";
  return output.good();
}

bool Check(bool condition, const char* name) {
  if (!condition) std::cerr << "SYSTEM_FONT_PATH_FAIL " << name << "\n";
  return condition;
}

int main(int argc, char** argv) {
  if (argc != 2) return 2;
  const fs::path root(argv[1]);
  const fs::path system_fonts = root / "system";
  const fs::path user_fonts = root / "user";
  const fs::path user_file = user_fonts / "user-font.ttf";
  const fs::path fallback_file = system_fonts / "fallback-font.otf";
  const fs::path machine_file = system_fonts / "machine-font.ttc";
  const fs::path absolute_file = root / "absolute-font.ttf";
  if (!WriteFixture(user_file) ||
      !WriteFixture(system_fonts / "user-font.ttf") ||
      !WriteFixture(user_fonts / "machine-font.ttc") ||
      !WriteFixture(fallback_file) ||
      !WriteFixture(machine_file) || !WriteFixture(absolute_file)) {
    std::cerr << "Could not create synthetic font-path fixtures.\n";
    return 2;
  }

  bool passed = true;
  const auto user = nsoalbum::ResolveSystemFontPath(
      L"user-font.ttf", true, system_fonts, user_fonts);
  passed &= Check(user && *user == user_file, "user-relative");

  const auto fallback = nsoalbum::ResolveSystemFontPath(
      L"fallback-font.otf", true, system_fonts, user_fonts);
  passed &= Check(fallback && *fallback == fallback_file, "system-fallback");

  const auto machine = nsoalbum::ResolveSystemFontPath(
      L"machine-font.ttc", false, system_fonts, user_fonts);
  passed &= Check(machine && *machine == machine_file, "machine-scope");

  const auto absolute = nsoalbum::ResolveSystemFontPath(
      absolute_file.wstring(), true, system_fonts, user_fonts);
  passed &= Check(absolute && *absolute == absolute_file, "absolute");

  const auto missing = nsoalbum::ResolveSystemFontPath(
      L"missing-font.otc", true, system_fonts, user_fonts);
  passed &= Check(!missing, "missing");

  if (!passed) return 1;
  std::cout << "SYSTEM_FONT_PATH_PASS all\n";
  return 0;
}
