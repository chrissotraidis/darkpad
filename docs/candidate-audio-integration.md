> **Superseded (25 October 2026).** The shipping 0023 (from rebelancap 1.0.4, on
> v3.15.1) keeps the iOS queue, gain and rate matcher and forces two output
> channels on iOS, so 5.1 plays as Dolby Surround and Headphone Surround stays
> two channels. The six-channel merge below was not needed.

# Candidate audio merge findings

Target engine: `3ee8ed0cd549b64350848655c43ae1568e449c6d`. Baseline: `90c8622e74b35be669d60d177effc6d7d2d7621c`. This is an unresolved integration, not an accepted patch.

The original0023 applies cleanly to baseline audio.c. A three-way merge against candidate audio.c yields five conflicts; reproducible inputs and marked output are in ignored `work/audio-candidate-merge/`. Do not compile that marked file. Candidate source must be the starting point for the semantic merge: the automatic merge also moves device-spec instrumentation into a scope without `have`.

## Behaviors that must coexist

Candidate audio.c adds surround output (2 or6 channels), headphone surround, focus-mute fading, stereo recording downmix, raw output dumping, and queuedTotal/audioGetFramesQueued for network event timing. Preserve those paths.

The iOS overlay adds master gain/ducking, startup priming, queue telemetry, bounded rate matching, burst-drop/resync fades and interruption recovery. Later0028 adds the engine production threshold and0048 exposes stalled-drop state. Preserve their symbols and behavior for PDAudio/PDBridge.

## Concrete merge requirements

- Rename the iOS gain buffer: both implementations declare gainBuf/gainBufSize with different use. Sharing them can alias the input/output of the second gain pass.
- Place buffer floors before opening the device; update actual-device instrumentation in audioOpenDevice, which now owns SDL_AudioSpec. A surround change reopens the device, so reset interpolation history/priming for each reopen rather than relying on lifetime push count.
- Generalize rate conversion, interpolation history, fades and silence from hardcoded stereo (4bytes/frame,2samples/frame) to the active2/6 channel count. Reallocate sufficient capacity after channel changes even when frame count is unchanged. Never process widened buffers with the stereo resampler.
- Widen/consume mixer side-channel chunks once per produced buffer. Consume/discard them on every drop path, including the iOS early return during a burst; otherwise stale surround chunks survive the drop.
- Apply focus gain and platform gain to speaker output; retain the candidate's stereo recorder source and raw device dump semantics.
- Keep queue level in frames (audioGetSamplesBuffered already normalizes candidate channels). Decide and document queuedTotal accounting for resampled output and inserted silence, because audioGetFramesQueued is used by networking diagnostics. It must describe actual output position, not assume every input frame was queued unchanged.
- Retain the candidate's audio configuration entries alongside iOS entries; then reapply0028 and0048 and inspect their semantics, not only patch success.

## Verification required

Compile both PLATFORM_IOS and desktop paths. Exercise deterministic2/6-channel buffers through interpolation/fades, channel changes, unity/muted gain, priming and burst drops with bounds instrumentation. Verify channel identity and frame accounting. Then build the full candidate and run simulator audio/lifecycle checks. No physical-performance claim follows from these tests.
