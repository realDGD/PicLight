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
