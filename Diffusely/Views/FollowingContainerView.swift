import SwiftUI

/// Which segment of the Following section is showing.
enum FollowingSegment: String, CaseIterable, Identifiable {
    case users = "Users"
    case tags = "Tags"

    var id: Self { self }
}

/// Hosts the Users and Tags lists as two segments of one section.
///
/// They share a section rather than each taking a top-level slot because iOS
/// collapses a 6th tab into a system "More" tab, which would have buried both
/// Tags and Library on iPhone. macOS uses the same structure so the two
/// platforms don't drift.
///
/// The children set their own `navigationTitle` and toolbar items, which
/// propagate up to the enclosing stack — so the title and the Add Tag button
/// follow the selected segment without this view coordinating them.
struct FollowingContainerView: View {
    @AppStorage("followingSegment") private var segment: FollowingSegment = .users

    var body: some View {
        VStack(spacing: 0) {
            Picker("Section", selection: $segment) {
                ForEach(FollowingSegment.allCases) { segment in
                    Text(segment.rawValue).tag(segment)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal)
            .padding(.vertical, 8)

            Divider()

            switch segment {
            case .users:
                FollowingView()
            case .tags:
                TagsView()
            }
        }
    }
}
