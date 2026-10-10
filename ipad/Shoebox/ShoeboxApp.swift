import SwiftUI
import WebKit

@main
struct ShoeboxApp: App {
    var body: some Scene { WindowGroup { ConnectionView() } }
}

struct ConnectionView: View {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var discovery = ServerDiscovery()
    @AppStorage("serverAddress") private var savedAddress = ""
    @State private var address = ""
    @State private var server: URL?
    @State private var error: String?
    @State private var loading = false
    @State private var reloadID = UUID()

    var body: some View {
        NavigationStack {
            Group {
                if let server {
                    ZStack {
                        LibraryBrowser(server: server, loading: $loading, error: $error)
                            .id(reloadID)
                        if loading { ProgressView("Connecting to your Mac…").padding().background(.regularMaterial).clipShape(RoundedRectangle(cornerRadius: 12)) }
                        if let error {
                            VStack(spacing: 16) {
                                Text("Couldn’t connect").font(.headline)
                                Text(error)
                                Text("Keep the Mac server running, use the same Wi-Fi, and allow local network access in Settings if requested.")
                                Button("Retry") { self.error = nil; loading = true; reloadID = UUID() }.buttonStyle(.borderedProminent)
                            }
                            .padding(24).frame(maxWidth: 480).background(.regularMaterial)
                            .clipShape(RoundedRectangle(cornerRadius: 16)).padding()
                        }
                    }
                } else {
                    Form {
                        Section {
                            Text("Watch the videos on your Mac").font(.title2.bold())
                            Text("Start the Shoebox server on your Mac, then choose it below. Keep both devices on the same Wi-Fi.")
                        }
                        Section("Nearby servers") {
                            ForEach(discovery.servers) { nearby in
                                Button {
                                    address = nearby.url.absoluteString
                                    connect()
                                } label: {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text("Connect to \(nearby.name)")
                                        Text(nearby.url.absoluteString).font(.caption).foregroundStyle(.secondary)
                                    }.frame(minHeight: 44)
                                }
                            }
                            if let message = discovery.error { Text(message) }
                            else if discovery.servers.isEmpty {
                                Text("No Shoebox servers found yet. Start the Mac sharing script, allow local network access, or use manual entry below.")
                                if discovery.searching { ProgressView("Looking on your Wi-Fi…") }
                            }
                            Button("Refresh servers") { discovery.stop(); discovery.start() }.frame(minHeight: 44)
                        }
                        Section("Manual server address") {
                            TextField("http://192.168.1.10:7171", text: $address)
                                .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                                .submitLabel(.go).onSubmit(connect)
                                .accessibilityLabel("Mac server address")
                            if let error { Text(error).foregroundStyle(.red) }
                            Button("Connect", action: connect).frame(minHeight: 44)
                                .disabled(address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        }
                        Section {
                            Text("Enter an address for a Mac you trust. Your videos stay on that Mac and stream over your network.")
                        }
                        Section("App developer") {
                            Text("Habibur Rahman Talha")
                            Link("habiburrahmantahla@gmail.com", destination: URL(string: "mailto:habiburrahmantahla@gmail.com")!)
                        }
                    }
                    .onAppear {
                        if address.isEmpty { address = savedAddress }
                        discovery.start()
                    }
                    .onDisappear { discovery.stop() }
                }
            }
            .navigationTitle("Shoebox").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if server != nil {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Change Mac") { server = nil; error = nil; loading = false }
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Reload", systemImage: "arrow.clockwise") { error = nil; loading = true; reloadID = UUID() }
                    }
                }
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active && server == nil { discovery.start() }
            else { discovery.stop() }
        }
    }

    private func connect() {
        guard let url = ServerAddress.parse(address) else {
            error = "Enter a server address such as http://192.168.1.10:7171, without a path or password."
            return
        }
        savedAddress = url.absoluteString
        error = nil
        loading = true
        server = url
    }
}

struct LibraryBrowser: UIViewControllerRepresentable {
    let server: URL
    @Binding var loading: Bool
    @Binding var error: String?

    func makeUIViewController(context: Context) -> BrowserController {
        let controller = BrowserController(server: server)
        controller.onState = { busy, message in loading = busy; error = message }
        return controller
    }
    func updateUIViewController(_ controller: BrowserController, context: Context) {}
    static func dismantleUIViewController(_ controller: BrowserController, coordinator: ()) {
        controller.webView.stopLoading()
        controller.webView.loadHTMLString("", baseURL: nil)
        controller.onState = nil
    }
}

final class BrowserController: UIViewController, WKNavigationDelegate, WKUIDelegate {
    let server: URL
    let webView: WKWebView
    var onState: ((Bool, String?) -> Void)?

    init(server: URL) {
        self.server = server
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        config.allowsPictureInPictureMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        config.preferences.isElementFullscreenEnabled = true
        if let file = Bundle.main.url(forResource: "LibraryLoading", withExtension: "js"),
           let script = try? String(contentsOf: file, encoding: .utf8) {
            config.userContentController.addUserScript(WKUserScript(source: script, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        }
        webView = WKWebView(frame: .zero, configuration: config)
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("Use init(server:)") }
    override func loadView() { view = webView }
    override func viewDidLoad() {
        super.viewDidLoad()
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        webView.load(URLRequest(url: server, timeoutInterval: 20))
    }
    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) { onState?(true, nil) }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { onState?(false, nil) }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { failed(error) }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { failed(error) }
    private func failed(_ error: Error) {
        if (error as NSError).code != NSURLErrorCancelled { onState?(false, error.localizedDescription) }
    }
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = action.request.url else { decisionHandler(.cancel); return }
        if url.absoluteString == "about:blank" { decisionHandler(.allow); return }
        if ServerAddress.sameOrigin(url, as: server), action.targetFrame != nil {
            decisionHandler(.allow)
            return
        }
        if action.navigationType == .linkActivated, ["http", "https", "vlc"].contains(url.scheme ?? "") {
            UIApplication.shared.open(url)
        }
        decisionHandler(.cancel)
    }
    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
        guard ServerAddress.sameOrigin(frame.request.url, as: server) else { completionHandler(); return }
        let alert = UIAlertController(title: "Shoebox", message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default) { _ in completionHandler() })
        present(alert, animated: true)
    }
    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
        guard ServerAddress.sameOrigin(frame.request.url, as: server) else { completionHandler(false); return }
        let alert = UIAlertController(title: "Shoebox", message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { _ in completionHandler(false) })
        alert.addAction(UIAlertAction(title: "OK", style: .default) { _ in completionHandler(true) })
        present(alert, animated: true)
    }
}
