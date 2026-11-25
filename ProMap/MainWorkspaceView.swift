import AppKit
import AVFoundation
import Combine
import Darwin
import Darwin.Mach
import MetalKit
import SwiftUI
import UniformTypeIdentifiers

private struct ScreenChoice: Identifiable {
    let id: String
    let screen: NSScreen
}

private enum GeometryAxis {
    case horizontal
    case vertical
}

private enum WorkspaceArea {
    case live
    case scenes
    case diagnostics
}

struct MainWorkspaceView: View {
    @StateObject private var library: MediaLibrary
    @StateObject private var session: RenderSession
    @StateObject private var previewSession: RenderSession
    @StateObject private var renderer: MetalRenderer
    @StateObject private var output: ProjectorOutputController
    @StateObject private var externalControl: ExternalControlManager
    @StateObject private var midiControl: MIDIControlManager
    @StateObject private var ndiService = NDIService.shared
    @StateObject private var ndiOutputService = NDIOutputService.shared
    @StateObject private var syphonService = SyphonService.shared
    @StateObject private var syphonOutputService = SyphonOutputService.shared
    @AppStorage("outputAboveMenuBar") private var outputAboveMenuBar = false
    @AppStorage("outputFrameRate") private var outputFrameRate = 30
    @AppStorage("previewFrameRate") private var previewFrameRate = 10
    @AppStorage("previewRenderScale") private var previewRenderScale = 0.5
    @AppStorage("sceneTransitionDuration") private var sceneTransitionDuration = 0.35
    @AppStorage("sceneTransitionStyle") private var sceneTransitionStyle = SceneTransitionStyle.dissolve.rawValue
    @AppStorage("sceneTransitionCurve") private var sceneTransitionCurve = SceneTransitionCurve.easeInOut.rawValue
    @AppStorage("masterOutputIntensity") private var masterOutputIntensity = 1.0
    @AppStorage("masterAudioVolume") private var masterAudioVolume = 1.0
    @AppStorage("audioOutputDeviceUID") private var audioOutputDeviceUID = ""
    @AppStorage("externalHTTPEnabled") private var externalHTTPEnabled = false
    @AppStorage("externalHTTPPort") private var externalHTTPPort = 8765
    @AppStorage("externalHTTPRemoteAccess") private var externalHTTPRemoteAccess = false
    @AppStorage("externalAPIToken") private var externalAPIToken = ""
    @AppStorage("externalOSCEnabled") private var externalOSCEnabled = false
    @AppStorage("externalOSCPort") private var externalOSCPort = 8766
    @AppStorage("midiControlEnabled") private var midiControlEnabled = false
    @AppStorage("ndiInputsEnabled") private var ndiInputsEnabled = false
    @AppStorage("ndiOutputEnabled") private var ndiOutputEnabled = false
    @AppStorage("ndiOutputSourceName") private var ndiOutputSourceName = "ProMap Program"
    @AppStorage("syphonInputsEnabled") private var syphonInputsEnabled = false
    @AppStorage("syphonOutputEnabled") private var syphonOutputEnabled = false
    @AppStorage("syphonOutputSourceName") private var syphonOutputSourceName = "ProMap Program"
    @AppStorage("launchInBlackout") private var launchInBlackout = false
    @AppStorage("preventSleepWhileOutputOpen") private var preventSleepWhileOutputOpen = true
    @AppStorage("mappingLockedForLive") private var mappingLockedForLive = false
    @AppStorage("operatorModeEnabled") private var operatorModeEnabled = false
    @AppStorage("timedCueAdvanceEnabled") private var timedCueAdvanceEnabled = false
    @AppStorage("userEffectPresetsJSON") private var userEffectPresetsJSON = "[]"
    @State private var selectedScreenID: String?
    @State private var selectedSurfaceID: UUID?
    @State private var mappingPreviewOutputID = ProjectionOutput.mainID
    @State private var selectedMaskPointIndex: Int?
    @State private var selectedMaskPathID: UUID?
    @State private var selectedOutputMaskPathID: UUID?
    @State private var selectedOutputMaskPointIndex: Int?
    @State private var selectedMediaSourceID: UUID?
    @State private var selectedLayerID: UUID?
    @State private var selectedWorkspaceArea: WorkspaceArea = .live
    @State private var selectedRecallSceneID: UUID?
    @State private var showsCustomVirtualCanvas = false
    @State private var customVirtualWidth = "1920"
    @State private var customVirtualHeight = "1080"
    @State private var sceneNameDraft: String?
    @State private var pendingNDIShowLayerReferences = Set<String>()
    @State private var pendingSyphonShowLayerReferences = Set<String>()
    @State private var previewSceneID: UUID?
    @State private var takeButtonPulse = false
    @State private var activeCueStartedAt: Date?
    @State private var newSceneName = "Scene 1"
    @State private var checkedAutosave = false
    @State private var checkedStartupBehavior = false
    @State private var isColorCorrectionExpanded = false
    @State private var isEffectStackExpanded = false
    @State private var isGeometryExpanded = true
    @State private var isMoveToolEnabled = false
    @State private var isMaskEditingEnabled = false
    @State private var isMeshEditingEnabled = false
    @State private var isSavingEffectPreset = false
    @State private var effectPresetDraftName = ""
    @State private var pendingEffectPresetEffects: [SurfaceEffect] = []
    @State private var snapMappingPoints = false
    @State private var snapToVertices = false
    @State private var mappingZoom = 1.0
    @State private var keystoneStep = 0.005
    @State private var maskNudgeStep = 0.001
    private let autosaveTimer = Timer.publish(every: 30, on: .main, in: .common).autoconnect()
    private let cueTimer = Timer.publish(every: 0.25, on: .main, in: .common).autoconnect()

    init() {
        let mediaLibrary = MediaLibrary()
        let renderSession = RenderSession()
        let stagedSession = RenderSession()
        let metalRenderer = MetalRenderer()
        let controlManager = ExternalControlManager()
        _library = StateObject(wrappedValue: mediaLibrary)
        _session = StateObject(wrappedValue: renderSession)
        _previewSession = StateObject(wrappedValue: stagedSession)
        _renderer = StateObject(wrappedValue: metalRenderer)
        _midiControl = StateObject(wrappedValue: MIDIControlManager.shared)
        _externalControl = StateObject(wrappedValue: controlManager)
        _output = StateObject(wrappedValue: ProjectorOutputController(
            renderer: metalRenderer,
            session: renderSession
        ))
    }

    private var screens: [ScreenChoice] {
        NSScreen.screens.compactMap { screen in
            guard screen.frame.width > 1, screen.frame.height > 1 else { return nil }
            let key = NSDeviceDescriptionKey("NSScreenNumber")
            let number = (screen.deviceDescription[key] as? NSNumber)?.stringValue
            return ScreenChoice(id: number ?? screen.localizedName, screen: screen)
        }
    }

    private var userEffectPresets: [UserEffectPreset] {
        guard let data = userEffectPresetsJSON.data(using: .utf8),
              let presets = try? JSONDecoder().decode([UserEffectPreset].self, from: data) else { return [] }
        return presets
    }

    var body: some View { housekeepingLifecycle }

    private var workspaceContent: some View {
        VStack(spacing: 0) {
            header
            workspaceNavigation
            if selectedWorkspaceArea == .live {
                HStack(spacing: 0) {
                    mediaPanel
                        .frame(width: 276)
                    divider
                    previewPanel
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    divider
                    layersPanel
                        .frame(width: 310)
                }
            } else if selectedWorkspaceArea == .scenes {
                sceneRecallWorkspace
            } else {
                diagnosticsWorkspace
            }
            footer
        }
        .frame(minWidth: 1120, minHeight: 720)
        .background(Palette.background)
        .foregroundColor(Palette.primaryText)
        .preferredColorScheme(.dark)
        .background {
            Color.clear
        }
    }

    private var presentationLayer: some View {
        workspaceContent
        .sheet(isPresented: $showsCustomVirtualCanvas) {
            customVirtualCanvasSheet
        }
        .sheet(isPresented: $isSavingEffectPreset) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Save Effect Preset")
                    .font(.headline)
                TextField("Preset name", text: $effectPresetDraftName)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(savePendingEffectPreset)
                Text("Stores the current ordered effects for reuse on any layer or surface.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack {
                    Button("Cancel") { isSavingEffectPreset = false }
                        .keyboardShortcut(.cancelAction)
                    Spacer()
                    Button("Save", action: savePendingEffectPreset)
                        .keyboardShortcut(.defaultAction)
                        .disabled(effectPresetDraftName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .padding(20)
            .frame(width: 360)
        }
    }

    private var startupLifecycle: some View {
        presentationLayer
        .onAppear {
            session.setSourceCatalog(library.sources)
            previewSession.setSourceCatalog(library.sources)
            output.setOutputAboveMenuBar(outputAboveMenuBar)
            output.setOutputFrameRate(outputFrameRate)
            output.setPreventSleepWhileOutputOpen(preventSleepWhileOutputOpen)
            session.setOutputIntensity(masterOutputIntensity)
            previewSession.setOutputIntensity(masterOutputIntensity)
            output.setNDIOutputEnabled(ndiOutputEnabled)
            output.setSyphonOutputEnabled(syphonOutputEnabled)
            session.setMappingLocked(mappingLockedForLive)
            library.setMasterAudioVolume(masterAudioVolume)
            library.setAudioOutputDevice(audioOutputDeviceUID.isEmpty ? nil : audioOutputDeviceUID)
            configureExternalControl()
            midiControl.configure(enabled: midiControlEnabled)
            ndiService.configure(enabled: ndiInputsEnabled)
            syphonService.configure(enabled: syphonInputsEnabled)
            configureNDIOutput()
            configureSyphonOutput()
            midiControl.updateScenes(session.scenes)
            configureExternalStatusProvider()
            if selectedScreenID == nil {
                selectedScreenID = screens.dropFirst().first?.id ?? screens.first?.id
            }
            if selectedSurfaceID == nil {
                selectedSurfaceID = session.surfaces.first?.id
            }
            if operatorModeEnabled {
                selectedWorkspaceArea = .scenes
            }
            if !checkedStartupBehavior {
                checkedStartupBehavior = true
                if launchInBlackout { session.setBlackout(true) }
            }
            if !checkedAutosave {
                checkedAutosave = true
                offerAutosaveRecovery()
            }
        }
    }

    private var outputLifecycle: some View {
        startupLifecycle
        .onChange(of: outputAboveMenuBar) { enabled in
            output.setOutputAboveMenuBar(enabled)
        }
        .onChange(of: outputFrameRate) { rate in
            output.setOutputFrameRate(rate)
        }
        .onChange(of: masterOutputIntensity) { intensity in
            session.setOutputIntensity(intensity)
            previewSession.setOutputIntensity(intensity)
        }
        .onChange(of: ndiOutputEnabled) { enabled in
            output.setNDIOutputEnabled(enabled)
            configureNDIOutput()
        }
        .onChange(of: ndiOutputSourceName) { _ in configureNDIOutput() }
        .onChange(of: output.activeOutputID) { _ in
            configureNDIOutput()
            configureSyphonOutput()
        }
        .onChange(of: syphonInputsEnabled) { syphonService.configure(enabled: $0) }
        .onChange(of: syphonOutputEnabled) { enabled in
            output.setSyphonOutputEnabled(enabled)
            configureSyphonOutput()
        }
        .onChange(of: syphonOutputSourceName) { _ in configureSyphonOutput() }
        .onChange(of: preventSleepWhileOutputOpen) { enabled in
            output.setPreventSleepWhileOutputOpen(enabled)
        }
        .onChange(of: mappingLockedForLive) { enabled in
            session.setMappingLocked(enabled)
        }
        .onChange(of: operatorModeEnabled) { enabled in
            if enabled { selectedWorkspaceArea = .scenes }
        }
        .onChange(of: masterAudioVolume) { volume in
            library.setMasterAudioVolume(volume)
        }
        .onChange(of: audioOutputDeviceUID) { uniqueID in
            library.setAudioOutputDevice(uniqueID.isEmpty ? nil : uniqueID)
        }
        .onChange(of: externalHTTPEnabled) { _ in configureExternalControl() }
        .onChange(of: externalHTTPPort) { _ in configureExternalControl() }
        .onChange(of: externalHTTPRemoteAccess) { _ in configureExternalControl() }
        .onChange(of: externalAPIToken) { _ in configureExternalControl() }
        .onChange(of: externalOSCEnabled) { _ in configureExternalControl() }
        .onChange(of: externalOSCPort) { _ in configureExternalControl() }
        .onChange(of: midiControlEnabled) { enabled in midiControl.configure(enabled: enabled) }
        .onChange(of: ndiInputsEnabled) { enabled in ndiService.configure(enabled: enabled) }
    }

    private var sceneLifecycle: some View {
        outputLifecycle
        .onChange(of: selectedRecallSceneID) { sceneID in
            sceneNameDraft = session.scenes.first(where: { $0.id == sceneID })?.name
        }
        .onChange(of: previewSceneID) { sceneID in
            guard sceneID != nil else {
                takeButtonPulse = false
                return
            }
            takeButtonPulse = true
            withAnimation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true)) {
                takeButtonPulse = false
            }
        }
        .onChange(of: session.currentSceneID) { sceneID in
            activeCueStartedAt = sceneID == nil ? nil : Date()
        }
        .onChange(of: ndiService.sources) { _ in
            let references = Set(currentShowDocument().mediaPaths).union(pendingNDIShowLayerReferences)
            library.restoreNDISources(references: Array(references)) {
                for reference in Array(self.pendingNDIShowLayerReferences) {
                    guard let source = self.library.sources.first(where: { $0.reference == reference }) else { continue }
                    if !self.session.hasLayer(sourcePath: reference) { self.session.addLayer(source: source) }
                    self.pendingNDIShowLayerReferences.remove(reference)
                }
            }
        }
        .onChange(of: syphonService.sources) { _ in
            let references = Set(currentShowDocument().mediaPaths).union(pendingSyphonShowLayerReferences)
            library.restoreSyphonSources(references: Array(references), device: renderer.device) {
                for reference in Array(self.pendingSyphonShowLayerReferences) {
                    guard let source = self.library.sources.first(where: { $0.reference == reference }) else { continue }
                    if !self.session.hasLayer(sourcePath: reference) { self.session.addLayer(source: source) }
                    self.pendingSyphonShowLayerReferences.remove(reference)
                }
                self.session.setSourceCatalog(self.library.sources)
            }
        }
        .onChange(of: session.scenes) { scenes in midiControl.updateScenes(scenes) }
    }

    private var commandLifecycle: some View {
        sceneLifecycle
        .onReceive(externalControl.commands) { command in
            executeExternalControl(command)
        }
        .onReceive(midiControl.commands) { command in
            executeExternalControl(command)
        }
        .onReceive(NotificationCenter.default.publisher(for: .proMapCommand)) { notification in
            guard let rawAction = notification.userInfo?["action"] as? String,
                  let action = ProMapCommandAction(rawValue: rawAction) else { return }
            handleAppCommand(action)
        }
    }

    private var mappingLifecycle: some View {
        commandLifecycle
        .onChange(of: selectedSurfaceID) { _ in
            selectedMaskPointIndex = nil
            selectedMaskPathID = nil
            selectedOutputMaskPathID = nil
            selectedOutputMaskPointIndex = nil
            if let surface = selectedSurface {
                mappingPreviewOutputID = surface.outputID ?? ProjectionOutput.mainID
            }
        }
        .onChange(of: selectedSurface?.outputID) { outputID in
            mappingPreviewOutputID = outputID ?? ProjectionOutput.mainID
        }
        .onChange(of: mappingPreviewOutputID) { outputID in
            let pathStillExists = session.outputs
                .first(where: { $0.id == outputID })?
                .exclusionPaths?
                .contains(where: { $0.id == selectedOutputMaskPathID }) ?? false
            if !pathStillExists {
                selectedOutputMaskPathID = nil
                selectedOutputMaskPointIndex = nil
            }
        }
        .onChange(of: selectedMaskPathID) { _ in selectedMaskPointIndex = nil }
        .onChange(of: selectedOutputMaskPathID) { _ in selectedOutputMaskPointIndex = nil }
    }

    private var housekeepingLifecycle: some View {
        mappingLifecycle
        .onReceive(library.$sources) { sources in
            session.setSourceCatalog(sources)
        }
        .onReceive(session.objectWillChange.debounce(for: .seconds(2), scheduler: RunLoop.main)) { _ in
            saveAutosave()
        }
        .onReceive(autosaveTimer) { _ in saveAutosave() }
        .onReceive(cueTimer) { _ in advanceTimedCueIfNeeded() }
        .onDisappear {
            saveAutosave()
            externalControl.stop()
        }
    }

    private var workspaceNavigation: some View {
        HStack(spacing: 5) {
            if !operatorModeEnabled {
                workspaceTab("LIVE EDITOR", symbol: "slider.horizontal.3", area: .live)
            } else {
                Label("OPERATOR MODE", systemImage: "person.crop.rectangle.stack")
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .foregroundColor(Palette.accentSoft)
                    .padding(.horizontal, 11)
                    .padding(.vertical, 7)
            }
            workspaceTab("PLAYBACK", symbol: "rectangle.stack.fill", area: .scenes)
            workspaceTab("DIAGNOSTICS", symbol: "waveform.path.ecg", area: .diagnostics)
            Spacer()
            Button {
                session.toggleBlackout()
            } label: {
                Label("BLACKOUT", systemImage: session.isBlackout ? "lightbulb.slash.fill" : "lightbulb")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .tint(session.isBlackout ? .orange : nil)
            .keyboardShortcut("b", modifiers: [.command, .option])
            .help("Emergency blackout (⌥⌘B)")
            Button {
                output.setOutputFrozen(!output.isOutputFrozen)
            } label: {
                Label(output.isOutputFrozen ? "FROZEN" : "FREEZE", systemImage: output.isOutputFrozen ? "pause.rectangle.fill" : "pause.rectangle")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .tint(output.isOutputFrozen ? .orange : nil)
            .disabled(output.openOutputIDs.isEmpty)
            .keyboardShortcut("f", modifiers: [.command, .option])
            .help(output.isOutputFrozen ? "Unfreeze projector outputs (⌥⌘F)" : "Freeze the displayed projector frame (⌥⌘F)")
            Text(workspaceTagline)
                .font(.system(size: 8, weight: .semibold, design: .monospaced))
                .tracking(0.5)
                .foregroundColor(Palette.tertiaryText)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 7)
        .background(Palette.background)
        .overlay(alignment: .bottom) { dividerLine }
    }

    private var workspaceTagline: String {
        switch selectedWorkspaceArea {
        case .live: return "MAP · ASSIGN · COMPOSE"
        case .scenes: return "PREVIEW · TRANSITION · TAKE"
        case .diagnostics: return "GPU · FRAME PACE · INPUT STATUS"
        }
    }

    private func workspaceTab(_ title: String, symbol: String, area: WorkspaceArea) -> some View {
        Button {
            selectedWorkspaceArea = area
        } label: {
            Label(title, systemImage: symbol)
                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                .padding(.horizontal, 11)
                .padding(.vertical, 7)
                .foregroundColor(selectedWorkspaceArea == area ? Palette.primaryText : Palette.secondaryText)
                .background(selectedWorkspaceArea == area ? Palette.control : Color.clear)
                .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
    }

    private var selectedRecallScene: ScenePreset? {
        session.scenes.first(where: { $0.id == selectedRecallSceneID }) ?? session.scenes.first
    }

    private var playbackTransitionStyle: SceneTransitionStyle {
        SceneTransitionStyle(rawValue: sceneTransitionStyle) ?? .dissolve
    }

    private var playbackTransitionCurve: SceneTransitionCurve {
        SceneTransitionCurve(rawValue: sceneTransitionCurve) ?? .easeInOut
    }

    private var sceneRecallWorkspace: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                panelTitle("PLAYBACK", detail: "\(session.scenes.count) CUES · PREVIEW, THEN TAKE TO PROGRAM")
                Spacer()
                Button {
                    stepSceneCue(-1)
                } label: {
                    Image(systemName: "backward.end.fill")
                }
                .disabled(session.scenes.isEmpty)
                .help("Previous scene")
                Button {
                    stepSceneCue(1)
                } label: {
                    Image(systemName: "forward.end.fill")
                }
                .disabled(session.scenes.isEmpty)
                .help("Next scene")
                Toggle(isOn: $timedCueAdvanceEnabled) {
                    Label("CUE AUTO", systemImage: "timer")
                }
                .toggleStyle(.button)
                .controlSize(.small)
                .help("Enable timed cue advancement for scenes with a duration")
                TextField("New scene name", text: $newSceneName)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 170)
                    .onSubmit(captureScene)
                Button(action: captureScene) {
                    Label("Capture Current", systemImage: "plus")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
            .background(Palette.panel)
            .overlay(alignment: .bottom) { dividerLine }

            HStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 0) {
                    panelTitle("CUE LIST", detail: "SELECT A SCENE TO PREVIEW OR TAKE")
                        .padding(14)
                    Rectangle().fill(Palette.border).frame(height: 1)
                    if session.scenes.isEmpty {
                        VStack(spacing: 9) {
                            Image(systemName: "rectangle.stack.badge.plus")
                                .font(.system(size: 26, weight: .light))
                                .foregroundColor(Palette.secondaryText)
                            Text("No scenes yet")
                                .font(.system(size: 13, weight: .semibold))
                            Text("Capture the current program to create your first cue.")
                                .font(.system(size: 10))
                                .foregroundColor(Palette.secondaryText)
                                .multilineTextAlignment(.center)
                            Button("Capture Current Scene", action: captureScene)
                                .buttonStyle(.borderedProminent)
                                .controlSize(.small)
                        }
                        .padding(20)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        ScrollView {
                            VStack(spacing: 6) {
                                ForEach(Array(session.scenes.enumerated()), id: \.element.id) { index, scene in
                                    sceneCueRow(scene, number: index + 1)
                                }
                            }
                            .padding(10)
                        }
                    }
                }
                .frame(width: 250)
                .background(Palette.panel)

                divider

                VStack(alignment: .leading, spacing: 0) {
                    if let scene = selectedRecallScene {
                        sceneDetails(scene)
                    } else {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Scenes save media selection and playback state, mask visibility, brightness and effect settings.")
                                .font(.system(size: 12))
                                .foregroundColor(Palette.secondaryText)
                            Text("Calibrated mapping geometry stays with the show so scene changes cannot move the projection surfaces.")
                                .font(.system(size: 10))
                                .foregroundColor(Palette.tertiaryText)
                        }
                        .padding(20)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Palette.background)

                divider

                VStack(alignment: .leading, spacing: 13) {
                    if let stagedScene {
                        previewTakeBar(stagedScene)
                    } else {
                        Text("Click a cue to preview it. Program stays live until you press TAKE SCENE.")
                            .font(.system(size: 9))
                            .foregroundColor(Palette.tertiaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    sceneMonitor("PROGRAM", session: session, outputTitle: output.activeOutputTitle ?? "OUTPUT CLOSED")
                    sceneMonitor("PREVIEW", session: previewSession, outputTitle: previewSceneID == nil ? "NO SCENE STAGED" : (stagedScene?.name ?? "STAGED SCENE"))
                    playbackTransitionControls
                }
                .padding(14)
                .frame(width: 350)
                .frame(maxHeight: .infinity, alignment: .top)
                .background(Palette.panel)
            }
        }
    }

    private var diagnosticsWorkspace: some View {
        DiagnosticsWorkspace(
            renderer: renderer,
            session: session,
            output: output,
            library: library,
            ndiService: ndiService,
            ndiOutputService: ndiOutputService,
            syphonService: syphonService,
            syphonOutputService: syphonOutputService,
            outputFrameRate: outputFrameRate,
            previewFrameRate: previewFrameRate,
            previewRenderScale: previewRenderScale
        )
    }

    private func sceneCueRow(_ scene: ScenePreset, number: Int) -> some View {
        Button {
            selectedRecallSceneID = scene.id
            stageSceneForPreview(scene)
        } label: {
            HStack(spacing: 9) {
                Text(String(format: "%02d", number))
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .foregroundColor(Palette.tertiaryText)
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 4) {
                    Text(scene.name)
                        .font(.system(size: 11, weight: .semibold))
                        .lineLimit(1)
                    Text("\(scene.layers.count) clips · \(scene.surfaces.count) masks" + (scene.autoAdvanceAfter.map { " · AUTO \(Int($0))s" } ?? ""))
                        .font(.system(size: 8, weight: .medium, design: .monospaced))
                        .foregroundColor(Palette.secondaryText)
                }
                Spacer(minLength: 2)
                if scene.id == session.currentSceneID {
                    Text("LIVE")
                        .font(.system(size: 7, weight: .bold, design: .monospaced))
                        .foregroundColor(Palette.green)
                }
                if scene.id == previewSceneID {
                    Image(systemName: "eye.fill")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundColor(Palette.accentSoft)
                }
                if scene.isBlackout == true {
                    Image(systemName: "lightbulb.slash.fill")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundColor(Palette.orange)
                        .help("This scene recalls master blackout")
                }
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 10)
            .background(scene.id == selectedRecallScene?.id ? Palette.control : Palette.raised.opacity(0.7))
            .clipShape(RoundedRectangle(cornerRadius: 7))
            .overlay {
                RoundedRectangle(cornerRadius: 7)
                    .stroke(scene.id == selectedRecallScene?.id ? Palette.accent.opacity(0.8) : Palette.border, lineWidth: 0.7)
            }
            .contentShape(RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Preview Scene") {
                selectedRecallSceneID = scene.id
                stageSceneForPreview(scene)
            }
            Button("Take Scene") { takeScene(scene) }
            Divider()
            Button("Move Cue Up") { session.moveScene(scene.id, by: -1) }
                .disabled(number == 1)
            Button("Move Cue Down") { session.moveScene(scene.id, by: 1) }
                .disabled(number == session.scenes.count)
            Divider()
            Button("Delete Scene", role: .destructive) { deleteScene(scene) }
        }
    }

    private func sceneDetails(_ scene: ScenePreset) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                panelTitle("CUE DETAILS", detail: scene.id == session.currentSceneID ? "CURRENT PROGRAM CUE" : "SAVED MEDIA AND SURFACE STATE")
            }
            .padding(16)
            Rectangle().fill(Palette.border).frame(height: 1)

            ScrollView {
                VStack(alignment: .leading, spacing: 15) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("SCENE NAME")
                            .font(.system(size: 8, weight: .semibold, design: .monospaced))
                            .foregroundColor(Palette.secondaryText)
                        TextField("Scene name", text: Binding(
                            get: { sceneNameDraft ?? scene.name },
                            set: { sceneNameDraft = $0 }
                        ))
                        .textFieldStyle(.roundedBorder)
                        .onSubmit {
                            session.renameScene(scene.id, to: sceneNameDraft ?? scene.name)
                            sceneNameDraft = session.scenes.first(where: { $0.id == scene.id })?.name ?? scene.name
                        }
                    }

                    VStack(alignment: .leading, spacing: 7) {
                        Text("CUE TIMING")
                            .font(.system(size: 8, weight: .semibold, design: .monospaced))
                            .foregroundColor(Palette.secondaryText)
                        Stepper(value: Binding(
                            get: { scene.autoAdvanceAfter ?? 0 },
                            set: { session.setSceneAutoAdvance($0 == 0 ? nil : $0, for: scene.id) }
                        ), in: 0...3600, step: 5) {
                            Text(scene.autoAdvanceAfter.map { "Advance after \(Int($0)) seconds" } ?? "Manual advance")
                                .font(.system(size: 10, weight: .medium))
                        }
                        Text("Timed advance runs only when AUTO is enabled in the cue toolbar.")
                            .font(.system(size: 9))
                            .foregroundColor(Palette.tertiaryText)
                    }

                    VStack(alignment: .leading, spacing: 7) {
                        Text("OPERATOR NOTES")
                            .font(.system(size: 8, weight: .semibold, design: .monospaced))
                            .foregroundColor(Palette.secondaryText)
                        TextEditor(text: Binding(
                            get: { session.scenes.first(where: { $0.id == scene.id })?.operatorNotes ?? "" },
                            set: { session.setSceneOperatorNotes($0, for: scene.id) }
                        ))
                        .font(.system(size: 10))
                        .padding(5)
                        .frame(minHeight: 58, maxHeight: 90)
                        .background(Palette.raised)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                    }

                    VStack(alignment: .leading, spacing: 7) {
                        Text("LAYER STACK · \(scene.layers.count)")
                            .font(.system(size: 8, weight: .semibold, design: .monospaced))
                            .foregroundColor(Palette.secondaryText)
                        if scene.layers.isEmpty {
                            Text("This scene contains no media layers.")
                                .font(.system(size: 10))
                                .foregroundColor(Palette.tertiaryText)
                        } else {
                            ForEach(Array(scene.layers.enumerated()), id: \.element.id) { index, layer in
                                HStack(spacing: 8) {
                                    Text("\(index + 1)")
                                        .font(.system(size: 8, weight: .semibold, design: .monospaced))
                                        .foregroundColor(Palette.tertiaryText)
                                        .frame(width: 18)
                                    Image(systemName: layer.isEnabled ? "square.stack.3d.up.fill" : "eye.slash")
                                        .font(.system(size: 9))
                                        .foregroundColor(layer.isEnabled ? Palette.accentSoft : Palette.tertiaryText)
                                    Text(sceneMediaName(layer.sourcePath))
                                        .font(.system(size: 10, weight: .medium))
                                        .lineLimit(1)
                                    Spacer()
                                    Text("\(Int(layer.opacity * 100))%")
                                        .font(.system(size: 8, weight: .medium, design: .monospaced))
                                        .foregroundColor(Palette.secondaryText)
                                }
                                .padding(.horizontal, 9)
                                .padding(.vertical, 8)
                                .background(Palette.raised)
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                            }
                        }
                    }

                    VStack(alignment: .leading, spacing: 7) {
                        Text("MASK OUTPUTS · \(scene.surfaces.count)")
                            .font(.system(size: 8, weight: .semibold, design: .monospaced))
                            .foregroundColor(Palette.secondaryText)
                        ForEach(scene.surfaces, id: \.surfaceID) { surfaceState in
                            HStack(spacing: 8) {
                                Image(systemName: surfaceState.isVisible ? "scope" : "eye.slash")
                                    .font(.system(size: 9))
                                    .foregroundColor(surfaceState.isVisible ? Palette.accentSoft : Palette.tertiaryText)
                                Text(session.surfaces.first(where: { $0.id == surfaceState.surfaceID })?.name ?? "Removed mask")
                                    .font(.system(size: 10, weight: .medium))
                                Spacer(minLength: 4)
                                Text(surfaceState.usesLayerStack ? "LAYER STACK" : sceneMediaName(surfaceState.sourcePath ?? ""))
                                    .font(.system(size: 7, weight: .medium, design: .monospaced))
                                    .foregroundColor(Palette.secondaryText)
                                    .lineLimit(1)
                                if surfaceState.isBlackout {
                                    Image(systemName: "lightbulb.slash.fill")
                                        .foregroundColor(Palette.orange)
                                }
                            }
                            .padding(.horizontal, 9)
                            .padding(.vertical, 8)
                            .background(Palette.raised)
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                        }
                    }
                }
                .padding(16)
            }
        }
        .onAppear { sceneNameDraft = scene.name }
    }

    private func sceneMonitor(_ title: String, session: RenderSession, outputTitle: String) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text(title)
                    .font(.system(size: 8, weight: .semibold, design: .monospaced))
                    .foregroundColor(Palette.secondaryText)
                Spacer()
                Text(outputTitle)
                    .font(.system(size: 7, weight: .medium, design: .monospaced))
                    .foregroundColor(Palette.tertiaryText)
                    .lineLimit(1)
            }
            MetalCanvas(
                renderer: renderer,
                session: session,
                preferredFramesPerSecond: previewFrameRate,
                previewScale: previewRenderScale
            )
                .aspectRatio(16.0 / 9.0, contentMode: .fit)
                .background(Color.black)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Palette.border, lineWidth: 1))
        }
    }

    private func sceneMediaName(_ reference: String) -> String {
        if let source = library.sources.first(where: { $0.reference == reference }) { return source.title }
        if let ndiName = NDISourceDescriptor.sourceName(from: reference) { return ndiName }
        if reference.hasPrefix("capture://") { return "Live capture source" }
        if let generator = VisualGenerator(reference: reference) { return generator.title }
        return URL(fileURLWithPath: reference).lastPathComponent
    }

    private func captureScene() {
        let scene = session.captureScene(named: newSceneName)
        selectedRecallSceneID = scene.id
        newSceneName = "Scene \(session.scenes.count + 1)"
    }

    private func stepSceneCue(_ direction: Int) {
        cancelScenePreview()
        guard !session.scenes.isEmpty, direction != 0 else { return }
        let currentIndex = session.scenes.firstIndex(where: { $0.id == session.currentSceneID }) ?? (direction > 0 ? -1 : 0)
        let nextIndex = (currentIndex + direction + session.scenes.count) % session.scenes.count
        takeScene(session.scenes[nextIndex])
    }

    private func handleAppCommand(_ action: ProMapCommandAction) {
        switch action {
        case .captureScene: captureScene()
        case .saveShow: saveShow()
        case .loadShow: loadShow()
        case .importMedia: importMedia()
        case .liveEditor: selectedWorkspaceArea = .live
        case .playback: selectedWorkspaceArea = .scenes
        case .diagnostics: selectedWorkspaceArea = .diagnostics
        case .takePreview: takePreviewScene()
        case .previousCue: stepSceneCue(-1)
        case .nextCue: stepSceneCue(1)
        case .toggleBlackout: session.toggleBlackout()
        case .toggleFreeze: output.setOutputFrozen(!output.isOutputFrozen)
        }
    }

    private func takeScene(_ scene: ScenePreset) {
        takeScene(scene, transitionStyle: nil, duration: nil)
    }

    private func takeScene(
        _ scene: ScenePreset,
        transitionStyle: SceneTransitionStyle?,
        duration: TimeInterval?
    ) {
        session.recallScene(
            scene,
            sources: library.sources,
            transitionDuration: duration ?? sceneTransitionDuration,
            transitionStyle: transitionStyle ?? playbackTransitionStyle,
            transitionCurve: playbackTransitionCurve
        )
        selectedRecallSceneID = scene.id
        previewSceneID = nil
        activeCueStartedAt = Date()
        previewSession.copyContent(from: session)
    }

    private func advanceTimedCueIfNeeded() {
        guard timedCueAdvanceEnabled,
              previewSceneID == nil,
              let currentSceneID = session.currentSceneID,
              let currentScene = session.scenes.first(where: { $0.id == currentSceneID }),
              let duration = currentScene.autoAdvanceAfter,
              duration > 0,
              let activeCueStartedAt,
              Date().timeIntervalSince(activeCueStartedAt) >= duration,
              !session.scenes.isEmpty,
              let currentIndex = session.scenes.firstIndex(where: { $0.id == currentSceneID }) else { return }
        takeScene(session.scenes[(currentIndex + 1) % session.scenes.count])
    }

    private func deleteScene(_ scene: ScenePreset) {
        session.removeScene(scene.id)
        if previewSceneID == scene.id { cancelScenePreview() }
        if selectedRecallSceneID == scene.id { selectedRecallSceneID = session.scenes.first?.id }
    }

    private var header: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 9)
                    .fill(Palette.accent)
                    .frame(width: 34, height: 34)
                Image(systemName: "light.beacon.max.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(.white)
            }

            VStack(alignment: .leading, spacing: 1) {
                Text("PROMAP")
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                    .tracking(1.2)
                Text("LIVE COMPOSITION")
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .tracking(0.8)
                    .foregroundColor(Palette.secondaryText)
            }

            Spacer()

            HStack(spacing: 8) {
                Circle()
                    .fill(renderer.renderingAvailable ? Palette.green : Palette.orange)
                    .frame(width: 7, height: 7)
                Text(renderer.renderingAvailable ? "RENDERER READY" : "RENDERER UNAVAILABLE")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundColor(Palette.secondaryText)
            }
            .padding(.trailing, 16)

            outputPickerMenu
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 13)
        .background(Palette.panel)
        .overlay(alignment: .bottom) { dividerLine }
    }

    private var outputPickerMenu: some View {
        Menu {
            if !screens.isEmpty {
                Section("Physical Displays") {
                    ForEach(screens) { choice in
                        Button {
                            selectedScreenID = choice.id
                            openPhysicalOutput(choice)
                        } label: {
                            Label(choice.screen.localizedName, systemImage: "display")
                        }
                    }
                }
            }
            Section("Virtual Canvas") {
                Button("1920 × 1080") { openVirtualOutput(width: 1920, height: 1080) }
                Button("1280 × 720") { openVirtualOutput(width: 1280, height: 720) }
                Button("3840 × 2160") { openVirtualOutput(width: 3840, height: 2160) }
                Button("Custom Size…") { showsCustomVirtualCanvas = true }
            }
            if !session.outputs.isEmpty {
                Section("Saved Outputs") {
                    ForEach(session.outputs) { savedOutput in
                        Button {
                            openSavedOutput(savedOutput)
                        } label: {
                            Label(savedOutput.name, systemImage: savedOutput.displayID == nil ? "macwindow" : "display")
                        }
                    }
                }
            }
            let openedOutputs = session.outputs.filter { output.openOutputIDs.contains($0.id) }
            if !openedOutputs.isEmpty {
                Section("Close Output") {
                    ForEach(openedOutputs) { openedOutput in
                        Button("Close · \(openedOutput.name)", systemImage: "xmark.circle") {
                            output.close(outputID: openedOutput.id)
                        }
                    }
                }
            }
            let removableOutputs = session.outputs.filter { $0.id != ProjectionOutput.mainID }
            if !removableOutputs.isEmpty {
                Section("Remove Saved Output") {
                    ForEach(removableOutputs) { removableOutput in
                        Button("Remove · \(removableOutput.name)", systemImage: "trash", role: .destructive) {
                            output.close(outputID: removableOutput.id)
                            session.removeOutput(removableOutput.id)
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: output.isVirtualOutput ? "macwindow" : "display")
                Text(output.activeOutputTitle ?? selectedScreenName)
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .bold))
            }
            .frame(maxWidth: 220)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Palette.control)
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .menuStyle(.borderlessButton)
        .disabled(!renderer.renderingAvailable)
        .help("Open a physical or virtual output, switch displays, or close an output")
    }

    private var customVirtualCanvasSheet: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("CUSTOM VIRTUAL CANVAS")
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                Spacer()
                Button("Cancel") { showsCustomVirtualCanvas = false }
                    .keyboardShortcut(.cancelAction)
            }
            Text("Set the render resolution for this window. The window stays resizable for your screen.")
                .font(.system(size: 10))
                .foregroundColor(Palette.secondaryText)
            HStack(spacing: 8) {
                TextField("Width", text: $customVirtualWidth)
                    .textFieldStyle(.roundedBorder)
                Text("×").foregroundColor(Palette.secondaryText)
                TextField("Height", text: $customVirtualHeight)
                    .textFieldStyle(.roundedBorder)
                Text("px")
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .foregroundColor(Palette.secondaryText)
            }
            Text("Width 320–7680 px · Height 240–4320 px")
                .font(.system(size: 9))
                .foregroundColor(Palette.tertiaryText)
            HStack {
                Spacer()
                Button("Open Canvas") {
                    openCustomVirtualOutput()
                    showsCustomVirtualCanvas = false
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canOpenCustomVirtualOutput)
            }
        }
        .padding(18)
        .frame(width: 370)
        .background(Palette.panel)
    }

    private var mediaPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                panelTitle("CLIP GRID", detail: "\(library.sources.count) CLIPS")
                Spacer()
                Menu {
                    Button("Import Images or Videos…", action: importMedia)
                    Divider()
                    if library.captureDevices.isEmpty {
                        Button("Refresh Capture Devices") { library.refreshCaptureDevices() }
                    } else {
                        Section("Live Camera / USB Capture") {
                            ForEach(library.captureDevices, id: \.uniqueID) { device in
                                Button(device.localizedName) {
                                    library.addCaptureDevice(device)
                                }
                            }
                        }
                    }
                    Divider()
                    if ndiInputsEnabled {
                        if ndiService.sources.isEmpty {
                            Button(ndiService.status.hasPrefix("NDI ready") ? "No NDI sources found" : "NDI unavailable · check Settings") {}
                                .disabled(true)
                        } else {
                            Section("NDI® Network Sources") {
                                ForEach(ndiService.sources) { source in
                                    Button(source.name) {
                                library.addNDISource(source) {
                                    guard let imported = library.sources.first(where: { $0.reference == source.reference }) else { return }
                                    assign(imported, to: selectedSurface)
                                }
                            }
                                    .help("Add this NDI input and assign it to the selected mask")
                                }
                            }
                        }
                        Button("Refresh NDI Sources") { ndiService.refresh() }
                    } else {
                        Button("NDI® inputs are off · Enable in Settings") {}
                            .disabled(true)
                    }
                    if syphonInputsEnabled {
                        if syphonService.sources.isEmpty {
                            Button(syphonService.status.hasPrefix("Syphon ready") ? "No Syphon servers found" : "Syphon unavailable · check Settings") {}
                                .disabled(true)
                        } else {
                            Section("Syphon Sources") {
                                ForEach(syphonService.sources) { source in
                                    Button(source.displayName) {
                                        library.addSyphonSource(source, device: renderer.device) {
                                            guard let imported = library.sources.first(where: { $0.reference == source.reference }) else { return }
                                            assign(imported, to: selectedSurface)
                                        }
                                    }
                                    .help("Add this Syphon input and assign it to the selected mask")
                                }
                            }
                        }
                        Button("Refresh Syphon Servers") { syphonService.refresh() }
                    } else {
                        Button("Syphon inputs are off · Enable in Settings") {}
                            .disabled(true)
                    }
                    Section("Generated Visuals") {
                        ForEach(VisualGenerator.presets) { generator in
                            Button(generator.title, systemImage: "sparkles") {
                                let source = library.addGenerator(generator)
                                assign(source, to: selectedSurface)
                            }
                        }
                    }
                    Link("NDI® is a registered trademark of Vizrt NDI AB", destination: URL(string: "https://ndi.video/")!)
                    Divider()
                    Button("Camera Access…") { library.requestCaptureAccess() }
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 12, weight: .bold))
                        .frame(width: 29, height: 29)
                        .background(Palette.control)
                        .clipShape(RoundedRectangle(cornerRadius: 7))
                }
                .menuStyle(.borderlessButton)
                .help("Import files or add a live capture source")
            }
            .padding(.horizontal, 16)
            .padding(.top, 15)
            .padding(.bottom, 9)

            Menu {
                ForEach(session.surfaces) { surface in
                    Button {
                        selectedSurfaceID = surface.id
                    } label: {
                        if surface.id == selectedSurface?.id {
                            Label(surface.name, systemImage: "checkmark")
                        } else {
                            Text(surface.name)
                        }
                    }
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "scope")
                        .foregroundColor(Palette.accentSoft)
                    Text("ASSIGN TO")
                        .foregroundColor(Palette.secondaryText)
                    Spacer(minLength: 4)
                    Text(selectedSurface?.name ?? "No mask")
                        .lineLimit(1)
                        .foregroundColor(Palette.primaryText)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundColor(Palette.secondaryText)
                }
                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(Palette.raised)
                .clipShape(RoundedRectangle(cornerRadius: 7))
            }
            .menuStyle(.borderlessButton)
            .padding(.horizontal, 12)
            .padding(.bottom, 10)

            Text("Click a clip to map it to this mask. Use the layer button on a clip to add it to the composition grid.")
                .font(.system(size: 8))
                .foregroundColor(Palette.tertiaryText)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 16)
                .padding(.bottom, 8)

            if let importMessage = library.importMessage {
                Text(importMessage)
                    .font(.system(size: 10))
                    .foregroundColor(Palette.secondaryText)
                    .lineLimit(3)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 8)
            }

            if library.sources.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "square.stack.3d.up")
                        .font(.system(size: 25, weight: .light))
                        .foregroundColor(Palette.secondaryText)
                    Text("Your media appears here")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(Palette.secondaryText)
                    Button("Import Media", action: importMedia)
                        .font(.system(size: 11, weight: .semibold))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(Palette.control)
                        .clipShape(RoundedRectangle(cornerRadius: 7))
                        .buttonStyle(.plain)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                        ForEach(library.sources) { source in
                            MediaClipCell(
                                source: source,
                                isSelected: selectedMediaSourceID == source.id,
                                isAssigned: selectedSurface?.sourcePath == source.reference
                                    || session.layers.contains { $0.id == selectedLayerID && $0.source.reference == source.reference },
                                onAssign: { assignClipToCurrentTarget(source) },
                                onTogglePlayback: source.togglePlayback,
                                onAddLayer: { selectedLayerID = session.addLayer(source: source) },
                                onRemove: { library.remove(source) },
                                onEditGenerator: { editGenerator(source, configuration: $0) }
                            )
                        }
                    }
                    .padding(12)
                }
            }

            Spacer(minLength: 0)
        }
        .background(Palette.panel)
    }

    private var previewPanel: some View {
        VStack(spacing: 0) {
            HStack {
                panelTitle(
                    previewSceneID == nil ? "MAPPING PREVIEW" : "SCENE PREVIEW",
                    detail: previewSceneID == nil ? "DRAG CORNERS AND MASK POINTS" : "STAGED · PROGRAM OUTPUT IS UNAFFECTED"
                )
                Spacer()
                Menu {
                    ForEach(CalibrationPattern.allCases) { pattern in
                        Button(pattern.rawValue) { canvasSession.setCalibrationPattern(pattern) }
                    }
                } label: {
                    Label(session.calibrationPattern.rawValue, systemImage: "scope")
                        .font(.system(size: 10, weight: .medium))
                        .padding(.horizontal, 9)
                        .padding(.vertical, 7)
                        .background(Palette.control)
                        .clipShape(RoundedRectangle(cornerRadius: 7))
                }
                .menuStyle(.borderlessButton)

                Menu {
                    Section("Mapping Preset") {
                        Button("Save Mapping…", action: saveMapping)
                        Button("Load Mapping…", action: loadMapping)
                    }
                    Section("Show File") {
                        Button("Save Show…", action: saveShow)
                        Button("Export Portable Show Bundle…", action: exportShowBundle)
                        Button("Load Show or Bundle…", action: loadShow)
                    }
                } label: {
                    Label("Project", systemImage: "folder")
                        .font(.system(size: 10, weight: .medium))
                        .padding(.horizontal, 9)
                        .padding(.vertical, 7)
                        .background(Palette.control)
                        .clipShape(RoundedRectangle(cornerRadius: 7))
                }
                .menuStyle(.borderlessButton)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 15)

            if let stagedScene {
                previewTakeBar(stagedScene)
            }
            mappingToolbar

            GeometryReader { geometry in
                let fitWidth = min(geometry.size.width, geometry.size.height * 16.0 / 9.0)
                let canvasWidth = fitWidth * mappingZoom
                let canvasHeight = canvasWidth * 9.0 / 16.0
                let hasAssignedSurfaceContent = canvasSession.surfaces.contains { !$0.usesLayerStack && $0.sourcePath != nil }
                ScrollView([.horizontal, .vertical], showsIndicators: mappingZoom > 1.01) {
                    ZStack {
                        Palette.background
                        ZStack {
                            MetalCanvas(
                                renderer: renderer,
                                session: canvasSession,
                                outputID: mappingPreviewOutputID,
                                preferredFramesPerSecond: previewFrameRate,
                                previewScale: previewRenderScale
                            )
                                .frame(width: canvasWidth, height: canvasHeight)
                                .background(Color.black)
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                                .overlay {
                                    RoundedRectangle(cornerRadius: 8)
                                        .stroke(Palette.border, lineWidth: 1)
                                }

                            if previewSceneID == nil, let surface = selectedSurface {
                                MappingEditorOverlay(
                                    surface: surfaceForMaskEditing(surface),
                                    isMoveToolEnabled: isMoveToolEnabled,
                                    isMaskEditingEnabled: isMaskEditingEnabled,
                                    isMeshEditingEnabled: isMeshEditingEnabled,
                                    showsGrid: snapMappingPoints,
                                    snapToVertices: snapToVertices,
                                    snapTargets: session.surfaces
                                        .filter { $0.id != surface.id }
                                        .flatMap(\.corners),
                                    selectedMaskPointIndex: $selectedMaskPointIndex,
                                    outputMaskPath: selectedOutputMaskPath(for: surface),
                                    isOutputMaskEditingEnabled: selectedOutputMaskPathID != nil,
                                    selectedOutputMaskPointIndex: $selectedOutputMaskPointIndex,
                                    onBeginGeometryEdit: { session.beginGeometryEdit() },
                                    onEndGeometryEdit: { session.endGeometryEdit() },
                                    onCorner: { index, point in session.updateCorner(index, to: point, on: surface.id) },
                                    onEdgeMove: { index, point in session.moveSurfaceEdge(index, to: point, on: surface.id) },
                                    onMeshControlPoint: { index, point in session.updateMeshControlPoint(index, to: point, on: surface.id) },
                                    onMaskPoint: { index, point in updateSelectedMaskPoint(index, to: point, on: surface) },
                                    onMove: { dx, dy in session.translateSurface(surface.id, dx: dx, dy: dy) },
                                    onInsertMaskPoint: { edgeIndex in
                                        let previousCount = maskPoints(for: surface).count
                                        insertSelectedMaskPoint(after: edgeIndex, on: surface)
                                        selectedMaskPointIndex = edgeIndex == previousCount - 1 ? previousCount : edgeIndex + 1
                                    },
                                    onRemoveMaskPoint: { index in
                                        removeSelectedMaskPoint(at: index, on: surface)
                                        selectedMaskPointIndex = nil
                                    },
                                    onOutputMaskPoint: { index, point in updateOutputMaskPoint(index, to: point, on: surface) },
                                    onInsertOutputMaskPoint: { edgeIndex in
                                        let pointCount = selectedOutputMaskPath(for: surface)?.points.count ?? 0
                                        insertOutputMaskPoint(after: edgeIndex, on: surface)
                                        selectedOutputMaskPointIndex = edgeIndex == pointCount - 1 ? pointCount : edgeIndex + 1
                                    },
                                    onRemoveOutputMaskPoint: { index in
                                        removeOutputMaskPoint(at: index, on: surface)
                                        selectedOutputMaskPointIndex = nil
                                    }
                                )
                                .frame(width: canvasWidth, height: canvasHeight)
                            }

                            if session.surfaces.isEmpty {
                                Text("Add a projection surface")
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundColor(Palette.secondaryText)
                                    .allowsHitTesting(false)
                        } else if canvasSession.layers.isEmpty && !hasAssignedSurfaceContent && canvasSession.calibrationPattern == .off {
                                Text("Choose a clip in the library, or add it to a layer track.")
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundColor(Palette.secondaryText)
                                    .allowsHitTesting(false)
                            }

                            if !renderer.renderingAvailable {
                                Text(renderer.gpuName)
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundColor(Palette.orange)
                                    .padding(10)
                                    .background(Palette.background.opacity(0.88))
                                    .clipShape(RoundedRectangle(cornerRadius: 6))
                                    .allowsHitTesting(false)
                            }
                        }
                        .frame(width: canvasWidth, height: canvasHeight)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.horizontal, 30)
            .padding(.vertical, 16)

            HStack(spacing: 8) {
                Image(systemName: "info.circle")
                Text("\(canvasSession.surfaces.count) surface\(canvasSession.surfaces.count == 1 ? "" : "s") · \(canvasSession.layers.count) media layer\(canvasSession.layers.count == 1 ? "" : "s") · geometry is resolution independent")
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .font(.system(size: 10))
            .foregroundColor(Palette.secondaryText)
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
            .overlay(alignment: .top) { dividerLine }
        }
        .background(Palette.background)
    }

    private var mappingToolbar: some View {
        HStack(spacing: 5) {
            Button {
                isMoveToolEnabled.toggle()
                if isMoveToolEnabled {
                    isMaskEditingEnabled = false
                    isMeshEditingEnabled = false
                }
            } label: {
                Label("Move", systemImage: "hand.draw")
            }
            .buttonStyle(.bordered)
            .tint(isMoveToolEnabled ? Palette.accent : Palette.secondaryText)
            .help("Drag inside the selected surface to move it")

            Button {
                isMaskEditingEnabled.toggle()
                if isMaskEditingEnabled {
                    isMoveToolEnabled = false
                    isMeshEditingEnabled = false
                }
            } label: {
                Label("Mask", systemImage: "point.3.connected.trianglepath.dotted")
            }
            .buttonStyle(.bordered)
            .tint(isMaskEditingEnabled ? Palette.accent : Palette.secondaryText)
            .help("Show and edit mask vertices; click + on an edge to insert a point")

            Button {
                isMeshEditingEnabled.toggle()
                if isMeshEditingEnabled {
                    isMoveToolEnabled = false
                    isMaskEditingEnabled = false
                }
            } label: {
                Label("Mesh", systemImage: "arrow.up.and.down.and.arrow.left.and.right")
            }
            .buttonStyle(.bordered)
            .tint(isMeshEditingEnabled ? Palette.accent : Palette.secondaryText)
            .disabled(selectedSurface?.meshWarp == nil)
            .help("Show and edit the selected surface's mesh control points")

            Button(action: session.undoGeometry) {
                Image(systemName: "arrow.uturn.backward")
            }
            .buttonStyle(.bordered)
            .disabled(!session.canUndoGeometry)
            .keyboardShortcut("z", modifiers: .command)
            .help("Undo geometry change (⌘Z)")

            Button(action: session.redoGeometry) {
                Image(systemName: "arrow.uturn.forward")
            }
            .buttonStyle(.bordered)
            .disabled(!session.canRedoGeometry)
            .keyboardShortcut("z", modifiers: [.command, .shift])
            .help("Redo geometry change (⇧⌘Z)")

            Button { snapMappingPoints.toggle() } label: {
                Image(systemName: "grid")
            }
            .buttonStyle(.bordered)
            .tint(snapMappingPoints ? Palette.accent : Palette.secondaryText)
            .help("Show a 10 × 10 guide and snap edited points to 1% increments")

            Button { snapToVertices.toggle() } label: {
                Image(systemName: snapToVertices ? "dot.circle.fill" : "dot.circle")
            }
            .buttonStyle(.bordered)
            .tint(snapToVertices ? Palette.accent : Palette.secondaryText)
            .help("Snap corners to the corners of other surfaces")

            Picker("Preview Output", selection: $mappingPreviewOutputID) {
                ForEach(session.outputs) { outputConfig in
                    Text(outputConfig.name).tag(outputConfig.id)
                }
            }
            .pickerStyle(.menu)
            .frame(width: 132)
            .help("Choose the output canvas shown in the mapping editor")

            Spacer(minLength: 4)

            Button { mappingZoom = max(0.5, mappingZoom - 0.1) } label: {
                Image(systemName: "minus.magnifyingglass")
            }
            .buttonStyle(.bordered)
            .help("Zoom out")
            Text("\(Int(mappingZoom * 100))%")
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .foregroundColor(Palette.secondaryText)
                .frame(width: 36)
            Button { mappingZoom = min(4, mappingZoom + 0.1) } label: {
                Image(systemName: "plus.magnifyingglass")
            }
            .buttonStyle(.bordered)
            .help("Zoom in; scroll the canvas to pan")
            Button("Fit") { mappingZoom = 1 }
                .buttonStyle(.bordered)
                .help("Fit the complete output canvas")
        }
        .font(.system(size: 9, weight: .medium))
        .controlSize(.mini)
        .padding(.horizontal, 18)
        .padding(.bottom, 6)
    }

    private func previewTakeBar(_ scene: ScenePreset) -> some View {
        HStack(spacing: 8) {
            Label("PREVIEW READY · \(scene.name)", systemImage: "eye.fill")
                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                .foregroundColor(Palette.accentSoft)
                .lineLimit(1)
            Spacer()
            Button("Cancel") { cancelScenePreview() }
                .buttonStyle(.bordered)
                .controlSize(.mini)
            Button("CUT") { takePreviewScene(transitionStyle: .cut) }
                .buttonStyle(.bordered)
                .controlSize(.mini)
                .tint(.orange)
                .help("Take this cue immediately without a transition")
            Button {
                takePreviewScene()
            } label: {
                Label("TAKE SCENE", systemImage: "play.fill")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundColor(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Color.red.opacity(takeButtonPulse ? 1 : 0.72))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.return, modifiers: .command)
            .help("Take this preview to the live output")
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 6)
        .background(Palette.control.opacity(0.6))
    }

    private var playbackTransitionControls: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 7) {
                Text("TRANSITION")
                    .font(.system(size: 8, weight: .semibold, design: .monospaced))
                    .foregroundColor(Palette.secondaryText)
                Picker("Transition", selection: $sceneTransitionStyle) {
                    ForEach(SceneTransitionStyle.allCases) { style in
                        Text(style.rawValue).tag(style.rawValue)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: .infinity)
            }
            HStack(spacing: 7) {
                Text("DURATION")
                    .font(.system(size: 8, weight: .semibold, design: .monospaced))
                    .foregroundColor(Palette.secondaryText)
                Slider(value: $sceneTransitionDuration, in: 0.05...5, step: 0.05)
                    .controlSize(.mini)
                    .disabled(playbackTransitionStyle == .cut)
                    .help("Set the active transition duration")
                Text(String(format: "%.2f s", sceneTransitionDuration))
                    .font(.system(size: 8, weight: .medium, design: .monospaced))
                    .monospacedDigit()
                    .foregroundColor(Palette.primaryText)
                    .frame(width: 46, alignment: .trailing)
            }
            HStack(spacing: 5) {
                Text("CURVE")
                    .font(.system(size: 8, weight: .semibold, design: .monospaced))
                    .foregroundColor(Palette.secondaryText)
                Picker("Transition curve", selection: $sceneTransitionCurve) {
                    ForEach(SceneTransitionCurve.allCases) { curve in
                        Text(curve.rawValue).tag(curve.rawValue)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .disabled(playbackTransitionStyle == .cut)
                Spacer()
                ForEach([0.25, 0.5, 1.0, 2.0], id: \.self) { duration in
                    Button(String(format: "%.2g", duration)) { sceneTransitionDuration = duration }
                        .buttonStyle(.bordered)
                        .controlSize(.mini)
                        .help("Set duration to \(duration) seconds")
                        .disabled(playbackTransitionStyle == .cut)
                }
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 8)
        .background(Palette.raised)
        .clipShape(RoundedRectangle(cornerRadius: 7))
    }

    private var programMonitor: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text("PROGRAM OUTPUT")
                    .font(.system(size: 8, weight: .semibold, design: .monospaced))
                    .foregroundColor(Palette.secondaryText)
                Spacer()
                Circle()
                    .fill(output.activeOutputTitle == nil ? Palette.tertiaryText : Palette.green)
                    .frame(width: 6, height: 6)
                Text(output.activeOutputTitle ?? "OUTPUT CLOSED")
                    .font(.system(size: 7, weight: .medium))
                    .foregroundColor(Palette.tertiaryText)
                    .lineLimit(1)
            }
            MetalCanvas(
                renderer: renderer,
                session: session,
                preferredFramesPerSecond: previewFrameRate,
                previewScale: previewRenderScale
            )
                .aspectRatio(16.0 / 9.0, contentMode: .fit)
                .background(Color.black)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Palette.border, lineWidth: 1))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .overlay(alignment: .bottom) { dividerLine }
    }

    private var layersPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                panelTitle("COMPOSITION GRID", detail: "SOURCE CLIPS × LAYER TRACKS")
                Spacer()
                Menu {
                    Section("Add Layer from Clip") {
                        ForEach(library.sources) { source in
                            Button(source.title) {
                                selectedLayerID = session.addLayer(source: source)
                            }
                        }
                    }
                } label: {
                    Label("Layer +", systemImage: "plus")
                        .font(.system(size: 9, weight: .semibold))
                }
                .menuStyle(.borderlessButton)
                .disabled(library.sources.isEmpty || session.isMappingLocked)
                .help("Add a layer track with a clip slot row")
                Button(action: session.toggleBlackout) {
                    Image(systemName: session.isBlackout ? "lightbulb.slash.fill" : "lightbulb")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(session.isBlackout ? Palette.orange : Palette.secondaryText)
                        .frame(width: 29, height: 29)
                        .background(Palette.control)
                        .clipShape(RoundedRectangle(cornerRadius: 7))
                }
                .buttonStyle(.plain)
                .help("Toggle master blackout")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 15)

            programMonitor

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    surfaceControls

                    VStack(alignment: .leading, spacing: 9) {
                        HStack {
                            Text("LAYER TRACKS")
                                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                                .foregroundColor(Palette.secondaryText)
                            Spacer()
                            Text("TOP IS FRONT · CLICK A SLOT TO LOAD IT")
                                .font(.system(size: 8, weight: .medium, design: .monospaced))
                                .foregroundColor(Palette.tertiaryText)
                        }
                        if session.layers.isEmpty {
                            Text("Add media from the library")
                                .font(.system(size: 10))
                                .foregroundColor(Palette.tertiaryText)
                                .padding(.vertical, 5)
                        } else {
                            ForEach(Array(session.layers.enumerated().reversed()), id: \.element.id) { index, layer in
                                LayerRow(
                                    layer: layer,
                                    source: layer.source,
                                    availableSources: library.sources,
                                    number: session.layers.count - index,
                                    isSelected: selectedLayerID == layer.id,
                                    onSelect: { selectedLayerID = layer.id },
                                    onToggle: { session.setEnabled(!$0, for: layer.id) },
                                    onSolo: { session.setSolo(!$0, for: layer.id) },
                                    onMove: { session.moveLayer(layer.id, by: $0) },
                                    canMoveUp: index < session.layers.count - 1
                                        && !layer.isLocked
                                        && !session.layers[index + 1].isLocked,
                                    canMoveDown: index > 0
                                        && !layer.isLocked
                                        && !session.layers[index - 1].isLocked,
                                    onRename: { session.renameLayer(layer.id, to: $0) },
                                    onDuplicate: { session.duplicateLayer(layer.id) },
                                    onToggleLock: { session.setLayerLocked(!$0, for: layer.id) },
                                    onContentTransform: { session.setContentTransform($0, for: layer.id) },
                                    onOpacity: { session.setOpacity($0, for: layer.id) },
                                    onRemove: { session.removeLayer(layer) },
                                    onSelectSource: { session.setLayerSource($0, for: layer.id) },
                                    onEffectStack: { session.setEffectStack($0, for: layer.id) },
                                    userEffectPresets: userEffectPresets,
                                    onSaveEffectPreset: beginSavingEffectPreset,
                                    onDeleteEffectPreset: deleteUserEffectPreset
                                )
                            }
                        }
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Text("MASTER OUTPUT")
                            .font(.system(size: 9, weight: .semibold, design: .monospaced))
                            .tracking(0.8)
                            .foregroundColor(Palette.secondaryText)
                        HStack {
                            Circle().fill(output.activeOutputTitle == nil ? Palette.tertiaryText : Palette.green).frame(width: 7, height: 7)
                            Text(output.activeOutputTitle ?? "No output open")
                                .font(.system(size: 10, weight: .medium))
                                .lineLimit(1)
                            Spacer(minLength: 0)
                            Text(output.activeOutputTitle == nil ? "CLOSED" : "LIVE")
                                .font(.system(size: 8, weight: .bold, design: .monospaced))
                                .foregroundColor(output.activeOutputTitle == nil ? Palette.secondaryText : Palette.green)
                        }
                        HStack(spacing: 8) {
                            Text("INTENSITY")
                                .font(.system(size: 8, weight: .semibold, design: .monospaced))
                                .foregroundColor(Palette.secondaryText)
                            Slider(value: $masterOutputIntensity, in: 0...1)
                                .controlSize(.small)
                                .help("Set program output intensity")
                            Text("\(Int(masterOutputIntensity * 100))%")
                                .font(.system(size: 9, weight: .medium, design: .monospaced))
                                .monospacedDigit()
                                .frame(width: 34, alignment: .trailing)
                        }
                        HStack {
                            Button(session.isBlackout ? "Restore Output" : "Blackout") {
                                session.setBlackout(!session.isBlackout)
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .tint(session.isBlackout ? Palette.green : .red)
                            .disabled(output.activeOutputTitle == nil)
                            if ndiOutputEnabled {
                                Label(ndiOutputService.status.contains("On Air") ? "NDI ON AIR" : "NDI", systemImage: "dot.radiowaves.left.and.right")
                                    .font(.system(size: 8, weight: .semibold, design: .monospaced))
                                    .foregroundColor(ndiOutputService.status.contains("On Air") ? Palette.green : Palette.orange)
                                    .help(ndiOutputService.status)
                            }
                            Spacer(minLength: 0)
                        }
                    }
                    .padding(12)
                    .background(Palette.raised)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .contextMenu {
                        if output.activeOutputTitle != nil {
                            Button("Close Output", action: output.close)
                        }
                    }
                }
                .padding(12)
            }
        }
        .background(Palette.panel)
    }

    private var selectedSurface: ProjectionSurface? {
        session.surfaces.first(where: { $0.id == selectedSurfaceID }) ?? session.surfaces.first
    }

    private var canvasSession: RenderSession {
        previewSceneID == nil ? session : previewSession
    }

    private var stagedScene: ScenePreset? {
        guard let previewSceneID else { return nil }
        return session.scenes.first(where: { $0.id == previewSceneID })
    }

    private func assign(_ source: MediaSource, to surface: ProjectionSurface?) {
        selectedMediaSourceID = source.id
        guard let surface else { return }
        session.setSourceCatalog(library.sources)
        let path = source.reference
        session.setSurfaceSource(path, usesLayerStack: false, on: surface.id)
        if source.kind == .video && !source.isPlaying {
            source.togglePlayback()
        }
    }

    private func assignClipToCurrentTarget(_ source: MediaSource) {
        selectedMediaSourceID = source.id
        if let selectedLayerID,
           let layer = session.layers.first(where: { $0.id == selectedLayerID }),
           !layer.isLocked {
            session.setLayerSource(source, for: selectedLayerID)
            if source.kind == .video && !source.isPlaying { source.togglePlayback() }
            return
        }
        assign(source, to: selectedSurface)
    }

    private func editGenerator(_ source: MediaSource, configuration: VisualGenerator) {
        guard let references = source.updateGeneratorConfiguration(configuration) else { return }
        session.updateSourceReference(from: references.oldReference, to: references.newReference)
        previewSession.updateSourceReference(from: references.oldReference, to: references.newReference)
    }

    private func stageSceneForPreview(_ scene: ScenePreset) {
        previewSession.copyContent(from: session)
        previewSession.stageScene(scene, sources: library.sources)
        previewSceneID = scene.id
    }

    private func cancelScenePreview() {
        previewSceneID = nil
        previewSession.copyContent(from: session)
    }

    private func takePreviewScene(transitionStyle: SceneTransitionStyle? = nil) {
        guard let stagedScene else {
            cancelScenePreview()
            return
        }
        takeScene(stagedScene, transitionStyle: transitionStyle, duration: nil)
    }

    private func configureExternalControl() {
        if externalHTTPRemoteAccess && externalAPIToken.isEmpty {
            externalAPIToken = UUID().uuidString.lowercased()
        }
        externalControl.configureHTTP(
            enabled: externalHTTPEnabled,
            port: externalHTTPPort,
            remoteAccess: externalHTTPRemoteAccess,
            token: externalAPIToken
        )
        externalControl.configureOSC(enabled: externalOSCEnabled, port: externalOSCPort)
    }

    private func configureExternalStatusProvider() {
        externalControl.statusProvider = { [weak session, weak output] in
            let outputOpen = output?.activeOutputTitle != nil
            let isBlackedOut = session?.isBlackout ?? false
            let status: [String: Any] = [
                "blackout": isBlackedOut,
                "active": outputOpen && !isBlackedOut,
                "intensity": session?.outputIntensity ?? 1,
                "outputOpen": outputOpen,
                "output": output?.activeOutputTitle ?? "",
                "outputs": session?.outputs.map { item in
                    [
                        "id": item.id.uuidString,
                        "name": item.name,
                        "open": output?.openOutputIDs.contains(item.id) ?? false
                    ] as [String: Any]
                } ?? [],
                "currentScene": session?.currentSceneID?.uuidString ?? "",
                "scenes": session?.scenes.map { ["id": $0.id.uuidString, "name": $0.name] } ?? [],
                "surfaces": session?.surfaces.map { surface in
                    let targetOutputID = surface.outputID ?? ProjectionOutput.mainID
                    let targetOutputName = session?.outputs.first(where: { $0.id == targetOutputID })?.name ?? "Main Output"
                    return [
                        "id": surface.id.uuidString,
                        "name": surface.name,
                        "locked": surface.isLocked,
                        "active": surface.isVisible && !surface.isBlackout,
                        "visible": surface.isVisible,
                        "blackout": surface.isBlackout,
                        "intensity": surface.brightness,
                        "source": surface.sourcePath ?? "",
                        "usesLayerStack": surface.usesLayerStack,
                        "outputID": targetOutputID.uuidString,
                        "output": targetOutputName,
                        "corners": surface.corners.map { [$0.x, $0.y] }
                    ] as [String: Any]
                } ?? []
            ]
            return (try? JSONSerialization.data(withJSONObject: status, options: [.sortedKeys])) ?? Data("{}".utf8)
        }
    }

    private func configureNDIOutput() {
        ndiOutputService.configure(
            enabled: ndiOutputEnabled,
            sourceName: ndiOutputSourceName,
            targetOutputID: output.activeOutputID
        )
    }

    private func configureSyphonOutput() {
        syphonOutputService.configure(
            enabled: syphonOutputEnabled,
            sourceName: syphonOutputSourceName,
            targetOutputID: output.activeOutputID,
            device: renderer.device
        )
    }

    private func executeExternalControl(_ command: ExternalControlCommand) {
        switch command {
        case .setBlackout(let enabled):
            if session.isBlackout != enabled { session.toggleBlackout() }
        case .setOutputActive(let active):
            session.setBlackout(!active)
        case .setOutputIntensity(let intensity):
            masterOutputIntensity = intensity
        case .setSurfaceActive(let surfaceID, let active):
            session.setSurfaceActive(active, on: surfaceID)
        case .setSurfaceBlackout(let surfaceID, let blackout):
            session.setSurfaceBlackout(blackout, on: surfaceID)
        case .setSurfaceIntensity(let surfaceID, let intensity):
            session.setSurfaceIntensity(intensity, on: surfaceID)
        case .setSurfaceActiveNamed(let name, let active):
            guard let surfaceID = uniqueSurfaceID(named: name) else { return }
            session.setSurfaceActive(active, on: surfaceID)
        case .setSurfaceBlackoutNamed(let name, let blackout):
            guard let surfaceID = uniqueSurfaceID(named: name) else { return }
            session.setSurfaceBlackout(blackout, on: surfaceID)
        case .setSurfaceIntensityNamed(let name, let intensity):
            guard let surfaceID = uniqueSurfaceID(named: name) else { return }
            session.setSurfaceIntensity(intensity, on: surfaceID)
        case .toggleBlackout:
            session.toggleBlackout()
        case .stepCue(let direction):
            stepSceneCue(direction)
        case .takeScene(let sceneID):
            guard let scene = session.scenes.first(where: { $0.id == sceneID }) else { return }
            takeScene(scene)
        case .takeSceneNamed(let name):
            guard let sceneID = uniqueSceneID(named: name),
                  let scene = session.scenes.first(where: { $0.id == sceneID }) else { return }
            takeScene(scene)
        case .setCorner(let surfaceID, let cornerIndex, let point):
            session.updateCorner(cornerIndex, to: point, on: surfaceID)
        }
    }

    private func uniqueSurfaceID(named name: String) -> UUID? {
        let matches = session.surfaces.filter {
            $0.name.localizedCaseInsensitiveCompare(name.trimmingCharacters(in: .whitespacesAndNewlines)) == .orderedSame
        }
        return matches.count == 1 ? matches.first?.id : nil
    }

    private func uniqueSceneID(named name: String) -> UUID? {
        let normalizedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedName.isEmpty else { return nil }
        let matches = session.scenes.filter {
            $0.name.localizedCaseInsensitiveCompare(normalizedName) == .orderedSame
        }
        return matches.count == 1 ? matches.first?.id : nil
    }

    private func surfaceSourceTitle(_ surface: ProjectionSurface) -> String {
        if surface.usesLayerStack { return "Layer stack" }
        guard let sourcePath = surface.sourcePath else { return "No clip assigned" }
        if let source = library.sources.first(where: { $0.reference == sourcePath }) { return source.title }
        if let generator = VisualGenerator(reference: sourcePath) { return generator.title }
        return sourcePath.hasPrefix("capture://") ? "Unavailable Live Input" : URL(fileURLWithPath: sourcePath).lastPathComponent
    }

    private var surfaceControls: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Text("MASK OUTPUTS")
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .foregroundColor(Palette.secondaryText)
                Spacer()
                Menu {
                    Button("Quadrilateral") { addSurface(ProjectionSurface(name: "Quadrilateral")) }
                    Button("Triangle") { addSurface(.triangle()) }
                    Button("Circle") { addSurface(.circle()) }
                    Button("Ellipse") { addSurface(.ellipse()) }
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 10, weight: .bold))
                        .frame(width: 24, height: 24)
                        .background(Palette.control)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                }
                .menuStyle(.borderlessButton)
                .help("Add projection surface")
            }

            ForEach(session.surfaces) { surface in
                Button {
                    selectedSurfaceID = surface.id
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 7) {
                            Image(systemName: surface.maskKind == .cross ? "plus" : "rectangle.dashed")
                                .foregroundColor(surface.id == selectedSurface?.id ? Palette.accentSoft : Palette.secondaryText)
                            Text(surface.name)
                                .lineLimit(1)
                            Spacer(minLength: 0)
                            if surface.isLocked { Image(systemName: "lock.fill") }
                            if surface.isBlackout { Image(systemName: "lightbulb.slash.fill").foregroundColor(Palette.orange) }
                        }
                        HStack(spacing: 5) {
                            Image(systemName: "arrow.right")
                                .font(.system(size: 7))
                            Text(surfaceSourceTitle(surface))
                                .lineLimit(1)
                        }
                        .font(.system(size: 8, weight: .medium))
                        .foregroundColor(Palette.tertiaryText)
                    }
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(surface.id == selectedSurface?.id ? Palette.primaryText : Palette.secondaryText)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 7)
                    .background(surface.id == selectedSurface?.id ? Palette.control : Palette.raised)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)
                .contextMenu {
                    Button(surface.isVisible ? "Hide Surface" : "Show Surface") { mutate(surface) { $0.isVisible.toggle() } }
                    Button(surface.isBlackout ? "Enable Surface" : "Black Out Surface") { mutate(surface) { $0.isBlackout.toggle() } }
                    Button("Delete Surface", role: .destructive) {
                        session.removeSurface(surface.id)
                        selectedSurfaceID = session.surfaces.first(where: { $0.id != surface.id })?.id
                    }
                }
            }

            if let surface = selectedSurface {
                Rectangle().fill(Palette.border).frame(height: 1).padding(.vertical, 2)

                HStack {
                    TextField("Surface name", text: Binding(
                        get: { surface.name },
                        set: { value in mutate(surface) { $0.name = value } }
                    ))
                    .textFieldStyle(.roundedBorder)
                    Button {
                        mutate(surface) { $0.isLocked.toggle() }
                    } label: {
                        Image(systemName: surface.isLocked ? "lock.fill" : "lock.open")
                            .foregroundColor(surface.isLocked ? Palette.orange : Palette.secondaryText)
                            .frame(width: 26, height: 25)
                            .background(Palette.control)
                            .clipShape(RoundedRectangle(cornerRadius: 5))
                    }
                    .buttonStyle(.plain)
                    .help(surface.isLocked ? "Unlock mapping geometry" : "Lock mapping geometry")
                }

                geometryInspector(surface)

                Picker("Content", selection: Binding(
                    get: { surface.usesLayerStack ? "@layers" : (surface.sourcePath ?? "") },
                    set: { value in
                        if value == "@layers" {
                            session.setSurfaceSource(nil, usesLayerStack: true, on: surface.id)
                        } else if value.isEmpty {
                            session.setSurfaceSource(nil, usesLayerStack: false, on: surface.id)
                        } else {
                            session.setSurfaceSource(value, usesLayerStack: false, on: surface.id)
                        }
                    }
                )) {
                    Text("No Source").tag("")
                    Text("Layer Stack").tag("@layers")
                    ForEach(library.sources) { source in
                    Text(source.title).tag(source.reference)
                    }
                    if let missing = surface.sourcePath,
                   !library.sources.contains(where: { $0.reference == missing }),
                   !missing.hasPrefix("generator://"), !missing.hasPrefix("syphon://") {
                    Text("Missing: \(missing.hasPrefix("capture://") ? "Live Input" : URL(fileURLWithPath: missing).lastPathComponent)").tag(missing)
                    }
                }
                .font(.system(size: 10))
                .pickerStyle(.menu)

                Picker("Mask", selection: Binding(
                    get: { surface.maskKind },
                    set: { kind in
                        mutate(surface) {
                            let previousKind = $0.maskKind
                            $0.maskKind = kind
                            if kind == .rectangle { $0.maskPoints = ProjectionSurface.rectanglePoints }
                            if kind == .polygon && previousKind != .polygon {
                                $0.maskPoints = [
                                    NormalizedPoint(0.06, 0.06), NormalizedPoint(0.94, 0.06),
                                    NormalizedPoint(0.94, 0.94), NormalizedPoint(0.06, 0.94)
                                ]
                            }
                        }
                    }
                )) {
                    if surface.maskKind == .cross {
                        Text("Existing custom mask").tag(SurfaceMaskKind.cross)
                    }
                    ForEach(SurfaceMaskKind.allCases.filter { $0 != .cross }) { kind in
                        Text(kind.rawValue).tag(kind)
                    }
                }
                .font(.system(size: 10))
                .pickerStyle(.menu)

                HStack(spacing: 6) {
                    Button(surface.isVisible ? "Visible" : "Hidden") { mutate(surface) { $0.isVisible.toggle() } }
                    Button(surface.isBlackout ? "Blackout On" : "Blackout Off") { mutate(surface) { $0.isBlackout.toggle() } }
                    Button("Invert Mask") { mutate(surface) { $0.isMaskInverted.toggle() } }
                }
                .font(.system(size: 8, weight: .medium))
                .buttonStyle(.bordered)
                .controlSize(.mini)

                HStack(spacing: 7) {
                    Text("MASK EDGE FEATHER")
                        .font(.system(size: 7, weight: .semibold, design: .monospaced))
                        .foregroundColor(Palette.secondaryText)
                        .frame(width: 92, alignment: .leading)
                    Slider(value: Binding(
                        get: { surface.maskFeather ?? 0 },
                        set: { value in mutate(surface) { $0.maskFeather = value } }
                    ), in: 0...0.05)
                    .controlSize(.mini)
                    .tint(Palette.accent)
                    Text(String(format: "%.1f%%", (surface.maskFeather ?? 0) * 100))
                        .font(.system(size: 8, weight: .medium, design: .monospaced))
                        .foregroundColor(Palette.secondaryText)
                        .frame(width: 35, alignment: .trailing)
                }
                .help("Soften the polygon mask edge by up to 5% of the source size")

                surfaceSlider(title: "BRIGHTNESS", value: surface.brightness, disabled: false) { target, value in
                    mutate(target) { $0.brightness = value }
                }
                surfaceSlider(title: "SURFACE OPACITY", value: surface.opacity, disabled: false) { target, value in
                    mutate(target) { $0.opacity = value }
                }

                HStack {
                    Button {
                        isColorCorrectionExpanded.toggle()
                    } label: {
                        HStack(spacing: 6) {
                            Text("COLOUR CORRECTION")
                                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                                .foregroundColor(Palette.secondaryText)
                            if surface.colorCorrection != nil {
                                Circle().fill(Palette.accentSoft).frame(width: 5, height: 5)
                            }
                            Image(systemName: isColorCorrectionExpanded ? "chevron.up" : "chevron.down")
                                .font(.system(size: 8, weight: .bold))
                                .foregroundColor(Palette.secondaryText)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    Spacer(minLength: 0)
                    Button {
                        session.resetColorCorrection(on: surface.id)
                    } label: {
                        Image(systemName: "arrow.counterclockwise")
                            .font(.system(size: 8, weight: .semibold))
                            .foregroundColor(Palette.secondaryText)
                    }
                    .buttonStyle(.plain)
                    .help("Reset surface colour correction")
                    .disabled(surface.colorCorrection == nil)
                }

                if isColorCorrectionExpanded {
                    VStack(spacing: 7) {
                        correctionSlider("CONTRAST", surface: surface, keyPath: \.contrast, range: 0...2)
                        correctionSlider("SATURATION", surface: surface, keyPath: \.saturation, range: 0...2)
                        correctionSlider("EXPOSURE", surface: surface, keyPath: \.exposure, range: -4...4)
                        correctionSlider("GAMMA", surface: surface, keyPath: \.gamma, range: 0.1...4)
                        correctionSlider("RED GAIN", surface: surface, keyPath: \.redGain, range: 0...2)
                        correctionSlider("GREEN GAIN", surface: surface, keyPath: \.greenGain, range: 0...2)
                        correctionSlider("BLUE GAIN", surface: surface, keyPath: \.blueGain, range: 0...2)
                        HStack(spacing: 8) {
                            Toggle("B&W", isOn: correctionLookBinding(surface, keyPath: \.isGrayscale))
                            Toggle("Sepia", isOn: correctionLookBinding(surface, keyPath: \.isSepia))
                            Toggle("Invert", isOn: correctionLookBinding(surface, keyPath: \.isInverted))
                        }
                        .font(.system(size: 8, weight: .medium))
                        .toggleStyle(.checkbox)
                    }
                    .padding(.vertical, 2)
                }

                HStack(spacing: 6) {
                    Button {
                        isEffectStackExpanded.toggle()
                    } label: {
                        HStack(spacing: 6) {
                            Text("EFFECT STACK")
                                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                                .foregroundColor(Palette.secondaryText)
                            if !(surface.effectStack ?? []).isEmpty {
                                Circle().fill(Palette.accentSoft).frame(width: 5, height: 5)
                            }
                            Image(systemName: isEffectStackExpanded ? "chevron.up" : "chevron.down")
                                .font(.system(size: 8, weight: .bold))
                                .foregroundColor(Palette.secondaryText)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    Spacer(minLength: 0)
                    Menu {
                        Section("Add Effect") {
                            ForEach(SurfaceEffectKind.allCases) { kind in
                                Button(kind.rawValue) { appendEffect(kind, to: surface) }
                                    .disabled((surface.effectStack ?? []).count >= SurfaceEffect.maximumStackSize)
                            }
                        }
                        Section("Apply Preset") {
                            ForEach(SurfaceEffectPreset.allCases) { preset in
                                Button(preset.rawValue) {
                                    session.setEffectStack(preset.effects, on: surface.id)
                                }
                            }
                        }
                        Section("Saved Presets") {
                            if userEffectPresets.isEmpty {
                                Text("No saved presets")
                            } else {
                                ForEach(userEffectPresets) { preset in
                                    Button(preset.name) {
                                        session.setEffectStack(preset.effects, on: surface.id)
                                    }
                                }
                            }
                        }
                        Section("Save Current") {
                            Button("Save Stack as Preset…") { beginSavingEffectPreset(surface.effectStack ?? []) }
                                .disabled((surface.effectStack ?? []).isEmpty)
                        }
                        if !userEffectPresets.isEmpty {
                            Section("Delete Saved Preset") {
                                ForEach(userEffectPresets) { preset in
                                    Button("Delete · \(preset.name)", role: .destructive) {
                                        deleteUserEffectPreset(preset.id)
                                    }
                                }
                            }
                        }
                        Divider()
                        Button("Clear Stack", role: .destructive) {
                            session.resetEffectStack(on: surface.id)
                        }
                        .disabled((surface.effectStack ?? []).isEmpty)
                    } label: {
                        Image(systemName: "slider.horizontal.3")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundColor(Palette.secondaryText)
                    }
                    .menuStyle(.borderlessButton)
                    .help("Add an effect or apply a reusable preset")
                }

                if isEffectStackExpanded {
                    VStack(alignment: .leading, spacing: 7) {
                        if (surface.effectStack ?? []).isEmpty {
                            Text("Add blur or chroma key, or choose a preset.")
                                .font(.system(size: 8))
                                .foregroundColor(Palette.tertiaryText)
                        }
                        ForEach(Array((surface.effectStack ?? []).enumerated()), id: \.element.id) { entry in
                            effectEditor(entry.element, index: entry.offset, surface: surface)
                        }
                    }
                    .padding(.vertical, 2)
                }

                HStack {
                    Text("MASK VERTICES · \(maskPoints(for: surface).count)")
                        .font(.system(size: 8, weight: .semibold, design: .monospaced))
                        .foregroundColor(Palette.secondaryText)
                    Spacer()
                    Button(isMaskEditingEnabled ? "Done" : "Edit Vertices") {
                        isMaskEditingEnabled.toggle()
                        if isMaskEditingEnabled {
                            isMoveToolEnabled = false
                            isMeshEditingEnabled = false
                        }
                        if !isMaskEditingEnabled { selectedMaskPointIndex = nil }
                    }
                    .disabled(isMappingGeometryLocked(surface))
                }
                .buttonStyle(.bordered)
                .controlSize(.mini)
                if isMaskEditingEnabled {
                    Text("Drag a numbered point · click + on an edge to add · right-click a point to remove")
                        .font(.system(size: 7))
                        .foregroundColor(Palette.tertiaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }

                HStack(spacing: 6) {
                    Button {
                        selectedSurfaceID = session.duplicateSurface(surface.id)
                    } label: {
                        Label("Duplicate", systemImage: "plus.square.on.square")
                    }
                    .font(.system(size: 9))
                    Button("Delete Surface", role: .destructive) {
                        session.removeSurface(surface.id)
                        selectedSurfaceID = session.surfaces.first(where: { $0.id != surface.id })?.id
                    }
                    .font(.system(size: 9))
                    .disabled(session.surfaces.count <= 1)
                }
            }

        }
    }

    private func geometryInspector(_ surface: ProjectionSurface) -> some View {
        let activeMaskPoints = maskPoints(for: surface)
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Button {
                    isGeometryExpanded.toggle()
                } label: {
                    HStack(spacing: 5) {
                        Text("OUTPUT GEOMETRY")
                            .font(.system(size: 8, weight: .semibold, design: .monospaced))
                            .foregroundColor(Palette.secondaryText)
                        Image(systemName: isGeometryExpanded ? "chevron.up" : "chevron.down")
                            .font(.system(size: 7, weight: .bold))
                            .foregroundColor(Palette.secondaryText)
                    }
                }
                .buttonStyle(.plain)
                Spacer()
                Button("Reset All") { session.resetGeometry(on: surface.id) }
                    .font(.system(size: 8, weight: .medium))
                    .buttonStyle(.plain)
                    .disabled(isMappingGeometryLocked(surface))
                    .help("Reset all four corners to the full output canvas")
            }

            if isGeometryExpanded {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 5) {
                        Text("INPUT SELECTION")
                            .font(.system(size: 7, weight: .semibold, design: .monospaced))
                            .foregroundColor(Palette.secondaryText)
                        Spacer(minLength: 0)
                        Button("Reset") {
                            session.updateContentTransform(on: surface.id) { $0 = .identity }
                        }
                        .font(.system(size: 7, weight: .medium))
                        .buttonStyle(.plain)
                        .disabled(isMappingGeometryLocked(surface))
                    }
                    Text("Adjust the source inside the calibrated surface.")
                        .font(.system(size: 7))
                        .foregroundColor(Palette.tertiaryText)
                    contentTransformSlider("ZOOM X", surface: surface, keyPath: \.zoomX, range: 0.25...4, format: "%.2f×")
                    contentTransformSlider("ZOOM Y", surface: surface, keyPath: \.zoomY, range: 0.25...4, format: "%.2f×")
                    contentTransformSlider("POSITION X", surface: surface, keyPath: \.offsetX, range: -0.5...0.5, format: "%+.2f")
                    contentTransformSlider("POSITION Y", surface: surface, keyPath: \.offsetY, range: -0.5...0.5, format: "%+.2f")
                    contentTransformSlider("ROTATION", surface: surface, keyPath: \.rotationDegrees, range: -180...180, format: "%.0f°")
                    HStack(spacing: 12) {
                        contentTransformToggle("Flip H", surface: surface, keyPath: \.isFlippedHorizontally)
                        contentTransformToggle("Flip V", surface: surface, keyPath: \.isFlippedVertically)
                        Spacer(minLength: 0)
                    }
                }
                .padding(.bottom, 4)

                HStack(spacing: 6) {
                    Text("OUTPUT")
                        .font(.system(size: 7, weight: .semibold, design: .monospaced))
                        .foregroundColor(Palette.secondaryText)
                        .frame(width: 43, alignment: .leading)
                    Picker("Surface output", selection: Binding(
                        get: { surface.outputID ?? ProjectionOutput.mainID },
                        set: { session.assignSurface(surface.id, to: $0) }
                    )) {
                        ForEach(session.outputs) { outputConfig in
                            Text(outputConfig.name).tag(outputConfig.id)
                        }
                    }
                    .pickerStyle(.menu)
                    .font(.system(size: 8))
                    .disabled(isMappingGeometryLocked(surface))
                    Spacer(minLength: 0)
                }
                if let outputConfig = session.outputs.first(where: { $0.id == (surface.outputID ?? ProjectionOutput.mainID) }) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("EDGE BLEND · WIDTH OF OUTPUT")
                            .font(.system(size: 7, weight: .semibold, design: .monospaced))
                            .foregroundColor(Palette.tertiaryText)
                        outputBlendSlider("LEFT", output: outputConfig, keyPath: \.blendLeft)
                        outputBlendSlider("RIGHT", output: outputConfig, keyPath: \.blendRight)
                        outputBlendSlider("TOP", output: outputConfig, keyPath: \.blendTop)
                        outputBlendSlider("BOTTOM", output: outputConfig, keyPath: \.blendBottom)
                    }
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 4) {
                            Text("GLOBAL OUTPUT EXCLUSIONS")
                                .font(.system(size: 7, weight: .semibold, design: .monospaced))
                                .foregroundColor(Palette.secondaryText)
                            Spacer(minLength: 0)
                            Menu {
                                Button("Add Polygon Exclusion") { addOutputExclusion(outputConfig, circular: false) }
                                Button("Add Circular Exclusion") { addOutputExclusion(outputConfig, circular: true) }
                            } label: {
                                Label("Add", systemImage: "plus")
                                    .font(.system(size: 7, weight: .medium))
                            }
                            .menuStyle(.borderlessButton)
                            .disabled((outputConfig.exclusionPaths?.count ?? 0) >= 8)
                        }
                        if (outputConfig.exclusionPaths ?? []).isEmpty {
                            Text("Hide fixed objects after all surfaces are warped.")
                                .font(.system(size: 7))
                                .foregroundColor(Palette.tertiaryText)
                        } else {
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 4) {
                                    ForEach(outputConfig.exclusionPaths ?? []) { path in
                                        Button(path.name) { selectOutputMaskPath(path.id, on: outputConfig.id) }
                                            .tint(selectedOutputMaskPathID == path.id ? Palette.accent : Palette.secondaryText)
                                            .buttonStyle(.bordered)
                                            .controlSize(.mini)
                                    }
                                }
                            }
                            outputMaskFeatherSlider(outputConfig)
                            if let path = outputConfig.exclusionPaths?.first(where: { $0.id == selectedOutputMaskPathID }) {
                                HStack(spacing: 4) {
                                    Text("EDITING \(path.name.uppercased())")
                                        .font(.system(size: 7, weight: .medium, design: .monospaced))
                                        .foregroundColor(Palette.accentSoft)
                                    Spacer(minLength: 0)
                                    Button(role: .destructive) {
                                        session.updateOutputMaskConfiguration(outputConfig.id) { output in
                                            output.exclusionPaths?.removeAll { $0.id == path.id }
                                        }
                                        selectedOutputMaskPathID = nil
                                    } label: {
                                        Image(systemName: "trash")
                                    }
                                    .buttonStyle(.plain)
                                    .help("Delete this output exclusion")
                                }
                                Text("Drag a pink point, tap + on an edge to add one, or right-click a point to remove it.")
                                    .font(.system(size: 8))
                                    .foregroundColor(Palette.tertiaryText)
                            }
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 4) {
                        Text("MASK PATHS")
                            .font(.system(size: 7, weight: .semibold, design: .monospaced))
                            .foregroundColor(Palette.secondaryText)
                        Spacer(minLength: 0)
                        Menu {
                            Button("Add Region") { addMaskPath(on: surface, operation: .include) }
                                .disabled(isMappingGeometryLocked(surface) || (surface.additionalMaskPaths?.count ?? 0) >= 7)
                            Button("Add Hole / Cutout") { addMaskPath(on: surface, operation: .exclude) }
                                .disabled(isMappingGeometryLocked(surface) || (surface.additionalMaskPaths?.count ?? 0) >= 7)
                        } label: {
                            Label("Add Path", systemImage: "plus")
                                .font(.system(size: 7, weight: .medium))
                        }
                        .menuStyle(.borderlessButton)
                    }
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 4) {
                            Button("Main") { selectMaskPath(nil) }
                                .tint(selectedMaskPathID == nil ? Palette.accent : Palette.secondaryText)
                                .buttonStyle(.bordered)
                                .controlSize(.mini)
                            ForEach(surface.additionalMaskPaths ?? []) { path in
                                Button { selectMaskPath(path.id) } label: {
                                    Label(
                                        path.name,
                                        systemImage: path.operation == .include ? "plus.circle.fill" : "minus.circle.fill"
                                    )
                                }
                                    .tint(selectedMaskPathID == path.id ? Palette.accent : Palette.secondaryText)
                                    .buttonStyle(.bordered)
                                    .controlSize(.mini)
                            }
                        }
                    }
                    if let pathID = selectedMaskPathID,
                       let path = surface.additionalMaskPaths?.first(where: { $0.id == pathID }) {
                        HStack(spacing: 4) {
                            Text(path.name)
                                .font(.system(size: 7, weight: .medium, design: .monospaced))
                                .foregroundColor(Palette.secondaryText)
                            Picker("Path operation", selection: maskPathOperationBinding(surface, pathID: path.id)) {
                                Text("Include area").tag(ProjectionMaskOperation.include)
                                Text("Cut out area").tag(ProjectionMaskOperation.exclude)
                            }
                            .pickerStyle(.menu)
                            .font(.system(size: 8))
                            .disabled(isMappingGeometryLocked(surface))
                            Button(role: .destructive) {
                                session.removeMaskPath(path.id, on: surface.id)
                                selectedMaskPathID = nil
                                selectedMaskPointIndex = nil
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.plain)
                            .font(.system(size: 8))
                            .help("Delete this mask path")
                            .disabled(isMappingGeometryLocked(surface))
                            Spacer(minLength: 0)
                        }
                    }
                }

                Toggle("Enable Mesh Warp", isOn: Binding(
                    get: { surface.meshWarp != nil },
                    set: { enabled in
                        session.setMeshWarpEnabled(enabled, on: surface.id)
                        isMeshEditingEnabled = enabled
                        if enabled {
                            isMoveToolEnabled = false
                            isMaskEditingEnabled = false
                        }
                    }
                ))
                .font(.system(size: 8, weight: .medium))
                .toggleStyle(.checkbox)
                .disabled(isMappingGeometryLocked(surface))
                .help("Add independently draggable mesh points inside the four-corner keystone")
                if surface.meshWarp != nil {
                    HStack(spacing: 6) {
                        Text("GRID")
                            .font(.system(size: 7, weight: .semibold, design: .monospaced))
                            .foregroundColor(Palette.secondaryText)
                        Picker("Mesh grid", selection: Binding(
                            get: { surface.meshWarp?.subdivisionCount ?? 3 },
                            set: { session.setMeshWarpSubdivisions($0, on: surface.id) }
                        )) {
                            ForEach(2...6, id: \.self) { divisions in
                                Text("\(divisions) × \(divisions) cells").tag(divisions)
                            }
                        }
                        .pickerStyle(.menu)
                        .font(.system(size: 8))
                        .disabled(isMappingGeometryLocked(surface))
                    }
                    HStack(spacing: 6) {
                        Text("Drag purple points to bend the mapped surface.")
                            .font(.system(size: 7))
                            .foregroundColor(Palette.tertiaryText)
                        Spacer(minLength: 0)
                        Button("Reset Mesh") { session.resetMeshWarp(on: surface.id) }
                            .font(.system(size: 7, weight: .medium))
                            .buttonStyle(.plain)
                            .disabled(isMappingGeometryLocked(surface))
                    }
                }
                HStack(spacing: 4) {
                    Text("CORNER")
                        .frame(width: 43, alignment: .leading)
                    Text("X %").frame(width: 64)
                    Text("Y %").frame(width: 64)
                    Spacer()
                }
                .font(.system(size: 7, weight: .semibold, design: .monospaced))
                .foregroundColor(Palette.tertiaryText)

                ForEach(0..<4, id: \.self) { index in
                    HStack(spacing: 4) {
                        Text(["TL", "TR", "BR", "BL"][index])
                            .font(.system(size: 8, weight: .semibold, design: .monospaced))
                            .foregroundColor(Palette.secondaryText)
                            .frame(width: 43, alignment: .leading)
                        coordinateTextField("X", value: cornerCoordinateBinding(surface, cornerIndex: index, axis: .horizontal), disabled: surface.isLocked)
                        coordinateTextField("Y", value: cornerCoordinateBinding(surface, cornerIndex: index, axis: .vertical), disabled: surface.isLocked)
                        Button {
                            session.resetCorner(index, on: surface.id)
                        } label: {
                            Image(systemName: "arrow.counterclockwise")
                                .font(.system(size: 8, weight: .medium))
                        }
                        .buttonStyle(.plain)
                        .disabled(isMappingGeometryLocked(surface))
                        .help("Reset this corner")
                    }
                }

                HStack(spacing: 4) {
                    Text("H KEYSTONE")
                        .font(.system(size: 7, weight: .semibold, design: .monospaced))
                        .foregroundColor(Palette.secondaryText)
                        .frame(width: 67, alignment: .leading)
                    geometryActionButton("minus", help: "Narrow the top edge and widen the bottom edge") {
                        session.adjustHorizontalKeystone(keystoneStep, on: surface.id)
                    }
                    geometryActionButton("plus", help: "Widen the top edge and narrow the bottom edge") {
                        session.adjustHorizontalKeystone(-keystoneStep, on: surface.id)
                    }
                    Text("V KEYSTONE")
                        .font(.system(size: 7, weight: .semibold, design: .monospaced))
                        .foregroundColor(Palette.secondaryText)
                        .padding(.leading, 4)
                    geometryActionButton("minus", help: "Lean the left edge inward and the right edge outward") {
                        session.adjustVerticalKeystone(keystoneStep, on: surface.id)
                    }
                    geometryActionButton("plus", help: "Lean the left edge outward and the right edge inward") {
                        session.adjustVerticalKeystone(-keystoneStep, on: surface.id)
                    }
                    Spacer(minLength: 0)
                }
                HStack(spacing: 5) {
                    Text("KEYSTONE STEP")
                        .font(.system(size: 7, weight: .semibold, design: .monospaced))
                        .foregroundColor(Palette.tertiaryText)
                    Picker("Keystone step", selection: $keystoneStep) {
                        Text("Fine · 0.1%").tag(0.001)
                        Text("Medium · 0.5%").tag(0.005)
                        Text("Coarse · 1%").tag(0.01)
                    }
                    .pickerStyle(.menu)
                    .font(.system(size: 8))
                    .disabled(isMappingGeometryLocked(surface))
                    Spacer(minLength: 0)
                }

                VStack(alignment: .leading, spacing: 3) {
                    Text("INDIVIDUAL EDGE WIDTH")
                        .font(.system(size: 7, weight: .semibold, design: .monospaced))
                        .foregroundColor(Palette.tertiaryText)
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 3) {
                        ForEach(0..<4, id: \.self) { edgeIndex in
                            let edgeName = ["TOP", "RIGHT", "BOTTOM", "LEFT"][edgeIndex]
                            HStack(spacing: 3) {
                                Text(edgeName)
                                    .font(.system(size: 7, weight: .semibold, design: .monospaced))
                                    .foregroundColor(Palette.secondaryText)
                                    .frame(width: 40, alignment: .leading)
                                geometryActionButton("minus", help: "Narrow the \(edgeName.lowercased()) edge") {
                                    session.adjustSurfaceEdgeWidth(edgeIndex, by: -keystoneStep, on: surface.id)
                                }
                                geometryActionButton("plus", help: "Widen the \(edgeName.lowercased()) edge") {
                                    session.adjustSurfaceEdgeWidth(edgeIndex, by: keystoneStep, on: surface.id)
                                }
                            }
                        }
                    }
                    Text("Drag a cyan edge handle on the canvas to move that side.")
                        .font(.system(size: 7))
                        .foregroundColor(Palette.tertiaryText)
                }

                HStack(spacing: 4) {
                    Text("MOVE")
                        .font(.system(size: 7, weight: .semibold, design: .monospaced))
                        .foregroundColor(Palette.secondaryText)
                        .frame(width: 43, alignment: .leading)
                    geometryActionButton("arrow.left", help: "Move left 0.1%") { session.translateSurface(surface.id, dx: -0.001, dy: 0) }
                    geometryActionButton("arrow.up", help: "Move up 0.1%") { session.translateSurface(surface.id, dx: 0, dy: -0.001) }
                    geometryActionButton("arrow.down", help: "Move down 0.1%") { session.translateSurface(surface.id, dx: 0, dy: 0.001) }
                    geometryActionButton("arrow.right", help: "Move right 0.1%") { session.translateSurface(surface.id, dx: 0.001, dy: 0) }
                    Spacer(minLength: 0)
                    Text("0.1% / tap")
                        .font(.system(size: 7, design: .monospaced))
                        .foregroundColor(Palette.tertiaryText)
                }

                HStack(spacing: 5) {
                    Text("SCALE")
                        .font(.system(size: 7, weight: .semibold, design: .monospaced))
                        .foregroundColor(Palette.secondaryText)
                    geometryActionButton("minus", help: "Scale down 1%") { session.scaleSurface(surface.id, scaleX: 0.99, scaleY: 0.99) }
                    geometryActionButton("plus", help: "Scale up 1%") { session.scaleSurface(surface.id, scaleX: 1.01, scaleY: 1.01) }
                    Text("ROTATE")
                        .font(.system(size: 7, weight: .semibold, design: .monospaced))
                        .foregroundColor(Palette.secondaryText)
                        .padding(.leading, 5)
                    geometryActionButton("rotate.left", help: "Rotate counterclockwise 1°") { session.rotateSurface(surface.id, degrees: -1) }
                    geometryActionButton("rotate.right", help: "Rotate clockwise 1°") { session.rotateSurface(surface.id, degrees: 1) }
                    Spacer(minLength: 0)
                }

                if let index = selectedMaskPointIndex, activeMaskPoints.indices.contains(index) {
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 4) {
                            Text("VERTEX \(index + 1) / \(activeMaskPoints.count)")
                                .font(.system(size: 7, weight: .semibold, design: .monospaced))
                                .foregroundColor(Palette.accentSoft)
                                .frame(width: 75, alignment: .leading)
                            Spacer(minLength: 0)
                            Button {
                                selectedMaskPointIndex = (index - 1 + activeMaskPoints.count) % activeMaskPoints.count
                            } label: { Image(systemName: "chevron.left") }
                                .help("Select previous mask vertex")
                            Button {
                                selectedMaskPointIndex = (index + 1) % activeMaskPoints.count
                            } label: { Image(systemName: "chevron.right") }
                                .help("Select next mask vertex")
                            Button {
                                insertSelectedMaskPoint(after: index, on: surface)
                                selectedMaskPointIndex = index + 1
                            } label: { Image(systemName: "plus") }
                                .help("Insert a new vertex after this one")
                                .disabled(isMappingGeometryLocked(surface) || activeMaskPoints.count >= 32)
                            Button(role: .destructive) {
                                removeSelectedMaskPoint(at: index, on: surface)
                                selectedMaskPointIndex = nil
                            } label: { Image(systemName: "trash") }
                                .help("Delete selected mask vertex")
                                .disabled(isMappingGeometryLocked(surface) || activeMaskPoints.count <= 3)
                        }
                        .buttonStyle(.plain)
                        .font(.system(size: 8, weight: .medium))

                        HStack(spacing: 3) {
                                Text("SELECT VERTEX")
                                .font(.system(size: 7, weight: .semibold, design: .monospaced))
                                .foregroundColor(Palette.tertiaryText)
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 3) {
                                    ForEach(activeMaskPoints.indices, id: \.self) { pointIndex in
                                        Button {
                                            selectedMaskPointIndex = pointIndex
                                        } label: {
                                            Text("\(pointIndex + 1)")
                                                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                                                .frame(width: 24, height: 22)
                                                .foregroundColor(selectedMaskPointIndex == pointIndex ? .black : Palette.secondaryText)
                                                .background(selectedMaskPointIndex == pointIndex ? Palette.accent : Palette.control)
                                                .clipShape(RoundedRectangle(cornerRadius: 4))
                                        }
                                        .buttonStyle(.plain)
                                        .help("Select mask vertex \(pointIndex + 1)")
                                    }
                                }
                            }
                            .frame(height: 26)
                        }

                        HStack(spacing: 4) {
                            Text("SOURCE %")
                                .font(.system(size: 7, weight: .semibold, design: .monospaced))
                                .foregroundColor(Palette.tertiaryText)
                            coordinateTextField("X", value: maskCoordinateBinding(surface, pointIndex: index, axis: .horizontal), disabled: surface.isLocked)
                            coordinateTextField("Y", value: maskCoordinateBinding(surface, pointIndex: index, axis: .vertical), disabled: surface.isLocked)
                        }

                        HStack(spacing: 4) {
                            Text("NUDGE")
                                .font(.system(size: 7, weight: .semibold, design: .monospaced))
                                .foregroundColor(Palette.tertiaryText)
                            Picker("Vertex nudge", selection: $maskNudgeStep) {
                                Text("0.1%").tag(0.001)
                                Text("0.5%").tag(0.005)
                                Text("1%").tag(0.01)
                            }
                            .pickerStyle(.menu)
                            .font(.system(size: 8))
                            maskNudgeButton("arrow.left", help: "Move selected vertex left") {
                                nudgeMaskVertex(surface, index: index, dx: -maskNudgeStep, dy: 0)
                            }
                            maskNudgeButton("arrow.up", help: "Move selected vertex up") {
                                nudgeMaskVertex(surface, index: index, dx: 0, dy: -maskNudgeStep)
                            }
                            maskNudgeButton("arrow.down", help: "Move selected vertex down") {
                                nudgeMaskVertex(surface, index: index, dx: 0, dy: maskNudgeStep)
                            }
                            maskNudgeButton("arrow.right", help: "Move selected vertex right") {
                                nudgeMaskVertex(surface, index: index, dx: maskNudgeStep, dy: 0)
                            }
                            Spacer(minLength: 0)
                        }

                        if let outputPoint = ProjectiveTransform.sourceToOutput(activeMaskPoints[index], corners: surface.corners) {
                            Text(String(format: "Canvas position  X %.1f%%  Y %.1f%%", outputPoint.x * 100, outputPoint.y * 100))
                                .font(.system(size: 7, design: .monospaced))
                                .foregroundColor(Palette.tertiaryText)
                        }
                    }
                    .padding(.top, 3)
                }
            }
        }
        .padding(8)
        .background(Palette.raised.opacity(0.55))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private func coordinateTextField(_ placeholder: String, value: Binding<Double>, disabled: Bool) -> some View {
        TextField(placeholder, value: value, format: .number.precision(.fractionLength(1)))
            .textFieldStyle(.roundedBorder)
            .font(.system(size: 8, design: .monospaced))
            .controlSize(.mini)
            .frame(width: 64)
            .disabled(disabled)
    }

    private func geometryActionButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 9, weight: .semibold))
                .frame(width: 24, height: 22)
                .background(Palette.control)
                .clipShape(RoundedRectangle(cornerRadius: 4))
        }
        .buttonStyle(.plain)
        .help(help)
        .disabled(selectedSurface.map(isMappingGeometryLocked) ?? true)
    }

    private func maskNudgeButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .semibold))
                .frame(width: 27, height: 25)
                .background(Palette.control)
                .clipShape(RoundedRectangle(cornerRadius: 4))
        }
        .buttonStyle(.plain)
        .help(help)
        .disabled(selectedSurface.map(isMappingGeometryLocked) ?? true)
    }

    private func nudgeMaskVertex(_ surface: ProjectionSurface, index: Int, dx: Double, dy: Double) {
        let activePoints = maskPoints(for: surface)
        guard activePoints.indices.contains(index),
              let outputPoint = ProjectiveTransform.sourceToOutput(activePoints[index], corners: surface.corners),
              let sourcePoint = ProjectiveTransform.outputToSource(
                NormalizedPoint(outputPoint.x + dx, outputPoint.y + dy).clamped(),
                corners: surface.corners
              ) else { return }
        updateSelectedMaskPoint(index, to: sourcePoint.clamped(), on: surface)
    }

    private func cornerCoordinateBinding(
        _ surface: ProjectionSurface,
        cornerIndex: Int,
        axis: GeometryAxis
    ) -> Binding<Double> {
        Binding(
            get: {
                guard surface.corners.indices.contains(cornerIndex) else { return 0 }
                let point = surface.corners[cornerIndex]
                return (axis == .horizontal ? point.x : point.y) * 100
            },
            set: { value in
                guard value.isFinite, surface.corners.indices.contains(cornerIndex) else { return }
                var point = surface.corners[cornerIndex]
                if axis == .horizontal { point.x = value / 100 } else { point.y = value / 100 }
                session.updateCorner(cornerIndex, to: point, on: surface.id)
            }
        )
    }

    private func maskCoordinateBinding(
        _ surface: ProjectionSurface,
        pointIndex: Int,
        axis: GeometryAxis
    ) -> Binding<Double> {
        Binding(
            get: {
                let points = maskPoints(for: surface)
                guard points.indices.contains(pointIndex) else { return 0 }
                let point = points[pointIndex]
                return (axis == .horizontal ? point.x : point.y) * 100
            },
            set: { value in
                let points = maskPoints(for: surface)
                guard value.isFinite, points.indices.contains(pointIndex) else { return }
                var point = points[pointIndex]
                if axis == .horizontal { point.x = value / 100 } else { point.y = value / 100 }
                updateSelectedMaskPoint(pointIndex, to: point, on: surface)
            }
        )
    }

    private func correctionSlider(
        _ title: String,
        surface: ProjectionSurface,
        keyPath: WritableKeyPath<SurfaceColorCorrection, Double>,
        range: ClosedRange<Double>
    ) -> some View {
        let binding = correctionBinding(surface, keyPath: keyPath)
        return HStack(spacing: 7) {
            Text(title)
                .font(.system(size: 7, weight: .semibold, design: .monospaced))
                .foregroundColor(Palette.secondaryText)
                .frame(width: 92, alignment: .leading)
            Slider(value: binding, in: range)
                .controlSize(.mini)
                .tint(Palette.accent)
            Text(String(format: "%.1f", binding.wrappedValue))
                .font(.system(size: 8, weight: .medium, design: .monospaced))
                .foregroundColor(Palette.secondaryText)
                .frame(width: 27, alignment: .trailing)
        }
    }

    private func outputBlendSlider(
        _ title: String,
        output: ProjectionOutput,
        keyPath: WritableKeyPath<ProjectionOutput, Double>
    ) -> some View {
        let binding = Binding<Double>(
            get: { output[keyPath: keyPath] },
            set: { value in
                var updated = output
                updated[keyPath: keyPath] = value
                session.updateOutput(updated)
            }
        )
        return HStack(spacing: 5) {
            Text(title)
                .font(.system(size: 7, weight: .semibold, design: .monospaced))
                .foregroundColor(Palette.secondaryText)
                .frame(width: 43, alignment: .leading)
            Slider(value: binding, in: 0...0.25)
                .controlSize(.mini)
                .tint(Palette.accent)
            Text(String(format: "%.0f%%", binding.wrappedValue * 100))
                .font(.system(size: 7, weight: .medium, design: .monospaced))
                .foregroundColor(Palette.secondaryText)
                .frame(width: 28, alignment: .trailing)
        }
    }

    private func outputMaskFeatherSlider(_ output: ProjectionOutput) -> some View {
        let binding = Binding<Double>(
            get: { output.exclusionFeather ?? 0 },
            set: { value in
                session.updateOutputMaskConfiguration(output.id) { $0.exclusionFeather = value }
            }
        )
        return HStack(spacing: 5) {
            Text("SOFT EDGE")
                .font(.system(size: 7, weight: .semibold, design: .monospaced))
                .foregroundColor(Palette.tertiaryText)
                .frame(width: 62, alignment: .leading)
            Slider(value: binding, in: 0...0.05, onEditingChanged: { isEditing in
                if isEditing { session.beginGeometryEdit() } else { session.endGeometryEdit() }
            })
                .controlSize(.mini)
                .tint(Palette.accent)
            Text(String(format: "%.1f%%", binding.wrappedValue * 100))
                .font(.system(size: 7, weight: .medium, design: .monospaced))
                .foregroundColor(Palette.secondaryText)
                .frame(width: 40, alignment: .trailing)
        }
    }

    private func contentTransformSlider(
        _ title: String,
        surface: ProjectionSurface,
        keyPath: WritableKeyPath<SurfaceContentTransform, Double>,
        range: ClosedRange<Double>,
        format: String
    ) -> some View {
        let binding = Binding<Double>(
            get: { (surface.contentTransform?.sanitized() ?? .identity)[keyPath: keyPath] },
            set: { value in
                session.updateContentTransform(on: surface.id) { $0[keyPath: keyPath] = value }
            }
        )
        return HStack(spacing: 5) {
            Text(title)
                .font(.system(size: 7, weight: .semibold, design: .monospaced))
                .foregroundColor(Palette.tertiaryText)
                .frame(width: 62, alignment: .leading)
            Slider(value: binding, in: range, onEditingChanged: { isEditing in
                if isEditing { session.beginGeometryEdit() } else { session.endGeometryEdit() }
            })
                .controlSize(.mini)
                .tint(Palette.accent)
                .disabled(isMappingGeometryLocked(surface))
            Text(String(format: format, binding.wrappedValue))
                .font(.system(size: 7, weight: .medium, design: .monospaced))
                .foregroundColor(Palette.secondaryText)
                .frame(width: 40, alignment: .trailing)
        }
    }

    private func contentTransformToggle(
        _ title: String,
        surface: ProjectionSurface,
        keyPath: WritableKeyPath<SurfaceContentTransform, Bool>
    ) -> some View {
        Toggle(title, isOn: Binding(
            get: { (surface.contentTransform?.sanitized() ?? .identity)[keyPath: keyPath] },
            set: { value in
                session.updateContentTransform(on: surface.id) { $0[keyPath: keyPath] = value }
            }
        ))
        .font(.system(size: 7, weight: .medium))
        .toggleStyle(.checkbox)
        .disabled(isMappingGeometryLocked(surface))
    }

    private func correctionBinding(
        _ surface: ProjectionSurface,
        keyPath: WritableKeyPath<SurfaceColorCorrection, Double>
    ) -> Binding<Double> {
        Binding(
            get: { (surface.colorCorrection ?? .neutral)[keyPath: keyPath] },
            set: { value in
                var correction = surface.colorCorrection ?? .neutral
                correction[keyPath: keyPath] = value
                session.setColorCorrection(correction, on: surface.id)
            }
        )
    }

    private func correctionLookBinding(
        _ surface: ProjectionSurface,
        keyPath: WritableKeyPath<SurfaceColorCorrection, Bool>
    ) -> Binding<Bool> {
        Binding(
            get: { (surface.colorCorrection ?? .neutral)[keyPath: keyPath] },
            set: { value in
                var correction = surface.colorCorrection ?? .neutral
                correction[keyPath: keyPath] = value
                session.setColorCorrection(correction, on: surface.id)
            }
        )
    }

    private func appendEffect(_ kind: SurfaceEffectKind, to surface: ProjectionSurface) {
        editEffectStack(surface) { effects in
            guard effects.count < SurfaceEffect.maximumStackSize else { return }
            effects.append(SurfaceEffect(kind: kind, radius: kind == .hueRotation ? 0 : 5))
        }
    }

    private func beginSavingEffectPreset(_ effects: [SurfaceEffect]) {
        guard !effects.isEmpty else { return }
        pendingEffectPresetEffects = effects.map { $0.sanitized() }
        effectPresetDraftName = "Preset \(userEffectPresets.count + 1)"
        isSavingEffectPreset = true
    }

    private func savePendingEffectPreset() {
        let name = effectPresetDraftName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !pendingEffectPresetEffects.isEmpty else { return }
        var presets = userEffectPresets
        presets.append(UserEffectPreset(name: name, effects: pendingEffectPresetEffects))
        guard let data = try? JSONEncoder().encode(presets),
              let encoded = String(data: data, encoding: .utf8) else { return }
        userEffectPresetsJSON = encoded
        pendingEffectPresetEffects = []
        isSavingEffectPreset = false
    }

    private func deleteUserEffectPreset(_ presetID: UUID) {
        let remaining = userEffectPresets.filter { $0.id != presetID }
        guard let data = try? JSONEncoder().encode(remaining),
              let encoded = String(data: data, encoding: .utf8) else { return }
        userEffectPresetsJSON = encoded
    }

    private func editEffectStack(_ surface: ProjectionSurface, _ change: (inout [SurfaceEffect]) -> Void) {
        var effects = surface.effectStack ?? []
        change(&effects)
        session.setEffectStack(effects, on: surface.id)
    }

    private func effectEditor(_ effect: SurfaceEffect, index: Int, surface: ProjectionSurface) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                Toggle(isOn: effectEnabledBinding(surface, effectID: effect.id)) {
                    Text(effect.kind.rawValue.uppercased())
                        .font(.system(size: 8, weight: .semibold, design: .monospaced))
                        .foregroundColor(Palette.primaryText)
                }
                .toggleStyle(.checkbox)
                Spacer(minLength: 0)
                Button {
                    editEffectStack(surface) { effects in
                        guard index > 0, effects.indices.contains(index) else { return }
                        effects.swapAt(index, index - 1)
                    }
                } label: {
                    Image(systemName: "arrow.up")
                }
                .disabled(index == 0)
                Button {
                    editEffectStack(surface) { effects in
                        guard index + 1 < effects.count else { return }
                        effects.swapAt(index, index + 1)
                    }
                } label: {
                    Image(systemName: "arrow.down")
                }
                .disabled(index + 1 >= (surface.effectStack ?? []).count)
                Button {
                    editEffectStack(surface) { effects in
                        guard effects.indices.contains(index) else { return }
                        effects.remove(at: index)
                    }
                } label: {
                    Image(systemName: "xmark")
                }
                .help("Remove effect")
            }
            .buttonStyle(.plain)

            switch effect.kind {
            case .blur:
                effectSlider("RADIUS", surface: surface, effectID: effect.id, keyPath: \.radius, range: 0...24, decimals: 0, suffix: "px")
            case .chromaKey:
                HStack(spacing: 5) {
                    Text("KEY COLOR")
                        .font(.system(size: 7, weight: .semibold, design: .monospaced))
                        .foregroundColor(Palette.secondaryText)
                    Spacer()
                    ColorPicker("Key color", selection: effectColorBinding(surface, effectID: effect.id), supportsOpacity: false)
                        .labelsHidden()
                        .controlSize(.mini)
                }
                effectSlider("TOLERANCE", surface: surface, effectID: effect.id, keyPath: \.threshold, range: 0...1, decimals: 2, suffix: "")
                effectSlider("SOFT EDGE", surface: surface, effectID: effect.id, keyPath: \.softness, range: 0.001...0.5, decimals: 2, suffix: "")
            case .brightness:
                effectSlider("GAIN", surface: surface, effectID: effect.id, keyPath: \.threshold, range: 0...2, decimals: 2, suffix: "×", scale: 2)
            case .saturation:
                effectSlider("SATURATION", surface: surface, effectID: effect.id, keyPath: \.threshold, range: 0...2, decimals: 2, suffix: "×", scale: 2)
            case .pixelate:
                effectSlider("BLOCK SIZE", surface: surface, effectID: effect.id, keyPath: \.radius, range: 1...64, decimals: 0, suffix: "px")
            case .hueRotation:
                effectSlider("ANGLE", surface: surface, effectID: effect.id, keyPath: \.radius, range: -180...180, decimals: 0, suffix: "°")
            case .tint:
                HStack(spacing: 5) {
                    Text("TINT COLOR")
                        .font(.system(size: 7, weight: .semibold, design: .monospaced))
                        .foregroundColor(Palette.secondaryText)
                    Spacer()
                    ColorPicker("Tint color", selection: effectColorBinding(surface, effectID: effect.id), supportsOpacity: false)
                        .labelsHidden()
                        .controlSize(.mini)
                }
                effectSlider("AMOUNT", surface: surface, effectID: effect.id, keyPath: \.threshold, range: 0...1, decimals: 2, suffix: "")
            case .sharpen:
                effectSlider("RADIUS", surface: surface, effectID: effect.id, keyPath: \.radius, range: 0...12, decimals: 1, suffix: "px")
            case .vignette:
                effectSlider("STRENGTH", surface: surface, effectID: effect.id, keyPath: \.threshold, range: 0...1, decimals: 2, suffix: "")
            case .lumaKey:
                effectSlider("CUTOFF", surface: surface, effectID: effect.id, keyPath: \.threshold, range: 0...1, decimals: 2, suffix: "")
                effectSlider("SOFT EDGE", surface: surface, effectID: effect.id, keyPath: \.softness, range: 0.001...0.5, decimals: 2, suffix: "")
            case .threshold:
                effectSlider("LEVEL", surface: surface, effectID: effect.id, keyPath: \.threshold, range: 0...1, decimals: 2, suffix: "")
            case .grayscale, .sepia, .invert:
                Text("Applies this look to the layer.")
                    .font(.system(size: 7))
                    .foregroundColor(Palette.tertiaryText)
            }
        }
        .padding(7)
        .background(Palette.raised)
        .clipShape(RoundedRectangle(cornerRadius: 5))
    }

    private func effectSlider(
        _ title: String,
        surface: ProjectionSurface,
        effectID: UUID,
        keyPath: WritableKeyPath<SurfaceEffect, Double>,
        range: ClosedRange<Double>,
        decimals: Int,
        suffix: String,
        scale: Double = 1
    ) -> some View {
        let binding = effectValueBinding(surface, effectID: effectID, keyPath: keyPath)
        let displayBinding = Binding(
            get: { binding.wrappedValue * scale },
            set: { binding.wrappedValue = $0 / scale }
        )
        return HStack(spacing: 6) {
            Text(title)
                .font(.system(size: 7, weight: .semibold, design: .monospaced))
                .foregroundColor(Palette.secondaryText)
                .frame(width: 64, alignment: .leading)
            Slider(value: displayBinding, in: range)
                .controlSize(.mini)
                .tint(Palette.accent)
            Text(String(format: "%.*f%@", decimals, displayBinding.wrappedValue, suffix))
                .font(.system(size: 7, weight: .medium, design: .monospaced))
                .foregroundColor(Palette.secondaryText)
                .frame(width: 34, alignment: .trailing)
        }
    }

    private func effectEnabledBinding(_ surface: ProjectionSurface, effectID: UUID) -> Binding<Bool> {
        Binding(
            get: { (surface.effectStack ?? []).first(where: { $0.id == effectID })?.isEnabled ?? false },
            set: { value in
                editEffectStack(surface) { effects in
                    guard let index = effects.firstIndex(where: { $0.id == effectID }) else { return }
                    effects[index].isEnabled = value
                }
            }
        )
    }

    private func effectValueBinding(
        _ surface: ProjectionSurface,
        effectID: UUID,
        keyPath: WritableKeyPath<SurfaceEffect, Double>
    ) -> Binding<Double> {
        Binding(
            get: { (surface.effectStack ?? []).first(where: { $0.id == effectID })?[keyPath: keyPath] ?? 0 },
            set: { value in
                editEffectStack(surface) { effects in
                    guard let index = effects.firstIndex(where: { $0.id == effectID }) else { return }
                    effects[index][keyPath: keyPath] = value
                }
            }
        )
    }

    private func effectColorBinding(_ surface: ProjectionSurface, effectID: UUID) -> Binding<Color> {
        Binding(
            get: {
                guard let color = (surface.effectStack ?? []).first(where: { $0.id == effectID })?.keyColor else {
                    return .green
                }
                return Color(red: color.red, green: color.green, blue: color.blue)
            },
            set: { value in
                let nativeColor = NSColor(value).usingColorSpace(.deviceRGB) ?? NSColor.green
                var red: CGFloat = 0
                var green: CGFloat = 0
                var blue: CGFloat = 0
                var alpha: CGFloat = 1
                nativeColor.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
                editEffectStack(surface) { effects in
                    guard let index = effects.firstIndex(where: { $0.id == effectID }) else { return }
                    effects[index].keyColor = SurfaceEffectColor(
                        red: Double(red),
                        green: Double(green),
                        blue: Double(blue)
                    )
                }
            }
        )
    }

    private func surfaceSlider(title: String, value: Double, disabled: Bool, onChange: @escaping (ProjectionSurface, Double) -> Void) -> some View {
        guard let surface = selectedSurface else { return AnyView(EmptyView()) }
        return AnyView(HStack(spacing: 7) {
            Text(title)
                .font(.system(size: 7, weight: .semibold, design: .monospaced))
                .foregroundColor(Palette.secondaryText)
                .frame(width: 92, alignment: .leading)
            Slider(value: Binding(get: { value }, set: { onChange(surface, $0) }), in: 0...1)
                .controlSize(.mini)
                .tint(Palette.accent)
                .disabled(disabled)
            Text("\(Int(value * 100))")
                .font(.system(size: 8, weight: .medium, design: .monospaced))
                .foregroundColor(Palette.secondaryText)
                .frame(width: 22, alignment: .trailing)
        })
    }

    private func mutate(_ surface: ProjectionSurface, _ change: (inout ProjectionSurface) -> Void) {
        var updated = surface
        change(&updated)
        session.updateSurface(updated)
    }

    private func isMappingGeometryLocked(_ surface: ProjectionSurface) -> Bool {
        surface.isLocked || session.isMappingLocked
    }

    private func addSurface(_ surface: ProjectionSurface) {
        session.addSurface(surface)
        selectedSurfaceID = surface.id
    }

    private var footer: some View {
        HStack(spacing: 18) {
            Label("GPU", systemImage: "cpu")
                .foregroundColor(Palette.secondaryText)
            Text(renderer.gpuName)
                .foregroundColor(renderer.renderingAvailable ? Palette.primaryText : Palette.orange)
                .lineLimit(1)
            Spacer()
            Text(output.activeOutputID == nil ? "PREVIEW FPS" : "OUTPUT FPS")
                .foregroundColor(Palette.secondaryText)
            Text(displayedPresentedFPS > 0 ? String(format: "%.0f", displayedPresentedFPS) : "—")
                .foregroundColor(Palette.primaryText)
                .help("Rolling rate of successfully presented Metal frames for the active output")
            if let latePercent = displayedLatePresentationPercent {
                Text(String(format: "%.0f%% LATE", latePercent))
                    .foregroundColor(latePercent >= 10 ? Palette.orange : Palette.secondaryText)
                    .help("Estimated presentation pacing: percentage of frame intervals longer than 1.5 times the selected output frame interval. This is a timing estimate, not a GPU utilization reading.")
            }
            Circle().fill(Palette.border).frame(width: 3, height: 3)
            Text("\(screens.count) DISPLAY\(screens.count == 1 ? "" : "S")")
                .foregroundColor(Palette.secondaryText)
            if externalHTTPEnabled {
                Circle().fill(isExternalHTTPReady ? Palette.green : Palette.orange).frame(width: 4, height: 4)
                Text("HTTP \(externalControl.httpStatus)")
                    .foregroundColor(isExternalHTTPReady ? Palette.green : Palette.orange)
                    .lineLimit(1)
            }
            if externalOSCEnabled {
                Circle().fill(externalControl.oscStatus.hasPrefix("127.0.0.1") ? Palette.green : Palette.orange).frame(width: 4, height: 4)
                Text("OSC \(externalControl.oscStatus)")
                    .foregroundColor(externalControl.oscStatus.hasPrefix("127.0.0.1") ? Palette.green : Palette.orange)
                    .lineLimit(1)
            }
            if midiControlEnabled {
                Circle().fill(midiControl.inputCount > 0 ? Palette.green : Palette.orange).frame(width: 4, height: 4)
                Text("MIDI \(midiControl.inputCount) IN")
                    .foregroundColor(midiControl.inputCount > 0 ? Palette.green : Palette.orange)
            }
            if ndiInputsEnabled {
                Circle().fill(ndiService.status.hasPrefix("NDI ready") ? Palette.green : Palette.orange).frame(width: 4, height: 4)
                Text("NDI \(ndiService.sources.count)")
                    .foregroundColor(ndiService.status.hasPrefix("NDI ready") ? Palette.green : Palette.orange)
                    .help(ndiService.status)
            }
        }
        .font(.system(size: 10, weight: .medium, design: .monospaced))
        .padding(.horizontal, 18)
        .padding(.vertical, 11)
        .background(Palette.panel)
        .overlay(alignment: .top) { dividerLine }
    }

    private var divider: some View {
        Rectangle().fill(Palette.border).frame(width: 1)
    }

    private var dividerLine: some View {
        Rectangle().fill(Palette.border).frame(height: 1)
    }

    private var selectedScreenName: String {
        screens.first(where: { $0.id == selectedScreenID })?.screen.localizedName ?? "Select display"
    }

    private func maskPoints(for surface: ProjectionSurface) -> [NormalizedPoint] {
        guard let selectedMaskPathID,
              let selectedPath = surface.additionalMaskPaths?.first(where: { $0.id == selectedMaskPathID }) else {
            return surface.maskPoints
        }
        return selectedPath.points
    }

    private func selectMaskPath(_ pathID: UUID?) {
        selectedMaskPathID = pathID
        isMaskEditingEnabled = true
        isMoveToolEnabled = false
        isMeshEditingEnabled = false
    }

    private func selectedOutputMaskPath(for surface: ProjectionSurface) -> ProjectionMaskPath? {
        guard let selectedOutputMaskPathID,
              let output = session.outputs.first(where: { $0.id == (surface.outputID ?? ProjectionOutput.mainID) }) else {
            return nil
        }
        return output.exclusionPaths?.first(where: { $0.id == selectedOutputMaskPathID })
    }

    private func selectOutputMaskPath(_ pathID: UUID, on outputID: UUID) {
        selectedOutputMaskPathID = pathID
        selectedOutputMaskPointIndex = nil
        selectedMaskPathID = nil
        isMaskEditingEnabled = false
        isMeshEditingEnabled = false
        isMoveToolEnabled = false
        mappingPreviewOutputID = outputID
    }

    private func addOutputExclusion(_ output: ProjectionOutput, circular: Bool) {
        let currentPaths = output.exclusionPaths ?? []
        guard currentPaths.count < 8 else { return }
        let points: [NormalizedPoint]
        if circular {
            points = (0..<24).map { index in
                let angle = Double(index) * 2 * .pi / 24
                return NormalizedPoint(0.5 + cos(angle) * 0.12, 0.5 + sin(angle) * 0.12)
            }
        } else {
            points = [
                NormalizedPoint(0.35, 0.35), NormalizedPoint(0.65, 0.35),
                NormalizedPoint(0.65, 0.65), NormalizedPoint(0.35, 0.65)
            ]
        }
        let path = ProjectionMaskPath(
            name: "Exclusion \(currentPaths.count + 1)",
            operation: .exclude,
            points: points
        )
        session.updateOutputMaskConfiguration(output.id) { value in
            value.exclusionPaths = (value.exclusionPaths ?? []) + [path]
        }
        selectOutputMaskPath(path.id, on: output.id)
    }

    private func updateOutputMaskPoint(_ index: Int, to point: NormalizedPoint, on surface: ProjectionSurface) {
        let outputID = surface.outputID ?? ProjectionOutput.mainID
        guard let pathID = selectedOutputMaskPathID else { return }
        session.updateOutputMaskConfiguration(outputID) { output in
            guard var paths = output.exclusionPaths,
                  let pathIndex = paths.firstIndex(where: { $0.id == pathID }),
                  paths[pathIndex].points.indices.contains(index) else { return }
            paths[pathIndex].points[index] = point.clamped()
            output.exclusionPaths = paths
        }
    }

    private func insertOutputMaskPoint(after edgeIndex: Int, on surface: ProjectionSurface) {
        let outputID = surface.outputID ?? ProjectionOutput.mainID
        guard let pathID = selectedOutputMaskPathID else { return }
        session.updateOutputMaskConfiguration(outputID) { output in
            guard var paths = output.exclusionPaths,
                  let pathIndex = paths.firstIndex(where: { $0.id == pathID }),
                  paths[pathIndex].points.count < 32,
                  paths[pathIndex].points.indices.contains(edgeIndex) else { return }
            let nextIndex = (edgeIndex + 1) % paths[pathIndex].points.count
            let start = paths[pathIndex].points[edgeIndex]
            let end = paths[pathIndex].points[nextIndex]
            paths[pathIndex].points.insert(
                NormalizedPoint((start.x + end.x) * 0.5, (start.y + end.y) * 0.5),
                at: edgeIndex + 1
            )
            output.exclusionPaths = paths
        }
    }

    private func removeOutputMaskPoint(at index: Int, on surface: ProjectionSurface) {
        let outputID = surface.outputID ?? ProjectionOutput.mainID
        guard let pathID = selectedOutputMaskPathID else { return }
        session.updateOutputMaskConfiguration(outputID) { output in
            guard var paths = output.exclusionPaths,
                  let pathIndex = paths.firstIndex(where: { $0.id == pathID }),
                  paths[pathIndex].points.count > 3,
                  paths[pathIndex].points.indices.contains(index) else { return }
            paths[pathIndex].points.remove(at: index)
            output.exclusionPaths = paths
        }
    }

    private func surfaceForMaskEditing(_ surface: ProjectionSurface) -> ProjectionSurface {
        var editingSurface = surface
        editingSurface.maskPoints = maskPoints(for: surface)
        editingSurface.isLocked = isMappingGeometryLocked(surface)
        return editingSurface
    }

    private func updateSelectedMaskPoint(_ index: Int, to point: NormalizedPoint, on surface: ProjectionSurface) {
        if let selectedMaskPathID,
           surface.additionalMaskPaths?.contains(where: { $0.id == selectedMaskPathID }) == true {
            session.updateMaskPathPoint(selectedMaskPathID, pointIndex: index, to: point, on: surface.id)
        } else {
            session.updateMaskPoint(index, to: point, on: surface.id)
        }
    }

    private func insertSelectedMaskPoint(after edgeIndex: Int, on surface: ProjectionSurface) {
        if let selectedMaskPathID,
           surface.additionalMaskPaths?.contains(where: { $0.id == selectedMaskPathID }) == true {
            session.insertMaskPathPoint(after: edgeIndex, pathID: selectedMaskPathID, on: surface.id)
        } else {
            session.insertMaskPoint(after: edgeIndex, on: surface.id)
        }
    }

    private func removeSelectedMaskPoint(at index: Int, on surface: ProjectionSurface) {
        if let selectedMaskPathID,
           surface.additionalMaskPaths?.contains(where: { $0.id == selectedMaskPathID }) == true {
            session.removeMaskPathPoint(at: index, pathID: selectedMaskPathID, on: surface.id)
        } else {
            session.removeMaskPoint(at: index, on: surface.id)
        }
    }

    private func addMaskPath(on surface: ProjectionSurface, operation: ProjectionMaskOperation) {
        let points: [NormalizedPoint]
        if operation == .exclude {
            points = (0..<24).map { index in
                let angle = Double(index) * 2 * .pi / 24
                return NormalizedPoint(0.5 + cos(angle) * 0.12, 0.5 + sin(angle) * 0.12)
            }
        } else {
            points = [
                NormalizedPoint(0.35, 0.35), NormalizedPoint(0.65, 0.35),
                NormalizedPoint(0.65, 0.65), NormalizedPoint(0.35, 0.65)
            ]
        }
        let number = (surface.additionalMaskPaths?.count ?? 0) + 1
        let name = operation == .exclude ? "Cutout \(number)" : "Region \(number)"
        selectedMaskPathID = session.addMaskPath(
            name: name,
            operation: operation,
            points: points,
            on: surface.id
        )
        if selectedMaskPathID != nil {
            isMaskEditingEnabled = true
            isMoveToolEnabled = false
            isMeshEditingEnabled = false
        }
    }

    private func maskPathOperationBinding(_ surface: ProjectionSurface, pathID: UUID) -> Binding<ProjectionMaskOperation> {
        Binding(
            get: { surface.additionalMaskPaths?.first(where: { $0.id == pathID })?.operation ?? .include },
            set: { operation in
                session.setMaskPathOperation(pathID, operation: operation, on: surface.id)
            }
        )
    }

    private var displayedPresentedFPS: Double {
        guard let activeOutputID = output.activeOutputID else { return renderer.presentedFPS }
        return renderer.presentedFPSByOutputID[activeOutputID] ?? 0
    }

    private var displayedLatePresentationPercent: Double? {
        guard let activeOutputID = output.activeOutputID else {
            return renderer.latePresentationPercentByOutputID.values.max()
        }
        return renderer.latePresentationPercentByOutputID[activeOutputID]
    }

    private var canOpenCustomVirtualOutput: Bool {
        guard let width = Int(customVirtualWidth), let height = Int(customVirtualHeight) else { return false }
        return (320...7680).contains(width) && (240...4320).contains(height)
    }

    private func openCustomVirtualOutput() {
        guard canOpenCustomVirtualOutput,
              let width = Int(customVirtualWidth),
              let height = Int(customVirtualHeight) else { return }
        openVirtualOutput(width: width, height: height)
    }

    private func openPhysicalOutput(_ choice: ScreenChoice) {
        let screen = choice.screen
        let outputConfig = session.ensurePhysicalOutput(
            displayID: choice.id,
            name: screen.localizedName,
            width: Int(screen.frame.width * screen.backingScaleFactor),
            height: Int(screen.frame.height * screen.backingScaleFactor)
        )
        output.open(on: screen, outputID: outputConfig.id)
    }

    private func openVirtualOutput(width: Int, height: Int) {
        let outputConfig = session.ensureVirtualOutput(width: width, height: height)
        output.openVirtual(width: width, height: height, outputID: outputConfig.id)
    }

    private func openSavedOutput(_ outputConfig: ProjectionOutput) {
        if let displayID = outputConfig.displayID,
           let choice = screens.first(where: { $0.id == displayID }) {
            output.open(on: choice.screen, outputID: outputConfig.id)
        } else {
            output.openVirtual(width: outputConfig.width, height: outputConfig.height, outputID: outputConfig.id)
        }
    }

    private var isExternalHTTPReady: Bool {
        externalControl.httpStatus.hasPrefix("127.0.0.1") || externalControl.httpStatus.hasPrefix("LAN ")
    }

    private func panelTitle(_ title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .tracking(0.7)
            Text(detail)
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .foregroundColor(Palette.secondaryText)
        }
    }

    private func importMedia() {
        let panel = NSOpenPanel()
        panel.title = "Import Media"
        panel.prompt = "Import"
        panel.allowedContentTypes = MediaSource.supportedExtensions.compactMap { UTType(filenameExtension: $0) }
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK else { return }
        library.importFiles(panel.urls)
    }

    private func saveMapping() {
        let panel = NSSavePanel()
        panel.title = "Save Mapping Preset"
        panel.nameFieldStringValue = "Church Mapping.json"
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(MappingDocument(surfaces: session.surfaces, outputs: session.outputs)).write(to: url, options: .atomic)
        } catch {
            showMappingError("Could not save the mapping preset: \(error.localizedDescription)")
        }
    }

    private func loadMapping() {
        let panel = NSOpenPanel()
        panel.title = "Load Mapping Preset"
        panel.prompt = "Load Mapping"
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let document = try JSONDecoder().decode(MappingDocument.self, from: Data(contentsOf: url))
            guard document.formatVersion == MappingDocument.currentVersion else {
                showMappingError("This mapping preset uses an unsupported version.")
                return
            }
            session.replaceMapping(with: document)
            selectedSurfaceID = session.surfaces.first?.id
            pendingNDIShowLayerReferences = []
            pendingSyphonShowLayerReferences = []

            library.restoreGeneratorSources(references: document.sourcePaths) {
                self.library.restoreCaptureSources(references: document.sourcePaths) {
                    self.library.restoreNDISources(references: document.sourcePaths) {
                    self.library.restoreSyphonSources(references: document.sourcePaths, device: self.renderer.device) {
                    let pathsToImport = document.sourcePaths
                        .filter { !$0.hasPrefix("capture://") && !$0.hasPrefix("ndi://") && !$0.hasPrefix("syphon://") && !$0.hasPrefix("generator://") }
                        .filter { path in !self.library.sources.contains(where: { $0.reference == path }) }
                        .filter { FileManager.default.fileExists(atPath: $0) }
                        .map { URL(fileURLWithPath: $0) }
                    self.library.importFiles(pathsToImport) { _ in
                        self.session.setSourceCatalog(self.library.sources)
                    }
                    }
                    }
                }
            }
        } catch {
            showMappingError("Could not load the mapping preset: \(error.localizedDescription)")
        }
    }

    private func saveShow() {
        let panel = NSSavePanel()
        panel.title = "Save Show File"
        panel.nameFieldStringValue = "Church Show.json"
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(currentShowDocument()).write(to: url, options: .atomic)
        } catch {
            showMappingError("Could not save the show file: \(error.localizedDescription)")
        }
    }

    private func loadShow() {
        let panel = NSOpenPanel()
        panel.title = "Load Show or Portable Bundle"
        panel.prompt = "Load"
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            var showURL = url
            var bundleRoot: URL?
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue {
                guard url.pathExtension.lowercased() == "promapshow" else {
                    showMappingError("Choose a .promapshow bundle folder or a show JSON file.")
                    return
                }
                bundleRoot = url
                showURL = url.appendingPathComponent("Show.json")
            } else if url.lastPathComponent == "Show.json",
                      url.deletingLastPathComponent().pathExtension.lowercased() == "promapshow" {
                bundleRoot = url.deletingLastPathComponent()
            }

            var document = try JSONDecoder().decode(ShowDocument.self, from: Data(contentsOf: showURL))
            guard document.formatVersion == ShowDocument.currentVersion else {
                showMappingError("This show file uses an unsupported version.")
                return
            }
            if let bundleRoot {
                document = document.remappingMediaPaths { path in
                    guard !path.hasPrefix("capture://"), !path.hasPrefix("ndi://"), !path.hasPrefix("syphon://"), !path.hasPrefix("generator://"), !(path as NSString).isAbsolutePath else { return path }
                    return bundleRoot.appendingPathComponent(path).standardizedFileURL.path
                }
            }
            restoreShowDocument(document)
            selectedSurfaceID = document.surfaces.first?.id
        } catch {
            showMappingError("Could not load the show file: \(error.localizedDescription)")
        }
    }

    private func currentShowDocument() -> ShowDocument {
        ShowDocument(
            surfaces: session.surfaces,
            layers: session.layers.map(\.savedState),
            scenes: session.scenes,
            outputs: session.outputs,
            sourceAudio: library.sources
                .filter { $0.kind == .ndi || $0.kind == .video }
                .map {
                    SavedSourceAudioState(
                        sourcePath: $0.reference,
                        audioMuted: $0.isAudioMuted,
                        audioVolume: $0.audioVolume,
                        audioDelayMilliseconds: $0.kind == .ndi || $0.kind == .video ? $0.audioDelayMilliseconds : 0,
                        isLooping: $0.kind == .video ? $0.isLooping : nil,
                        isPlaying: $0.kind == .video ? $0.isPlaying : nil,
                        playbackTime: $0.kind == .video ? $0.playbackTimeSeconds : nil,
                        playbackRate: $0.kind == .video ? $0.playbackRate : nil
                    )
                }
        )
    }

    private func exportShowBundle() {
        let folderPanel = NSOpenPanel()
        folderPanel.title = "Choose a Destination for the Show Bundle"
        folderPanel.prompt = "Choose Folder"
        folderPanel.message = "ProMap will create a portable .promapshow folder here."
        folderPanel.canChooseFiles = false
        folderPanel.canChooseDirectories = true
        folderPanel.allowsMultipleSelection = false
        guard folderPanel.runModal() == .OK, let parentURL = folderPanel.url else { return }

        let nameField = NSTextField(string: "ProMap Show")
        nameField.frame = NSRect(x: 0, y: 0, width: 300, height: 24)
        let namingAlert = NSAlert()
        namingAlert.messageText = "Name the Portable Show Bundle"
        namingAlert.informativeText = "Media files will be copied into the bundle. Capture devices stay as live source references."
        namingAlert.accessoryView = nameField
        namingAlert.addButton(withTitle: "Export")
        namingAlert.addButton(withTitle: "Cancel")
        guard namingAlert.runModal() == .alertFirstButtonReturn else { return }

        let requestedName = nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "/", with: "-")
        guard !requestedName.isEmpty else {
            showMappingError("Enter a name for the show bundle.")
            return
        }

        let fileManager = FileManager.default
        var packageURL = parentURL.appendingPathComponent("\(requestedName).promapshow", isDirectory: true)
        var suffix = 2
        while fileManager.fileExists(atPath: packageURL.path) {
            packageURL = parentURL.appendingPathComponent("\(requestedName) \(suffix).promapshow", isDirectory: true)
            suffix += 1
        }
        let stagingURL = parentURL.appendingPathComponent(".promapshow-\(UUID().uuidString).tmp", isDirectory: true)

        do {
            try fileManager.createDirectory(at: stagingURL.appendingPathComponent("Media", isDirectory: true), withIntermediateDirectories: true)
            var bundledPaths: [String: String] = [:]
            var missingCount = 0
            for path in currentShowDocument().mediaPaths where !path.hasPrefix("capture://") && !path.hasPrefix("ndi://") && !path.hasPrefix("syphon://") && !path.hasPrefix("generator://") {
                let sourceURL = URL(fileURLWithPath: path).standardizedFileURL
                guard fileManager.fileExists(atPath: sourceURL.path) else {
                    missingCount += 1
                    continue
                }
                let relativePath = "Media/\(UUID().uuidString)-\(sourceURL.lastPathComponent)"
                try fileManager.copyItem(at: sourceURL, to: stagingURL.appendingPathComponent(relativePath))
                bundledPaths[path] = relativePath
            }

            let document = currentShowDocument().remappingMediaPaths { bundledPaths[$0] ?? $0 }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(document).write(to: stagingURL.appendingPathComponent("Show.json"), options: .atomic)
            try fileManager.moveItem(at: stagingURL, to: packageURL)

            let summary = NSAlert()
            summary.messageText = "Portable Show Bundle Exported"
            summary.informativeText = missingCount == 0
                ? packageURL.path
                : "\(packageURL.path)\n\n\(missingCount) missing media reference(s) remain linked to their original paths."
            summary.alertStyle = .informational
            summary.runModal()
        } catch {
            try? fileManager.removeItem(at: stagingURL)
            showMappingError("Could not export the portable show bundle: \(error.localizedDescription)")
        }
    }

    private func restoreShowDocument(_ document: ShowDocument) {
        let resolvedDocument = relinkMissingMediaIfRequested(in: document)
        pendingNDIShowLayerReferences = Set(resolvedDocument.layers.map(\.sourcePath).filter { $0.hasPrefix("ndi://") })
        pendingSyphonShowLayerReferences = Set(resolvedDocument.layers.map(\.sourcePath).filter { $0.hasPrefix("syphon://") })
        library.restoreGeneratorSources(references: resolvedDocument.mediaPaths) {
            self.library.restoreCaptureSources(references: resolvedDocument.mediaPaths) {
                self.library.restoreNDISources(references: resolvedDocument.mediaPaths) {
                self.library.restoreSyphonSources(references: resolvedDocument.mediaPaths, device: self.renderer.device) {
                let existingReferences = Set(self.library.sources.map(\.reference))
                let urlsToImport = resolvedDocument.mediaPaths
                    .filter { !$0.hasPrefix("capture://") && !$0.hasPrefix("ndi://") && !$0.hasPrefix("syphon://") && !$0.hasPrefix("generator://") && !existingReferences.contains($0) && FileManager.default.fileExists(atPath: $0) }
                    .map { URL(fileURLWithPath: $0) }
                if urlsToImport.isEmpty {
                    self.session.replaceShow(with: resolvedDocument, sources: self.library.sources)
                } else {
                    self.library.importFiles(urlsToImport) { _ in
                        self.session.replaceShow(with: resolvedDocument, sources: self.library.sources)
                    }
                }
                }
                }
            }
        }
    }

    private func relinkMissingMediaIfRequested(in document: ShowDocument) -> ShowDocument {
        let missingPaths = document.mediaPaths.filter {
            !$0.hasPrefix("capture://") && !$0.hasPrefix("ndi://") && !$0.hasPrefix("syphon://") && !$0.hasPrefix("generator://") && !FileManager.default.fileExists(atPath: $0)
        }
        guard !missingPaths.isEmpty else { return document }

        let prompt = NSAlert()
        prompt.messageText = "Some show media is missing"
        prompt.informativeText = "ProMap can search a folder for files with matching names and relink them. Unmatched media will remain offline."
        prompt.addButton(withTitle: "Locate Media Folder…")
        prompt.addButton(withTitle: "Continue Offline")
        guard prompt.runModal() == .alertFirstButtonReturn else { return document }

        let panel = NSOpenPanel()
        panel.title = "Locate Show Media"
        panel.prompt = "Search Folder"
        panel.message = "Choose the folder that contains the moved show media. ProMap will relink only filenames with a single match."
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let root = panel.url,
              let enumerator = FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
              ) else { return document }

        var filesByName: [String: [URL]] = [:]
        for case let fileURL as URL in enumerator {
            guard MediaSource.supportedExtensions.contains(fileURL.pathExtension.lowercased()) else { continue }
            filesByName[fileURL.lastPathComponent.lowercased(), default: []].append(fileURL.standardizedFileURL)
        }

        var replacements: [String: String] = [:]
        for oldPath in missingPaths {
            let filename = URL(fileURLWithPath: oldPath).lastPathComponent.lowercased()
            if let matches = filesByName[filename], matches.count == 1, let match = matches.first {
                replacements[oldPath] = match.path
            }
        }
        guard !replacements.isEmpty else {
            showRelinkSummary(unresolvedCount: missingPaths.count)
            return document
        }

        var updated = document
        updated.layers = updated.layers.map { layer in
            var value = layer
            value.sourcePath = replacements[layer.sourcePath] ?? layer.sourcePath
            return value
        }
        updated.surfaces = updated.surfaces.map { surface in
            var value = surface
            if let path = surface.sourcePath { value.sourcePath = replacements[path] ?? path }
            return value
        }
        updated.scenes = updated.scenes.map { scene in
            var value = scene
            value.layers = scene.layers.map { layer in
                var layerValue = layer
                layerValue.sourcePath = replacements[layer.sourcePath] ?? layer.sourcePath
                return layerValue
            }
            value.surfaces = scene.surfaces.map { state in
                var stateValue = state
                if let path = state.sourcePath { stateValue.sourcePath = replacements[path] ?? path }
                return stateValue
            }
            return value
        }
        let unresolvedCount = updated.mediaPaths.filter {
            !$0.hasPrefix("capture://") && !$0.hasPrefix("ndi://") && !$0.hasPrefix("syphon://") && !$0.hasPrefix("generator://") && !FileManager.default.fileExists(atPath: $0)
        }.count
        if unresolvedCount > 0 { showRelinkSummary(unresolvedCount: unresolvedCount) }
        return updated
    }

    private func showRelinkSummary(unresolvedCount: Int) {
        let alert = NSAlert()
        alert.messageText = "Some media could not be relinked"
        alert.informativeText = "\(unresolvedCount) file(s) remain offline because no unique filename match was found. You can import and assign them after the show loads."
        alert.addButton(withTitle: "Continue")
        alert.runModal()
    }

    private func offerAutosaveRecovery() {
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return }
        do {
            let url = try autosaveURL()
            let backupURL = url.appendingPathExtension("previous")
            let recoveryCandidate = [url, backupURL].first { candidate in
                guard FileManager.default.fileExists(atPath: candidate.path),
                      let document = try? JSONDecoder().decode(ShowDocument.self, from: Data(contentsOf: candidate)) else { return false }
                return document.formatVersion == ShowDocument.currentVersion
            }
            guard let recoveryCandidate,
                  let document = try? JSONDecoder().decode(ShowDocument.self, from: Data(contentsOf: recoveryCandidate)) else { return }
            let alert = NSAlert()
            let previousSessionWasUnclean = UserDefaults.standard.bool(forKey: "previousSessionWasUnclean")
            alert.messageText = previousSessionWasUnclean
                ? "ProMap did not close normally. Restore the autosaved show?"
                : "Restore the autosaved show?"
            let modificationDate = (try? FileManager.default.attributesOfItem(atPath: recoveryCandidate.path)[.modificationDate]) as? Date
            let savedAt = modificationDate.map { DateFormatter.localizedString(from: $0, dateStyle: .medium, timeStyle: .short) } ?? "an earlier session"
            let recoveryDescription = previousSessionWasUnclean
                ? "ProMap found a recovery copy saved \(savedAt), with \(document.surfaces.count) surfaces and \(document.scenes.count) scenes."
                : "ProMap found an autosaved copy saved \(savedAt), with \(document.surfaces.count) surfaces and \(document.scenes.count) scenes."
            alert.informativeText = recoveryDescription
            alert.addButton(withTitle: "Restore")
            alert.addButton(withTitle: "Start Fresh")
            if alert.runModal() == .alertFirstButtonReturn {
                restoreShowDocument(document)
                selectedSurfaceID = document.surfaces.first?.id
            } else {
                try? FileManager.default.removeItem(at: url)
                try? FileManager.default.removeItem(at: backupURL)
            }
        } catch {
            showMappingError("Could not read the autosaved show: \(error.localizedDescription)")
        }
    }

    private func saveAutosave() {
        let surface = session.surfaces.first
        let isPristine = session.layers.isEmpty && session.scenes.isEmpty && session.surfaces.count == 1
            && session.outputs == [.main]
            && surface?.name == "Main Surface"
            && surface?.corners == ProjectionSurface.rectanglePoints
            && surface?.maskKind == .rectangle
            && surface?.maskPoints == ProjectionSurface.rectanglePoints
            && surface?.sourcePath == nil
            && surface?.usesLayerStack == true
            && surface?.isVisible == true
            && surface?.isLocked == false
            && surface?.isBlackout == false
            && surface?.isMaskInverted == false
            && surface?.brightness == 1
            && surface?.opacity == 1
            && surface?.colorCorrection == nil
            && (surface?.effectStack ?? []).isEmpty
        guard !isPristine else { return }
        do {
            let url = try autosaveURL()
            let backupURL = url.appendingPathExtension("previous")
            if let previousData = try? Data(contentsOf: url),
               let previousDocument = try? JSONDecoder().decode(ShowDocument.self, from: previousData),
               previousDocument.formatVersion == ShowDocument.currentVersion {
                try? FileManager.default.removeItem(at: backupURL)
                try FileManager.default.copyItem(at: url, to: backupURL)
            }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(currentShowDocument()).write(to: url, options: .atomic)
        } catch {
            NSLog("ProMap autosave failed: %@", error.localizedDescription)
        }
    }

    private func autosaveURL() throws -> URL {
        guard let applicationSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            throw CocoaError(.fileNoSuchFile)
        }
        let folder = applicationSupport.appendingPathComponent("ProMap", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent("Autosave.json")
    }

    private func showMappingError(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "Mapping Preset"
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.runModal()
    }
}

private struct DiagnosticsWorkspace: View {
    @ObservedObject var renderer: MetalRenderer
    @ObservedObject var session: RenderSession
    @ObservedObject var output: ProjectorOutputController
    @ObservedObject var library: MediaLibrary
    @ObservedObject var ndiService: NDIService
    @ObservedObject var ndiOutputService: NDIOutputService
    @ObservedObject var syphonService: SyphonService
    @ObservedObject var syphonOutputService: SyphonOutputService
    let outputFrameRate: Int
    let previewFrameRate: Int
    let previewRenderScale: Double

    @StateObject private var processMonitor = ProcessDiagnosticsMonitor()

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 10), count: 3)

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .center) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("SYSTEM DIAGNOSTICS")
                            .font(.system(size: 11, weight: .bold, design: .monospaced))
                            .tracking(0.6)
                        Text("Live rendering, resource and connection status")
                            .font(.system(size: 10))
                            .foregroundColor(Palette.secondaryText)
                    }
                    Spacer()
                    Text("UPDATES EVERY SECOND")
                        .font(.system(size: 8, weight: .medium, design: .monospaced))
                        .foregroundColor(Palette.tertiaryText)
                }

                LazyVGrid(columns: columns, spacing: 10) {
                    DiagnosticMetricCard(
                        title: "ACTIVE GPU",
                        value: renderer.renderingAvailable ? renderer.gpuName : "Unavailable",
                        detail: renderer.usesLowPowerGPU.map { $0 ? "Low power device" : "High performance device" } ?? "No Metal device",
                        symbol: "cpu",
                        warning: !renderer.renderingAvailable
                    )
                    DiagnosticMetricCard(
                        title: output.activeOutputID == nil ? "PREVIEW RATE" : "OUTPUT RATE",
                        value: String(format: "%.1f / %d fps", measuredFPS, targetFrameRate),
                        detail: "Presentation interval: \(measuredIntervalDescription)",
                        symbol: "speedometer"
                    )
                    DiagnosticMetricCard(
                        title: "GPU COMMAND TIME",
                        value: gpuTimeDescription,
                        detail: gpuTimingDetail,
                        symbol: "timer",
                        warning: activeOutputID != nil && gpuTimeMilliseconds == nil
                    )
                    DiagnosticMetricCard(
                        title: "CPU FRAME BUILD",
                        value: cpuFrameBuildDescription,
                        detail: "CPU time to prepare and encode one Metal frame; not GPU execution time.",
                        symbol: "cpu"
                    )
                    DiagnosticMetricCard(
                        title: "LATE PRESENTATIONS",
                        value: latePresentationDescription,
                        detail: "Intervals longer than 1.5× the selected target. Cadence estimate, not GPU utilization.",
                        symbol: "waveform.path.ecg",
                        warning: (latePresentationPercent ?? 0) >= 10
                    )
                    DiagnosticMetricCard(
                        title: "PROCESS CPU",
                        value: processMonitor.cpuPercent.map { String(format: "%.0f%%", $0) } ?? "Sampling…",
                        detail: "App CPU across active cores; can exceed 100%.",
                        symbol: "chart.bar.xaxis"
                    )
                    DiagnosticMetricCard(
                        title: "APP MEMORY",
                        value: processMonitor.physicalFootprintBytes.map(Self.byteDescription) ?? "Unavailable",
                        detail: "macOS process physical footprint.",
                        symbol: "memorychip"
                    )
                    DiagnosticMetricCard(
                        title: "CACHED TEXTURES",
                        value: Self.byteDescription(processMonitor.cachedTextureBytes),
                        detail: "Metal allocation estimate for textures currently retained by the media cache.",
                        symbol: "square.stack.3d.up"
                    )
                    DiagnosticMetricCard(
                        title: "PREVIEW QUALITY",
                        value: "\(Int(previewRenderScale * 100))% · \(previewFrameRate) fps",
                        detail: "Editor and scene monitors only; projector output remains full resolution.",
                        symbol: "rectangle.inset.filled"
                    )
                    DiagnosticMetricCard(
                        title: "PROJECTOR TARGET",
                        value: "\(outputFrameRate) fps",
                        detail: "Output frame target configured in Settings.",
                        symbol: "display"
                    )
                }

                HStack(alignment: .top, spacing: 10) {
                    outputStatusPanel
                    inputStatusPanel
                    connectionStatusPanel
                }
            }
            .padding(18)
        }
        .background(Palette.background)
        .onAppear {
            let renderer = renderer
            processMonitor.start { [weak renderer] in
                renderer?.estimatedTextureMemoryBytes() ?? 0
            }
        }
        .onDisappear { processMonitor.stop() }
    }

    private var activeOutputID: UUID? { output.activeOutputID }

    private var targetFrameRate: Int {
        activeOutputID == nil ? previewFrameRate : outputFrameRate
    }

    private var measuredFPS: Double {
        guard let activeOutputID else { return renderer.presentedFPS }
        return renderer.presentedFPSByOutputID[activeOutputID] ?? 0
    }

    private var measuredIntervalDescription: String {
        guard measuredFPS > 0 else { return "Waiting for frames" }
        return String(format: "%.2f ms", 1_000 / measuredFPS)
    }

    private var gpuTimeMilliseconds: Double? {
        guard let activeOutputID else { return renderer.gpuTimeMillisecondsByOutputID.values.max() }
        return renderer.gpuTimeMillisecondsByOutputID[activeOutputID]
    }

    private var gpuTimeDescription: String {
        guard let gpuTimeMilliseconds else {
            if let activeOutputID,
               renderer.gpuTimingStatusByOutputID[activeOutputID]?.contains("without GPU timestamps") == true {
                return "No timestamps"
            }
            return activeOutputID == nil ? "No output" : "Sampling…"
        }
        return String(format: "%.2f ms", gpuTimeMilliseconds)
    }

    private var gpuTimingDetail: String {
        guard let activeOutputID else { return "Open a physical or virtual output to sample its Metal command buffer." }
        return renderer.gpuTimingStatusByOutputID[activeOutputID]
            ?? "Waiting for a completed output frame."
    }

    private var cpuFrameBuildDescription: String {
        let milliseconds: Double?
        if let activeOutputID {
            milliseconds = renderer.cpuFrameBuildMillisecondsByOutputID[activeOutputID]
        } else {
            milliseconds = renderer.cpuFrameBuildMillisecondsByOutputID.values.max()
        }
        guard let milliseconds else { return "Waiting…" }
        return String(format: "%.2f ms", milliseconds)
    }

    private var latePresentationPercent: Double? {
        guard let activeOutputID else { return renderer.latePresentationPercentByOutputID.values.max() }
        return renderer.latePresentationPercentByOutputID[activeOutputID]
    }

    private var latePresentationDescription: String {
        guard let latePresentationPercent else { return "Waiting for frames" }
        return String(format: "%.0f%% of intervals", latePresentationPercent)
    }

    private var outputStatusPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("DISPLAY OUTPUTS")
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundColor(Palette.secondaryText)
            if session.outputs.isEmpty {
                Text("No outputs configured")
                    .font(.system(size: 10))
                    .foregroundColor(Palette.tertiaryText)
            } else {
                ForEach(session.outputs) { savedOutput in
                    HStack(spacing: 7) {
                        Circle()
                            .fill(output.openOutputIDs.contains(savedOutput.id) ? Palette.green : Palette.tertiaryText)
                            .frame(width: 6, height: 6)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(savedOutput.name)
                                .font(.system(size: 10, weight: .medium))
                                .lineLimit(1)
                            Text("\(savedOutput.width) × \(savedOutput.height) · \(displayType(savedOutput)) · \(output.openOutputIDs.contains(savedOutput.id) ? "OPEN" : "CLOSED")")
                                .font(.system(size: 8, weight: .medium, design: .monospaced))
                                .foregroundColor(Palette.tertiaryText)
                                .lineLimit(1)
                        }
                        Spacer(minLength: 0)
                    }
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 135, alignment: .topLeading)
        .background(Palette.panel)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var inputStatusPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("MEDIA & INPUTS · \(library.sources.count)")
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundColor(Palette.secondaryText)
            if library.sources.isEmpty {
                Text("Add local media or live sources from the Clip Grid.")
                    .font(.system(size: 10))
                    .foregroundColor(Palette.tertiaryText)
            } else {
                ForEach(library.sources) { source in
                    HStack(spacing: 7) {
                        Image(systemName: inputSymbol(source))
                            .font(.system(size: 9))
                            .foregroundColor(Palette.accentSoft)
                            .frame(width: 14)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(source.title)
                                .font(.system(size: 10, weight: .medium))
                                .lineLimit(1)
                            Text(inputDescription(source))
                                .font(.system(size: 8, weight: .medium, design: .monospaced))
                                .foregroundColor(Palette.tertiaryText)
                                .lineLimit(1)
                        }
                        Spacer(minLength: 0)
                    }
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 135, alignment: .topLeading)
        .background(Palette.panel)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var connectionStatusPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("NETWORK & SHARED VIDEO")
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundColor(Palette.secondaryText)
            connectionRow("NDI INPUT", status: ndiService.status)
            connectionRow("NDI OUTPUT", status: ndiOutputService.status)
            connectionRow("SYPHON INPUT", status: syphonService.status)
            connectionRow("SYPHON OUTPUT", status: syphonOutputService.status)
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 135, alignment: .topLeading)
        .background(Palette.panel)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func connectionRow(_ title: String, status: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Circle()
                .fill(connectionColor(for: status))
                .frame(width: 6, height: 6)
                .padding(.top, 3)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 8, weight: .bold, design: .monospaced))
                Text(status)
                    .font(.system(size: 8))
                    .foregroundColor(Palette.tertiaryText)
                    .lineLimit(2)
            }
        }
    }

    private func connectionColor(for status: String) -> Color {
        let value = status.lowercased()
        if value.contains("error") || value.contains("failed") || value.contains("unavailable") || value.contains("not found") {
            return Palette.orange
        }
        if value.contains("ready") || value.contains("connected") || value.contains("sending") || value.contains("publishing") {
            return Palette.green
        }
        return Palette.tertiaryText
    }

    private func displayType(_ savedOutput: ProjectionOutput) -> String {
        guard let displayID = savedOutput.displayID else { return "VIRTUAL" }
        let connected = NSScreen.screens.contains { screen in
            let key = NSDeviceDescriptionKey("NSScreenNumber")
            return (screen.deviceDescription[key] as? NSNumber)?.stringValue == displayID
        }
        return connected ? "PHYSICAL · CONNECTED" : "PHYSICAL · DISCONNECTED"
    }

    private func inputSymbol(_ source: MediaSource) -> String {
        switch source.kind {
        case .image: return "photo"
        case .video: return "film"
        case .capture: return "web.camera"
        case .ndi: return "dot.radiowaves.left.and.right"
        case .syphon: return "rectangle.on.rectangle"
        case .generator: return "sparkles"
        }
    }

    private func inputDescription(_ source: MediaSource) -> String {
        switch source.kind {
        case .image:
            return "STILL IMAGE · READY"
        case .video:
            return "AVFOUNDATION · \(source.isPlaying ? "PLAYING" : "PAUSED")"
        case .capture, .ndi, .syphon:
            let signal = source.liveInputMetadata.uppercased()
            return source.isCaptureConnected ? signal : "DISCONNECTED · \(signal)"
        case .generator:
            return "GPU GENERATED VISUAL"
        }
    }

    private static func byteDescription(_ value: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(clamping: value), countStyle: .memory)
    }
}

private struct DiagnosticMetricCard: View {
    let title: String
    let value: String
    let detail: String
    let symbol: String
    var warning = false

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                Image(systemName: symbol)
                    .foregroundColor(warning ? Palette.orange : Palette.accentSoft)
                Text(title)
                    .foregroundColor(Palette.secondaryText)
                Spacer(minLength: 0)
            }
            .font(.system(size: 8, weight: .bold, design: .monospaced))
            Text(value)
                .font(.system(size: 15, weight: .semibold, design: .rounded))
                .foregroundColor(warning ? Palette.orange : Palette.primaryText)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .help(value)
            Text(detail)
                .font(.system(size: 8))
                .foregroundColor(Palette.tertiaryText)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 100, alignment: .topLeading)
        .background(Palette.panel)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

private final class ProcessDiagnosticsMonitor: ObservableObject {
    @Published private(set) var cpuPercent: Double?
    @Published private(set) var physicalFootprintBytes: UInt64?
    @Published private(set) var cachedTextureBytes: UInt64 = 0

    private var timer: Timer?
    private var textureMemoryProvider: (() -> UInt64)?
    private var previousCPUTime: Double?
    private var previousWallTime: TimeInterval?

    func start(textureMemoryProvider: @escaping () -> UInt64) {
        self.textureMemoryProvider = textureMemoryProvider
        sample()
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            self?.sample()
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        textureMemoryProvider = nil
        previousCPUTime = nil
        previousWallTime = nil
    }

    private func sample() {
        let wallTime = ProcessInfo.processInfo.systemUptime
        let cpuTime = Self.processCPUTime()
        var sampledCPU: Double?
        if let cpuTime, let previousCPUTime, let previousWallTime, wallTime > previousWallTime {
            sampledCPU = max(0, (cpuTime - previousCPUTime) / (wallTime - previousWallTime) * 100)
        }
        if let cpuTime {
            previousCPUTime = cpuTime
            previousWallTime = wallTime
        }
        let memory = Self.physicalFootprint()
        let textures = textureMemoryProvider?() ?? 0
        cpuPercent = sampledCPU
        physicalFootprintBytes = memory
        cachedTextureBytes = textures
    }

    private static func processCPUTime() -> Double? {
        var usage = rusage()
        guard getrusage(RUSAGE_SELF, &usage) == 0 else { return nil }
        let user = Double(usage.ru_utime.tv_sec) + Double(usage.ru_utime.tv_usec) / 1_000_000
        let system = Double(usage.ru_stime.tv_sec) + Double(usage.ru_stime.tv_usec) / 1_000_000
        return user + system
    }

    private static func physicalFootprint() -> UInt64? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size
        )
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        return UInt64(info.phys_footprint)
    }
}

private struct MappingEditorOverlay: View {
    let surface: ProjectionSurface
    let isMoveToolEnabled: Bool
    let isMaskEditingEnabled: Bool
    let isMeshEditingEnabled: Bool
    let showsGrid: Bool
    let snapToVertices: Bool
    let snapTargets: [NormalizedPoint]
    @Binding var selectedMaskPointIndex: Int?
    let outputMaskPath: ProjectionMaskPath?
    let isOutputMaskEditingEnabled: Bool
    @Binding var selectedOutputMaskPointIndex: Int?
    let onBeginGeometryEdit: () -> Void
    let onEndGeometryEdit: () -> Void
    let onCorner: (Int, NormalizedPoint) -> Void
    let onEdgeMove: (Int, NormalizedPoint) -> Void
    let onMeshControlPoint: (Int, NormalizedPoint) -> Void
    let onMaskPoint: (Int, NormalizedPoint) -> Void
    let onMove: (Double, Double) -> Void
    let onInsertMaskPoint: (Int) -> Void
    let onRemoveMaskPoint: (Int) -> Void
    let onOutputMaskPoint: (Int, NormalizedPoint) -> Void
    let onInsertOutputMaskPoint: (Int) -> Void
    let onRemoveOutputMaskPoint: (Int) -> Void

    @State private var selectedCornerIndex: Int?
    @State private var selectedEdgeIndex: Int?
    @State private var activeGestureID: String?
    @State private var lastMoveTranslation = CGSize.zero
    @State private var activeDragGrabOffset: NormalizedPoint?

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            ZStack {
                if showsGrid {
                    Canvas { context, canvasSize in
                        for division in 0...10 {
                            let x = canvasSize.width * CGFloat(division) / 10
                            let y = canvasSize.height * CGFloat(division) / 10
                            var vertical = Path()
                            vertical.move(to: CGPoint(x: x, y: 0))
                            vertical.addLine(to: CGPoint(x: x, y: canvasSize.height))
                            context.stroke(vertical, with: .color(.white.opacity(0.18)), lineWidth: 0.5)
                            var horizontal = Path()
                            horizontal.move(to: CGPoint(x: 0, y: y))
                            horizontal.addLine(to: CGPoint(x: canvasSize.width, y: y))
                            context.stroke(horizontal, with: .color(.white.opacity(0.18)), lineWidth: 0.5)
                        }
                    }
                    .allowsHitTesting(false)
                }

                Canvas { context, _ in
                    guard surface.corners.count == 4 else { return }
                    var surfacePath = Path()
                    surfacePath.move(to: point(surface.corners[0], size))
                    for corner in surface.corners.dropFirst() { surfacePath.addLine(to: point(corner, size)) }
                    surfacePath.closeSubpath()
                    context.stroke(surfacePath, with: .color(Color.white.opacity(0.95)), lineWidth: 2)

                    if let outputMaskPath, outputMaskPath.points.count >= 3 {
                        var exclusionPath = Path()
                        exclusionPath.move(to: point(outputMaskPath.points[0], size))
                        for vertex in outputMaskPath.points.dropFirst() {
                            exclusionPath.addLine(to: point(vertex, size))
                        }
                        exclusionPath.closeSubpath()
                        context.fill(exclusionPath, with: .color(Color.pink.opacity(0.12)))
                        context.stroke(
                            exclusionPath,
                            with: .color(Color.pink),
                            style: StrokeStyle(lineWidth: 2, dash: [6, 4])
                        )
                    }

                    if isMeshEditingEnabled,
                       let warp = surface.meshWarp?.sanitized(),
                       let grid = surface.meshGridPoints {
                        let side = warp.subdivisionCount + 1
                        for row in 0..<side {
                            var path = Path()
                            for column in 0..<side {
                                let location = point(grid[row * side + column], size)
                                if column == 0 { path.move(to: location) } else { path.addLine(to: location) }
                            }
                            context.stroke(path, with: .color(Color.purple.opacity(0.82)), lineWidth: 1)
                        }
                        for column in 0..<side {
                            var path = Path()
                            for row in 0..<side {
                                let location = point(grid[row * side + column], size)
                                if row == 0 { path.move(to: location) } else { path.addLine(to: location) }
                            }
                            context.stroke(path, with: .color(Color.purple.opacity(0.82)), lineWidth: 1)
                        }
                    }

                    guard surface.maskPoints.count >= 3 else { return }
                    var maskPath = Path()
                    let mapped = surface.maskPoints.compactMap {
                        ProjectiveTransform.sourceToOutput($0, corners: surface.corners)
                    }
                    guard let first = mapped.first else { return }
                    maskPath.move(to: point(first, size))
                    for vertex in mapped.dropFirst() { maskPath.addLine(to: point(vertex, size)) }
                    maskPath.closeSubpath()
                    context.stroke(maskPath, with: .color(Color(red: 1, green: 0.67, blue: 0.23)), lineWidth: 2)
                }

                if !isMoveToolEnabled, !isMaskEditingEnabled, !isMeshEditingEnabled,
                   !isOutputMaskEditingEnabled, surface.corners.count == 4 {
                    ForEach(0..<4, id: \.self) { index in
                        let nextIndex = (index + 1) % 4
                        let edgeName = ["top", "right", "bottom", "left"][index]
                        let start = surface.corners[index]
                        let end = surface.corners[nextIndex]
                        let midpoint = NormalizedPoint((start.x + end.x) * 0.5, (start.y + end.y) * 0.5)
                        ZStack {
                            RoundedRectangle(cornerRadius: 7)
                                .fill(selectedEdgeIndex == index ? Color(red: 0.22, green: 0.9, blue: 1) : Color.white)
                            RoundedRectangle(cornerRadius: 7)
                                .stroke(Color.black.opacity(0.8), lineWidth: 1.2)
                            HStack(spacing: 2) {
                                Text(["T", "R", "B", "L"][index])
                                    .font(.system(size: 8, weight: .heavy, design: .rounded))
                                Image(systemName: index.isMultiple(of: 2) ? "arrow.up.and.down" : "arrow.left.and.right")
                                    .font(.system(size: 7, weight: .bold))
                            }
                            .foregroundColor(.black)
                        }
                        .frame(width: 40, height: 26)
                        .contentShape(RoundedRectangle(cornerRadius: 7))
                        .position(point(midpoint, size))
                        .zIndex(1.5)
                        .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("mappingCanvas"))
                            .onChanged { value in
                                beginPointGesture("edge-\(index)", startLocation: value.startLocation, anchor: midpoint, size: size)
                                selectedEdgeIndex = index
                                onEdgeMove(index, dragPoint(value.location, size))
                            }
                            .onEnded { _ in finishGesture("edge-\(index)") })
                        .allowsHitTesting(!surface.isLocked)
                        .help("Drag the \(edgeName) edge to move both corners together")
                    }
                }

                if isOutputMaskEditingEnabled, let outputMaskPath, outputMaskPath.points.count >= 3 {
                    ForEach(outputMaskPath.points.indices, id: \.self) { index in
                        let nextIndex = (index + 1) % outputMaskPath.points.count
                        let start = outputMaskPath.points[index]
                        let end = outputMaskPath.points[nextIndex]
                        if outputMaskPath.points.count < 32 {
                            Button { onInsertOutputMaskPoint(index) } label: {
                                Image(systemName: "plus")
                                    .font(.system(size: 10, weight: .bold))
                                    .foregroundColor(.white)
                                    .frame(width: 30, height: 30)
                                    .background(Color.pink)
                                    .clipShape(Circle())
                                    .overlay(Circle().stroke(Color.black.opacity(0.7), lineWidth: 1))
                            }
                            .buttonStyle(.plain)
                            .position(point(NormalizedPoint((start.x + end.x) * 0.5, (start.y + end.y) * 0.5), size))
                            .help("Insert a vertex on this output exclusion edge")
                            .zIndex(2)
                        }
                    }

                    ForEach(Array(outputMaskPath.points.enumerated()), id: \.offset) { index, maskPoint in
                        ZStack {
                            Circle().fill(Color.pink.opacity(0.10))
                            Circle()
                                .fill(selectedOutputMaskPointIndex == index ? .white : Color.pink)
                                .frame(width: 20, height: 20)
                                .overlay(Circle().stroke(Color.black.opacity(0.9), lineWidth: 1.3))
                            Text("\(index + 1)")
                                .font(.system(size: 8, weight: .bold, design: .rounded))
                                .foregroundColor(.black)
                        }
                        .frame(width: 52, height: 52)
                        .contentShape(Circle())
                        .position(point(maskPoint, size))
                        .zIndex(3)
                        .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("mappingCanvas"))
                            .onChanged { value in
                                beginPointGesture(
                                    "output-mask-\(index)",
                                    startLocation: value.startLocation,
                                    anchor: maskPoint,
                                    size: size
                                )
                                selectedOutputMaskPointIndex = index
                                onOutputMaskPoint(index, dragPoint(value.location, size).clamped())
                            }
                            .onEnded { _ in finishGesture("output-mask-\(index)") })
                        .contextMenu {
                            Button("Delete Exclusion Vertex \(index + 1)", role: .destructive) {
                                onRemoveOutputMaskPoint(index)
                            }
                            .disabled(outputMaskPath.points.count <= 3)
                        }
                        .help("Output exclusion vertex \(index + 1). Drag to reshape; right-click to remove.")
                    }
                }

                if isMoveToolEnabled, !isOutputMaskEditingEnabled, surface.corners.count == 4 {
                    surfaceHitPath(size)
                        .fill(Color.white.opacity(0.001))
                        .contentShape(surfaceHitPath(size))
                        .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("mappingCanvas"))
                            .onChanged { value in
                                beginGesture("move")
                                let deltaX = value.translation.width - lastMoveTranslation.width
                                let deltaY = value.translation.height - lastMoveTranslation.height
                                lastMoveTranslation = value.translation
                                onMove(Double(deltaX / max(size.width, 1)), Double(deltaY / max(size.height, 1)))
                            }
                            .onEnded { _ in finishGesture("move") })
                        .allowsHitTesting(!surface.isLocked)
                        .zIndex(0.5)
                }

                if isMeshEditingEnabled,
                   let warp = surface.meshWarp?.sanitized(),
                   let grid = surface.meshGridPoints {
                    let divisions = warp.subdivisionCount
                    let side = divisions + 1
                    ForEach(warp.controlOffsets.indices, id: \.self) { controlIndex in
                        let interior = divisions - 1
                        let row = controlIndex / interior + 1
                        let column = controlIndex % interior + 1
                        let gridIndex = row * side + column
                        ZStack {
                            Circle().fill(Color.purple.opacity(0.12))
                            Circle()
                                .fill(Color(red: 0.79, green: 0.55, blue: 1))
                                .frame(width: 15, height: 15)
                                .overlay(Circle().stroke(Color.black.opacity(0.85), lineWidth: 1.4))
                            Image(systemName: "arrow.up.and.down.and.arrow.left.and.right")
                                .font(.system(size: 6, weight: .black))
                                .foregroundColor(.black)
                        }
                        .frame(width: 34, height: 34)
                        .contentShape(Circle())
                        .position(point(grid[gridIndex], size))
                        .zIndex(2)
                        .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("mappingCanvas"))
                            .onChanged { value in
                                beginPointGesture(
                                    "mesh-\(controlIndex)",
                                    startLocation: value.startLocation,
                                    anchor: grid[gridIndex],
                                    size: size
                                )
                                onMeshControlPoint(controlIndex, dragPoint(value.location, size))
                            }
                            .onEnded { _ in finishGesture("mesh-\(controlIndex)") })
                        .allowsHitTesting(!surface.isLocked && !isMoveToolEnabled && !isMaskEditingEnabled && !isOutputMaskEditingEnabled)
                        .help("Mesh point \(controlIndex + 1). Drag to bend the output surface.")
                    }
                }

                if isMaskEditingEnabled && !isOutputMaskEditingEnabled {
                    ForEach(surface.maskPoints.indices, id: \.self) { index in
                        let nextIndex = (index + 1) % surface.maskPoints.count
                        let start = surface.maskPoints[index]
                        let end = surface.maskPoints[nextIndex]
                        if let outputStart = ProjectiveTransform.sourceToOutput(start, corners: surface.corners),
                           let outputEnd = ProjectiveTransform.sourceToOutput(end, corners: surface.corners) {
                            if surface.maskPoints.count < 32 {
                                Button { onInsertMaskPoint(index) } label: {
                                    Image(systemName: "plus")
                                        .font(.system(size: 10, weight: .bold))
                                        .foregroundColor(.black)
                                        .frame(width: 30, height: 30)
                                        .background(Color(red: 1, green: 0.84, blue: 0.35))
                                        .clipShape(Circle())
                                        .overlay(Circle().stroke(Color.black.opacity(0.65), lineWidth: 1))
                                }
                                .buttonStyle(.plain)
                                .position(point(NormalizedPoint((outputStart.x + outputEnd.x) * 0.5, (outputStart.y + outputEnd.y) * 0.5), size))
                                .disabled(surface.isLocked)
                                .help("Insert a mask vertex on this edge")
                                .zIndex(1)
                            }
                        }
                    }
                }

                ForEach(Array(surface.corners.enumerated()), id: \.offset) { index, corner in
                    ZStack {
                        Circle().fill(Color.white.opacity(0.01))
                        Circle()
                            .fill(selectedCornerIndex == index ? Color(red: 0.25, green: 0.78, blue: 1) : .white)
                            .frame(width: 17, height: 17)
                            .overlay(Circle().stroke(Color.black.opacity(0.8), lineWidth: 1.5))
                        Text("\(index + 1)")
                            .font(.system(size: 8, weight: .bold, design: .rounded))
                            .foregroundColor(.black)
                    }
                        .frame(width: 34, height: 34)
                        .contentShape(Circle())
                        .position(point(corner, size))
                        .zIndex(2)
                        .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("mappingCanvas"))
                            .onChanged { value in
                                beginPointGesture(
                                    "corner-\(index)",
                                    startLocation: value.startLocation,
                                    anchor: corner,
                                    size: size
                                )
                                selectedCornerIndex = index
                                onCorner(index, dragPoint(value.location, size))
                            }
                            .onEnded { _ in finishGesture("corner-\(index)") })
                        .allowsHitTesting(
                            !isOutputMaskEditingEnabled && !surface.isLocked && !isMoveToolEnabled
                                && !isMaskEditingEnabled && !isMeshEditingEnabled
                        )
                        .help("Corner \(index + 1). Drag to adjust keystone.")
                }

                if isMaskEditingEnabled && !isOutputMaskEditingEnabled {
                    ForEach(Array(surface.maskPoints.enumerated()), id: \.offset) { index, maskPoint in
                        if let outputPoint = ProjectiveTransform.sourceToOutput(maskPoint, corners: surface.corners) {
                            ZStack {
                                Circle().fill(Color(red: 1, green: 0.67, blue: 0.23).opacity(0.08))
                                Circle()
                                    .fill(selectedMaskPointIndex == index ? Color.white : Color(red: 1, green: 0.67, blue: 0.23))
                                    .frame(width: 20, height: 20)
                                    .overlay(Circle().stroke(Color.black.opacity(0.9), lineWidth: 1.3))
                                Text("\(index + 1)")
                                    .font(.system(size: 8, weight: .bold, design: .rounded))
                                    .foregroundColor(.black)
                            }
                                .frame(width: 52, height: 52)
                                .contentShape(Circle())
                            .position(point(outputPoint, size))
                            .zIndex(1)
                            .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("mappingCanvas"))
                                .onChanged { value in
                                    beginPointGesture(
                                        "mask-\(index)",
                                        startLocation: value.startLocation,
                                        anchor: outputPoint,
                                        size: size
                                    )
                                    selectedMaskPointIndex = index
                                    let draggedPoint = dragPoint(value.location, size)
                                    if let sourcePoint = ProjectiveTransform.outputToSource(draggedPoint, corners: surface.corners) {
                                        onMaskPoint(index, sourcePoint.clamped())
                                    }
                                }
                                .onEnded { _ in finishGesture("mask-\(index)") })
                                .allowsHitTesting(!surface.isLocked)
                                .contextMenu {
                                    Button("Delete Vertex \(index + 1)", role: .destructive) {
                                        onRemoveMaskPoint(index)
                                    }
                                    .disabled(surface.maskPoints.count <= 3 || surface.isLocked)
                                }
                                .help("Mask vertex \(index + 1). Drag to reshape; right-click to remove.")
                        }
                    }
                }
            }
            .coordinateSpace(name: "mappingCanvas")
            .onChange(of: isMoveToolEnabled) { _ in lastMoveTranslation = .zero }
        }
    }

    private func surfaceHitPath(_ size: CGSize) -> Path {
        var path = Path()
        guard let first = surface.corners.first else { return path }
        path.move(to: point(first, size))
        for corner in surface.corners.dropFirst() { path.addLine(to: point(corner, size)) }
        path.closeSubpath()
        return path
    }

    private func beginPointGesture(
        _ identifier: String,
        startLocation: CGPoint,
        anchor: NormalizedPoint,
        size: CGSize
    ) {
        let startPoint = normalized(startLocation, size)
        beginGesture(
            identifier,
            grabOffset: NormalizedPoint(startPoint.x - anchor.x, startPoint.y - anchor.y)
        )
    }

    private func dragPoint(_ location: CGPoint, _ size: CGSize) -> NormalizedPoint {
        let pointer = normalized(location, size)
        let offset = activeDragGrabOffset ?? NormalizedPoint(0, 0)
        return snapped(NormalizedPoint(pointer.x - offset.x, pointer.y - offset.y))
    }

    private func beginGesture(_ identifier: String, grabOffset: NormalizedPoint? = nil) {
        if activeGestureID != identifier {
            if activeGestureID != nil { onEndGeometryEdit() }
            activeGestureID = identifier
            activeDragGrabOffset = grabOffset
            onBeginGeometryEdit()
            if identifier == "move" { lastMoveTranslation = .zero }
        }
    }

    private func finishGesture(_ identifier: String) {
        guard activeGestureID == identifier else { return }
        onEndGeometryEdit()
        activeGestureID = nil
        lastMoveTranslation = .zero
        activeDragGrabOffset = nil
    }

    private func snapped(_ point: NormalizedPoint) -> NormalizedPoint {
        var result = point
        if showsGrid {
            let step = 0.01
            result = NormalizedPoint((result.x / step).rounded() * step, (result.y / step).rounded() * step)
        }
        if snapToVertices,
           let nearest = snapTargets.min(by: { distance($0, result) < distance($1, result) }),
           distance(nearest, result) < 0.018 {
            result = nearest
        }
        return result.clamped()
    }

    private func distance(_ lhs: NormalizedPoint, _ rhs: NormalizedPoint) -> Double {
        hypot(lhs.x - rhs.x, lhs.y - rhs.y)
    }

    private func point(_ normalized: NormalizedPoint, _ size: CGSize) -> CGPoint {
        CGPoint(x: normalized.x * size.width, y: normalized.y * size.height)
    }

    private func normalized(_ point: CGPoint, _ size: CGSize) -> NormalizedPoint {
        NormalizedPoint(point.x / max(size.width, 1), point.y / max(size.height, 1)).clamped()
    }
}

private func mediaSymbol(_ source: MediaSource) -> String {
    switch source.kind {
    case .image: return "photo"
    case .video: return "film"
    case .capture: return "video.fill"
    case .ndi: return "dot.radiowaves.left.and.right"
    case .syphon: return "rectangle.on.rectangle"
    case .generator: return "sparkles"
    }
}

private struct MediaClipCell: View {
    @ObservedObject var source: MediaSource
    let isSelected: Bool
    let isAssigned: Bool
    let onAssign: () -> Void
    let onTogglePlayback: () -> Void
    let onAddLayer: () -> Void
    let onRemove: () -> Void
    let onEditGenerator: (VisualGenerator) -> Void
    @State private var showsAudioControls = false
    @State private var isScrubbingPlayback = false
    @State private var playbackScrubPosition = 0.0
    @State private var showsGeneratorControls = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button(action: onAssign) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Image(systemName: mediaSymbol(source))
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(Palette.accentSoft)
                        Spacer(minLength: 0)
                        if isAssigned {
                            Image(systemName: "scope")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundColor(Palette.green)
                        } else if source.kind == .capture || source.kind == .ndi || source.kind == .syphon {
                            Circle().fill(source.isCaptureConnected ? Palette.green : Palette.orange).frame(width: 6, height: 6)
                        }
                    }
                    if source.kind == .generator, let generator = source.generator {
                        RoundedRectangle(cornerRadius: 5)
                            .fill(LinearGradient(
                                colors: [
                                    Color(
                                        red: generator.primaryColor.red,
                                        green: generator.primaryColor.green,
                                        blue: generator.primaryColor.blue
                                    ),
                                    Color(
                                        red: generator.secondaryColor.red,
                                        green: generator.secondaryColor.green,
                                        blue: generator.secondaryColor.blue
                                    )
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ))
                            .overlay(alignment: .bottomLeading) {
                                Label(generator.title, systemImage: "sparkles")
                                    .font(.system(size: 7, weight: .semibold, design: .monospaced))
                                    .foregroundColor(.white)
                                    .padding(5)
                                    .shadow(color: .black.opacity(0.85), radius: 3)
                            }
                            .frame(maxWidth: .infinity)
                            .frame(height: 72)
                    } else if source.kind == .capture || source.kind == .ndi || source.kind == .syphon {
                        ZStack(alignment: .topLeading) {
                            if let previewImage = source.capturePreviewImage {
                                Image(nsImage: previewImage)
                                    .resizable()
                                    .scaledToFill()
                            } else {
                                Rectangle()
                                    .fill(Palette.background)
                                    .overlay {
                                        Image(systemName: source.isCaptureConnected ? "video" : "video.slash")
                                            .font(.system(size: 18, weight: .light))
                                            .foregroundColor(Palette.secondaryText)
                                    }
                            }
                            Text(source.isCaptureConnected
                                 ? (source.kind == .ndi ? "NDI · \(source.liveInputMetadata)" : (source.kind == .syphon ? "SYPHON · \(source.liveInputMetadata)" : "LIVE PREVIEW"))
                                 : (source.kind == .ndi && source.ndiFallbackMode == .holdLastFrame && source.latestCaptureFrame != nil
                                    ? "OFFLINE · HOLDING LAST"
                                    : "DISCONNECTED"))
                                .font(.system(size: 6, weight: .bold, design: .monospaced))
                                .foregroundColor(.white)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 3)
                                .background(Color.black.opacity(0.72))
                                .clipShape(RoundedRectangle(cornerRadius: 3))
                                .padding(4)
                                .lineLimit(1)
                                .minimumScaleFactor(0.75)
                            SourcePreviewRefresh(source: source)
                        }
                        .frame(maxWidth: .infinity)
                        .frame(height: 72)
                        .clipShape(RoundedRectangle(cornerRadius: 5))
                    }
                    Text(source.title)
                        .font(.system(size: 10, weight: .medium))
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, minHeight: 26, alignment: .leading)
                    Text(source.fileExtension.uppercased())
                        .font(.system(size: 8, weight: .medium, design: .monospaced))
                        .foregroundColor(Palette.secondaryText)
                }
            }
            .buttonStyle(.plain)
            .help("Assign to the selected mask output")

            HStack(spacing: 6) {
                if source.kind == .video {
                    Button(action: onTogglePlayback) {
                        Image(systemName: source.isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 9, weight: .bold))
                            .frame(width: 25, height: 23)
                            .background(Palette.background)
                            .clipShape(RoundedRectangle(cornerRadius: 5))
                    }
                    .buttonStyle(.plain)
                    .help(source.isPlaying ? "Pause video" : "Play video")

                    Button { source.setLooping(!source.isLooping) } label: {
                        Image(systemName: "repeat")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundColor(source.isLooping ? Palette.accentSoft : Palette.secondaryText)
                            .frame(width: 25, height: 23)
                            .background(Palette.background)
                            .clipShape(RoundedRectangle(cornerRadius: 5))
                    }
                    .buttonStyle(.plain)
                    .help(source.isLooping ? "Disable clip looping" : "Loop clip")

                }
                if source.kind == .video || source.kind == .ndi {
                    Button {
                        showsAudioControls.toggle()
                    } label: {
                        Image(systemName: source.isAudioMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                            .font(.system(size: 9, weight: .bold))
                            .frame(width: 25, height: 23)
                            .background(Palette.background)
                            .clipShape(RoundedRectangle(cornerRadius: 5))
                    }
                    .buttonStyle(.plain)
                    .popover(isPresented: $showsAudioControls, arrowEdge: .bottom) {
                        VStack(alignment: .leading, spacing: 10) {
                            if source.kind == .video {
                                playbackControls
                                Divider()
                            }
                            if source.kind == .ndi || source.kind == .video {
                                InputAudioMeter(source: source)
                            }
                            Toggle("Mute audio", isOn: Binding(
                                get: { source.isAudioMuted },
                                set: source.setAudioMuted
                            ))
                            HStack(spacing: 8) {
                                Image(systemName: "speaker.fill")
                                Slider(value: Binding(
                                    get: { source.audioVolume },
                                    set: source.setAudioVolume
                                ), in: 0...1)
                                Text("\(Int(source.audioVolume * 100))%")
                                    .monospacedDigit()
                                    .frame(width: 32, alignment: .trailing)
                            }
                            .font(.system(size: 9))
                            if source.kind == .ndi || source.kind == .video {
                                VStack(alignment: .leading, spacing: 4) {
                                    HStack {
                                        Text("A/V SYNC DELAY")
                                            .font(.system(size: 7, weight: .semibold, design: .monospaced))
                                            .foregroundColor(Palette.secondaryText)
                                        Spacer()
                                        Text("\(Int(source.audioDelayMilliseconds)) ms")
                                            .font(.system(size: 8, weight: .medium, design: .monospaced))
                                            .monospacedDigit()
                                    }
                                    Slider(value: Binding(
                                        get: { source.audioDelayMilliseconds },
                                        set: source.setAudioDelayMilliseconds
                                    ), in: 0...500, step: 10)
                                    .controlSize(.mini)
                                    .disabled(source.kind == .video && !source.isAudioDelaySupported)
                                }
                                Text(source.audioDelayStatusMessage ?? (source.kind == .video
                                    ? "Delays this clip's audio to sync it with its picture."
                                    : "Delays this input's audio while its picture remains live."))
                                    .font(.system(size: 8))
                                    .foregroundColor(Palette.tertiaryText)
                            }
                        }
                        .padding(12)
                        .frame(width: source.kind == .video ? 274 : 190)
                    }
                    .help(source.kind == .video
                        ? "Open clip playback and audio controls"
                        : (source.isAudioMuted ? "Audio is muted; edit source audio" : "Edit source audio"))
                }
                if source.kind == .capture {
                    Menu {
                        Section("Resolution and frame rate") {
                            ForEach(source.captureFormatOptions) { option in
                                Button {
                                    source.setCaptureFormat(option)
                                } label: {
                                    if source.captureFormatLabel == option.title {
                                        Label(option.title, systemImage: "checkmark")
                                    } else {
                                        Text(option.title)
                                    }
                                }
                            }
                        }
                    } label: {
                        Image(systemName: "gearshape")
                            .font(.system(size: 9, weight: .semibold))
                            .frame(width: 25, height: 23)
                            .background(Palette.background)
                            .clipShape(RoundedRectangle(cornerRadius: 5))
                    }
                    .menuStyle(.borderlessButton)
                    .disabled(!source.isCaptureConnected || source.captureFormatOptions.isEmpty)
                    .help("Choose capture resolution and frame rate")
                    Text(source.isCaptureConnected ? source.captureFormatLabel : "Disconnected")
                        .font(.system(size: 7, weight: .medium, design: .monospaced))
                        .foregroundColor(source.isCaptureConnected ? Palette.tertiaryText : Palette.orange)
                        .lineLimit(1)
                        .help(source.isCaptureConnected ? "Active capture format" : "Reconnect this device and re-add the source")
                } else if source.kind == .generator, let generator = source.generator {
                    Button {
                        showsGeneratorControls.toggle()
                    } label: {
                        Image(systemName: "slider.horizontal.3")
                            .font(.system(size: 9, weight: .semibold))
                            .frame(width: 25, height: 23)
                            .background(Palette.background)
                            .clipShape(RoundedRectangle(cornerRadius: 5))
                    }
                    .buttonStyle(.plain)
                    .popover(isPresented: $showsGeneratorControls, arrowEdge: .bottom) {
                        generatorControls(generator)
                    }
                    .help("Adjust generated visual colour and motion")
                }
                if source.kind == .ndi || source.kind == .syphon {
                    Text(source.liveInputMetadata)
                        .font(.system(size: 7, weight: .medium, design: .monospaced))
                        .foregroundColor(source.isCaptureConnected ? Palette.tertiaryText : Palette.orange)
                        .lineLimit(1)
                        .help("NDI input resolution and frame rate")
                }
                Button(action: onAddLayer) {
                    Image(systemName: "square.stack.3d.up")
                        .font(.system(size: 10, weight: .semibold))
                        .frame(width: 25, height: 23)
                        .background(Palette.background)
                        .clipShape(RoundedRectangle(cornerRadius: 5))
                }
                .buttonStyle(.plain)
                .help("Add another layer to the layer stack")
                Spacer(minLength: 0)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isSelected ? Palette.control : Palette.raised)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(isSelected ? Palette.accent : Palette.border, lineWidth: isSelected ? 1 : 0.5)
        }
        .contextMenu {
            Button("Assign to Selected Mask", action: onAssign)
            Button("Add Layer", action: onAddLayer)
            Button("Remove from Library", role: .destructive, action: onRemove)
        }
    }

    private func generatorControls(_ generator: VisualGenerator) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("GENERATED VISUAL")
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundColor(Palette.secondaryText)
            ColorPicker("Primary colour", selection: generatorColorBinding(\.primaryColor, fallback: generator.primaryColor))
            if generator.kind != .solid {
                ColorPicker("Secondary colour", selection: generatorColorBinding(\.secondaryColor, fallback: generator.secondaryColor))
                generatorSlider("SPEED", keyPath: \.speed, range: 0.01...2, format: "%.2f×")
                generatorSlider("SCALE", keyPath: \.scale, range: 0.1...8, format: "%.2f×")
                generatorSlider("DIRECTION", keyPath: \.directionDegrees, range: -180...180, format: "%.0f°")
            }
        }
        .font(.system(size: 9))
        .padding(12)
        .frame(width: 230)
    }

    private var playbackControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("CLIP PLAYBACK")
                    .font(.system(size: 8, weight: .semibold, design: .monospaced))
                    .foregroundColor(Palette.secondaryText)
                Spacer()
                Menu {
                    ForEach([0.5, 0.75, 1.0, 1.25, 1.5, 2.0], id: \.self) { rate in
                        Button {
                            source.setPlaybackRate(rate)
                        } label: {
                            if abs(source.playbackRate - rate) < 0.001 {
                                Label(String(format: "%.2g×", rate), systemImage: "checkmark")
                            } else {
                                Text(String(format: "%.2g×", rate))
                            }
                        }
                    }
                } label: {
                    Label(String(format: "%.2g×", source.playbackRate), systemImage: "speedometer")
                        .font(.system(size: 9, weight: .medium, design: .monospaced))
                }
                .menuStyle(.borderlessButton)
                .help("Set clip playback speed")
            }

            HStack {
                Text(playbackTimeLabel(isScrubbingPlayback ? playbackScrubPosition : source.playbackTimeSeconds))
                Spacer()
                Text(playbackTimeLabel(source.playbackDurationSeconds))
                    .foregroundColor(Palette.secondaryText)
            }
            .font(.system(size: 8, weight: .medium, design: .monospaced))

            Slider(
                value: Binding(
                    get: { isScrubbingPlayback ? playbackScrubPosition : source.playbackTimeSeconds },
                    set: { playbackScrubPosition = $0 }
                ),
                in: 0...max(source.playbackDurationSeconds, 0.01),
                onEditingChanged: { isEditing in
                    if isEditing {
                        playbackScrubPosition = source.playbackTimeSeconds
                        isScrubbingPlayback = true
                    } else {
                        source.seekPlayback(to: playbackScrubPosition)
                        isScrubbingPlayback = false
                    }
                }
            )
            .controlSize(.small)
            .disabled(source.playbackDurationSeconds <= 0)

            HStack(spacing: 8) {
                Button { source.seekPlayback(by: -5) } label: { Text("−5s") }
                    .help("Rewind five seconds")
                Button { source.seekPlayback(by: -1.0 / 30.0) } label: { Image(systemName: "backward.end.fill") }
                    .help("Step back one frame")
                Button { source.seekPlayback(by: 1.0 / 30.0) } label: { Image(systemName: "forward.end.fill") }
                    .help("Step forward one frame")
                Button { source.seekPlayback(by: 5) } label: { Text("+5s") }
                    .help("Advance five seconds")
            }
            .buttonStyle(.bordered)
            .controlSize(.mini)
            .frame(maxWidth: .infinity)
        }
        .padding(12)
        .frame(width: 250)
    }

    private func playbackTimeLabel(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "00:00" }
        let wholeSeconds = Int(seconds.rounded(.down))
        return String(format: "%02d:%02d", wholeSeconds / 60, wholeSeconds % 60)
    }

    private func generatorSlider(
        _ title: String,
        keyPath: WritableKeyPath<VisualGenerator, Double>,
        range: ClosedRange<Double>,
        format: String
    ) -> some View {
        let current = source.generator?[keyPath: keyPath] ?? range.lowerBound
        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                    .font(.system(size: 7, weight: .semibold, design: .monospaced))
                    .foregroundColor(Palette.secondaryText)
                Spacer()
                Text(String(format: format, current))
                    .font(.system(size: 8, weight: .medium, design: .monospaced))
                    .monospacedDigit()
            }
            Slider(value: Binding(
                get: { source.generator?[keyPath: keyPath] ?? range.lowerBound },
                set: { value in
                    mutateGenerator { $0[keyPath: keyPath] = value }
                }
            ), in: range)
            .controlSize(.mini)
        }
    }

    private func generatorColorBinding(
        _ keyPath: WritableKeyPath<VisualGenerator, SurfaceEffectColor>,
        fallback: SurfaceEffectColor
    ) -> Binding<Color> {
        Binding(
            get: {
                let color = source.generator?[keyPath: keyPath] ?? fallback
                return Color(red: color.red, green: color.green, blue: color.blue)
            },
            set: { value in
                let nativeColor = NSColor(value).usingColorSpace(.deviceRGB) ?? NSColor.white
                var red: CGFloat = 0
                var green: CGFloat = 0
                var blue: CGFloat = 0
                var alpha: CGFloat = 1
                nativeColor.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
                mutateGenerator {
                    $0[keyPath: keyPath] = SurfaceEffectColor(red: Double(red), green: Double(green), blue: Double(blue))
                }
            }
        )
    }

    private func mutateGenerator(_ update: (inout VisualGenerator) -> Void) {
        guard var configuration = source.generator else { return }
        update(&configuration)
        onEditGenerator(configuration)
    }
}

private struct InputAudioMeter: View {
    @ObservedObject var source: MediaSource
    private let meterTimer = Timer.publish(every: 0.08, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("INPUT LEVEL")
                    .font(.system(size: 7, weight: .semibold, design: .monospaced))
                    .foregroundColor(Palette.secondaryText)
                Spacer()
                Text("\(Int(boundedLevel * 100))%")
                    .font(.system(size: 8, weight: .medium, design: .monospaced))
                    .monospacedDigit()
            }
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(Palette.control)
                    Capsule()
                        .fill(boundedLevel >= 0.88 ? Palette.orange : Palette.green)
                        .frame(width: max(3, geometry.size.width * boundedLevel))
                }
            }
            .frame(height: 7)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(source.kind == .video ? "Video clip audio level" : "NDI input audio level")
        .accessibilityValue("\(Int(boundedLevel * 100)) percent")
        .onReceive(meterTimer) { _ in source.refreshAudioMeter() }
    }

    private var boundedLevel: Double {
        min(max(source.audioMeterLevel.isFinite ? source.audioMeterLevel : 0, 0), 1)
    }
}

private struct SourcePreviewRefresh: View {
    @ObservedObject var source: MediaSource
    private let previewTimer = Timer.publish(every: 0.25, on: .main, in: .common).autoconnect()

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .onReceive(previewTimer) { _ in source.refreshCapturePreview() }
            .accessibilityHidden(true)
    }
}

private struct LayerRow: View {
    let layer: RenderLayer
    @ObservedObject var source: MediaSource
    let availableSources: [MediaSource]
    let number: Int
    let isSelected: Bool
    let onSelect: () -> Void
    let onToggle: (Bool) -> Void
    let onSolo: (Bool) -> Void
    let onMove: (Int) -> Void
    let canMoveUp: Bool
    let canMoveDown: Bool
    let onRename: (String) -> Void
    let onDuplicate: () -> Void
    let onToggleLock: (Bool) -> Void
    let onContentTransform: (SurfaceContentTransform) -> Void
    let onOpacity: (Double) -> Void
    let onRemove: () -> Void
    let onSelectSource: (MediaSource) -> Void
    let onEffectStack: ([SurfaceEffect]) -> Void
    let userEffectPresets: [UserEffectPreset]
    let onSaveEffectPreset: ([SurfaceEffect]) -> Void
    let onDeleteEffectPreset: (UUID) -> Void
    @State private var effectsExpanded = false
    @State private var showsTransformControls = false
    @State private var isEditingName = false
    @State private var nameDraft = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 9) {
                Text(String(format: "%02d", number))
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .foregroundColor(Palette.tertiaryText)
                    .frame(width: 20)

                if isEditingName {
                    HStack(spacing: 4) {
                        TextField("Layer name", text: $nameDraft)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 10, weight: .medium))
                            .onSubmit(finishRenaming)
                        Button(action: finishRenaming) {
                            Image(systemName: "checkmark")
                                .font(.system(size: 8, weight: .bold))
                        }
                        .buttonStyle(.plain)
                        Button { isEditingName = false } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 8, weight: .bold))
                        }
                        .buttonStyle(.plain)
                    }
                    .frame(minWidth: 80, maxWidth: 145)
                } else {
                    Menu {
                        Section("Clip Slot · Layer \(number)") {
                            ForEach(availableSources) { candidate in
                                Button {
                                    onSelect()
                                    onSelectSource(candidate)
                                } label: {
                                    Label(candidate.title, systemImage: mediaSymbol(candidate))
                                }
                            }
                        }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: mediaSymbol(layer.source))
                                .foregroundColor(Palette.accentSoft)
                            Text(layer.displayName)
                                .font(.system(size: 10, weight: .semibold))
                                .lineLimit(1)
                            Image(systemName: "chevron.down")
                                .font(.system(size: 7, weight: .bold))
                                .foregroundColor(Palette.tertiaryText)
                        }
                        .padding(.horizontal, 7)
                        .padding(.vertical, 5)
                        .background(Palette.control.opacity(0.75))
                        .clipShape(RoundedRectangle(cornerRadius: 5))
                    }
                    .menuStyle(.borderlessButton)
                    .onTapGesture(perform: onSelect)
                    .help("Choose the clip loaded into this layer slot")
                }

                if layer.isLocked {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundColor(Palette.orange)
                        .help("Layer is locked")
                }

                Spacer(minLength: 2)

                Button { onMove(1) } label: {
                    Image(systemName: "chevron.up")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundColor(Palette.secondaryText)
                }
                .buttonStyle(.plain)
                .disabled(!canMoveUp)
                .help("Move layer forward")

                Button { onMove(-1) } label: {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundColor(Palette.secondaryText)
                }
                .buttonStyle(.plain)
                .disabled(!canMoveDown)
                .help("Move layer backward")

                if source.kind == .video {
                    Button(action: source.togglePlayback) {
                        Image(systemName: source.isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundColor(Palette.secondaryText)
                    }
                    .buttonStyle(.plain)
                    .help(source.isPlaying ? "Pause source" : "Play source")
                }

                Button {
                    onToggle(layer.isEnabled)
                } label: {
                    Image(systemName: layer.isEnabled ? "eye" : "eye.slash")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(layer.isEnabled ? Palette.primaryText : Palette.secondaryText)
                }
                .buttonStyle(.plain)
                .help(layer.isEnabled ? "Disable layer" : "Enable layer")

                Button { onSolo(layer.isSolo) } label: {
                    Text("S")
                        .font(.system(size: 8, weight: .bold, design: .monospaced))
                        .foregroundColor(layer.isSolo ? Palette.background : Palette.secondaryText)
                        .frame(width: 15, height: 15)
                        .background(layer.isSolo ? Palette.accentSoft : Palette.control)
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
                .help(layer.isSolo ? "Stop soloing this layer" : "Solo this layer")

                Button { showsTransformControls.toggle() } label: {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundColor(layer.contentTransform == nil ? Palette.secondaryText : Palette.accentSoft)
                }
                .buttonStyle(.plain)
                .popover(isPresented: $showsTransformControls, arrowEdge: .bottom) {
                    layerTransformControls
                }
                .disabled(layer.isLocked)
                .help("Transform this layer's source independently of its mapped surface")

                Menu {
                    Button {
                        nameDraft = layer.displayName
                        isEditingName = true
                    } label: {
                        Label("Rename Layer…", systemImage: "pencil")
                    }
                    Button(action: onDuplicate) {
                        Label("Duplicate Layer", systemImage: "plus.square.on.square")
                    }
                    Divider()
                    Button { onToggleLock(layer.isLocked) } label: {
                        Label(
                            layer.isLocked ? "Unlock Layer" : "Lock Layer",
                            systemImage: layer.isLocked ? "lock.open" : "lock"
                        )
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(Palette.secondaryText)
                }
                .menuStyle(.borderlessButton)
                .help("Rename, duplicate or lock this layer")

                Button(action: onRemove) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundColor(Palette.secondaryText)
                }
                .buttonStyle(.plain)
                .disabled(layer.isLocked)
                .help("Remove layer")
            }

            HStack(spacing: 5) {
                Text("CLIP SLOTS")
                    .font(.system(size: 7, weight: .semibold, design: .monospaced))
                    .foregroundColor(Palette.tertiaryText)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 4) {
                        ForEach(Array(availableSources.enumerated()), id: \.element.id) { index, candidate in
                            let isActiveClip = candidate.reference == source.reference
                            Button {
                                onSelect()
                                onSelectSource(candidate)
                            } label: {
                                VStack(spacing: 3) {
                                    Text(String(format: "%02d", index + 1))
                                        .font(.system(size: 7, weight: .semibold, design: .monospaced))
                                        .foregroundColor(isActiveClip ? Palette.background : Palette.tertiaryText)
                                    HStack(spacing: 3) {
                                        Image(systemName: mediaSymbol(candidate))
                                            .font(.system(size: 7, weight: .semibold))
                                        Text(candidate.title)
                                            .font(.system(size: 7, weight: .medium))
                                            .lineLimit(1)
                                    }
                                    .foregroundColor(isActiveClip ? Palette.background : Palette.secondaryText)
                                }
                                .frame(width: 78, height: 33)
                                .background(isActiveClip ? Palette.accentSoft : Palette.control)
                                .clipShape(RoundedRectangle(cornerRadius: 5))
                            }
                            .buttonStyle(.plain)
                            .disabled(layer.isLocked)
                            .help("Load \(candidate.title) into this track")
                        }
                    }
                }
                .frame(height: 35)
            }

            HStack(spacing: 8) {
                Text("OPACITY")
                    .font(.system(size: 8, weight: .semibold, design: .monospaced))
                    .foregroundColor(Palette.secondaryText)
                Slider(value: Binding(get: { layer.opacity }, set: onOpacity), in: 0...1)
                    .controlSize(.mini)
                    .tint(Palette.accent)
                    .disabled(layer.isLocked)
                Text("\(Int(layer.opacity * 100))%")
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .foregroundColor(Palette.secondaryText)
                    .frame(width: 31, alignment: .trailing)
            }

            HStack(spacing: 6) {
                Button {
                    effectsExpanded.toggle()
                } label: {
                    Label("Effects · \((layer.effectStack ?? []).count)", systemImage: "slider.horizontal.3")
                        .font(.system(size: 8, weight: .medium))
                }
                .buttonStyle(.plain)
                .foregroundColor((layer.effectStack ?? []).isEmpty ? Palette.secondaryText : Palette.accentSoft)
                .disabled(layer.isLocked)
                .help("Edit effects applied to this layer before it is mapped")
                Spacer(minLength: 0)
                Menu {
                    Section("Add Effect") {
                        ForEach(SurfaceEffectKind.allCases) { kind in
                            Button(kind.rawValue) { editEffects { effects in
                                guard effects.count < SurfaceEffect.maximumStackSize else { return }
                                effects.append(SurfaceEffect(kind: kind, radius: kind == .hueRotation ? 0 : 5))
                            }}
                            .disabled((layer.effectStack ?? []).count >= SurfaceEffect.maximumStackSize)
                        }
                    }
                    Section("Apply Preset") {
                        ForEach(SurfaceEffectPreset.allCases) { preset in
                            Button(preset.rawValue) { onEffectStack(preset.effects) }
                        }
                    }
                    Section("Saved Presets") {
                        if userEffectPresets.isEmpty {
                            Text("No saved presets")
                        } else {
                            ForEach(userEffectPresets) { preset in
                                Button(preset.name) { onEffectStack(preset.effects) }
                            }
                        }
                    }
                    Section("Save Current") {
                        Button("Save Stack as Preset…") { onSaveEffectPreset(layer.effectStack ?? []) }
                            .disabled((layer.effectStack ?? []).isEmpty)
                    }
                    if !userEffectPresets.isEmpty {
                        Section("Delete Saved Preset") {
                            ForEach(userEffectPresets) { preset in
                                Button("Delete · \(preset.name)", role: .destructive) {
                                    onDeleteEffectPreset(preset.id)
                                }
                            }
                        }
                    }
                    Divider()
                    Button("Clear Layer Effects", role: .destructive) { onEffectStack([]) }
                        .disabled((layer.effectStack ?? []).isEmpty)
                } label: {
                    Image(systemName: "plus.circle")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(Palette.secondaryText)
                }
                .menuStyle(.borderlessButton)
                .disabled(layer.isLocked)
                .help("Add a layer effect or apply a preset")
            }

            if effectsExpanded {
                VStack(alignment: .leading, spacing: 7) {
                    if (layer.effectStack ?? []).isEmpty {
                        Text("Effects run before the layer is assigned to a surface.")
                            .font(.system(size: 8))
                            .foregroundColor(Palette.tertiaryText)
                    }
                    ForEach(Array((layer.effectStack ?? []).enumerated()), id: \.element.id) { entry in
                        layerEffectRow(entry.element, index: entry.offset)
                    }
                }
                .padding(.top, 2)
                .disabled(layer.isLocked)
            }
        }
        .padding(11)
        .background(layer.isEnabled ? Palette.raised : Palette.raised.opacity(0.6))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(isSelected ? Palette.accentSoft : Color.clear, lineWidth: 1.25)
        }
        .contentShape(RoundedRectangle(cornerRadius: 8))
        .onTapGesture(perform: onSelect)
        .opacity(layer.isEnabled ? 1 : 0.65)
    }

    private func layerEffectRow(_ effect: SurfaceEffect, index: Int) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 5) {
                Toggle("", isOn: Binding(
                    get: { layer.effectStack?[safe: index]?.isEnabled ?? false },
                    set: { enabled in editEffects { effects in effects[index].isEnabled = enabled } }
                ))
                .labelsHidden()
                .toggleStyle(.checkbox)
                Text(effect.kind.rawValue)
                    .font(.system(size: 8, weight: .medium))
                    .foregroundColor(Palette.secondaryText)
                Spacer()
                Button { moveEffect(at: index, by: -1) } label: { Image(systemName: "chevron.up") }
                    .disabled(index == 0)
                Button { moveEffect(at: index, by: 1) } label: { Image(systemName: "chevron.down") }
                    .disabled(index == (layer.effectStack ?? []).count - 1)
                Button { editEffects { $0.remove(at: index) } } label: { Image(systemName: "xmark") }
            }
            .buttonStyle(.plain)
            .font(.system(size: 7, weight: .semibold))

            switch effect.kind {
            case .blur:
                effectSlider("RADIUS", value: effect.radius, range: 0...24, index: index, keyPath: \.radius)
            case .chromaKey:
                effectSlider("THRESHOLD", value: effect.threshold, range: 0...1, index: index, keyPath: \.threshold)
                effectSlider("SOFTNESS", value: effect.softness, range: 0.001...0.5, index: index, keyPath: \.softness)
            case .brightness, .saturation:
                effectSlider("AMOUNT ×2", value: effect.threshold * 2, range: 0...2, index: index, keyPath: \.threshold, scale: 2)
            case .pixelate:
                effectSlider("BLOCK SIZE", value: effect.radius, range: 1...64, index: index, keyPath: \.radius)
            case .hueRotation:
                effectSlider("ANGLE °", value: effect.radius, range: -180...180, index: index, keyPath: \.radius)
            case .tint:
                HStack(spacing: 5) {
                    Text("TINT")
                        .font(.system(size: 7, weight: .medium, design: .monospaced))
                        .foregroundColor(Palette.tertiaryText)
                    Spacer()
                    ColorPicker("Tint color", selection: effectColorBinding(at: index, fallback: effect.keyColor), supportsOpacity: false)
                        .labelsHidden()
                        .controlSize(.mini)
                }
                effectSlider("AMOUNT", value: effect.threshold, range: 0...1, index: index, keyPath: \.threshold)
            case .sharpen:
                effectSlider("RADIUS", value: effect.radius, range: 0...12, index: index, keyPath: \.radius)
            case .vignette:
                effectSlider("STRENGTH", value: effect.threshold, range: 0...1, index: index, keyPath: \.threshold)
            case .lumaKey:
                effectSlider("CUTOFF", value: effect.threshold, range: 0...1, index: index, keyPath: \.threshold)
                effectSlider("SOFTNESS", value: effect.softness, range: 0.001...0.5, index: index, keyPath: \.softness)
            case .threshold:
                effectSlider("LEVEL", value: effect.threshold, range: 0...1, index: index, keyPath: \.threshold)
            case .grayscale, .sepia, .invert:
                Text("Applies this look to the layer.")
                    .font(.system(size: 7))
                    .foregroundColor(Palette.tertiaryText)
            }
        }
        .padding(7)
        .background(Palette.background.opacity(0.72))
        .clipShape(RoundedRectangle(cornerRadius: 5))
    }

    private var layerTransformControls: some View {
        let transform = layer.contentTransform?.sanitized() ?? .identity
        return VStack(alignment: .leading, spacing: 9) {
            HStack {
                Text("LAYER INPUT TRANSFORM")
                    .font(.system(size: 8, weight: .bold, design: .monospaced))
                    .foregroundColor(Palette.secondaryText)
                Spacer()
                Button("Reset") { onContentTransform(.identity) }
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
            }
            layerTransformSlider("ZOOM X", value: transform.zoomX, range: 0.1...4, keyPath: \.zoomX, format: "%.2f×")
            layerTransformSlider("ZOOM Y", value: transform.zoomY, range: 0.1...4, keyPath: \.zoomY, format: "%.2f×")
            layerTransformSlider("POSITION X", value: transform.offsetX, range: -1...1, keyPath: \.offsetX, format: "%+.2f")
            layerTransformSlider("POSITION Y", value: transform.offsetY, range: -1...1, keyPath: \.offsetY, format: "%+.2f")
            layerTransformSlider("SKEW X", value: transform.skewX, range: -1...1, keyPath: \.skewX, format: "%+.2f")
            layerTransformSlider("SKEW Y", value: transform.skewY, range: -1...1, keyPath: \.skewY, format: "%+.2f")
            layerTransformSlider("ROTATION", value: transform.rotationDegrees, range: -180...180, keyPath: \.rotationDegrees, format: "%.0f°")
            HStack(spacing: 14) {
                Toggle("Flip horizontal", isOn: Binding(
                    get: { layer.contentTransform?.isFlippedHorizontally ?? false },
                    set: { value in updateLayerTransform { $0.isFlippedHorizontally = value } }
                ))
                Toggle("Flip vertical", isOn: Binding(
                    get: { layer.contentTransform?.isFlippedVertically ?? false },
                    set: { value in updateLayerTransform { $0.isFlippedVertically = value } }
                ))
            }
            .toggleStyle(.checkbox)
            .font(.system(size: 9))
            Text("This changes only the layer's sampled content. Surface corners, mesh and masks stay fixed.")
                .font(.system(size: 8))
                .foregroundColor(Palette.tertiaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(width: 270)
        .disabled(layer.isLocked)
    }

    private func layerTransformSlider(
        _ title: String,
        value: Double,
        range: ClosedRange<Double>,
        keyPath: WritableKeyPath<SurfaceContentTransform, Double>,
        format: String
    ) -> some View {
        HStack(spacing: 6) {
            Text(title)
                .font(.system(size: 7, weight: .semibold, design: .monospaced))
                .foregroundColor(Palette.tertiaryText)
                .frame(width: 66, alignment: .leading)
            Slider(value: Binding(
                get: { layer.contentTransform?.sanitized()[keyPath: keyPath] ?? value },
                set: { newValue in updateLayerTransform { $0[keyPath: keyPath] = newValue } }
            ), in: range)
            .controlSize(.mini)
            Text(String(format: format, value))
                .font(.system(size: 8, weight: .medium, design: .monospaced))
                .monospacedDigit()
                .frame(width: 38, alignment: .trailing)
        }
    }

    private func updateLayerTransform(_ update: (inout SurfaceContentTransform) -> Void) {
        var transform = layer.contentTransform?.sanitized() ?? .identity
        update(&transform)
        onContentTransform(transform)
    }

    private func finishRenaming() {
        let trimmed = nameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { onRename(trimmed) }
        isEditingName = false
    }

    private func effectSlider(
        _ title: String,
        value: Double,
        range: ClosedRange<Double>,
        index: Int,
        keyPath: WritableKeyPath<SurfaceEffect, Double>,
        scale: Double = 1
    ) -> some View {
        HStack(spacing: 5) {
            Text(title)
                .font(.system(size: 7, weight: .medium, design: .monospaced))
                .foregroundColor(Palette.tertiaryText)
                .frame(width: 45, alignment: .leading)
            Slider(value: Binding(
                get: { (layer.effectStack?[safe: index]?[keyPath: keyPath] ?? value / scale) * scale },
                set: { newValue in editEffects { effects in effects[index][keyPath: keyPath] = newValue / scale } }
            ), in: range)
            .controlSize(.mini)
        }
    }

    private func editEffects(_ update: (inout [SurfaceEffect]) -> Void) {
        var effects = layer.effectStack ?? []
        update(&effects)
        onEffectStack(effects)
    }

    private func effectColorBinding(at index: Int, fallback: SurfaceEffectColor) -> Binding<Color> {
        Binding(
            get: {
                let color = layer.effectStack?[safe: index]?.keyColor ?? fallback
                return Color(red: color.red, green: color.green, blue: color.blue)
            },
            set: { newColor in
                guard let rgb = NSColor(newColor).usingColorSpace(.deviceRGB) else { return }
                editEffects { effects in
                    guard effects.indices.contains(index) else { return }
                    effects[index].keyColor = SurfaceEffectColor(
                        red: Double(rgb.redComponent),
                        green: Double(rgb.greenComponent),
                        blue: Double(rgb.blueComponent)
                    )
                }
            }
        )
    }

    private func moveEffect(at index: Int, by offset: Int) {
        editEffects { effects in
            let destination = index + offset
            guard effects.indices.contains(index), effects.indices.contains(destination) else { return }
            effects.swapAt(index, destination)
        }
    }
}

private extension Array {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

private struct MetalCanvas: NSViewRepresentable {
    let renderer: MetalRenderer
    let session: RenderSession
    var outputID = ProjectionOutput.mainID
    var preferredFramesPerSecond = 30
    var previewScale = 1.0

    func makeCoordinator() -> Coordinator {
        Coordinator(renderer: renderer)
    }

    func makeNSView(context: Context) -> MTKView {
        renderer.makeView(
            session: session,
            outputID: outputID,
            preferredFramesPerSecond: preferredFramesPerSecond,
            previewScale: previewScale
        )
    }

    func updateNSView(_ view: MTKView, context: Context) {
        renderer.updateSession(for: view, session: session, outputID: outputID, previewScale: previewScale)
        view.preferredFramesPerSecond = preferredFramesPerSecond
    }

    static func dismantleNSView(_ view: MTKView, coordinator: Coordinator) {
        coordinator.renderer.releaseView(view)
    }

    final class Coordinator {
        let renderer: MetalRenderer

        init(renderer: MetalRenderer) {
            self.renderer = renderer
        }
    }
}

private enum Palette {
    static let background = Color(red: 0.055, green: 0.065, blue: 0.083)
    static let panel = Color(red: 0.078, green: 0.090, blue: 0.113)
    static let raised = Color(red: 0.105, green: 0.120, blue: 0.148)
    static let control = Color(red: 0.145, green: 0.165, blue: 0.202)
    static let border = Color(red: 0.17, green: 0.19, blue: 0.23)
    static let primaryText = Color(red: 0.91, green: 0.93, blue: 0.97)
    static let secondaryText = Color(red: 0.55, green: 0.59, blue: 0.66)
    static let tertiaryText = Color(red: 0.37, green: 0.41, blue: 0.49)
    static let accent = Color(red: 0.34, green: 0.40, blue: 0.94)
    static let accentSoft = Color(red: 0.57, green: 0.63, blue: 1.0)
    static let green = Color(red: 0.31, green: 0.79, blue: 0.58)
    static let orange = Color(red: 1.0, green: 0.66, blue: 0.31)
}
