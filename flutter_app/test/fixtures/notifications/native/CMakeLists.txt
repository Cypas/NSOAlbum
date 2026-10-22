cmake_minimum_required(VERSION 3.20)
project(SyncNotificationFixture LANGUAGES CXX)
add_executable(sync_notification_fixture
  sync_notification_fixture.cpp
  "${NSOALBUM_RUNNER_DIR}/sync_notifications.cpp"
  "${NSOALBUM_RUNNER_DIR}/native_single_instance.cpp")
target_include_directories(sync_notification_fixture PRIVATE "${NSOALBUM_RUNNER_DIR}")
target_compile_features(sync_notification_fixture PRIVATE cxx_std_17)
target_compile_definitions(sync_notification_fixture PRIVATE UNICODE _UNICODE NOMINMAX)
target_compile_options(sync_notification_fixture PRIVATE /utf-8 /W4 /WX /EHsc)
target_link_libraries(sync_notification_fixture PRIVATE windowsapp user32 shell32 ole32 advapi32)
