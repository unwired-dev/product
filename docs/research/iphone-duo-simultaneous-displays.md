---
status: research
---

# iPhone Duo simultaneous display feasibility

Research date: **2026-11-11**, against the iOS 27.2 SDK in Xcode 27.2 (27B52) and
Apple's published iPhone Duo material. This note answers
[#1660](https://github.com/unwired-dev/product/issues/1660) for the
[iPhone Duo requirements](../product/iphone-duo.md). It contains no implementation
approval or qualification evidence.

## Verdict

**Unsupported.** No supported public API lets a non-camera app show mail on the
outer display while the app runs on the inner display. The only route Apple
documents is a camera capture accessory, which needs an active capture session,
so the requirements rule it out.

## Three kinds of "both displays"

- **Physical displays.** iPhone Duo shows an app on either the outer or the inner
  display. As the device opens and closes, "content transitions between displays"
  ([Preparing your app][prepare]). Showing content on the outer display while
  the device is open is the question this note answers.
- **Inner-display panes.** Split views, arrangement views and the folding region
  divide the inner display. Both sides stay interactive, and the
  [optimized Duo release](../product/iphone-duo.md#displays-and-tabletop-behavior)
  already covers tabletop reading and replying. These panes are one physical
  display, not two.
- **Independent app windows.** Duo supports multiple scenes as iPad does, but
  "on the outer display of iPhone Duo, new windows cannot be created"
  ([tech talk 111464][talk]). Additional windows are inner-display Split View
  instances. They stay under [#1200](https://github.com/unwired-dev/product/issues/1200).

## Findings

- **Scene accessories are the only API that spans displays.** Apple's tech talk
  says "scene accessories allow your app to show content on multiple displays at
  the same time" ([talk]). Apps register them with
  `UIViewController.registerSceneAccessory(_:)` or SwiftUI `sceneAccessory(content:)`.
  The system decides whether and where to present an accessory, and "the app must
  remain fully functional without them" ([UISceneAccessory][uisceneaccessory]).
- **The iOS 27.2 SDK has exactly two accessory kinds.** `UISceneAccessory`
  factories create only `externalNonInteractive(sceneConfiguration:)` and
  `cameraCapture(sceneConfiguration:)` accessories, each with a `userInfo:`
  variant. The only SwiftUI accessory structs are
  `ExternalNonInteractiveAccessory` and `CameraCaptureAccessory`. The SDK also has
  no outer-display scene session role. UIKit's current iOS window scene roles are
  application, external-display non-interactive, Assistive Access and
  `windowCameraCaptureAccessory` (iOS 27.1; the system assigns it to camera
  accessory scenes). The CarPlay roles target a car display.
- **An external accessory needs a connected display.** `ExternalNonInteractiveAccessory`
  "may be presented when an external display is connected to the device, or when
  the device is connected to an external display via AirPlay"
  ([ExternalNonInteractiveAccessory][external]). Apple's camera accessory guide
  says that the two kinds "never compete". An app can show slides on a connected
  display while it shows capture content on the outer display at the same time
  ([Registering a camera capture accessory][camera]). The external kind
  therefore does not target the outer display.
- **The camera accessory needs a capture session.** The accessory appears only
  "while your app is in the foreground with an active capture session, while the
  capture interface runs on the inner display". Content goes away "when capture
  stops, when your app leaves the foreground, or when someone folds the device
  closed" ([camera]). The tech talk also requires the app to be "full screen on
  the inner display", so Split View rules the accessory out ([talk]). Apple adds
  that "Simulator doesn't have a camera". An app
  cannot use this route without a camera session, so the requirements exclude it.
- **Availability belongs to the system.** "The system dynamically controls the
  availability of these accessories … can be toggled at any time"; apps observe
  it with `onAvailabilityChange(perform:)` ([talk]) or the read-only `available`
  property of `UISceneAccessoryRegistration`. An Apple DTS answer in the
  [iPhone Duo Group Lab thread][lab] states that non-camera apps can use the
  outer display while unfolded "only via the system-controlled scene accessory
  mechanism — not by drawing on the outer display directly". It also says apps
  "can't override system presentation decisions".
- **Other system surfaces do not carry mail.** Another answer in the same thread
  names AlarmKit as the other outer-display route in tent mode, and AlarmKit is limited
  to alarms and timers. Live Activities appear in the outer display's Dynamic
  Island, but Apple does not document a Live Activity presentation on the outer
  display while the device is open. The HIG also limits Live Activities to "tasks
  and events that have a defined beginning and end" ([Live Activities][hig-live]),
  which excludes mirroring an inbox or a Thread. Picture in Picture "moves to the
  outer display only when the device is closed" ([lab]).
- **The client stack adds no route.** The selected React Native 0.88 and Expo
  SDK 58 packages have no scene accessory API.
  [Expo's Duo guide](https://expo.dev/blog/supporting-iphone-duo) reads hinge and
  reserved-region data through the separate `expo-hinge` and
  `react-native-reserved-regions` libraries, which the app does not use. The
  React Native 0.88 release notes limit support to a single scene and keep
  `UIApplicationSupportsMultipleScenes` set to `false`. Apple says accessory
  scenes need no project-level configuration, so that limit's effect on an
  accessory scene is untested. A supported accessory kind would need a native
  module, which no current kind justifies.

## Limitations

- Because no plausible non-camera route exists, this investigation built no
  native integration. The criteria require that check only for a plausible route.
- No hardware evidence was recorded. This host has no physical iPhone Duo. Its
  only simulator runtime, iOS 27.0 (24A434), does not support the
  `iPhone-Duo` device type that Xcode 27.2 lists. A Duo simulator needs an
  iOS 27.1 or later runtime. A simulator could not show camera accessories anyway.
- The verdict rests on Apple's documentation, the iOS 27.2 SDK headers and
  interfaces, and Apple's own forum answers. The tech talk and Group Lab are
  Apple sources, but undocumented system behavior, such as an unannounced outer
  display Live Activity, could still differ on hardware. No supported API
  depends on such behavior.

## Revisit condition

Reopen the question when an iOS SDK adds a `UISceneAccessory` factory or a
`SceneAccessoryContent` type that presents on the outer display without a
capture session, adds an outer-display scene session role, or Apple documents
non-camera content on the outer display while the device is open. To check an SDK,
list the accessory kinds the `UISceneAccessory` factories create in
`UIKit.framework/Headers/UISceneAccessory.h` and the public accessory structs
that conform to `SceneAccessoryContent` in SwiftUI's `.swiftinterface`.

If a route appears, implementation still needs workflow, consent, ownership,
privacy, disable and remove, offline, and late-result decisions first. The
optimized Duo release does not depend on this verdict.

[prepare]: https://developer.apple.com/documentation/technologyoverviews/preparing-your-app-for-iphone-duo
[talk]: https://developer.apple.com/videos/play/tech-talks/111464/
[uisceneaccessory]: https://developer.apple.com/documentation/uikit/uisceneaccessory
[external]: https://developer.apple.com/documentation/swiftui/externalnoninteractiveaccessory
[camera]: https://developer.apple.com/documentation/avfoundation/registering-a-camera-capture-accessory-on-iphone-duo
[lab]: https://developer.apple.com/forums/thread/847644
[hig-live]: https://developer.apple.com/design/human-interface-guidelines/live-activities
