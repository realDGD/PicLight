import XCTest
import CoreGraphics
@testable import PicViewMac

final class GestureRouterTests: XCTestCase {
    // MARK: - Wheel

    func testWheelZoomIsPointerCenteredByDefault() {
        var router = GestureRouter(wheelMode: .zoom, swipeMode: .smart)
        let intent = router.routeWheel(deltaY: -40, deltaX: 0, anchor: CGPoint(x: 100, y: 100))
        guard case let .zoom(factor, anchor) = intent else {
            return XCTFail("expected a zoom intent, got \(intent)")
        }
        XCTAssertGreaterThan(factor, 1, "scrolling up must zoom in")
        XCTAssertEqual(anchor, CGPoint(x: 100, y: 100))
    }

    func testWheelPanModePansInsteadOfZooming() {
        var router = GestureRouter(wheelMode: .pan)
        XCTAssertEqual(router.routeWheel(deltaY: 20, deltaX: 5, anchor: .zero),
                       .pan(CGSize(width: 5, height: 20)))
    }

    func testWheelNavigateModeSwitchesImages() {
        var router = GestureRouter(wheelMode: .navigate)
        router.beginGesture()
        var intents: [GestureIntent] = []
        for _ in 0..<20 {
            intents.append(router.routeWheel(deltaY: -40, deltaX: 0, anchor: .zero))
        }
        XCTAssertTrue(intents.contains(.nextImage))
    }

    func testPinchAlwaysZoomsRegardlessOfWheelMode() {
        for mode in WheelMode.allCases {
            var router = GestureRouter(wheelMode: mode)
            let intent = router.routePinch(magnification: 0.25, anchor: CGPoint(x: 10, y: 10))
            guard case let .zoom(factor, _) = intent else {
                return XCTFail("pinch must zoom in \(mode) mode, got \(intent)")
            }
            XCTAssertEqual(factor, 1.25, accuracy: 0.0001)
        }
    }

    func testZeroMagnificationDoesNothing() {
        var router = GestureRouter()
        XCTAssertEqual(router.routePinch(magnification: 0, anchor: .zero), .none)
    }

    // MARK: - N4 smart swipe

    func testAtFitASwipeSwitchesImage() {
        var router = GestureRouter(swipeMode: .smart, switchThreshold: 0.1)
        router.beginGesture()
        let viewWidth: CGFloat = 1000
        var result: GestureIntent = .none
        for _ in 0..<10 where result == .none {
            result = router.routeSwipe(deltaX: -30, viewWidth: viewWidth,
                                       isZoomedIn: false, canPanInDirection: false)
        }
        XCTAssertEqual(result, .nextImage)
    }

    func testZoomedAndNotAtEdgeSwipePansInsteadOfSwitching() {
        var router = GestureRouter(swipeMode: .smart, switchThreshold: 0.1)
        router.beginGesture()
        for _ in 0..<20 {
            let intent = router.routeSwipe(deltaX: -30, viewWidth: 1000,
                                           isZoomedIn: true, canPanInDirection: true)
            if case .nextImage = intent { XCTFail("a pan-able swipe must never switch images") }
        }
    }

    func testZoomedAtEdgeContinuesToSwitchAfterHysteresis() {
        var router = GestureRouter(swipeMode: .smart, switchThreshold: 0.1)
        router.beginGesture()
        let viewWidth: CGFloat = 1000

        // A small accidental overscroll must not navigate.
        let small = router.routeSwipe(deltaX: -20, viewWidth: viewWidth,
                                      isZoomedIn: true, canPanInDirection: false)
        XCTAssertEqual(small, .none, "10 % threshold was not reached")

        var result: GestureIntent = .none
        for _ in 0..<10 where result == .none {
            result = router.routeSwipe(deltaX: -30, viewWidth: viewWidth,
                                       isZoomedIn: true, canPanInDirection: false)
        }
        XCTAssertEqual(result, .nextImage)
    }

    func testOnlyOneSwitchPerGesture() {
        var router = GestureRouter(swipeMode: .smart, switchThreshold: 0.05)
        router.beginGesture()
        var switches = 0
        for _ in 0..<40 {
            if case .nextImage = router.routeSwipe(deltaX: -30, viewWidth: 1000,
                                                   isZoomedIn: false, canPanInDirection: false) {
                switches += 1
            }
        }
        XCTAssertEqual(switches, 1, "a single continuous gesture switches only once")

        router.beginGesture()
        let second = router.routeSwipe(deltaX: -100, viewWidth: 1000,
                                       isZoomedIn: false, canPanInDirection: false)
        XCTAssertEqual(second, .nextImage, "a new gesture may switch again")
    }

    func testSwipeDirectionMapsToPreviousAndNext() {
        var forward = GestureRouter(swipeMode: .smart, switchThreshold: 0.05)
        forward.beginGesture()
        XCTAssertEqual(forward.routeSwipe(deltaX: -100, viewWidth: 1000,
                                          isZoomedIn: false, canPanInDirection: false), .nextImage)

        var backward = GestureRouter(swipeMode: .smart, switchThreshold: 0.05)
        backward.beginGesture()
        XCTAssertEqual(backward.routeSwipe(deltaX: 100, viewWidth: 1000,
                                           isZoomedIn: false, canPanInDirection: false), .previousImage)
    }

    func testAlwaysSwitchModeIgnoresZoomState() {
        var router = GestureRouter(swipeMode: .alwaysSwitch, switchThreshold: 0.05)
        router.beginGesture()
        XCTAssertEqual(router.routeSwipe(deltaX: -100, viewWidth: 1000,
                                         isZoomedIn: true, canPanInDirection: true), .nextImage)
    }

    func testAlwaysPanModeNeverSwitchesButPansWhenZoomed() {
        var router = GestureRouter(swipeMode: .alwaysPan, switchThreshold: 0.05)
        router.beginGesture()
        let zoomed = router.routeSwipe(deltaX: -100, viewWidth: 1000,
                                       isZoomedIn: true, canPanInDirection: true)
        XCTAssertEqual(zoomed, .pan(CGSize(width: -100, height: 0)))
    }

    func testDisabledModeDoesNotSwitchAndDoesNotPanAtFit() {
        var router = GestureRouter(swipeMode: .disabled, switchThreshold: 0.05)
        router.beginGesture()
        XCTAssertEqual(router.routeSwipe(deltaX: -200, viewWidth: 1000,
                                         isZoomedIn: false, canPanInDirection: false), .none)
    }

    func testDisabledModeStillPansWhileZoomed() {
        var router = GestureRouter(swipeMode: .disabled)
        router.beginGesture()
        XCTAssertEqual(router.routeSwipe(deltaX: -12, viewWidth: 1000,
                                         isZoomedIn: true, canPanInDirection: true),
                       .pan(CGSize(width: -12, height: 0)))
    }

    func testZeroWidthViewDoesNothing() {
        var router = GestureRouter()
        XCTAssertEqual(router.routeSwipe(deltaX: -100, viewWidth: 0,
                                         isZoomedIn: false, canPanInDirection: false), .none)
    }
}

/// Trackpad routing while zoomed: a two-finger gesture must move the image.
///
/// The router used to be entered only for events whose horizontal delta happened to
/// exceed the vertical one, and it returned a horizontal-only pan. One gesture was
/// therefore split into pans, zooms and image switches, and panning appeared to
/// change the picture.
final class ZoomedTrackpadPanningTests: XCTestCase {
    func testZoomedPanCarriesBothAxes() {
        var router = GestureRouter(swipeMode: .smart, switchThreshold: 0.1)
        router.beginGesture()
        let intent = router.routeSwipe(deltaX: -6, deltaY: -4, viewWidth: 900,
                                       isZoomedIn: true, canPanInDirection: true)
        XCTAssertEqual(intent, .pan(CGSize(width: -6, height: -4)),
                       "the vertical part of the gesture moves the image too")
    }

    func testZoomedPanNeverSwitchesWhileTheImageCanStillMove() {
        var router = GestureRouter(swipeMode: .smart, switchThreshold: 0.05)
        router.beginGesture()
        for _ in 0..<40 {
            let intent = router.routeSwipe(deltaX: -40, deltaY: -3, viewWidth: 900,
                                           isZoomedIn: true, canPanInDirection: true)
            if case .nextImage = intent {
                XCTFail("panning to the edge of a movable axis must not switch images")
            }
        }
    }

    func testSwitchingStillWorksAfterARealHorizontalOverscroll() {
        var router = GestureRouter(swipeMode: .smart, switchThreshold: 0.1)
        router.beginGesture()
        var result: GestureIntent = .none
        for _ in 0..<20 where result == .none {
            result = router.routeSwipe(deltaX: -40, deltaY: 0, viewWidth: 900,
                                       isZoomedIn: true, canPanInDirection: false)
        }
        XCTAssertEqual(result, .nextImage,
                       "a deliberate horizontal overscroll at the edge still switches")
    }

    /// A portrait image in a wide window cannot pan horizontally at all, which is the
    /// case where the old routing switched on the slightest nudge.
    func testAnAxisThatCannotPanDoesNotSwitchOnASmallNudge() {
        var router = GestureRouter(swipeMode: .smart, switchThreshold: 0.12)
        router.beginGesture()
        let nudge = router.routeSwipe(deltaX: -30, deltaY: 0, viewWidth: 900,
                                      isZoomedIn: true, canPanInDirection: false)
        XCTAssertEqual(nudge, .none, "well below the overscroll threshold")
    }

    func testDisabledModeStillPansBothAxes() {
        var router = GestureRouter(swipeMode: .disabled)
        router.beginGesture()
        XCTAssertEqual(router.routeSwipe(deltaX: -8, deltaY: 3, viewWidth: 900,
                                         isZoomedIn: true, canPanInDirection: false),
                       .pan(CGSize(width: -8, height: 3)))
    }
}

/// Inertia must never navigate.
///
/// After the fingers lift, macOS keeps delivering scroll events as a momentum
/// coast. Accumulating those made a fast flick that ended at the edge switch to the
/// next image after the user had already stopped touching the trackpad - and at Fit
/// it could switch twice for one flick.
final class MomentumCoastingTests: XCTestCase {
    func testMomentumNeverSwitchesWhileZoomed() {
        var router = GestureRouter(swipeMode: .smart, switchThreshold: 0.05)
        router.beginGesture()
        // The finger part of the gesture, deliberately short of the threshold.
        _ = router.routeSwipe(deltaX: -20, deltaY: 0, viewWidth: 900,
                              isZoomedIn: true, canPanInDirection: false, canSwitch: true)
        router.endGesture()

        // Now the coast: a long run of momentum events at the edge.
        for _ in 0..<60 {
            let intent = router.routeSwipe(deltaX: -40, deltaY: 0, viewWidth: 900,
                                           isZoomedIn: true, canPanInDirection: false,
                                           canSwitch: false)
            if case .nextImage = intent {
                XCTFail("coasting momentum must never switch images")
            }
        }
    }

    func testMomentumStillMovesTheImage() {
        var router = GestureRouter(swipeMode: .smart)
        router.beginGesture()
        XCTAssertEqual(router.routeSwipe(deltaX: -12, deltaY: -5, viewWidth: 900,
                                         isZoomedIn: true, canPanInDirection: true,
                                         canSwitch: false),
                       .pan(CGSize(width: -12, height: -5)),
                       "a coast may finish moving the image")
    }

    func testMomentumIsIgnoredAtFit() {
        var router = GestureRouter(swipeMode: .smart, switchThreshold: 0.05)
        router.beginGesture()
        for _ in 0..<60 {
            XCTAssertEqual(router.routeSwipe(deltaX: -40, deltaY: 0, viewWidth: 900,
                                             isZoomedIn: false, canPanInDirection: false,
                                             canSwitch: false),
                           .none,
                           "one flick switches at most once, by the fingers")
        }
    }

    func testAFingerGestureCanStillSwitchWhileFingersAreDown() {
        var router = GestureRouter(swipeMode: .smart, switchThreshold: 0.1)
        router.beginGesture()
        var result: GestureIntent = .none
        for _ in 0..<20 where result == .none {
            result = router.routeSwipe(deltaX: -40, deltaY: 0, viewWidth: 900,
                                       isZoomedIn: true, canPanInDirection: false,
                                       canSwitch: true)
        }
        XCTAssertEqual(result, .nextImage, "a deliberate finger swipe still navigates")
    }

    func testAlwaysSwitchModeAlsoRespectsTheCoastRule() {
        var router = GestureRouter(swipeMode: .alwaysSwitch, switchThreshold: 0.05)
        router.beginGesture()
        XCTAssertEqual(router.routeSwipe(deltaX: -100, deltaY: 0, viewWidth: 900,
                                         isZoomedIn: true, canPanInDirection: true,
                                         canSwitch: false),
                       .none, "even always-switch waits for the fingers")
    }
}

/// Classifying a scroll event is what keeps the two phases apart.
final class ScrollGestureOriginTests: XCTestCase {
    func testMouseWheelIsNotATrackpadGesture() {
        XCTAssertEqual(ImageCanvasView.gestureOrigin(preciseDeltas: false, phase: .changed,
                                                     momentumPhase: []),
                       .mouseWheel)
    }

    func testFingerPhaseIsRecognised() {
        XCTAssertEqual(ImageCanvasView.gestureOrigin(preciseDeltas: true, phase: .began,
                                                     momentumPhase: []),
                       .trackpadFingers)
        XCTAssertEqual(ImageCanvasView.gestureOrigin(preciseDeltas: true, phase: .changed,
                                                     momentumPhase: []),
                       .trackpadFingers)
    }

    func testMomentumPhaseIsRecognisedEvenThoughEventPhaseIsEmpty() {
        // This is the case the router used to treat as an ordinary gesture: after the
        // fingers lift, `phase` is empty and only `momentumPhase` carries information.
        XCTAssertEqual(ImageCanvasView.gestureOrigin(preciseDeltas: true, phase: [],
                                                     momentumPhase: .began),
                       .trackpadMomentum)
        XCTAssertEqual(ImageCanvasView.gestureOrigin(preciseDeltas: true, phase: [],
                                                     momentumPhase: .changed),
                       .trackpadMomentum)
    }
}
