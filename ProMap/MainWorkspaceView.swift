import AppKit
import MetalKit
import SwiftUI
import UniformTypeIdentifiers

private struct ScreenChoice: Identifiable {
    let id: String
    let screen: NSScreen
}

struct MainWorkspaceView: View {
    @StateObject private var library: MediaLibrary
    @StateObject private var session: RenderSession
    @StateObject private var renderer: MetalRenderer
    @StateObject private var output: ProjectorOutputController
    @State private var selectedScreenID: String?

    init() {
        let mediaLibrary = MediaLibrary()
        let renderSession = RenderSession()
        let metalRenderer = MetalRenderer()
        _library = StateObject(wrappedValue: mediaLibrary)
        _session = StateObject(wrappedValue: renderSession)
        _renderer = StateObject(wrappedValue: metalRenderer)
        _output = StateObject(wrappedValue: ProjectorOutputController(
            renderer: metalRenderer,
            session: renderSession
        ))
    }

    private var screens: [ScreenChoice] {
        NSScreen.screens.map { screen in
            let key = NSDeviceDescriptionKey("NSScreenNumber")
            let number = (screen.deviceDescription[key] as? NSNumber)?.stringValue
            return ScreenChoice(id: number ?? screen.localizedName, screen: screen)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
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
            footer
        }
        .frame(minWidth: 1120, minHeight: 720)
        .background(Palette.background)
        .foregroundColor(Palette.primaryText)
        .preferredColorScheme(.dark)
        .onAppear {
            if selectedScreenID == nil {
                selectedScreenID = screens.dropFirst().first?.id ?? screens.first?.id
            }
        }
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

            Menu {
                ForEach(screens) { choice in
                    Button(choice.screen.localizedName) {
                        selectedScreenID = choice.id
                        output.open(on: choice.screen)
                    }
                }
            } label: {
                Label(output.activeScreenName ?? selectedScreenName, systemImage: "display")
                    .lineLimit(1)
                    .frame(maxWidth: 180)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Palette.control)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }
            .menuStyle(.borderlessButton)
            .disabled(screens.isEmpty)

            Button {
                if let choice = screens.first(where: { $0.id == selectedScreenID }) ?? screens.first {
                    output.open(on: choice.screen)
                }
            } label: {
                Label(output.activeScreenName == nil ? "Open Output" : "Reopen Output", systemImage: "arrow.up.right.square")
                    .font(.system(size: 12, weight: .semibold))
                    .padding(.horizontal, 13)
                    .padding(.vertical, 9)
                    .background(Palette.accent)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(.plain)
            .disabled(screens.isEmpty || !renderer.renderingAvailable)

            if output.activeScreenName != nil {
                Button(action: output.close) {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .bold))
                        .frame(width: 32, height: 32)
                        .background(Palette.control)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
                .help("Close fullscreen output")
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 13)
        .background(Palette.panel)
        .overlay(alignment: .bottom) { dividerLine }
    }

    private var mediaPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                panelTitle("MEDIA", detail: "\(library.sources.count) SOURCES")
                Spacer()
                Button(action: importMedia) {
                    Image(systemName: "plus")
                        .font(.system(size: 12, weight: .bold))
                        .frame(width: 29, height: 29)
                        .background(Palette.control)
                        .clipShape(RoundedRectangle(cornerRadius: 7))
                }
                .buttonStyle(.plain)
                .help("Import images or video files")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 15)

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
                    LazyVStack(spacing: 8) {
                        ForEach(library.sources) { source in
                            MediaSourceRow(source: source) {
                                session.addLayer(source: source)
                            } onRemove: {
                                library.remove(source)
                            }
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
                panelTitle("COMPOSITION", detail: "1920 × 1080 · 60 FPS TARGET")
                Spacer()
                Text(session.layers.isEmpty ? "EMPTY" : "\(session.layers.count) LAYERS")
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .foregroundColor(Palette.secondaryText)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 6)
                    .background(Palette.control)
                    .clipShape(Capsule())
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 15)

            ZStack {
                Palette.background
                MetalCanvas(renderer: renderer, session: session)
                    .aspectRatio(16.0 / 9.0, contentMode: .fit)
                    .background(Color.black)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay {
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Palette.border, lineWidth: 1)
                    }

                if session.layers.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "play.rectangle")
                            .font(.system(size: 28, weight: .ultraLight))
                        Text("Add a source to the layer stack")
                            .font(.system(size: 12, weight: .medium))
                    }
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
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.horizontal, 30)
            .padding(.vertical, 16)

            HStack(spacing: 8) {
                Image(systemName: "info.circle")
                Text("Phase 1 draws a full-frame composition. Surface mapping and masks are planned for Phase 2.")
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

    private var layersPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                panelTitle("LAYERS", detail: "TOP LAYER IS FRONT")
                Spacer()
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

            if session.layers.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "square.3.layers.3d")
                        .font(.system(size: 24, weight: .light))
                        .foregroundColor(Palette.secondaryText)
                    Text("No layers yet")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(Palette.secondaryText)
                    Text("Add media from the library")
                        .font(.system(size: 10))
                        .foregroundColor(Palette.tertiaryText)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 9) {
                        ForEach(Array(session.layers.enumerated().reversed()), id: \.element.id) { index, layer in
                            LayerRow(
                                layer: layer,
                                source: layer.source,
                                number: session.layers.count - index,
                                onToggle: { session.setEnabled(!$0, for: layer.id) },
                                onOpacity: { session.setOpacity($0, for: layer.id) },
                                onRemove: { session.removeLayer(layer) }
                            )
                        }
                    }
                    .padding(12)
                }
            }

            Spacer(minLength: 0)

            VStack(alignment: .leading, spacing: 8) {
                Text("MASTER OUTPUT")
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .tracking(0.8)
                    .foregroundColor(Palette.secondaryText)
                HStack {
                    Circle().fill(output.activeScreenName == nil ? Palette.tertiaryText : Palette.green).frame(width: 7, height: 7)
                    Text(output.activeScreenName ?? "No fullscreen output")
                        .font(.system(size: 11, weight: .medium))
                        .lineLimit(1)
                    Spacer()
                    Text(output.activeScreenName == nil ? "CLOSED" : "LIVE")
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .foregroundColor(output.activeScreenName == nil ? Palette.secondaryText : Palette.green)
                }
            }
            .padding(14)
            .background(Palette.raised)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .padding(12)
        }
        .background(Palette.panel)
    }

    private var footer: some View {
        HStack(spacing: 18) {
            Label("GPU", systemImage: "gpu.fill")
                .foregroundColor(Palette.secondaryText)
            Text(renderer.gpuName)
                .foregroundColor(renderer.renderingAvailable ? Palette.primaryText : Palette.orange)
                .lineLimit(1)
            Spacer()
            Text("OUTPUT TARGET")
                .foregroundColor(Palette.secondaryText)
            Text("60 FPS")
                .foregroundColor(Palette.primaryText)
            Circle().fill(Palette.border).frame(width: 3, height: 3)
            Text("\(screens.count) DISPLAY\(screens.count == 1 ? "" : "S")")
                .foregroundColor(Palette.secondaryText)
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
}

private struct MediaSourceRow: View {
    @ObservedObject var source: MediaSource
    let onAdd: () -> Void
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 9) {
            ZStack {
                RoundedRectangle(cornerRadius: 6).fill(Palette.background)
                Image(systemName: source.kind == .video ? "film" : "photo")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(Palette.accentSoft)
            }
            .frame(width: 34, height: 34)

            VStack(alignment: .leading, spacing: 3) {
                Text(source.title)
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
                    .help(source.url.lastPathComponent)
                Text(source.fileExtension)
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .foregroundColor(Palette.secondaryText)
            }

            Spacer(minLength: 2)

            if source.kind == .video {
                Button(action: source.togglePlayback) {
                    Image(systemName: source.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 10, weight: .bold))
                        .frame(width: 25, height: 25)
                        .background(Palette.background)
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
                .help(source.isPlaying ? "Pause video" : "Play video")
            }

            Button(action: onAdd) {
                Image(systemName: "plus")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(Palette.accentSoft)
                    .frame(width: 25, height: 25)
                    .background(Palette.background)
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
            .help("Add as a new layer")
            .contextMenu {
                Button("Add Layer", action: onAdd)
                Button("Remove from Library", role: .destructive, action: onRemove)
            }
        }
        .padding(9)
        .background(Palette.raised)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

private struct LayerRow: View {
    let layer: RenderLayer
    @ObservedObject var source: MediaSource
    let number: Int
    let onToggle: (Bool) -> Void
    let onOpacity: (Double) -> Void
    let onRemove: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 9) {
                Text(String(format: "%02d", number))
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .foregroundColor(Palette.tertiaryText)
                    .frame(width: 20)

                Image(systemName: layer.source.kind == .video ? "film" : "photo")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(Palette.accentSoft)

                Text(layer.source.title)
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)

                Spacer(minLength: 2)

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

                Button(action: onRemove) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundColor(Palette.secondaryText)
                }
                .buttonStyle(.plain)
                .help("Remove layer")
            }

            HStack(spacing: 8) {
                Text("OPACITY")
                    .font(.system(size: 8, weight: .semibold, design: .monospaced))
                    .foregroundColor(Palette.secondaryText)
                Slider(value: Binding(get: { layer.opacity }, set: onOpacity), in: 0...1)
                    .controlSize(.mini)
                    .tint(Palette.accent)
                Text("\(Int(layer.opacity * 100))%")
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .foregroundColor(Palette.secondaryText)
                    .frame(width: 31, alignment: .trailing)
            }
        }
        .padding(11)
        .background(layer.isEnabled ? Palette.raised : Palette.raised.opacity(0.6))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .opacity(layer.isEnabled ? 1 : 0.65)
    }
}

private struct MetalCanvas: NSViewRepresentable {
    let renderer: MetalRenderer
    let session: RenderSession

    func makeNSView(context: Context) -> MTKView {
        renderer.makeView(session: session)
    }

    func updateNSView(_ view: MTKView, context: Context) {}
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
