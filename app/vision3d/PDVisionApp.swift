// PDVisionApp.swift — the visionOS process entry point (D-047).
//
// An ImmersiveSpace can only be declared by a SwiftUI `App`, so on visionOS —
// and ONLY on visionOS — the app entry is SwiftUI. It does nothing but scene
// plumbing: the WindowGroup hosts PDHostViewController, which boots the
// existing ObjC/SDL shell exactly as before, and the ImmersiveSpace declares
// the CompositorServices layer whose render thread is PDImmersive.m. Every
// decision the app makes still lives in C/ObjC.
//
// FILENAME. This file must NOT be called main.swift: Swift treats a file with
// that exact name as top-level code, which collides with @main ("'main'
// attribute cannot be used in a module that contains top-level code").
// sm64coopdx paid for that one in its build spike.
//
// WHY THERE IS NO SCENE DELEGATE HERE. Info-visionos.plist keeps
// UIApplicationSceneManifest (with UIApplicationSupportsMultipleScenes inside
// it, where it has to be) but declares NO UISceneConfigurations: SwiftUI
// declares its own scenes below. PDSceneDelegate is compiled out of this target
// altogether, which is deliberate — UIKit persists a scene session's
// configuration name and delegate CLASS NAME across installs of the same
// bundle id, so the user's headset, which has run the Phase-5 builds, will try to
// restore a session naming PDSceneDelegate. With the class absent the lookup
// fails and UIKit falls back to the app delegate's configuration, which is
// SwiftUI's. That is the vkQuake/q2repro fix (NOTES-FROM-VKQUAKE), and a fresh
// simulator never reproduces the problem it solves.

import SwiftUI
import CompositorServices

// The state the ObjC side flips to open and close the space. @Published on the
// main actor; PD_SetImmersiveMode hops there for callers on any thread.
final class PDAppModel: ObservableObject {
    static let shared = PDAppModel()
    @Published var immersive = false
    /// One open/dismiss at a time, however many root views are observing.
    ///
    /// M4 earned this: visionOS can disconnect and re-connect the window scene
    /// around an immersive dismissal, and for one round the shell answered that
    /// by asking for a scene back — which left TWO window scenes, two
    /// PDRootViews, and two `openImmersiveSpace` calls on the next entry. The
    /// second returned a bare `.error`, which rolled the shell straight back
    /// out of 3D. The cause is fixed in PDHostViewController (only re-activate
    /// when the LAST scene went away); this is the cheap guard that keeps a
    /// duplicate view from being able to do it again. Main actor only.
    var spaceBusy = false
    /// The 3D settings sheet (M6). Flipped by the ornament's gear and by
    /// PD_SetSettingsSheet, which is how the bridge and the 3D exit reach it.
    @Published var settingsSheet = false
}

/// Called from PDHostViewController.m (pdVision3dSetMode) to flip the SwiftUI
/// state that actually opens or dismisses the space.
@_cdecl("PD_SetImmersiveMode")
func PD_SetImmersiveMode(_ on: Bool) {
    DispatchQueue.main.async { PDAppModel.shared.immersive = on }
}

/// Called from pdVision3dSettingsSheetRequest() — the ornament's gear, the
/// bridge's `3d settings open|close`, and the 3D exit's own close-first
/// ordering all arrive here.
@_cdecl("PD_SetSettingsSheet")
func PD_SetSettingsSheet(_ on: Bool) {
    DispatchQueue.main.async { PDAppModel.shared.settingsSheet = on }
}

/// Hosts the settings table (UIKit) inside the sheet: the WHOLE settings page
/// since D-082 — the iOS sections, then the 3D rows under their own
/// "3D Settings | Reset" header.
///
/// A UIKit modal presented directly over an open immersive space silently
/// fails, which is why this is a SwiftUI `.sheet` around a UIKit table rather
/// than the table presenting itself (SETTINGS-SPEC :13-37).
struct PDSettingsTableView: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> PDVisionSettingsViewController {
        return PDVisionSettingsViewController()
    }
    func updateUIViewController(_ vc: PDVisionSettingsViewController, context: Context) {}
}

/// The sheet: our own header bar, then the table.
///
/// LAYOUT TRAPS, both paid for twice in the family (SETTINGS-SPEC :13-37):
///   * never force a HEIGHT on sheet content — SwiftUI centre-CLIPS content
///     taller than the sheet surface, which ate a Done bar and the first and
///     last rows. `minHeight` is a floor, and the table scrolls INTERNALLY, so
///     the content can never be taller than the surface;
///   * the header bar is ours, in a VStack above a Divider. A hosted
///     navigation bar's Done and `safeAreaInset` both bury controls instead.
/// Done is borderedProminent: a bare text button is nearly impossible to
/// gaze-pinch. D-082: the bar is vkQuake's ("Settings" + Done,
/// VKQVisionApp.swift:229-238) now that the sheet is the whole settings page;
/// Reset lives on the 3D section's own floating header in the table, as it
/// does in vkQuake and openQ4, because it resets the 3D rows and nothing else.
struct PD3DSettingsSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Settings").font(.title2.bold())
                Spacer()
                Button("Done") {
                    // Both, in this order: the SwiftUI dismissal, and the flag
                    // the ObjC side owns — so `3d state` cannot report a sheet
                    // the player has already closed, whichever way it closed.
                    dismiss()
                    pdVision3dSettingsSheetRequest(0)
                }.buttonStyle(.borderedProminent)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 14)
            Divider()
            PDSettingsTableView()
                .frame(minHeight: 620)
        }
        .frame(minWidth: 900)   // width ONLY — a forced height centre-clips
        .onAppear { pdVision3dSettingsSheetNote(1) }
        .onDisappear { pdVision3dSettingsSheetNote(0) }
    }
}

/// Hosts the UIKit engine bootstrap inside SwiftUI.
struct PDWindowView: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> PDHostViewController {
        return PDHostViewController()
    }
    func updateUIViewController(_ vc: PDHostViewController, context: Context) {}
}

// The compositor layer's configuration. Capabilities are QUERIED, never
// assumed: asking for an unsupported combination makes openImmersiveSpace fail
// with a generic .error that names nothing.
struct PDCompositorConfiguration: CompositorLayerConfiguration {
    func makeConfiguration(capabilities: LayerRenderer.Capabilities,
                           configuration: inout LayerRenderer.Configuration) {
        let layouts = capabilities.supportedLayouts(options: [])
        // FOVEATION — unconditional where supported (D-052; the five-step
        // recipe in ~/dev/VISIONOS-FOVEATION-GUIDE.md). The engine's own render
        // is untouched; this makes the COMPOSITOR's drawable eye-tracked
        // variable-density, which is where the family's lost sharpness went.
        // The simulator reports supportsFoveation == false, so on the sim this
        // is the .layered/off path and the verdict belongs to the device (M5).
        let fov = capabilities.supportsFoveation
        configuration.isFoveationEnabled = fov
        // TRAP 1 (cost a device round in the family): the .layered layout
        // carries ONE multi-layer rate map, but per-slice render passes each
        // rasterize with layer 0's (the left eye's) map — the compositor then
        // unwarps the right eye with its own, giving a right-eye fisheye that
        // zooms with head motion. .dedicated gives each eye its OWN texture and
        // its OWN rate map, which PDImmersive.m's per-view texture-map
        // targeting consumes correctly.
        if fov && layouts.contains(.dedicated) {
            configuration.layout = .dedicated
        } else {
            configuration.layout = layouts.contains(.layered) ? .layered : .dedicated
        }
        // TRAP 2: do NOT touch maxRenderQuality. Requesting a raised value
        // ABORTS the process at immersive entry, on the simulator AND on the
        // device, and there is no non-aborting way to validate it first.
        configuration.colorFormat = capabilities.supportedColorFormats.first ?? .bgra8Unorm_srgb
        configuration.depthFormat = capabilities.supportedDepthFormats.first ?? .depth32Float
        // D-063: report it, so `3d state` can be read instead of the source.
        // "Is foveation on" has three answers — supported, configured, and
        // live — and only the third one is evidence. The first two are here;
        // the loop counts the drawable's rate maps for the third.
        let dedicated = (configuration.layout == .dedicated)
        pdVision3dNoteCompositorConfig(capabilities.supportsFoveation ? 1 : 0,
                                       fov ? 1 : 0, dedicated ? 1 : 0)
        NSLog("perfectdark: [3d] compositor configured (foveation=\(fov) dedicated=\(dedicated) layered=\(layouts.contains(.layered)))")
    }
}

// The window's root view. It owns the immersive open/close environment actions,
// which are only valid inside a View — in the App struct they silently no-op.
struct PDRootView: View {
    @ObservedObject private var model = PDAppModel.shared
    @Environment(\.openImmersiveSpace) private var openImmersiveSpace
    @Environment(\.dismissImmersiveSpace) private var dismissImmersiveSpace

    var body: some View {
        PDWindowView()
            .ignoresSafeArea()
            // 3D in a BOTTOM ornament, pushed fully below the window:
            // contentAlignment .top anchors the pill's top edge to the window's
            // bottom edge, where the default centred ornament would straddle
            // the boundary and cover game content.
            .ornament(attachmentAnchor: .scene(.bottom), contentAlignment: .top) {
                HStack(spacing: 16) {
                    Button(model.immersive ? "Exit 3D" : "3D") {
                        pdVision3dSetMode(!model.immersive)
                    }
                    // THE GEAR, beside it, in the sibling ports' own placement
                    // and glyph — the user's note on 0.0.0.9 from the headset was
                    // "you have none of the SETTINGS gear ornament, we need that
                    // just like the other ports have". So: the LAST button in
                    // the same pill (sm64coopdx SM64VisionApp.swift:185,
                    // q2repro VisionShell.swift:426), `gearshape.fill` as the
                    // closest-lineage port draws it, at the pill's own
                    // `.title3`, and present in BOTH modes exactly as the
                    // siblings show it — a player who wants the panel further
                    // away must be able to reach the rows without entering 3D
                    // first. A GLYPH and never the word "Settings" (bean's
                    // rule): a pill with two words in it stops reading as a pill.
                    Button {
                        pdVision3dSettingsSheetRequest(1)
                    } label: {
                        Image(systemName: "gearshape.fill")
                    }
                }
                .font(.title3)
                .buttonStyle(.borderless)
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
                .glassBackgroundEffect()
                .opacity(0.85)
                .padding(.top, 14)
            }
            // The settings sheet (M6). Presented from the WINDOW's root view,
            // not from the immersive space: a sheet belongs to a window scene,
            // and the space has none — this is also why it survives the space
            // opening and closing underneath it.
            .sheet(isPresented: $model.settingsSheet) { PD3DSettingsSheet() }
            // The cold-launch deep link PDSceneDelegate used to pull out of the
            // scene's connection options. This is where it arrives now.
            .onOpenURL { url in
                pdVision3dQueueDeepLink(url)
            }
            .onChange(of: model.immersive) { _, on in
                NSLog("perfectdark: [3d] immersive onChange -> \(on)")
                Task {
                    if model.spaceBusy {
                        NSLog("perfectdark: [3d] a space request is already in flight — ignoring")
                        return
                    }
                    model.spaceBusy = true
                    defer { model.spaceBusy = false }
                    if on {
                        let r = await openImmersiveSpace(id: "PD-3D")
                        NSLog("perfectdark: [3d] openImmersiveSpace -> \(String(describing: r))")
                        if case .error = r {
                            // Roll the shell back out of 3D rather than leave it
                            // believing it is in a space that never opened.
                            pdVision3dSetMode(false)
                        } else if case .opened = r {
                            // THE PARK IS ARMED HERE AND NOWHERE ELSE: this
                            // await returning is the only moment that means
                            // "the transition has finished", and parking
                            // before it wedges a sibling animation (plan
                            // §2.9). The shell waits a further 1.5 s.
                            pdVision3dSpaceOpened()
                        }
                    } else {
                        await dismissImmersiveSpace()
                        NSLog("perfectdark: [3d] dismissed immersive")
                    }
                }
            }
    }
}

@main
struct PDVisionApp: App {
    /// 1280x720 unless `PD_VISION_WINDOW_SIZE=WxH` is in the environment
    /// (`SIMCTL_CHILD_PD_VISION_WINDOW_SIZE` from simctl). A screenshot
    /// instrument only: README captures of the simulated room want a larger
    /// window than the gate's determinism size. Only a NEW scene session
    /// reads defaultSize, so a reinstall is needed for it to take.
    static var windowSize: CGSize {
        if let v = ProcessInfo.processInfo.environment["PD_VISION_WINDOW_SIZE"] {
            let parts = v.lowercased().split(separator: "x")
            if parts.count == 2, let w = Double(parts[0]), let h = Double(parts[1]), w >= 320, h >= 180 {
                NSLog("perfectdark: [vision] window size override %gx%g", w, h)
                return CGSize(width: w, height: h)
            }
        }
        return CGSize(width: 1280, height: 720)
    }

    var body: some Scene {
        WindowGroup {
            PDRootView()
        }
        // The Phase-5 window size, kept: the visionOS gate's seeded replay
        // renders at the window's points (1280x720 at contentsScale 2) and
        // diffs against an oracle frame of exactly that size, so the window
        // geometry is a determinism input like the aspect ratio is.
        .defaultSize(width: PDVisionApp.windowSize.width, height: PDVisionApp.windowSize.height)

        ImmersiveSpace(id: "PD-3D") {
            CompositorLayer(configuration: PDCompositorConfiguration()) { layerRenderer in
                // This closure runs on the MAIN thread, which is where the
                // engine's game loop lives — so the frame loop must not.
                NSLog("perfectdark: [3d] CompositorLayer ready — spawning the render thread")
                let t = Thread {
                    pdVision3dImmersiveRun(Unmanaged.passUnretained(layerRenderer).toOpaque())
                }
                t.name = "PD-Immersive"
                t.stackSize = 2 << 20
                t.start()
            }
        }
        // MIXED ONLY. Merely ALLOWING .progressive changes the drawable
        // contract (portal rendering) and cp_drawable_encode_present aborts
        // with __BUG_IN_CLIENT__. The Surroundings Dimming slider (M6) is the
        // in-app replacement for Crown dimming.
        .immersionStyle(selection: .constant(.mixed), in: .mixed)
    }
}
