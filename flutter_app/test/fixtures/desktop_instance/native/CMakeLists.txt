cmake_minimum_required(VERSION 3.20)
project(NativeInstanceFixture LANGUAGES CXX)
add_executable(instance_fixture
  instance_fixture.cpp
  "${NSOALBUM_RUNNER_DIR}/native_single_instance.cpp")
target_include_directories(instance_fixture PRIVATE "${NSOALBUM_RUNNER_DIR}")
target_compile_features(instance_fixture PRIVATE cxx_std_17)
target_compile_definitions(instance_fixture PRIVATE UNICODE _UNICODE NOMINMAX)
target_link_libraries(instance_fixture PRIVATE user32 shell32 ole32)
