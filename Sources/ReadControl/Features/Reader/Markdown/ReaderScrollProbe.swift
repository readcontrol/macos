// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import SwiftUI

/// A view of no size that hands the reader its scroll view.
///
/// The deployment target is macOS 14, where SwiftUI cannot read or set a scroll
/// offset (`onScrollGeometryChange` and `scrollPosition(id:)` need macOS 15).
/// The reader puts this probe in the scroll content, finds the enclosing
/// `NSScrollView`, and works with AppKit.
///
/// The probe reports the scroll view once it is in the window, and again each
/// time the scroll stops. "Stops" means the clip view posted no bounds change
/// for `settleDelay`. The reader records a position only then, thus it writes
/// the position file one time for each stop of the scroll.
struct ReaderScrollProbe: NSViewRepresentable {
    /// How long the scroll must stay still before the reader records.
    static let settleDelay: Duration = .milliseconds(800)

    /// The reader can now read and set the scroll offset.
    var onReady: (NSScrollView) -> Void
    /// The scroll stopped after the user moved it.
    var onSettle: (NSScrollView) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = ProbeView()
        view.coordinator = context.coordinator
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        context.coordinator.onReady = onReady
        context.coordinator.onSettle = onSettle
        (view as? ProbeView)?.coordinator = context.coordinator
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onReady: onReady, onSettle: onSettle)
    }

    /// Holds the notification observation and the settle timer for one probe.
    @MainActor
    final class Coordinator {
        var onReady: (NSScrollView) -> Void
        var onSettle: (NSScrollView) -> Void

        private var observer: NSObjectProtocol?
        private var settleTask: Task<Void, Never>?
        private weak var scrollView: NSScrollView?

        init(onReady: @escaping (NSScrollView) -> Void, onSettle: @escaping (NSScrollView) -> Void) {
            self.onReady = onReady
            self.onSettle = onSettle
        }

        /// Watch `scrollView` for movement. A second call for the same scroll
        /// view does nothing, thus a SwiftUI update never adds an observer twice.
        func attach(to scrollView: NSScrollView) {
            guard self.scrollView !== scrollView else { return }
            stopWatching()
            self.scrollView = scrollView

            let clipView = scrollView.contentView
            clipView.postsBoundsChangedNotifications = true
            observer = NotificationCenter.default.addObserver(
                forName: NSView.boundsDidChangeNotification, object: clipView, queue: .main
            ) { [weak self] _ in
                Task { @MainActor in self?.scheduleSettle() }
            }
            onReady(scrollView)
        }

        /// Restart the settle timer. Each bounds change cancels the previous
        /// timer, thus only a stop of the scroll reaches `onSettle`.
        private func scheduleSettle() {
            settleTask?.cancel()
            settleTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: ReaderScrollProbe.settleDelay)
                guard !Task.isCancelled, let self, let scrollView else { return }
                onSettle(scrollView)
            }
        }

        /// Stop watching the scroll. The probe view calls this when it leaves
        /// the window, thus the observation never outlives the reader.
        func stopWatching() {
            settleTask?.cancel()
            settleTask = nil
            if let observer {
                NotificationCenter.default.removeObserver(observer)
            }
            observer = nil
            scrollView = nil
        }
    }

    /// Finds the scroll view as soon as the probe joins the window, and stops
    /// the observation when the probe leaves it. A `deinit` cannot do that work,
    /// because Swift 6 refuses to touch the observation token from a nonisolated
    /// deinit.
    private final class ProbeView: NSView {
        var coordinator: Coordinator?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            MainActor.assumeIsolated {
                guard let scrollView = enclosingScrollView else {
                    coordinator?.stopWatching()
                    return
                }
                coordinator?.attach(to: scrollView)
            }
        }
    }
}
