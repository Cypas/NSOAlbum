cmake_minimum_required(VERSION 3.20)
project(SystemFontPathFixture LANGUAGES CXX)

add_executable(system_font_path_fixture system_font_path_fixture.cpp)
target_include_directories(
  system_font_path_fixture
  PRIVATE "${NSOALBUM_RUNNER_DIR}")
target_compile_features(system_font_path_fixture PRIVATE cxx_std_20)
target_compile_options(system_font_path_fixture PRIVATE /W4 /WX /EHsc)
