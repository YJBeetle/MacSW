import AppKit
import SwiftUI

private struct ContentHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

private struct ViewportHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

private struct TotalHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

extension View {
    /// 滚动内容的完整高度（视口之外的部分也算）。
    func reportScrollContentHeight() -> some View {
        background(GeometryReader { proxy in
            Color.clear.preference(key: ContentHeightKey.self, value: proxy.size.height)
        })
    }

    /// 滚动视口当前高度。
    func reportViewportHeight() -> some View {
        background(GeometryReader { proxy in
            Color.clear.preference(key: ViewportHeightKey.self, value: proxy.size.height)
        })
    }
}

/// 安装窗口高度随内容自动贴合：内容多高窗口就多高，超过屏幕可用高度才让内部滚动接手。
/// 窗口没有 .resizable，用户不能自己拖，所以高度必须由这里维护。
struct AutoHeightWindow: ViewModifier {
    private static let screenMargin: CGFloat = 70
    private static let minimumWindowHeight: CGFloat = 320

    @State private var contentHeight: CGFloat = 0
    @State private var viewportHeight: CGFloat = 0
    @State private var totalHeight: CGFloat = 0

    func body(content: Content) -> some View {
        content
            .background(GeometryReader { proxy in
                Color.clear.preference(key: TotalHeightKey.self, value: proxy.size.height)
            })
            .onPreferenceChange(ContentHeightKey.self) { contentHeight = $0 }
            .onPreferenceChange(ViewportHeightKey.self) { viewportHeight = $0 }
            .onPreferenceChange(TotalHeightKey.self) { totalHeight = $0 }
            .background(WindowFitting(
                contentHeight: contentHeight,
                viewportHeight: viewportHeight,
                totalHeight: totalHeight
            ))
    }

    private struct WindowFitting: NSViewRepresentable {
        let contentHeight: CGFloat
        let viewportHeight: CGFloat
        let totalHeight: CGFloat

        final class Coordinator {
            var hasFitted = false
        }

        func makeCoordinator() -> Coordinator { Coordinator() }

        func makeNSView(context: Context) -> NSView { NSView(frame: .zero) }

        func updateNSView(_ view: NSView, context: Context) {
            guard let window = view.window,
                  contentHeight > 0, viewportHeight > 0, totalHeight > 0 else { return }
            let chrome = max(0, totalHeight - viewportHeight)
            let cap = (window.screen?.visibleFrame.height ?? 900) - AutoHeightWindow.screenMargin
            let delta = min(chrome + contentHeight, max(AutoHeightWindow.minimumWindowHeight, cap)) - viewportHeight
            guard abs(delta) > 1 else { return }
            // 布局回调里改窗口尺寸会重入，交给下一个主循环。
            DispatchQueue.main.async {
                var frame = window.frame
                let height = max(AutoHeightWindow.minimumWindowHeight, frame.size.height + delta)
                frame.size.height = height
                guard context.coordinator.hasFitted else {
                    // 首次贴合直接定尺寸并重新居中，别把窗口从初始位置往下推。
                    context.coordinator.hasFitted = true
                    window.setFrame(frame, display: true)
                    window.center()
                    return
                }
                frame.origin.y = window.frame.maxY - height
                window.setFrame(frame, display: true, animate: true)
            }
        }
    }
}

extension View {
    func autoHeightWindow() -> some View { modifier(AutoHeightWindow()) }
}
