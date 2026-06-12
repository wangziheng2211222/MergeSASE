import SwiftUI
import WebKit
import AppKit

struct DeveloperPortalWebView: View {
    @ObservedObject var svc: ProxyService
    @Environment(\.dismiss) private var dismiss
    @State private var webView = WKWebView()
    @State private var currentURL = "https://ai.limayao.com/developer"
    @State private var loading = false
    @State private var importInProgress = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("limayao 开发者后台")
                        .font(.system(size: 14, weight: .semibold))
                    Text(currentURL)
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer()
                if loading {
                    ProgressView()
                        .controlSize(.small)
                }
                Button {
                    webView.reload()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help("刷新")
                Button {
                    if let url = webView.url ?? URL(string: currentURL) {
                        NSWorkspace.shared.open(url)
                    }
                } label: {
                    Image(systemName: "safari")
                }
                .help("在外部浏览器打开")
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                }
                .help("关闭")
            }
            .padding(10)

            Divider()

            WebViewContainer(
                webView: webView,
                startURL: URL(string: "https://ai.limayao.com/developer")!,
                svc: svc,
                currentURL: $currentURL,
                loading: $loading
            )

            Divider()

            HStack(spacing: 8) {
                Text("登录完成并看到 CC Switch 导入按钮后，点击导入当前页面")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                Spacer()
                Button {
                    Task { await importCurrentPage() }
                } label: {
                    Label(importInProgress ? "导入中…" : "导入当前页面", systemImage: "square.and.arrow.down")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(importInProgress || loading)
            }
            .padding(10)
        }
        .frame(minWidth: 860, minHeight: 640)
    }

    @MainActor
    private func importCurrentPage() async {
        importInProgress = true
        defer { importInProgress = false }

        let js = """
        (() => {
          const nodes = Array.from(document.querySelectorAll('.ccswitch-dropdown-item.ccswitch-dropdown-item--both, .ccswitch-dropdown-item--both, a, button'));
          const target = nodes.find(node => node.matches('.ccswitch-dropdown-item.ccswitch-dropdown-item--both, .ccswitch-dropdown-item--both'))
            || nodes.find(node => /cc\\s*switch|导入/i.test(node.innerText || node.textContent || ''));
          const parts = [];
          for (const node of nodes) {
            const attrs = Array.from(node.attributes || []).map(a => `${a.name}=${a.value}`).join(' ');
            const text = (node.innerText || node.textContent || '').trim();
            parts.push(`${attrs}\\n${text}`);
          }
          parts.push(document.body ? document.body.innerText : '');
          if (target) {
            setTimeout(() => target.click(), 80);
          }
          return parts.join('\\n---CCS---\\n');
        })()
        """

        do {
            let value = try await webView.evaluateJavaScript(js)
            svc.importCCSwitchProvider(fromPageText: String(describing: value ?? ""))
        } catch {
            svc.importCCSwitchProvider(fromPageText: "")
        }
    }
}

private struct WebViewContainer: NSViewRepresentable {
    let webView: WKWebView
    let startURL: URL
    let svc: ProxyService
    @Binding var currentURL: String
    @Binding var loading: Bool

    func makeCoordinator() -> Coordinator {
        Coordinator(svc: svc, currentURL: $currentURL, loading: $loading)
    }

    func makeNSView(context: Context) -> WKWebView {
        webView.navigationDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = true
        webView.load(URLRequest(url: startURL))
        return webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {}

    final class Coordinator: NSObject, WKNavigationDelegate {
        let svc: ProxyService
        @Binding var currentURL: String
        @Binding var loading: Bool

        init(svc: ProxyService, currentURL: Binding<String>, loading: Binding<Bool>) {
            self.svc = svc
            _currentURL = currentURL
            _loading = loading
        }

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            guard let url = navigationAction.request.url else {
                decisionHandler(.allow)
                return
            }
            if url.scheme?.lowercased() == "ccswitch" {
                NSWorkspace.shared.open(url)
                loading = false
                svc.ccSwitchProviderImported = true
                svc.ccSwitchImportStatus = .imported
                svc.browserImportMessage = "已唤起 CC Switch 导入"
                decisionHandler(.cancel)
                return
            }
            decisionHandler(.allow)
        }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            loading = true
            currentURL = webView.url?.absoluteString ?? currentURL
        }

        func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
            currentURL = webView.url?.absoluteString ?? currentURL
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            loading = false
            currentURL = webView.url?.absoluteString ?? currentURL
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            loading = false
            currentURL = webView.url?.absoluteString ?? currentURL
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            loading = false
            currentURL = webView.url?.absoluteString ?? currentURL
        }
    }
}
