//
//  AppKitRenderingStrategy.swift
//
//
//  Created by Noah Martin on 8/8/24.
//

#if canImport(AppKit) && !targetEnvironment(macCatalyst)
import Foundation
import AppKit
import SwiftUI
import SnapshotSharedModels
import ScreenCaptureKit

class BorderlessWindow: NSWindow {
    override init(contentRect: NSRect, styleMask style: NSWindow.StyleMask, backing bufferingType: NSWindow.BackingStoreType, defer flag: Bool) {
        super.init(contentRect: contentRect, styleMask: [.borderless], backing: bufferingType, defer: flag)
        self.isOpaque = false
        self.backgroundColor = NSColor.clear
    }
}

/// A titled window for previews that fill one: it can be taller than the screen, and sit almost
/// entirely off it.
class ChromeWindow: NSWindow {
  init() {
    super.init(
      contentRect: NSRect(origin: .zero, size: AppKitContainer.defaultSize),
      styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
      backing: .buffered, defer: false)
    toolbarStyle = .unified
    isReleasedWhenClosed = false
  }

  override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
    frameRect
  }
}

private var _colorScheme: ColorScheme? = nil

public class AppKitRenderingStrategy: RenderingStrategy {

  private let window: NSWindow
  /// Whether previews that fill a window are captured from a titled one, as the screen shows it.
  private let capturesWindows: Bool
  private lazy var chromeWindow = ChromeWindow()

  /// - Parameter capturesWindows: Capture previews that put something in a window's chrome (a
  ///   split view, a navigation title or toolbar items) from a titled window, with ScreenCaptureKit,
  ///   so their title bar, toolbar and vibrant content (such as a sidebar's icons) come out as the
  ///   screen shows them. Drawing a view (`cacheDisplay`, the default) misses those. Other previews
  ///   are drawn as before. Needs Screen Recording access.
  public init(capturesWindows: Bool = false) {
    self.capturesWindows = capturesWindows
    window = BorderlessWindow()
    window.makeKeyAndOrderFront(nil)
  }

  @MainActor public func render(
    preview: SnapshotPreviewsCore.Preview,
    completion: @escaping (SnapshotResult) -> Void)
  {
    let capturesWindows = capturesWindows
    layOut(preview, in: window) { [weak self] vc, mode, metadata in
      guard let self else { return }
      let finish = { (image: NSImage?, frame: NSSize) in
        completion(metadata.result(image.map { .success($0) } ?? .failure(RenderingError.failedRendering(frame))))
      }
      if #available(macOS 14.0, *), capturesWindows, mode == nil, let vc,
        Self.fillsWindow(vc, in: self.window)
      {
        self.captureInChrome(preview) { image in completion(metadata.result(image)) }
      } else {
        Self.takeSnapshot(mode: mode ?? .nsView, viewController: vc, window: self.window) { image in
          finish(image, self.window.frame.size)
        }
      }
    }
  }

  /// What a preview reported, for its result.
  private struct Metadata {
    let precision: Float?
    let accessibilityEnabled: Bool?
    let appStoreSnapshot: Bool?
    let tags: [String: String]
    let additionalContext: [String: SnapshotMetadataValue]
    let groupOverride: SnapshotGroup?
    let canvasTheme: SnapshotCanvasTheme?

    func result(_ image: Result<NSImage, any Error>) -> SnapshotResult {
      SnapshotResult(
        image: image,
        precision: precision,
        accessibilityEnabled: accessibilityEnabled,
        colorScheme: _colorScheme,
        appStoreSnapshot: appStoreSnapshot,
        tags: tags,
        additionalContext: additionalContext,
        groupOverride: groupOverride,
        canvasTheme: canvasTheme)
    }
  }

  /// Hosts `preview` in `window` and calls back once it's laid out, its scroll view expanded.
  @MainActor private func layOut(
    _ preview: SnapshotPreviewsCore.Preview, in window: NSWindow,
    rendered: @escaping (AppKitContainer?, EmergeRenderingMode?, Metadata) -> Void
  ) {
    var wrappedView = preview.view()
    _colorScheme = nil
    wrappedView = PreferredColorSchemeWrapper {
      AnyView(wrappedView)
    } colorSchemeUpdater: { scheme in
      _colorScheme = scheme
    }
    let vc = AppKitContainer(rootView: wrappedView)
    vc.setupView(layout: preview.layout)
    // Reset the window size to default before adding the new view controller
    window.contentViewController = NSViewController()
    window.title = ""
    window.toolbar = nil
    window.setContentSize(AppKitContainer.defaultSize)
    window.contentViewController = vc
    vc.rendered = { [weak vc] mode, precision, accessibilityEnabled, appStoreSnapshot, tags, additionalContext, groupOverride, canvasTheme in
      DispatchQueue.main.async {
        rendered(
          vc, mode,
          Metadata(
            precision: precision, accessibilityEnabled: accessibilityEnabled,
            appStoreSnapshot: appStoreSnapshot, tags: tags, additionalContext: additionalContext,
            groupOverride: groupOverride, canvasTheme: canvasTheme))
      }
    }
  }

  /// Whether a preview puts something in its window's chrome: a split view (a sidebar), a
  /// navigation title or toolbar items.
  @MainActor private static func fillsWindow(_ vc: NSViewController, in window: NSWindow) -> Bool {
    func hasSplitView(_ view: NSView) -> Bool {
      view is NSSplitView || view.subviews.contains(where: hasSplitView)
    }
    return !window.title.isEmpty || window.toolbar?.items.isEmpty == false || hasSplitView(vc.view)
  }

  /// Renders `preview` again in the titled window and captures it as the screen shows it. The
  /// window sits off screen but for one point at the display's corner: ScreenCaptureKit captures
  /// windows that are partly on screen, whatever their size, but not ones entirely off it.
  @available(macOS 14.0, *)
  @MainActor private func captureInChrome(
    _ preview: SnapshotPreviewsCore.Preview,
    completion: @escaping (Result<NSImage, any Error>) -> Void
  ) {
    let window = chromeWindow
    window.orderFront(nil)
    layOut(preview, in: window) { _, _, _ in
      if let screen = NSScreen.main {
        let size = window.frame.size
        window.setFrameOrigin(
          NSPoint(x: screen.frame.minX - size.width + 1, y: screen.frame.minY - size.height + 1))
      }
      window.displayIfNeeded()
      Task { @MainActor in
        // A frame for the window server to show the window where it is now.
        try? await Task.sleep(for: .milliseconds(50))
        completion(await Self.screenCapture(window))
      }
    }
  }

  /// The window as the screen shows it, at its full size, without its shadow.
  @available(macOS 14.0, *)
  @MainActor private static func screenCapture(_ window: NSWindow) async -> Result<NSImage, any Error> {
    do {
      let content = try await SCShareableContent.excludingDesktopWindows(
        false, onScreenWindowsOnly: false)
      guard
        let scWindow = content.windows.first(where: {
          $0.windowID == CGWindowID(window.windowNumber)
        })
      else { return .failure(RenderingError.failedRendering(window.frame.size)) }
      let filter = SCContentFilter(desktopIndependentWindow: scWindow)
      let configuration = SCStreamConfiguration()
      let scale = CGFloat(filter.pointPixelScale)
      configuration.width = Int(filter.contentRect.width * scale)
      configuration.height = Int(filter.contentRect.height * scale)
      configuration.ignoreShadowsSingleWindow = true
      configuration.showsCursor = false
      configuration.captureResolution = .best
      let image = try await SCScreenshotManager.captureImage(
        contentFilter: filter, configuration: configuration)
      return .success(NSImage(cgImage: image, size: filter.contentRect.size))
    } catch {
      return .failure(RenderingError.screenCaptureFailed(error))
    }
  }

  private static func takeSnapshot(mode: EmergeRenderingMode, viewController: NSViewController?, window: NSWindow?, completion: @escaping (NSImage?) -> Void) {
    switch mode {
    case .coreAnimation:
        completion(viewController?.view.layerSnapshot())
    case .nsView:
      completion(viewController?.view.snapshot())
    case .window:
      if let window {
        attemptSnapshot(window: window, maxAttempts: 15, completion: completion)
      }
      else {
        completion(nil)
      }
    }
  }
  
  private static func attemptSnapshot(window: NSWindow?, maxAttempts: Int, completion: @escaping (NSImage?) -> Void) {
    guard let window = window else {
      completion(nil)
      return
    }
    
    func trySnapshot(attempt: Int) {
      let image = window.snapshot()
      
      if image != nil || attempt >= maxAttempts {
        if attempt >= maxAttempts {
          completion(nil)
        }
        completion(image)
        return
      }
      
      // Calculate exponential backoff delay: 0.01 * 2^(attempt-1)
      let baseDelay = 0.01
      let exponentialDelay = baseDelay * pow(2.0, Double(attempt - 1))
      
      DispatchQueue.main.asyncAfter(deadline: .now() + exponentialDelay) {
        trySnapshot(attempt: attempt + 1)
      }
    }
    
    trySnapshot(attempt: 1)
  }
}

final class AppKitContainer: NSHostingController<EmergeModifierView>, ScrollExpansionProviding {

  var supportsExpansion: Bool {
    rootView.supportsExpansion
  }
  var heightAnchor: NSLayoutConstraint?
  var previousHeight: CGFloat?

  public var rendered: ((EmergeRenderingMode?, Float?, Bool?, Bool?, [String: String], [String: SnapshotMetadataValue], SnapshotGroup?, SnapshotCanvasTheme?) -> Void)? {
    didSet { didCall = false }
  }

  static let defaultSize = NSSize(width: 800, height: 400)

  private var didCall = false
  private var widthAnchor: NSLayoutConstraint?

  init<Content: View>(rootView: Content) {
    super.init(rootView: EmergeModifierView(wrapped: rootView))

    if #available(macOS 13.0, *) {
      sizingOptions = .intrinsicContentSize
    }
    // The window takes the preview's navigation title and toolbar, as in an app, so a preview
    // that fills a window can be told apart, and shows them when captured in a titled one.
    if #available(macOS 14.0, *) {
      sceneBridgingOptions = [.title, .toolbars]
    }
    view.translatesAutoresizingMaskIntoConstraints = false
  }

  @MainActor required dynamic init?(coder aDecoder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  public func removeConstraints() {
    heightAnchor?.isActive = false
    widthAnchor?.isActive = false
    heightAnchor = nil
    widthAnchor = nil
  }

  public func setupView(layout: PreviewLayout) {
    removeConstraints()
    switch layout {
    case let .fixed(width: width, height: height):
      widthAnchor = view.widthAnchor.constraint(equalToConstant: width)
      widthAnchor?.isActive = true
      heightAnchor = view.heightAnchor.constraint(equalToConstant: height)
      heightAnchor?.isActive = true
    default:
      let fittingSize = sizeThatFits(in: Self.defaultSize)
      widthAnchor = view.widthAnchor.constraint(equalToConstant: fittingSize.width)
      widthAnchor?.isActive = true
      heightAnchor = view.heightAnchor.constraint(equalToConstant: fittingSize.height)
      heightAnchor?.isActive = true
    }
  }

  private func runCallback() {
    guard !didCall else { return }

    didCall = true
    rendered?(rootView.emergeRenderingMode, rootView.precision, rootView.accessibilityEnabled, rootView.appStoreSnapshot, rootView.tags, rootView.additionalContext, rootView.groupOverride, rootView.canvasTheme)
  }

  override func updateViewConstraints() {
    super.updateViewConstraints()
    updateScrollViewHeight()
  }

  public func updateScrollViewHeight() {
    guard rendered != nil else {
      runCallback()
      return
    }

    updateHeight {
      runCallback()
    }
  }
}

extension NSView {
  func snapshot() -> NSImage? {
    guard let bitmapRep = bitmapImageRepForCachingDisplay(in: bounds) else {
      return nil
    }
    bitmapRep.size = bounds.size
    cacheDisplay(in: bounds, to: bitmapRep)

    let image = NSImage(size: bounds.size)
    image.addRepresentation(bitmapRep)

    return image
  }
    
  func layerSnapshot() -> NSImage? {
    let scale = window?.backingScaleFactor ?? 1
    let height = Int(bounds.size.height * scale)
    let width = Int(bounds.size.width * scale)
    let bytesPerRow = width * 4
    let space = CGColorSpaceCreateDeviceRGB()
    guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: bytesPerRow, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
      return nil
    }
    
    context.translateBy(x: 0, y: CGFloat(height))
    context.scaleBy(x: scale, y: -scale)

    (self.layer?.presentation() ?? self.layer)?.render(in: context)
    guard let cgImage = context.makeImage() else {
      return nil
    }
    return NSImage(cgImage: cgImage, size: bounds.size)
  }
}

extension NSWindow {
  func snapshot() -> NSImage? {
    guard let cgImage = CGWindowListCreateImage(.null,
                                                .optionIncludingWindow,
                                                CGWindowID(self.windowNumber),
                                                .bestResolution)
    else {
      return nil
    }

    return NSImage(cgImage: cgImage, size: self.frame.size)
  }
}

#endif
