# Grid Video Poster Frames + On-Demand Playback Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stop grid cells from autoplaying every video at once — show still poster frames, and play a single video on demand (hover on macOS, tap-to-detail on iOS).

**Architecture:** The grid cell's media becomes a `ZStack` with the poster always underneath. On macOS a muted, looping `CachedVideoPlayer` is inserted on top only while a hover survives a ~300 ms intent debounce; un-hovering removes it (pausing the cached player). Because the player's `onAppear` is what triggers the video load, gating the player also gates the download/decode. iOS compiles to poster-only + tap.

**Tech Stack:** SwiftUI, AVKit (`CachedVideoPlayer`), swift-testing (`import Testing`), Xcode `Diffusely` scheme (iOS + macOS targets).

**Reference spec:** `docs/superpowers/specs/2026-07-05-grid-video-hover-preview-design.md`

**Build/test commands (isolated DerivedData so a live Xcode debug session is untouched):**

```bash
DD=/tmp/diffusely-plan-dd
# macOS unit tests, one suite:
xcodebuild test -project Diffusely.xcodeproj -scheme Diffusely \
  -destination 'platform=macOS' -derivedDataPath "$DD" \
  -only-testing:DiffuselyTests/<SuiteName> 2>&1 | grep -E "Test case|passed|failed|TEST (SUCCEEDED|FAILED)|error:"
# iOS compile check:
xcodebuild build -project Diffusely.xcodeproj -scheme Diffusely \
  -destination 'platform=iOS Simulator,name=iPad (A16),OS=26.5' -derivedDataPath "$DD" 2>&1 | grep -E "error:|BUILD (SUCCEEDED|FAILED)"
```

---

### Task 1: `HoverIntent` debounce model

A tiny `@MainActor ObservableObject` that arms `isArmed = true` only if a hover survives a delay. Delay is injectable so tests use `.zero`; `begin()` returns its `Task` so tests can await it deterministically (no test-only methods, no sleeping in tests).

**Files:**
- Create: `Diffusely/Views/HoverIntent.swift`
- Test: `DiffuselyTests/HoverIntentTests.swift`

- [ ] **Step 1: Write the failing tests**

Create `DiffuselyTests/HoverIntentTests.swift`:

```swift
import Testing
@testable import Diffusely

@MainActor
@Suite struct HoverIntentTests {
    /// A hover that lasts past the delay arms the intent.
    @Test func sustainedHoverArms() async {
        let intent = HoverIntent(delay: .zero)
        await intent.begin().value
        #expect(intent.isArmed)
    }

    /// A hover cancelled before the delay elapses never arms.
    @Test func quickHoverDoesNotArm() async {
        let intent = HoverIntent(delay: .milliseconds(100))
        let pending = intent.begin()
        intent.cancel()
        await pending.value
        #expect(!intent.isArmed)
    }

    /// cancel() after arming disarms.
    @Test func cancelAfterArmingDisarms() async {
        let intent = HoverIntent(delay: .zero)
        await intent.begin().value
        #expect(intent.isArmed)
        intent.cancel()
        #expect(!intent.isArmed)
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run:
```bash
DD=/tmp/diffusely-plan-dd
xcodebuild test -project Diffusely.xcodeproj -scheme Diffusely -destination 'platform=macOS' -derivedDataPath "$DD" -only-testing:DiffuselyTests/HoverIntentTests 2>&1 | grep -E "error:|TEST (SUCCEEDED|FAILED)"
```
Expected: build error — `Cannot find 'HoverIntent' in scope`.

- [ ] **Step 3: Write the implementation**

Create `Diffusely/Views/HoverIntent.swift`:

```swift
import Combine

/// Debounces pointer hover so a video preview starts only when the hover is
/// deliberate. `begin()` arms `isArmed` after `delay` unless `cancel()` (or a
/// newer `begin()`) intervenes first. `delay` is injectable for tests; `begin()`
/// returns its `Task` so callers/tests can await the pending arm.
@MainActor
final class HoverIntent: ObservableObject {
    @Published private(set) var isArmed = false

    private let delay: Duration
    private var task: Task<Void, Never>?

    init(delay: Duration = .milliseconds(300)) {
        self.delay = delay
    }

    @discardableResult
    func begin() -> Task<Void, Never> {
        task?.cancel()
        let delay = self.delay
        let task = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: delay) } catch { return }  // cancelled
            self?.isArmed = true
        }
        self.task = task
        return task
    }

    func cancel() {
        task?.cancel()
        task = nil
        isArmed = false
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run the Step 2 command.
Expected: `** TEST SUCCEEDED **`, all three `HoverIntentTests` pass.

- [ ] **Step 5: Commit**

```bash
git add Diffusely/Views/HoverIntent.swift DiffuselyTests/HoverIntentTests.swift
git commit -m "Add HoverIntent hover-debounce with tests"
```

---

### Task 2: Transparent loading state for `CachedVideoPlayer`

Add `showsLoadingPlaceholder: Bool = true`. When `false`, the `.idle`/`.loading` states render `Color.clear` instead of the opaque black+spinner, so a hover preview shows the poster underneath until the first video frame is ready. The `.idle` state must still trigger the media load. This is a view-only change with no branchable logic to unit-test; it is verified by compilation here and by manual verification in Task 5.

**Files:**
- Modify: `Diffusely/Views/CachedVideoPlayer.swift`

- [ ] **Step 1: Add the property and initializer parameter**

In `CachedVideoPlayer`, add the stored property after `let onTap: (() -> Void)?`:

```swift
    let showsLoadingPlaceholder: Bool
```

Replace the initializer with:

```swift
    init(url: String, autoPlay: Bool = true, isMuted: Bool = true, showsLoadingPlaceholder: Bool = true, onTap: (() -> Void)? = nil) {
        self.url = url
        self.autoPlay = autoPlay
        self.isMuted = isMuted
        self.showsLoadingPlaceholder = showsLoadingPlaceholder
        self.onTap = onTap
    }
```

- [ ] **Step 2: Add a placeholder subview**

Add this computed property inside `CachedVideoPlayer` (e.g. just above `var body`):

```swift
    @ViewBuilder
    private var loadingPlaceholder: some View {
        if showsLoadingPlaceholder {
            Rectangle()
                .fill(Color.black)
                .overlay(ProgressView().tint(.white))
        } else {
            Color.clear
        }
    }
```

- [ ] **Step 3: Use the placeholder in the `.idle` and `.loading` states**

Replace the `.idle` case body with (keeps the load trigger):

```swift
            case .idle:
                loadingPlaceholder
                    .onAppear {
                        state = mediaCache.getMediaState(for: url)
                        mediaCache.loadMedia(url: url, isVideo: true)
                    }
```

Replace the `.loading` case body with:

```swift
            case .loading:
                loadingPlaceholder
```

- [ ] **Step 4: Build to verify it compiles**

Run:
```bash
DD=/tmp/diffusely-plan-dd
xcodebuild build -project Diffusely.xcodeproj -scheme Diffusely -destination 'platform=macOS' -derivedDataPath "$DD" 2>&1 | grep -E "error:|BUILD (SUCCEEDED|FAILED)"
```
Expected: `** BUILD SUCCEEDED **`. Existing call sites keep the default `true`, so no behavior change elsewhere.

- [ ] **Step 5: Commit**

```bash
git add Diffusely/Views/CachedVideoPlayer.swift
git commit -m "Add transparent loading option to CachedVideoPlayer"
```

---

### Task 3: `FeedGridMedia` subview (poster base + macOS hover player)

A focused subview that renders the poster by default and, on macOS only, overlays a muted looping player once `HoverIntent` arms. iOS compiles to poster-only. Not unit-tested (pure view wiring — its one logic dependency, `HoverIntent`, is tested in Task 1); verified by build here and manual verification in Task 5.

**Files:**
- Create: `Diffusely/Views/FeedGridMedia.swift`

- [ ] **Step 1: Create the subview**

Create `Diffusely/Views/FeedGridMedia.swift`:

```swift
import SwiftUI

/// The media layer of a grid cell: a still poster by default, with an on-demand
/// video preview. Sized by the caller (`width`×`height`) so the hover swap never
/// reflows. macOS: hovering a video past HoverIntent's delay fades in a muted,
/// looping preview; un-hovering removes it (pausing the cached player). iOS: no
/// hover — the poster stays and the caller's tap opens the detail view.
struct FeedGridMedia: View {
    let image: CivitaiImage
    let width: CGFloat
    let height: CGFloat

    #if os(macOS)
    @StateObject private var hover = HoverIntent()
    #endif

    var body: some View {
        ZStack {
            poster

            #if os(macOS)
            if image.isVideo && hover.isArmed {
                CachedVideoPlayer(
                    url: image.detailURL,
                    autoPlay: true,
                    isMuted: true,
                    showsLoadingPlaceholder: false
                )
                .frame(width: width, height: height)
                .clipped()
                .allowsHitTesting(false)
                .transition(.opacity)
            }
            #endif
        }
        #if os(macOS)
        .contentShape(Rectangle())
        .animation(.easeInOut(duration: 0.2), value: hover.isArmed)
        .onHover { hovering in
            guard image.isVideo else { return }
            if hovering { hover.begin() } else { hover.cancel() }
        }
        .onDisappear { hover.cancel() }
        #endif
    }

    /// Still frame for both stills and videos. Videos use `thumbnailURL` (the
    /// CDN's `anim=false` frame); stills use `detailURL` as before.
    @ViewBuilder
    private var poster: some View {
        CachedAsyncImage(url: image.isVideo ? image.thumbnailURL : image.detailURL)
            .aspectRatio(contentMode: .fill)
            .frame(width: width, height: height)
            .clipped()
    }
}
```

- [ ] **Step 2: Build to verify it compiles on both platforms**

Run:
```bash
DD=/tmp/diffusely-plan-dd
xcodebuild build -project Diffusely.xcodeproj -scheme Diffusely -destination 'platform=macOS' -derivedDataPath "$DD" 2>&1 | grep -E "error:|BUILD (SUCCEEDED|FAILED)"
xcodebuild build -project Diffusely.xcodeproj -scheme Diffusely -destination 'platform=iOS Simulator,name=iPad (A16),OS=26.5' -derivedDataPath "$DD" 2>&1 | grep -E "error:|BUILD (SUCCEEDED|FAILED)"
```
Expected: `** BUILD SUCCEEDED **` for both. (`FeedGridMedia` is not referenced yet; this confirms it compiles standalone, including the iOS poster-only branch.)

- [ ] **Step 3: Commit**

```bash
git add Diffusely/Views/FeedGridMedia.swift
git commit -m "Add FeedGridMedia poster + macOS hover-preview subview"
```

---

### Task 4: Route `gridContent` through `FeedGridMedia`

Replace the inline autoplaying video / image branch in `ImageFeedItemView.gridContent` with `FeedGridMedia`. Overlays and the tap target stay. This is the change that removes the autoplay wall. View-only; verified by build + manual verification in Task 5.

**Files:**
- Modify: `Diffusely/Views/ImageFeedItemView.swift` (the `gridContent` computed property)

- [ ] **Step 1: Replace the media branch**

In `gridContent`, find this block inside the `ZStack` (the `if image.isVideo { … } else { … }`):

```swift
                if image.isVideo {
                    CachedVideoPlayer(
                        url: image.detailURL,
                        autoPlay: true,
                        isMuted: true
                    )
                    .frame(width: geometry.size.width, height: displayHeight)
                    .clipped()
                    .allowsHitTesting(false)
                } else {
                    CachedAsyncImage(url: image.detailURL)
                        .aspectRatio(contentMode: .fill)
                        .frame(width: geometry.size.width, height: displayHeight)
                        .clipped()
                }
```

Replace it with:

```swift
                FeedGridMedia(
                    image: image,
                    width: geometry.size.width,
                    height: displayHeight
                )
```

Leave everything else in `gridContent` unchanged: the `Color.clear` tap target (`openImageDetail()`) stays directly after `FeedGridMedia` so taps still land on it, and the overlays `VStack` (video badge, ellipsis, username) is unchanged.

- [ ] **Step 2: Build both platforms**

Run:
```bash
DD=/tmp/diffusely-plan-dd
xcodebuild build -project Diffusely.xcodeproj -scheme Diffusely -destination 'platform=macOS' -derivedDataPath "$DD" 2>&1 | grep -E "error:|BUILD (SUCCEEDED|FAILED)"
xcodebuild build -project Diffusely.xcodeproj -scheme Diffusely -destination 'platform=iOS Simulator,name=iPad (A16),OS=26.5' -derivedDataPath "$DD" 2>&1 | grep -E "error:|BUILD (SUCCEEDED|FAILED)"
```
Expected: `** BUILD SUCCEEDED **` for both.

- [ ] **Step 3: Commit**

```bash
git add Diffusely/Views/ImageFeedItemView.swift
git commit -m "Show poster + on-demand video in grid cells (no autoplay wall)"
```

---

### Task 5: Full verification (tests + both targets + manual)

**Files:** none (verification only)

- [ ] **Step 1: Run the full test target on macOS**

Run:
```bash
DD=/tmp/diffusely-plan-dd
xcodebuild test -project Diffusely.xcodeproj -scheme Diffusely -destination 'platform=macOS' -derivedDataPath "$DD" -only-testing:DiffuselyTests 2>&1 | grep -E "TEST (SUCCEEDED|FAILED)|failed|error:"
```
Expected: `** TEST SUCCEEDED **`; `HoverIntentTests` and `ImageFeedItemAspectRatioTests` pass; nothing else regressed.

- [ ] **Step 2: Manual verification — macOS**

Run the macOS app, open a video-heavy grid (e.g. the Videos feed). Confirm:
  - At rest, cells show still posters (no motion), each with the video badge.
  - Hovering a video cell starts it playing (muted, looping) after a brief moment; moving the pointer away returns it to the poster.
  - Only the hovered cell plays. Scrolling a hovered cell out of view stops it.
  - No layout jump when the preview appears/disappears.
  - In Activity Monitor (or `sample <pid>`), an idle grid no longer shows a large number of `com.apple.coremedia.videomediaconverter` threads.

- [ ] **Step 3: Manual verification — iOS**

Run the iOS app (simulator or device), open the grid. Confirm:
  - Video cells show still posters with the badge; nothing autoplays in the grid.
  - Tapping a video opens the detail view and it plays there.
  - Tapping a still image opens its detail as before.

- [ ] **Step 4: Final confirmation**

No code changes here; all commits already landed in Tasks 1–4. Confirm `git status` is clean and `git log --oneline -5` shows the four feature commits.

---

## Notes for the implementer

- **Why poster underneath, player on top:** the poster (`CachedAsyncImage`) is always in the `ZStack`; the player is inserted above it only while hovering. With `showsLoadingPlaceholder: false`, the player is transparent until its first frame, so the poster shows through — no black flash, no reflow (identical `width`×`height`).
- **Why no coordinator:** hover is inherently single, so only the hovered cell ever has a player in the tree. `HoverIntent.cancel()` on `.onDisappear` is the safety net for a cell scrolled away mid-hover.
- **iOS:** the `#if os(macOS)` blocks compile out, leaving `FeedGridMedia` as poster-only; the caller's existing `Color.clear` tap target drives `openImageDetail()`.
- **Out of scope (per spec):** list mode (`listContent`) inline video, sound in previews, hiding the badge during playback.
