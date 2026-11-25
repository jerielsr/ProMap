import SwiftUI
import AppKit

@main
struct ProMapApp: App {
    @NSApplicationDelegateAdaptor(ProMapApplicationDelegate.self) private var applicationDelegate

    var body: some Scene {
        WindowGroup {
            MainWorkspaceView()
        }
        .windowStyle(.hiddenTitleBar)
        .commands {
            ProMapCommands()
        }

        Settings {
            OutputSettingsView()
        }
    }
}

private struct ProMapCommands: Commands {
    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("Capture Current Scene") { post(.captureScene) }
        }
        CommandGroup(replacing: .saveItem) {
            Button("Save Show…") { post(.saveShow) }
            Button("Open Show…") { post(.loadShow) }
        }
        CommandGroup(replacing: .importExport) {
            Button("Import Media…") { post(.importMedia) }
        }
        CommandMenu("Workspace") {
            Button("Live Editor") { post(.liveEditor) }
            Button("Playback") { post(.playback) }
            Button("Diagnostics") { post(.diagnostics) }
        }
        CommandMenu("Playback") {
            Button("Take Preview to Program") { post(.takePreview) }
            Button("Previous Cue") { post(.previousCue) }
            Button("Next Cue") { post(.nextCue) }
            Button("Capture Current Scene") { post(.captureScene) }
        }
        CommandMenu("Output") {
            Button("Toggle Blackout") { post(.toggleBlackout) }
            Button("Freeze / Unfreeze Output") { post(.toggleFreeze) }
        }
    }

    private func post(_ action: ProMapCommandAction) {
        NotificationCenter.default.post(
            name: .proMapCommand,
            object: nil,
            userInfo: ["action": action.rawValue]
        )
    }
}

enum ProMapCommandAction: String {
    case captureScene, saveShow, loadShow, importMedia
    case liveEditor, playback, diagnostics
    case takePreview, previousCue, nextCue
    case toggleBlackout, toggleFreeze
}

extension Notification.Name {
    static let proMapCommand = Notification.Name("ProMap.command")
}

private final class ProMapApplicationDelegate: NSObject, NSApplicationDelegate {
    private let recoverySessionMarker = RecoverySessionMarker.applicationSupportMarker()

    func applicationWillFinishLaunching(_ notification: Notification) {
        let previousSessionWasUnclean = recoverySessionMarker?.beginSession() ?? false
        UserDefaults.standard.set(previousSessionWasUnclean, forKey: "previousSessionWasUnclean")
    }

    func applicationWillTerminate(_ notification: Notification) {
        recoverySessionMarker?.endSession()
    }
}

private struct OutputSettingsView: View {
    @StateObject private var midiControl = MIDIControlManager.shared
    @StateObject private var ndiService = NDIService.shared
    @StateObject private var ndiOutputService = NDIOutputService.shared
    @StateObject private var syphonService = SyphonService.shared
    @StateObject private var syphonOutputService = SyphonOutputService.shared
    @AppStorage("outputAboveMenuBar") private var outputAboveMenuBar = false
    @AppStorage("outputFrameRate") private var outputFrameRate = 30
    @AppStorage("previewFrameRate") private var previewFrameRate = 10
    @AppStorage("previewRenderScale") private var previewRenderScale = 0.5
    @AppStorage("performanceProfile") private var performanceProfile = "performance"
    @AppStorage("sceneTransitionDuration") private var sceneTransitionDuration = 0.35
    @AppStorage("masterAudioVolume") private var masterAudioVolume = 1.0
    @AppStorage("audioOutputDeviceUID") private var audioOutputDeviceUID = ""
    @AppStorage("externalHTTPEnabled") private var externalHTTPEnabled = false
    @AppStorage("externalHTTPPort") private var externalHTTPPort = 8765
    @AppStorage("externalHTTPRemoteAccess") private var externalHTTPRemoteAccess = false
    @AppStorage("externalAPIToken") private var externalAPIToken = ""
    @AppStorage("externalOSCEnabled") private var externalOSCEnabled = false
    @AppStorage("externalOSCPort") private var externalOSCPort = 8766
    @AppStorage("midiControlEnabled") private var midiControlEnabled = false
    @AppStorage("syphonInputsEnabled") private var syphonInputsEnabled = false
    @AppStorage("syphonOutputEnabled") private var syphonOutputEnabled = false
    @AppStorage("syphonOutputSourceName") private var syphonOutputSourceName = "ProMap Program"
    @AppStorage("ndiInputsEnabled") private var ndiInputsEnabled = false
    @AppStorage("ndiOutputEnabled") private var ndiOutputEnabled = false
    @AppStorage("ndiOutputSourceName") private var ndiOutputSourceName = "ProMap Program"
    @AppStorage("ndiReceiveBandwidth") private var ndiReceiveBandwidth = "full"
    @AppStorage("ndiFallbackMode") private var ndiFallbackMode = "black"
    @AppStorage("launchInBlackout") private var launchInBlackout = false
    @AppStorage("preventSleepWhileOutputOpen") private var preventSleepWhileOutputOpen = true
    @AppStorage("mappingLockedForLive") private var mappingLockedForLive = false
    @AppStorage("operatorModeEnabled") private var operatorModeEnabled = false
    @State private var audioOutputDevices = AudioOutputDevice.availableDevices()
    @State private var manualNDIName = ""
    @State private var manualNDIAddress = ""
    @State private var manualNDIMessage: String?

    var body: some View {
        TabView {
            generalPage
                .tabItem { Label("General", systemImage: "display") }
            audioPage
                .tabItem { Label("Audio", systemImage: "speaker.wave.2") }
            ndiPage
                .tabItem { Label("NDI I/O", systemImage: "dot.radiowaves.left.and.right") }
            syphonPage
                .tabItem { Label("Syphon I/O", systemImage: "rectangle.on.rectangle") }
            networkPage
                .tabItem { Label("Network", systemImage: "network") }
            midiPage
                .tabItem { Label("MIDI", systemImage: "pianokeys") }
            safetyPage
                .tabItem { Label("Safety", systemImage: "lock.shield") }
        }
        .frame(width: 620, height: 540)
        .onAppear {
            audioOutputDevices = AudioOutputDevice.availableDevices()
            midiControl.configure(enabled: midiControlEnabled)
            ndiService.configure(enabled: ndiInputsEnabled)
            syphonService.configure(enabled: syphonInputsEnabled)
        }
        .onChange(of: midiControlEnabled) { midiControl.configure(enabled: $0) }
        .onChange(of: ndiInputsEnabled) { ndiService.configure(enabled: $0) }
        .onChange(of: syphonInputsEnabled) { syphonService.configure(enabled: $0) }
        .onDisappear {
            if midiControl.learningActionID != nil { midiControl.cancelLearning() }
        }
    }

    private var generalPage: some View {
        settingsPage(
            title: "Output & Playback",
            detail: "Set output performance and how recalled cues transition."
        ) {
            settingsCard {
                Toggle("Keep output above the macOS menu bar", isOn: $outputAboveMenuBar)
                settingsHint("Use this for a clean physical projector surface. Virtual preview windows stay at normal level so operator controls remain available.")
            }
            settingsCard {
                Picker("Rendering profile", selection: performanceProfileBinding) {
                    Text("Performance").tag("performance")
                    Text("Balanced").tag("balanced")
                    Text("Full Detail").tag("detail")
                    Text("Custom").tag("custom")
                }
                settingsHint("Profiles adjust projector frame rate and in-app preview refresh and resolution. They do not change the projector canvas or saved mapping coordinates.")
                Picker("Projector output frame rate", selection: outputFrameRateBinding) {
                    ForEach([24, 25, 30, 50, 60], id: \.self) { rate in
                        Text("\(rate) fps").tag(rate)
                    }
                }
                settingsHint("Lower rates reduce rendering load on older Macs. Choose 30 fps for a lighter live setup or 60 fps when your Mac and projector can sustain it.")
                Picker("Editor and monitor preview rate", selection: previewFrameRateBinding) {
                    ForEach([5, 10, 15, 30], id: \.self) { rate in
                        Text("\(rate) fps").tag(rate)
                    }
                }
                settingsHint("This only changes in-app previews. Keep it low during a service to leave more GPU time for projector outputs.")
                HStack {
                    Text("Preview render resolution")
                    Spacer()
                    Text("\(Int(previewRenderScale * 100))%")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                Slider(value: previewRenderScaleBinding, in: 0.5...1, step: 0.25)
                settingsHint("This scales editor and monitor Metal canvases only. Physical and virtual projector outputs remain full resolution.")
            }
            settingsCard {
                VStack(alignment: .leading, spacing: 9) {
                    HStack {
                        Label("Scene transition", systemImage: "arrow.left.arrow.right")
                        Spacer()
                        Text(sceneTransitionDuration == 0 ? "Cut" : String(format: "%.2f s", sceneTransitionDuration))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    Slider(value: $sceneTransitionDuration, in: 0.05...5, step: 0.05)
                    settingsHint("Set the default transition length. Choose Cut, Dissolve or Dip to Black and a timing curve in Playback.")
                }
            }
        }
    }

    private var audioPage: some View {
        settingsPage(
            title: "Audio",
            detail: "Route video clip audio and set one master level for the show."
        ) {
            settingsCard {
                VStack(alignment: .leading, spacing: 9) {
                    HStack {
                        Label("Master media volume", systemImage: "speaker.wave.2")
                        Spacer()
                        Text("\(Int(masterAudioVolume * 100))%")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    Slider(value: $masterAudioVolume, in: 0...1)
                    settingsHint("This scales each video clip’s own volume. New clips start muted.")
                }
            }
            settingsCard {
                Picker("Audio output", selection: $audioOutputDeviceUID) {
                    Text("System Default").tag("")
                    ForEach(audioOutputDevices) { device in
                        Text(device.name).tag(device.uniqueID)
                    }
                }
                HStack {
                    settingsHint(audioOutputDeviceUID.isEmpty
                        ? "Video audio follows the current macOS output device."
                        : (audioOutputDevices.first(where: { $0.uniqueID == audioOutputDeviceUID })?.name ?? "The selected device is unavailable."))
                    Spacer()
                    Button("Refresh Devices") { audioOutputDevices = AudioOutputDevice.availableDevices() }
                }
            }
        }
    }

    private var performanceProfileBinding: Binding<String> {
        Binding(
            get: { performanceProfile },
            set: { profile in
                performanceProfile = profile
                switch profile {
                case "performance":
                    outputFrameRate = 30
                    previewFrameRate = 10
                    previewRenderScale = 0.5
                case "balanced":
                    outputFrameRate = 60
                    previewFrameRate = 15
                    previewRenderScale = 0.75
                case "detail":
                    outputFrameRate = 60
                    previewFrameRate = 30
                    previewRenderScale = 1
                default:
                    break
                }
            }
        )
    }

    private var outputFrameRateBinding: Binding<Int> {
        Binding(
            get: { outputFrameRate },
            set: { outputFrameRate = $0; performanceProfile = "custom" }
        )
    }

    private var previewFrameRateBinding: Binding<Int> {
        Binding(
            get: { previewFrameRate },
            set: { previewFrameRate = $0; performanceProfile = "custom" }
        )
    }

    private var previewRenderScaleBinding: Binding<Double> {
        Binding(
            get: { previewRenderScale },
            set: { previewRenderScale = $0; performanceProfile = "custom" }
        )
    }

    private var ndiPage: some View {
        settingsPage(
            title: "NDI® Inputs & Output",
            detail: "Receive live sources into masks or publish a projector output as an NDI source."
        ) {
            settingsCard {
                Toggle("Enable NDI input discovery", isOn: $ndiInputsEnabled)
                HStack(spacing: 8) {
                    Circle()
                        .fill(ndiInputsEnabled && ndiService.status.hasPrefix("NDI ready") ? Color.green : Color.secondary)
                        .frame(width: 8, height: 8)
                    Text(ndiInputsEnabled ? ndiService.status : "Discovery is off")
                        .font(.callout)
                    Spacer()
                    Button("Refresh") { ndiService.refresh() }
                        .disabled(!ndiInputsEnabled)
                }
                settingsHint("After discovery, open + beside Clip Grid and choose a source under NDI Network Sources. New inputs start muted; open the clip’s speaker control to set its level.")
                Picker("Receive bandwidth", selection: $ndiReceiveBandwidth) {
                    ForEach(NDIReceiveBandwidth.allCases) { option in
                        Text(option.title).tag(option.rawValue)
                    }
                }
                Picker("When a source disconnects", selection: $ndiFallbackMode) {
                    ForEach(NDIFallbackMode.allCases) { option in
                        Text(option.title).tag(option.rawValue)
                    }
                }
                settingsHint("These defaults apply to new NDI clips. Hold last frame keeps the final picture visible while the source reconnects.")
            }
            settingsCard {
                Text("Connect to a source manually")
                    .font(.headline)
                TextField("NDI source name", text: $manualNDIName)
                    .textFieldStyle(.roundedBorder)
                TextField("Source URL or address", text: $manualNDIAddress)
                    .textFieldStyle(.roundedBorder)
                HStack {
                    if let manualNDIMessage {
                        settingsHint(manualNDIMessage)
                    }
                    Spacer()
                    Button("Save Source") {
                        if let error = ndiService.addManualSource(name: manualNDIName, address: manualNDIAddress) {
                            manualNDIMessage = error
                        } else {
                            manualNDIMessage = "Saved. Add it from the + menu beside Clip Grid."
                            manualNDIName = ""
                            manualNDIAddress = ""
                        }
                    }
                    .disabled(!ndiInputsEnabled)
                }
                settingsHint("Enable NDI input discovery first. This saved source will appear with discovered sources and can be restored with a show.")
            }
            settingsCard {
                Toggle("Send the projector output over NDI", isOn: $ndiOutputEnabled)
                TextField("NDI output source name", text: $ndiOutputSourceName)
                    .textFieldStyle(.roundedBorder)
                    .disabled(!ndiOutputEnabled)
                HStack(spacing: 8) {
                    Circle()
                        .fill(ndiOutputService.status.contains("On Air") ? Color.green : (ndiOutputEnabled ? Color.orange : Color.secondary))
                        .frame(width: 7, height: 7)
                    Text(ndiOutputService.status)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                settingsHint("ProMap publishes the selected projector output as a video-only NDI source at up to 30 fps. The most recently selected open physical or virtual output is sent; layer and mask mapping are included in the stream. Sending requires the NDI runtime.")
            }
            if !ndiService.manualSources.isEmpty {
                settingsCard {
                    HStack {
                        Text("Saved manual sources")
                            .font(.headline)
                        Spacer()
                        Text("\(ndiService.manualSources.count)")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    ForEach(ndiService.manualSources) { source in
                        HStack(spacing: 10) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(source.name)
                                    .font(.system(size: 12, weight: .medium))
                                    .lineLimit(1)
                                Text(source.url)
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                            Spacer(minLength: 4)
                            Button(role: .destructive) {
                                ndiService.removeManualSource(reference: source.reference)
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.plain)
                            .help("Remove saved manual source")
                        }
                    }
                }
            }
            settingsCard {
                Link(destination: URL(string: "https://ndi.video/for-developers/ndi-sdk/download/")!) {
                    Label("Get the NDI SDK", systemImage: "arrow.up.right.square")
                }
                settingsHint("Install the NDI SDK or runtime and restart ProMap. ProMap loads the runtime from its standard macOS location; developer headers are not required for normal use.")
                Link("NDI® is a registered trademark of Vizrt NDI AB", destination: URL(string: "https://ndi.video/")!)
                    .font(.caption)
            }
        }
    }

    private var syphonPage: some View {
        settingsPage(
            title: "Syphon I/O",
            detail: "Exchange video with Syphon-compatible macOS apps without a capture device."
        ) {
            settingsCard {
                Toggle("Enable Syphon input discovery", isOn: $syphonInputsEnabled)
                HStack(spacing: 8) {
                    Circle()
                        .fill(syphonInputsEnabled && syphonService.status.hasPrefix("Syphon ready") ? Color.green : Color.secondary)
                        .frame(width: 8, height: 8)
                    Text(syphonInputsEnabled ? syphonService.status : "Discovery is off")
                        .font(.callout)
                    Spacer()
                    Button("Refresh") { syphonService.refresh() }
                        .disabled(!syphonInputsEnabled)
                }
                settingsHint("Discovered servers appear in the + menu beside Clip Grid. Add each as a separate source, then assign it to a mask such as the cross or ceiling.")
            }
            settingsCard {
                Toggle("Publish the projector output over Syphon", isOn: $syphonOutputEnabled)
                TextField("Syphon output server name", text: $syphonOutputSourceName)
                    .textFieldStyle(.roundedBorder)
                    .disabled(!syphonOutputEnabled)
                HStack(spacing: 8) {
                    Circle()
                        .fill(syphonOutputService.status.contains("On Air") ? Color.green : (syphonOutputEnabled ? Color.orange : Color.secondary))
                        .frame(width: 7, height: 7)
                    Text(syphonOutputService.status)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                settingsHint("The output includes the final mapped canvas. ProMap publishes the currently selected open projector output and stops sending when no Syphon client is connected.")
            }
            settingsCard {
                Label("Built in for Intel and Apple Silicon", systemImage: "checkmark.circle")
                    .font(.headline)
                settingsHint("The Syphon framework is included in ProMap. No separate framework installation is needed. See the bundled dependency notes for its license and source version.")
            }
        }
    }

    private var networkPage: some View {
        settingsPage(
            title: "Network Control",
            detail: "Optional local HTTP and OSC controls for automation. Both listeners start off."
        ) {
            settingsCard {
                Toggle("Enable HTTP control API", isOn: $externalHTTPEnabled)
                Stepper("Port  ·  \(externalHTTPPort)", value: $externalHTTPPort, in: 1024...65535)
                    .disabled(!externalHTTPEnabled)
                Toggle("Allow access from this local network", isOn: $externalHTTPRemoteAccess)
                    .disabled(!externalHTTPEnabled)
                if externalHTTPRemoteAccess {
                    HStack(spacing: 7) {
                        TextField("Bearer token", text: $externalAPIToken)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(.caption, design: .monospaced))
                        Button("Generate") { externalAPIToken = UUID().uuidString.lowercased() }
                        Button("Copy") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(externalAPIToken, forType: .string)
                        }
                    }
                }
                settingsHint("The HTTP API binds to this Mac by default. Network access requires a bearer token. The connection is unencrypted; use a trusted private network.")
            }
            settingsCard {
                Toggle("Enable OSC input", isOn: $externalOSCEnabled)
                Stepper("Port  ·  \(externalOSCPort)", value: $externalOSCPort, in: 1024...65535)
                    .disabled(!externalOSCEnabled)
                settingsHint("OSC addresses: /promap/blackout, /promap/cue/next, /promap/cue/previous and /promap/scene/{UUID}/take.")
            }
            settingsCard {
                VStack(alignment: .leading, spacing: 10) {
                    Text("FreeShow and HTTP controls")
                        .font(.headline)
                    Text("In FreeShow, add the Send REST Command action, set Method to GET, and paste one of these URLs. Leave Content Type and Payload empty. When FreeShow and ProMap run on this Mac, use the shown 127.0.0.1 address; remote access is intended for clients that can send the configured bearer token.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    httpExampleRow("Blackout", path: "/v1/output/blackout/on")
                    httpExampleRow("Restore output", path: "/v1/output/blackout/off")
                    httpExampleRow("Output inactive / blackout", path: "/v1/output/active?value=false")
                    httpExampleRow("Output active / restore", path: "/v1/output/active?value=true")
                    httpExampleRow("Set output intensity to 0%", path: "/v1/output/intensity?value=0")
                    httpExampleRow("Set output intensity to 50%", path: "/v1/output/intensity?value=0.5")
                    httpExampleRow("Set output intensity to 100%", path: "/v1/output/intensity?value=1")
                    httpExampleRow("List scene and mask IDs", path: "/v1/status")
                    httpExampleRow("Black out the Church Cross mask", path: "/v1/surface/blackout?name=Church%20Cross&value=true")
                    httpExampleRow("Restore the Church Cross mask", path: "/v1/surface/blackout?name=Church%20Cross&value=false")
                    httpExampleRow("Set the Ceiling mask to 50%", path: "/v1/surface/intensity?name=Ceiling&value=0.5")
                    httpExampleRow("Turn the Ceiling mask off", path: "/v1/surface/active?name=Ceiling&value=false")
                    Text("Intensity accepts 0.0–1.0 and scales rendered pixels across open output windows. Master active/blackout controls do not open or close a window. Named mask commands require a unique exact surface name (case-insensitive); UUID routes remain available if names change. Surface blackout, visibility and intensity are separate controls.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func httpExampleRow(_ title: String, path: String) -> some View {
        let url = "http://127.0.0.1:\(externalHTTPPort)\(path)"
        return HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 11, weight: .medium))
                Text(url)
                    .font(.system(.caption2, design: .monospaced))
                    .textSelection(.enabled)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 4)
            Button("Copy") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(url, forType: .string)
            }
            .disabled(!externalHTTPEnabled)
        }
    }

    private var midiPage: some View {
        settingsPage(
            title: "MIDI Control",
            detail: "Learn MIDI buttons for blackout, cue stepping and scene recall."
        ) {
            settingsCard {
                Toggle("Enable MIDI input", isOn: $midiControlEnabled)
                HStack {
                    Text(midiControl.status)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Refresh Inputs") { midiControl.refreshInputs() }
                        .disabled(!midiControlEnabled)
                }
            }
            if midiControlEnabled {
                ForEach(midiControl.learnableActions) { target in
                    settingsCard {
                        HStack(spacing: 10) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(target.title)
                                Text(midiControl.assignment(for: target.id)?.messageName ?? "No MIDI control assigned")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button(midiControl.learningActionID == target.id ? "Listening…" : "Learn") {
                                if midiControl.learningActionID == target.id {
                                    midiControl.cancelLearning()
                                } else {
                                    midiControl.beginLearning(for: target.id)
                                }
                            }
                            if midiControl.assignment(for: target.id) != nil {
                                Button {
                                    midiControl.removeAssignment(for: target.id)
                                } label: {
                                    Image(systemName: "xmark.circle")
                                }
                                .buttonStyle(.plain)
                                .help("Remove MIDI assignment")
                            }
                        }
                    }
                }
                if !midiControl.learningStatus.isEmpty {
                    settingsHint(midiControl.learningStatus)
                }
                settingsHint("Choose Learn, then press a connected MIDI button. Assignments persist across launches.")
            }
        }
    }

    private var safetyPage: some View {
        settingsPage(
            title: "Live Safety",
            detail: "Keep projection operation predictable and protect calibrated mapping."
        ) {
            settingsCard {
                Toggle("Start the show in blackout", isOn: $launchInBlackout)
                settingsHint("Projector output windows stay closed at launch. When enabled, opening an output starts with the image blacked out until you clear blackout.")
            }
            settingsCard {
                Toggle("Prevent sleep while a projector output is open", isOn: $preventSleepWhileOutputOpen)
                settingsHint("ProMap asks macOS to keep the display and system awake while at least one physical or virtual output window is open.")
            }
            settingsCard {
                Toggle("Lock all mapping geometry", isOn: $mappingLockedForLive)
                settingsHint("Disables corner, mesh, source-mask, output-mask and surface assignment edits while leaving content controls available.")
            }
            settingsCard {
                Toggle("Operator mode", isOn: $operatorModeEnabled)
                settingsHint("Opens directly to Scenes and hides the Live Editor tab. Turn this off to return to mapping and media setup.")
            }
            settingsCard {
                Label("Emergency blackout", systemImage: "lightbulb.slash.fill")
                    .font(.headline)
                settingsHint("Press ⌥⌘B in the main ProMap window to toggle master blackout at any time.")
            }
        }
    }

    private func settingsPage<Content: View>(
        title: String,
        detail: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.system(size: 22, weight: .semibold, design: .rounded))
                    Text(detail)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .padding(.bottom, 3)
                content()
            }
            .padding(22)
            .frame(maxWidth: 580, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }

    private func settingsCard<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 11, content: content)
            .padding(15)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: .controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private func settingsHint(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}
