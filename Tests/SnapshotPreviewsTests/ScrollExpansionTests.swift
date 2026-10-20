#if canImport(UIKit)
import UIKit
private typealias PlatformView = UIView
#else
import AppKit
private typealias PlatformView = NSView
#endif
import XCTest
@testable import SnapshotPreviewsCore

/// A scroll view whose content settles over a few layout passes, as a list's does.
private final class SettlingScrollView: ContentHeightProviding {
  var contentHeight: CGFloat
  var visibleContentHeight: CGFloat
  let pixelsPerPoint: CGFloat

  init(contentHeight: CGFloat, visibleContentHeight: CGFloat, pixelsPerPoint: CGFloat) {
    self.contentHeight = contentHeight
    self.visibleContentHeight = visibleContentHeight
    self.pixelsPerPoint = pixelsPerPoint
  }
}

private final class Expander: ScrollExpansionProviding {
  var previousHeight: CGFloat?
  let heightAnchor: NSLayoutConstraint?
  let supportsExpansion = true
  let scrollView: SettlingScrollView
  var firstScrollView: ContentHeightProviding? { scrollView }

  init(scrollView: SettlingScrollView) {
    self.scrollView = scrollView
    heightAnchor = PlatformView().heightAnchor.constraint(
      equalToConstant: scrollView.visibleContentHeight)
  }

  /// Runs expansion's passes until it's done: after each, layout snaps the frame to whole pixels
  /// and the content settles to its next height (the last one from then on). The final height.
  func expand(settlingThrough contents: [CGFloat], passes: Int = 20) -> CGFloat {
    var done = false
    for pass in 0..<passes where !done {
      scrollView.contentHeight = contents[min(pass, contents.count - 1)]
      updateHeight { done = true }
      let constant = heightAnchor?.constant ?? 0
      scrollView.visibleContentHeight =
        (constant * scrollView.pixelsPerPoint).rounded() / scrollView.pixelsPerPoint
    }
    XCTAssertTrue(done, "Expansion never finished")
    return scrollView.visibleContentHeight
  }
}

final class ScrollExpansionTests: XCTestCase {
  private func expand(
    from visible: CGFloat, settlingThrough contents: [CGFloat], scale: CGFloat = 3
  ) -> CGFloat {
    let scrollView = SettlingScrollView(
      contentHeight: contents[0], visibleContentHeight: visible, pixelsPerPoint: scale)
    return Expander(scrollView: scrollView).expand(settlingThrough: contents)
  }

  func testGrowsToTheContentRoundedUpToWholePixels() {
    XCTAssertEqual(expand(from: 852, settlingThrough: [1056.2]), 1056 + 1.0 / 3, accuracy: 0.001)
  }

  func testEndsTheSameHeightWhateverPassesTheContentSettlesOver() {
    // Truncating each pass's growth to whole points lost a different fraction for each.
    let once = expand(from: 852, settlingThrough: [1056.4])
    let thrice = expand(from: 852, settlingThrough: [900.7, 1001.6, 1056.4])
    XCTAssertEqual(once, thrice, accuracy: 0.001)
    XCTAssertEqual(once, 1056 + 2.0 / 3, accuracy: 0.001)
  }

  func testShrinksBackOnlyAfterGrowing() {
    // Content shorter than the view to start with: it keeps its size.
    XCTAssertEqual(expand(from: 852, settlingThrough: [600]), 852)
    // Grown, then the content settled shorter.
    XCTAssertEqual(expand(from: 852, settlingThrough: [1100, 1040.5]), 1040 + 2.0 / 3, accuracy: 0.001)
  }

  func testGivesUpOnContentThatGrowsWithTheView() {
    // Always half a point taller than the view: it stops rather than growing forever.
    let scrollView = SettlingScrollView(
      contentHeight: 852.5, visibleContentHeight: 852, pixelsPerPoint: 2)
    let expander = Expander(scrollView: scrollView)
    var done = false
    for _ in 0..<10 where !done {
      scrollView.contentHeight = scrollView.visibleContentHeight + 0.5
      expander.updateHeight { done = true }
      scrollView.visibleContentHeight = expander.heightAnchor?.constant ?? 0
    }
    XCTAssertTrue(done)
  }
}
