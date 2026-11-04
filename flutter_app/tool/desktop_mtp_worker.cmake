# Included after generated_plugins.cmake; Cargokit's FFI library target exists
# by then. Keep its cache and environment private to Cargokit.
function(nsoalbum_mtp_flutter_sdk_path output)
  include("${CMAKE_SOURCE_DIR}/flutter/ephemeral/generated_config.cmake")
  set(${output} "${FLUTTER_ROOT}" PARENT_SCOPE)
endfunction()
nsoalbum_mtp_flutter_sdk_path(MTP_FLUTTER_ROOT)
# Share an explicit output directory instead of TARGET_FILE_DIR: Runner's
# CMake 3.14 policy scope would make that expression depend on the Runner and
# create a cycle with the Runner -> helper build dependency.
get_target_property(MTP_RUNNER_BINARY_DIR ${BINARY_NAME} BINARY_DIR)
set(MTP_RUNNER_OUTPUT_DIR "${MTP_RUNNER_BINARY_DIR}/$<CONFIG>")
set_target_properties(${BINARY_NAME} PROPERTIES
  RUNTIME_OUTPUT_DIRECTORY "${MTP_RUNNER_OUTPUT_DIR}")
set(MTP_WORKER_REPORT_DIR "${CMAKE_CURRENT_BINARY_DIR}/mtp-worker/$<CONFIG>")
add_custom_target(nsoalbum_mtp_worker ALL
  COMMAND "${MTP_FLUTTER_ROOT}/bin/cache/dart-sdk/bin/dart.exe"
    "${CMAKE_CURRENT_LIST_DIR}/build_desktop_native.dart"
    --target x86_64-pc-windows-msvc
    --configuration "$<CONFIG>"
    --output "${MTP_RUNNER_OUTPUT_DIR}/nsoalbum_mtp_worker.exe"
    --report "${MTP_WORKER_REPORT_DIR}/build.json"
    --cargo-log "${MTP_WORKER_REPORT_DIR}/cargo.jsonl"
  VERBATIM)
add_dependencies(nsoalbum_mtp_worker squid_album_core_cargokit)
add_dependencies(${BINARY_NAME} nsoalbum_mtp_worker)
