Diffusely UI implementation — September 17, 2026

This implements a broad pass from the [UI review](ui-review-2026-09-17.md), with shared presentation rules and distinct touch/desktop interactions. The original review remains a record of the pre-change source assessment. Existing model, indexing, checkpoint, and sorting work in the working tree was preserved.

| Review findings | Implemented behavior |
|---|---|
| 1, 18 — Settings | Mac entry points open the native Settings window. iOS has an explicit Done action. Account, Browsing, Library, Sort Assistant, and Advanced are separate panes/screens. Destructive reset lives in Advanced. Civitai key status says “Key saved,” with inline setup guidance. Credential changes reload gated collections/following. |
| 2, 3 — Authentication and consequences | Biometric actions use the available Face ID/Touch ID method, show unlock progress, and support password submission. Delete wording distinguishes iCloud, local-only storage, and custom folders. Library load failures no longer assume iCloud. |
| 4–7 — Content access | Every nonempty collapsed prompt can expand, including short multiline text. Feed errors have recovery instead of appearing empty; refresh preserves existing items until success. Accessibility labels/actions, selected/followed states, and touch regions were added. Carousel previous/next controls and a bounded page count replace the unbounded dot row; accessibility paging uses the visual paging action. |
| 8, 9 — Details | Remote detail exposes Save/Saving/Saved and Share Link. Saved detail exposes organization/sharing and original-file export, with deletion in More. File provenance is collapsed below useful metadata. Wide detail layouts can place metadata beside media; narrower layouts remain vertical with bounded reading width. Remote creator names open the creator directly. |
| 10, 11 — Mac interaction | Library uses click to select and double-click/Return to open, with Command/Shift range selection and Space preview. Expanded groups participate in keyboard navigation. Remote masonry grids support spatial arrow navigation, retained item focus, and activation. Creator/tag context menus and focused refresh commands are available. |
| 12, 13 — Orientation | Mode controls share a content-row pattern; Following keeps a stable title. Library and collection sort choices persist per scope. Feed period/sort summaries stay visible. Mac remembers each top-level destination’s navigation path during the session. |
| 14–16 — Visual cohesion | Collection covers and captions now resemble album cards, using semantic typography and quieter surfaces. Shared spacing constants, a Mac Library thumbnail-size menu, readable prompt text, wrapping reaction rows, and constrained tag measurement improve density and narrow layouts. |
| 17 — Feedback | Metadata updates share one expandable status row; download warnings and local-only storage notices remain distinct. Completed collection sync strips disappear. Failed Library thumbnails no longer keep spinning. |
| 19, 20 — Editors | New Album opens a dedicated name/description form. Membership pickers are searchable and use one creation entry. Transactional editors protect dirty/in-flight work from interactive dismissal; collection membership shows pending changes and retry controls. Album membership retains its existing batch-on-close behavior. |
| 21 — Sort Assistant | One review commit action, consistent Reject All wording, select/deselect all, persistent Continue, direct Settings access, and a native modal preview replace conflicting or hard-to-reach controls. |
| 22, 23 — Discovery | Local search covers indexed Library creator/model/item ID, album names, collections, following, tags, and membership lists. Empty searches differ from empty scopes. Mac albums appear as sidebar navigation/drop targets. Mixed Library media is labeled All Items. Tag feeds expose Follow/Following. |
| 24 — Motion and native controls | Follow uses native prominent styling. Toolbar symbols are simpler. Preview autoplay has a setting and respects Reduce Motion; custom zoom and paging animations respect Reduce Motion. Mac still-image viewing exposes Zoom In, Zoom Out, and Fit controls. |

The refresh change also clears the previous pagination cursor before replacing a query. If a changed filter fails, its retained images cannot be mixed with a subsequent page fetched using the old cursor.

Validation performed:

- macOS Debug build and 20 focused unit tests passed: selection, search/deletion wording, feed requests and refresh/pagination, wrapping layout, and media sizing.
- iOS simulator Debug build and the same 20 tests plus two UI smoke tests passed. UI tests exercised Settings presentation/dismissal, short multiline prompt expansion, and album-form cancellation.
- The final pagination guard was also rerun on iOS after the main test pass.
- Inspected iPhone dark-mode screenshots of Settings, expanded prompt/shared controls, and the New Album form. The album screenshot includes the simulator’s first-use keyboard tutorial; form assertions and cancellation passed.
- `git diff --check` passed.

Evidence is available locally in `/private/tmp/diffusely-ui-mac-unit.xcresult`, `/private/tmp/diffusely-ui-ios-final.xcresult`, and `/private/tmp/diffusely-ui-ios-refresh.xcresult`. Screenshots are in `/private/tmp/diffusely-ui-ios-final-screenshots/`. The deterministic `--ui-review` Debug launch surface uses an in-memory model container and avoids Library scanning and live feed loading.

Mac UI automation launched its runner but stalled before producing test results. That run was stopped; it is **not** counted as passing. Mac unit tests subsequently ran successfully without the UI runner.

Remaining design and validation work:

- Exact scroll restoration across Mac sections is not implemented; navigation paths and scoped sort preferences are restored. Separating Group By from Sort remains a larger optional interaction change.
- Thumbnail-size customization currently applies to the Mac Library. A common density preference across every remote grid, a phone list/grid switch, and complete badge-position normalization remain possible refinements.
- Search uses data already available locally. Full prompt search would require indexing additional metadata. Original-file export is exposed for saved Library items; remote media still uses Save to Library and source-link sharing.
- This pass does not claim a completed accessibility or visual audit on every supported configuration. Hands-on checks remain for VoiceOver focus, Switch Control, maximum Dynamic Type, light/increased-contrast appearance, iPad multitasking, narrow/wide Mac windows, grouped keyboard selection, drag/drop, media gestures, and large libraries.
- Live-account membership failures, biometric devices, and cloud/custom-folder transitions need runtime verification with representative accounts and hardware. Those flows were source-reviewed, not exercised against personal data during automated testing.

No commit or release was created.

Album navigation follow-up: the Mac Library now opens only the complete media
grid. Its former Albums mode is a separate All Albums sidebar destination,
alongside a permanent Not in Any Album destination and individually selectable
albums. All sidebar rows use one selection type with stable album UUIDs, and
changing destinations resets scoped view state and the Library navigation path.
Library grids no longer automatically focus/select their first item. The smart
album tile remains available even when its count is zero. iOS retains its
in-content Library switcher because it has no corresponding album sidebar.

Follow-up validation: Mac and iOS simulator builds passed, and all 12 tests in
LibraryAlbumFilterTests and LibrarySelectionTests passed on Mac. No additional
Mac UI automation run was performed for this follow-up.
