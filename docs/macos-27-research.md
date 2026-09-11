**macOS 27 research for Atelier — September 12, 2026**

macOS 27 Golden Gate offers useful improvements for Atelier’s interface and system integration. I did not find a documented public replacement for the prototypes’ cross-application native tiling, window-to-Space identity, or Desktop management hooks. Keep the existing native-operation approach, validate it on 27, and prioritize a native group selector and App Intents integration.

Apple lists macOS 27.0 RC, build 26A428, released September 9, 2026. This research targets that release candidate. The development machine reports macOS 26.5.2, build 25F84; no macOS 27 runtime validation was performed. [Apple developer releases](https://developer.apple.com/news/releases/)

**What the prototypes currently do**

| Prototype | Implementation reviewed | Relevant boundary |
| --- | --- | --- |
| [Native tiling](../Prototypes/NativeWindowTilingPOC/README.md) | The shared [menu dispatcher](../Prototypes/NativeWindowTilingPOC/Sources/NativeMenuDispatch/NativeMenuDispatcher.swift) searches AX menu identifiers, checks the exact foreground window, and presses the native command. | AX is public, but identifiers such as `_zoomFill:` are undocumented. The retained private WindowManagement experiments have not established arbitrary foreign-window transactions. |
| [Desktop Groups](../Prototypes/NativeWindowTilingPOC/DESKTOP-GROUPS.md) | Ordered, session-only groups per Desktop/display; indexed activation; lazy native Fill; AX observers plus one-second reconciliation. | `_AXUIElementGetWindow` supplies identity; SkyLight supplies Space membership. It has no visible group selector or persistent workspace model. |
| [Space Control](../Prototypes/NativeWindowTilingPOC/SPACE-CONTROL.md) | Native symbolic shortcuts, live temporary hotkey enabling, and Dock AX operations for creation, selection, deletion, and thumbnail dragging. | Space dictionaries, symbolic-hotkey functions, Dock identifiers, and timing assumptions are undocumented. This is the most exposed prototype during an OS upgrade. |

This includes the current uncommitted Space Control work. The research adds documentation only.

**Opportunities, in priority order**

| Priority | Capability | Application to Atelier | Availability and limit |
| --- | --- | --- | --- |
| 1 | Status-item expanded interface sessions | A menu-bar group picker with system-managed keyboard focus and dismissal. | New in macOS 27. Controls Atelier’s interface lifecycle. |
| 1 | Semantic tab roles | A compact, accessible selector for the current group’s members. | New in macOS 27. Supplies UI semantics; Atelier still implements foreign-window activation. |
| 2 | Explicit App Intents execution targets | Invoke group selection and Desktop switching through Shortcuts using the process that owns the session. | New in macOS 27. Does not grant window-management privileges. |
| 2 | SwiftUI scenes inside AppKit | Add a group picker and Settings while retaining the existing AppKit lifecycle. | Available since macOS 26; useful now without a 27-only rewrite. |
| 3 | Expanded native tiling eligibility | Allow explicit tiling of supported standalone Open/Save panels. | New in macOS 27; test separately from automatic group membership. |
| 3 | Display and visual refinements | Let system window placement and standard controls carry more of the native experience. | OS improvements need real display and accessibility testing. |

**1. Give Desktop Groups a native, keyboard-accessible interface**

`NSStatusItem.expandedInterfaceSession` and its delegate let AppKit coordinate showing and dismissing custom status-item UI. Apple documents begin/end callbacks and session cancellation when focus moves elsewhere. Availability metadata identifies macOS 27.0. This is a concrete fit for a group picker opened from the menu bar. [Expanded interface session](https://developer.apple.com/documentation/appkit/nsstatusitem/expandedinterfacesession), [WWDC26 AppKit session, 5:51](https://developer.apple.com/videos/play/wwdc2026/289/?time=351)

Proposal: show numbered members, the active member, and Group/Repair in that picker. Reuse the same command path as the shortcuts. Preserve the target group/window before opening the UI, then explicitly reactivate and revalidate the selected foreign window before native Fill. The existing dispatcher’s foreground-window checks mean opening Atelier UI cannot be treated as an invisible step.

macOS 27 also adds a `role` to `NSSegmentedControl`, including a tabs role with tab-specific appearance and VoiceOver semantics. That makes a small group selector more natural. Use a list for larger groups or long titles. This does not merge windows from unrelated apps into an `NSWindowTabGroup`; it represents Atelier’s own selection model. [Segmented-control role](https://developer.apple.com/documentation/appkit/nssegmentedcontrol/role-swift.property), [macOS 27 release notes](https://developer.apple.com/documentation/macos-release-notes/macos-27-release-notes)

For implementation, `NSHostingSceneRepresentation` can add SwiftUI `MenuBarExtra` and Settings scenes from an existing AppKit delegate. Its documented minimum is macOS 26.0. Apple’s WWDC26 presentation explicitly says these integration APIs are already available on the 2026 releases or earlier. Do not mistake the presentation year for a requirement to adopt macOS 27. [API availability](https://developer.apple.com/documentation/swiftui/nshostingscenerepresentation), [SwiftUI with AppKit, 11:30](https://developer.apple.com/videos/play/wwdc2026/272/?time=690)

**2. Expose existing actions through Shortcuts and Spotlight**

App Intents already provides system entry points. The particularly relevant 27 addition is `allowedExecutionTargets`: an intent can require execution in the main app. That matches the prototypes’ in-memory group state, observers, and serialized commands once they are hosted in an application bundle. `.main` selects the app process; it is not a foreground-focus guarantee or a route into an arbitrary CLI helper. [Execution-target API](https://developer.apple.com/documentation/appintents/appintent/allowedexecutiontargets), [WWDC26 App Intents, 15:27](https://developer.apple.com/videos/play/wwdc2026/345/?time=927)

Start with “Select group member” and “Switch Desktop,” using explicit parameters. A later “Open workspace” could launch apps and invoke existing actions. Named workspace entities require a persistence and identity design; current numeric indexes and session window IDs are insufficient as durable identities. Capture or resolve the intended target explicitly because Spotlight/Siri can change focus before execution. Accessibility permission, exact-target validation, and command serialization still apply.

The new AppIntentsTesting framework exercises intents, entity queries, and Spotlight integrations through system infrastructure. Use it to verify routing and outcomes when adding intents. It does not replace runtime checks that Dock actually changed a Desktop or WindowManager actually tiled the intended window. [AppIntentsTesting session](https://developer.apple.com/videos/play/wwdc2026/295/)

**3. Extend tiling carefully**

Apple’s RC notes say Window > Move & Resize and Window > Full Screen Tile now work with Open/Save panels presented separately from a sheet (150791154). This is a small, direct expansion of what a native tiling command can handle. Test explicit panel tiling before changing eligibility. Desktop Groups currently requires `AXStandardWindow` and deliberately excludes dialogs and panels; automatic grouping should keep that boundary until a specific panel workflow is designed. [macOS 27 release notes](https://developer.apple.com/documentation/macos-release-notes/macos-27-release-notes)

**4. Adopt visual and display improvements without duplicating system behavior**

Apple describes refined Liquid Glass, updated window shapes, improved contrast, and better external-display arrangement persistence, including additional ultrawide modes. These are reasons to prefer standard controls and native placement, and to test reconnecting displays; they do not promise persistence of Atelier’s groups or their Space identities. [macOS 27 overview](https://www.apple.com/os/macos/)

AppKit’s new `cornerConfiguration` / container-concentric radius APIs can make an Atelier panel’s controls follow its container corners. Use them for Atelier-owned UI. Existing AppKit restoration APIs similarly restore an app’s own windows; they do not restore an entire multi-application workspace. [AppKit design and restoration session](https://developer.apple.com/videos/play/wwdc2026/289/)

**What this research did not establish**

After reviewing Apple’s macOS overview, RC release notes, AppKit sessions, and current `NSWindow`/`NSWorkspace` documentation, I found no documented public API that replaces:

- native tiling transactions against arbitrary windows owned by other applications;
- the private AX-to-WindowServer identity bridge or complete foreign-window Space membership;
- creating, deleting, reordering, or directly selecting arbitrary native Desktops.

This is a bounded research finding, not proof that an unlisted capability cannot exist. Public `NSWindow` APIs address the app’s window objects, and existing active-Space notifications do not supply the topology the prototypes consume. [NSWindow](https://developer.apple.com/documentation/appkit/nswindow), [NSWorkspace](https://developer.apple.com/documentation/appkit/nsworkspace)

Foundation Models gains multimodal and model-provider capabilities, but those do not supply missing window-management authority. A future workspace assistant could translate requests into Atelier commands; deterministic selection, tiling, and topology should come first. [Apple’s developer overview](https://developer.apple.com/macos/whats-new/)

One external lead was ruled out: OmniWM’s macOS-27-only “concealment” feature hides menu-bar icons, not group-member windows. It does not solve Desktop Groups visibility. [OmniWM’s own documentation](https://github.com/BarutSRB/OmniWM#hidden-bar)

**Recommended next experiment**

First run a compatibility pass on macOS 27 RC or final using the existing probes and manual checks. Then build a small group picker using native controls, followed by two App Intents routed to the application’s command coordinator. Keep the package’s current macOS 15 baseline until a product decision requires changing it; availability-gate 26/27 UI features.

The compatibility pass should cover:

1. **Identity and topology:** inspect both read-only probes on one and two displays; compare ordered Space IDs, ordinary/fullscreen classification, window membership, and display identifiers with the actual desktop.
2. **Tiling:** repeat left/right/corner/Fill/restore in AppKit, SwiftUI, and Electron apps. Record native-state evidence, restoration deltas, and focus changes. Separately try standalone Open/Save panels.
3. **Groups:** verify independent native Fill restore state across apps and within one app; close, minimize, hide, move, and manually resize members; test display disconnect/reconnect.
4. **Mission Control:** inspect fresh AX identifiers and actions before create/select/delete/reorder tests. Verify number mapping after each topology change, fullscreen traversal, thumbnail stabilization, temporary hotkey restoration, pointer restoration, and normal typing after dismissal. The current 100-ms overview monitor and fixed settle windows need measurement on 27.
5. **Interface:** test keyboard-only selection, VoiceOver, Reduce Motion/Transparency, menu dismissal, and focus handoff back to the selected member.

Apple marks the earlier fullscreen-exit lost-window issue (177660206) and persistent Dock issue (174992242) resolved in the RC. Retain those scenarios as regression checks rather than reporting them as current known failures. [RC release notes](https://developer.apple.com/documentation/macos-release-notes/macos-27-release-notes)

All proposed integrations remain unimplemented and unmeasured. No live Desktop operations were performed for this research.
