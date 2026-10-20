//
//  ScrollExpansion.swift
//
//
//  Created by Noah Martin on 8/22/24.
//

import Foundation
#if canImport(UIKit)
import UIKit
#endif

#if canImport(AppKit)
import AppKit
#endif

protocol ContentHeightProviding {
  var contentHeight: CGFloat { get }

  var visibleContentHeight: CGFloat { get }

  /// Screen pixels per point where it's shown: 2 on a Retina Mac, 3 on most iPhones.
  var pixelsPerPoint: CGFloat { get }
}

protocol FirstScrollViewProviding {
  var firstScrollView: ContentHeightProviding? { get }
}

#if !os(watchOS)
protocol ScrollExpansionProviding: AnyObject, FirstScrollViewProviding {
  var previousHeight: CGFloat? { get set }
  var heightAnchor: NSLayoutConstraint? { get }
  var supportsExpansion: Bool { get }
}

extension ScrollExpansionProviding {
  func updateHeight(_ complete: (() -> Void)) {
    // If heightAnchor isn't set, this was a fixed size and we don't expand the scroll view
    guard let heightAnchor, supportsExpansion, let scrollView = firstScrollView else {
      complete()
      return
    }

    // Grown to show the content's height rounded up to whole pixels, however many passes the
    // content settles over. Growing by the difference truncated to whole points, as upstream did,
    // left a list a pixel or two short in some runs and not others (851-2768).
    let pixel = 1 / max(scrollView.pixelsPerPoint, 1)
    let target = (scrollView.contentHeight / pixel).rounded(.up) * pixel
    let growth = target - scrollView.visibleContentHeight
    // Within half a pixel, it shows all of it. It only shrinks back after growing.
    guard abs(growth) >= pixel / 2, previousHeight != nil || growth > 0 else {
      complete()
      return
    }
    if let previousHeight {
      // Check if expansion isn't working and we should give up.
      // Could happen if the view is constrained to not grow, such as a half sheet, or if its
      // content grows with it, a little more each pass.
      guard abs(previousHeight - scrollView.visibleContentHeight) >= 1 else {
        complete()
        return
      }
    }
    previousHeight = scrollView.visibleContentHeight
    heightAnchor.constant += growth
  }
}
#endif

#if canImport(UIKit) && !os(visionOS) && !os(watchOS) && !os(tvOS)
extension UIScrollView: ContentHeightProviding {

  var contentHeight: CGFloat {
    contentSize.height
  }

  var visibleContentHeight: CGFloat {
    frame.height - (adjustedContentInset.top + adjustedContentInset.bottom)
  }

  var pixelsPerPoint: CGFloat {
    let scale = traitCollection.displayScale
    return scale > 0 ? scale : window?.screen.scale ?? UIScreen.main.scale
  }
}

extension UIView: FirstScrollViewProviding {
  var firstScrollView: ContentHeightProviding? {
    var subviews = subviews
    while !subviews.isEmpty {
      let subview = subviews.removeFirst()
      // Don’t expand UITextView, it can cause flakes
      guard !(subview is UITextView) else {
        continue
      }

      subviews.append(contentsOf: subview.subviews)
      if let scrollView = subview as? UIScrollView {
        return scrollView
      }
    }
    return nil
  }
}

extension UIViewController: FirstScrollViewProviding {
  var firstScrollView: ContentHeightProviding? {
    view?.firstScrollView
  }
}
#endif

#if canImport(AppKit) && !targetEnvironment(macCatalyst)
extension NSScrollView: ContentHeightProviding {

  var contentHeight: CGFloat {
    documentView?.frame.size.height ?? 0
  }

  var visibleContentHeight: CGFloat {
    frame.height - (contentInsets.top + contentInsets.bottom)
  }

  var pixelsPerPoint: CGFloat {
    window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
  }
}

extension NSView: FirstScrollViewProviding {
  var firstScrollView: ContentHeightProviding? {
    var subviews = subviews
    while !subviews.isEmpty {
      let subview = subviews.removeFirst()
      if let scrollView = subview as? NSScrollView {
        // Don’t expand NSTextView, it can cause flakes
        guard !(scrollView.documentView is NSTextView) else {
          continue
        }

        return scrollView
      }
      subviews.append(contentsOf: subview.subviews)
    }
    return nil
  }
}

extension NSViewController: FirstScrollViewProviding {
  var firstScrollView: ContentHeightProviding? {
    view.firstScrollView
  }
}
#endif
