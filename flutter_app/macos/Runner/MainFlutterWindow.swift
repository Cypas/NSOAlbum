import Cocoa
import FlutterMacOS
import Network
import WebKit

class MainFlutterWindow: NSWindow {
  override func awakeFromNib() {
    let project = FlutterDartProject()
    project.dartEntrypointArguments = Array(CommandLine.arguments.dropFirst())
    let flutterViewController = FlutterViewController(project: project)
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)
    configureSplatNetNetwork(flutterViewController)

    super.awakeFromNib()
  }

  private func configureSplatNetNetwork(_ controller: FlutterViewController) {
    let channel = FlutterMethodChannel(
      name: "io.github.cypas.nsoalbum/splatnet_network",
      binaryMessenger: controller.engine.binaryMessenger)
    channel.setMethodCallHandler { call, result in
      let store = WKWebsiteDataStore.default()
      if call.method == "configure" {
        let args = call.arguments as? [String: Any]
        if let host = args?["host"] as? String {
          guard #available(macOS 14.0, *),
                !host.isEmpty,
                let port = args?["port"] as? Int,
                let endpointPort = NWEndpoint.Port(rawValue: UInt16(exactly: port) ?? 0),
                endpointPort.rawValue != 0 else {
            result(FlutterError(code: "splatnet_proxy_unsupported",
                                message: "This WebView cannot use the app proxy.",
                                details: nil))
            return
          }
          var proxy = ProxyConfiguration(
            httpCONNECTProxy: .hostPort(host: .init(host), port: endpointPort),
            tlsOptions: nil)
          proxy.allowFailover = false
          store.proxyConfigurations = [proxy]
        } else if #available(macOS 14.0, *) {
          store.proxyConfigurations = []
        }
        Self.clearSplatNetData(store) { result(true) }
      } else if call.method == "clear" {
        Self.clearSplatNetData(store) {
          if #available(macOS 14.0, *) { store.proxyConfigurations = [] }
          result(true)
        }
      } else {
        result(FlutterMethodNotImplemented)
      }
    }
  }

  private static func clearSplatNetData(
    _ store: WKWebsiteDataStore, completion: @escaping () -> Void
  ) {
    let types = WKWebsiteDataStore.allWebsiteDataTypes()
    store.fetchDataRecords(ofTypes: types) { records in
      let nintendoRecords = records.filter {
        $0.displayName == "nintendo.net" ||
        $0.displayName == "api.lp1.av5ja.srv.nintendo.net"
      }
      store.removeData(ofTypes: types, for: nintendoRecords, completionHandler: completion)
    }
  }
}
