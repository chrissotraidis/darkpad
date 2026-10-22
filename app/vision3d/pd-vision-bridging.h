// pd-vision-bridging.h — Swift <-> ObjC bridging header for the visionOS target.
//
// Exposes the 3D shell to PDVisionApp.swift: the host view controller, the
// enter/exit entry point, the deep-link shim and the immersive render loop the
// CompositorLayer closure hands its layer renderer to.
//
// Wired by SWIFT_OBJC_BRIDGING_HEADER in app/project.yml, on the visionOS
// target ONLY. PDVision3D.h is self-gating on TARGET_OS_VISION, and nothing in
// the iOS target includes either file.
#import "PDVision3D.h"
