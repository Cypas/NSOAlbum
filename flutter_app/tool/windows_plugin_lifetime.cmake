# Derived sources stay in the build tree. Never rewrite the shared pub cache.
# Exact source fragments deliberately fail closed when an upstream owner changes.
function(nso_stage_lifetime_source target relative before after)
  get_target_property(plugin_root ${target} SOURCE_DIR)
  set(upstream "${plugin_root}/${relative}")
  file(READ "${upstream}" original)
  string(REPLACE "\r\n" "\n" original "${original}")
  string(FIND "${original}" "${before}" upstream_match)
  if(upstream_match EQUAL -1)
    message(FATAL_ERROR
      "The ${target} lifetime compatibility patch needs upstream-source review.")
  endif()

  string(REPLACE "/" "_" staged_key "${relative}")
  set(staged_property "NSO_STAGED_${target}_${staged_key}")
  get_property(current_set GLOBAL PROPERTY "${staged_property}" SET)
  if(current_set)
    get_property(current GLOBAL PROPERTY "${staged_property}")
  else()
    set(current "${original}")
  endif()
  string(FIND "${current}" "${before}" match)
  if(match EQUAL -1)
    message(FATAL_ERROR
      "The ${target} lifetime compatibility patch needs upstream-source review.")
  endif()
  string(REPLACE "${before}" "${after}" patched "${current}")
  set_property(GLOBAL PROPERTY "${staged_property}" "${patched}")
  set(generated "${CMAKE_BINARY_DIR}/nsoalbum-plugin-lifetime/${target}/${relative}")
  get_filename_component(generated_parent "${generated}" DIRECTORY)
  file(MAKE_DIRECTORY "${generated_parent}")
  if(NOT current STREQUAL patched)
    file(WRITE "${generated}" "${patched}")
  endif()
  get_target_property(sources ${target} SOURCES)
  set(replaced FALSE)
  set(updated_sources "")
  foreach(source IN LISTS sources)
    if(source STREQUAL relative OR source STREQUAL "${plugin_root}/${relative}" OR source STREQUAL "${generated}")
      list(APPEND updated_sources "${generated}")
      set(replaced TRUE)
    else()
      list(APPEND updated_sources "${source}")
    endif()
  endforeach()
  if(NOT replaced)
    message(FATAL_ERROR "The ${target} source list changed; review its lifetime patch.")
  endif()
  set_property(TARGET ${target} PROPERTY SOURCES "${updated_sources}")
  get_filename_component(original_parent "${plugin_root}/${relative}" DIRECTORY)
  target_include_directories(${target} PRIVATE "${plugin_root}" "${original_parent}")
endfunction()

if(TARGET flutter_inappwebview_windows_plugin)
  set(before "#include \"webview_environment.h\"")
  set(after "#include \"webview_environment.h\"\n#include \"runner/nso_webview_com.h\"")
  nso_stage_lifetime_source(flutter_inappwebview_windows_plugin
    "webview_environment/webview_environment.cpp" "${before}" "${after}")
  target_include_directories(flutter_inappwebview_windows_plugin PRIVATE
    "${CMAKE_SOURCE_DIR}")

  set(before "    if (!plugin) {")
  set(after "    // WebView2 requires an STA apartment. Preserve the actual COM error\n    // (notably RPC_E_CHANGED_MODE) so a wrong Flutter callback thread is diagnosable.\n    const auto comResult = nsoalbum::EnsureWebViewComApartment();\n    if (FAILED(comResult)) {\n      if (completionHandler) completionHandler(comResult);\n      return;\n    }\n    if (!plugin) {")
  nso_stage_lifetime_source(flutter_inappwebview_windows_plugin
    "webview_environment/webview_environment.cpp" "${before}" "${after}")

  set(before [=[
    windowWebViews.clear();
    UnregisterClass(windowClass_.lpszClassName, nullptr);
]=])
  set(after [=[
    windowWebViews.clear();
    // Release thread-affine resources while their owner apartment still exists,
    // not from static COM destructors during process/DLL teardown.
    compositor_ = nullptr;
    graphics_context_.reset();
    dispatcher_queue_controller_ = nullptr;
    rohelper_.reset();
    valid_ = false;
    UnregisterClass(windowClass_.lpszClassName, nullptr);
]=])
  nso_stage_lifetime_source(flutter_inappwebview_windows_plugin
    "in_app_webview/in_app_webview_manager.cpp" "${before}" "${after}")

  set(before [=[
    webViewEnvironmentManager = nullptr;
    inAppWebViewManager = nullptr;
    inAppBrowserManager = nullptr;
    headlessInAppWebViewManager = nullptr;
    cookieManager = nullptr;
]=])
  set(after [=[
    // Consumers must retire before their shared composition/environment owners.
    headlessInAppWebViewManager = nullptr;
    inAppBrowserManager = nullptr;
    inAppWebViewManager = nullptr;
    cookieManager = nullptr;
    webViewEnvironmentManager = nullptr;
]=])
  nso_stage_lifetime_source(flutter_inappwebview_windows_plugin
    "flutter_inappwebview_windows_plugin.cpp" "${before}" "${after}")
endif()

if(TARGET ffmpeg_kit_flutter_new_video_plugin)
  set(before [=[
FFmpegKitFlutterPlugin::~FFmpegKitFlutterPlugin() {
    g_plugin_instance = nullptr;
]=])
  set(after [=[
FFmpegKitFlutterPlugin::~FFmpegKitFlutterPlugin() {
    // Stop and join the native callback consumer before unloading its pthread
    // implementation. Do not hold the callback lock while joining that worker.
    if (lib_ && fn_disable_redirection_) {
        fn_disable_redirection_();
    }
    {
        std::lock_guard<std::mutex> lock(g_callback_mutex);
        g_plugin_instance = nullptr;
    }
]=])
  nso_stage_lifetime_source(ffmpeg_kit_flutter_new_video_plugin
    "ffmpeg_kit_flutter_plugin.cpp" "${before}" "${after}")
endif()
