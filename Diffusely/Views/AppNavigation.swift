import SwiftUI

/// A pushable destination in any of the app's navigation stacks.
///
/// Every push in the app goes through a `Route` appended to a
/// `NavigationRouter.path`, on both platforms. This replaces two older
/// mechanisms that each caused stack-collapsing bugs:
///
///  - The macOS `FeedNavigator` held ONE slot per destination type at the
///    NavigationStack root, so a second push of the same type replaced the
///    presented view instead of deepening the stack — and pushing from an
///    intermediate view collapsed everything between it and the root. Every
///    intermediate view grew local `@State pushedX` + `navigationDestination`
///    workarounds plus `onSelectX` closure plumbing to dodge this.
///  - iOS presented everything via chained `fullScreenCover`s: no edge
///    swipe-back, no back button, and a stack of custom X buttons.
///
/// A path-based stack gives arbitrary-depth push chains (feed → image → user
/// → post → …) with back walking one level at a time, for free.
///
/// NOTE: `NavigationLink(destination:)` must not be used in a stack whose
/// path can be pushed to by the router — appending to the path while a
/// destination-based link's view is on top rebuilds the stack from the path
/// and drops that view. Use `NavigationLink(value: Route…)` there instead.
/// (The Library stack keeps plain links because nothing in it routes.)
enum Route: Hashable {
    case image(CivitaiImage)
    /// An image opened from a feed grid, carrying the surrounding loaded
    /// slice so the detail view supports next/previous paging. The slice is
    /// captured at tap time; pages loaded afterward don't extend it.
    case browse(images: [CivitaiImage], index: Int)
    case post(CivitaiPost)
    case user(CivitaiUser)
    case tag(id: Int, name: String, videos: Bool)
    case collection(CivitaiCollection)
}

/// The programmatic push surface for the enclosing `NavigationStack`.
/// Injected via `.environmentObject` at each stack root.
@MainActor
final class NavigationRouter: ObservableObject {
    @Published var path: [Route] = []

    func push(_ route: Route) {
        path.append(route)
    }

    func popToRoot() {
        path.removeAll()
    }
}

/// Namespace for the iOS zoom navigation transition (grid thumbnail morphs
/// into the detail view, Photos-style). Owned by each stack root and read by
/// both the source cells and the pushed destination, which live at different
/// levels of the hierarchy. nil on macOS (no zoom transition there) and in
/// any stack that doesn't opt in — the helpers below then no-op.
private struct ZoomTransitionNamespaceKey: EnvironmentKey {
    static let defaultValue: Namespace.ID? = nil
}

extension EnvironmentValues {
    var zoomTransitionNamespace: Namespace.ID? {
        get { self[ZoomTransitionNamespaceKey.self] }
        set { self[ZoomTransitionNamespaceKey.self] = newValue }
    }
}

extension View {
    /// Marks this view as the visual origin of a zoom push (iOS only).
    /// `id` must match the destination's `zoomTransition(sourceID:)` — image
    /// and post ids are both Ints, so callers prefix them ("image-1", "post-1")
    /// to keep the namespace collision-free.
    @ViewBuilder
    func zoomTransitionSource(id: String, in namespace: Namespace.ID?) -> some View {
        #if os(iOS)
        if let namespace {
            matchedTransitionSource(id: id, in: namespace)
        } else {
            self
        }
        #else
        self
        #endif
    }

    /// Makes this pushed destination zoom out of the matching source (iOS only).
    @ViewBuilder
    func zoomTransition(sourceID: String?, in namespace: Namespace.ID?) -> some View {
        #if os(iOS)
        if let sourceID, let namespace {
            navigationTransition(.zoom(sourceID: sourceID, in: namespace))
        } else {
            self
        }
        #else
        self
        #endif
    }
}

/// Maps a `Route` to its destination view. Attached once at each stack root.
struct RouteDestinationView: View {
    let route: Route
    @Environment(\.zoomTransitionNamespace) private var zoomNamespace

    var body: some View {
        switch route {
        case .image(let image):
            ImageDetailView(image: image)
                .zoomTransition(sourceID: "image-\(image.id)", in: zoomNamespace)
        case .browse(let images, let index):
            // The zoom pairs with the cell that was tapped (the initial index),
            // so paging away and going back still lands on that cell.
            let tappedID = images.indices.contains(index) ? "image-\(images[index].id)" : nil
            ImageDetailView(images: images, initialIndex: index)
                .zoomTransition(sourceID: tappedID, in: zoomNamespace)
        case .post(let post):
            PostDetailView(post: post)
                .zoomTransition(sourceID: "post-\(post.id)", in: zoomNamespace)
        case .user(let user):
            UserContentView(user: user)
        case .tag(let id, let name, let videos):
            TagFeedView(tagId: id, tagName: name, videos: videos)
        case .collection(let collection):
            CollectionDetailView(collection: collection)
        }
    }
}

extension View {
    /// Registers the app-wide `Route` destinations on this stack's root.
    func routeDestinations() -> some View {
        navigationDestination(for: Route.self) { route in
            RouteDestinationView(route: route)
        }
    }
}

/// A `NavigationStack` that owns a router, registers the app's route
/// destinations, and exposes the router to its subtree. Used for each iOS
/// tab; the macOS split-view detail column wires the same pieces manually
/// because it needs the router for section-change resets.
struct RoutedNavigationStack<Root: View>: View {
    @StateObject private var router = NavigationRouter()
    @Namespace private var zoomNamespace
    @ViewBuilder var root: () -> Root

    var body: some View {
        NavigationStack(path: $router.path) {
            root()
                .routeDestinations()
        }
        .environmentObject(router)
        // Powers the iOS zoom push (cell → detail). Applied to the stack so
        // both root cells and pushed destinations read the same namespace.
        .environment(\.zoomTransitionNamespace, zoomNamespace)
    }
}
