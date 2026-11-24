import Combine
import CoreMIDI
import Foundation

struct MIDIAssignmentTarget: Identifiable, Equatable {
    let id: String
    let title: String
}

struct MIDIAssignment: Codable, Identifiable, Equatable {
    var id: String { actionID }
    let actionID: String
    let messageKey: String
    let messageName: String
}

final class MIDIControlManager: ObservableObject {
    static let shared = MIDIControlManager()

    @Published private(set) var inputCount = 0
    @Published private(set) var status = "Disabled"
    @Published private(set) var assignments: [MIDIAssignment] = []
    @Published private(set) var learningActionID: String?
    @Published private(set) var learningStatus = ""
    @Published private(set) var learnableActions: [MIDIAssignmentTarget] = [
        MIDIAssignmentTarget(id: "blackout.toggle", title: "Toggle blackout"),
        MIDIAssignmentTarget(id: "cue.next", title: "Next cue"),
        MIDIAssignmentTarget(id: "cue.previous", title: "Previous cue")
    ]

    let commands = PassthroughSubject<ExternalControlCommand, Never>()

    private var client = MIDIClientRef()
    private var inputPort = MIDIPortRef()
    private var connectedSources = Set<MIDIEndpointRef>()
    private var activeControllers: [String: Bool] = [:]
    private let assignmentsKey = "midiControlAssignments"

    private init() {
        loadAssignments()
    }

    func configure(enabled: Bool) {
        guard enabled else {
            stop()
            return
        }
        guard client == 0 else {
            refreshInputs()
            return
        }

        let clientStatus = MIDIClientCreateWithBlock("ProMap MIDI" as CFString, &client) { [weak self] _ in
            DispatchQueue.main.async { self?.refreshInputs() }
        }
        guard clientStatus == noErr else {
            status = "MIDI unavailable (\(clientStatus))"
            client = 0
            return
        }

        let portStatus = MIDIInputPortCreateWithBlock(client, "ProMap MIDI Input" as CFString, &inputPort) { [weak self] packetList, _ in
            self?.read(packetList)
        }
        guard portStatus == noErr else {
            status = "MIDI input unavailable (\(portStatus))"
            MIDIClientDispose(client)
            client = 0
            inputPort = 0
            return
        }
        refreshInputs()
    }

    func refreshInputs() {
        guard client != 0, inputPort != 0 else {
            DispatchQueue.main.async {
                self.inputCount = 0
                self.status = "Disabled"
            }
            return
        }

        let sourceCount = MIDIGetNumberOfSources()
        var currentSources = Set<MIDIEndpointRef>()
        if sourceCount > 0 {
            for index in 0..<sourceCount {
                let source = MIDIGetSource(index)
                guard source != 0 else { continue }
                currentSources.insert(source)
                if !connectedSources.contains(source) {
                    let result = MIDIPortConnectSource(inputPort, source, nil)
                    if result == noErr { connectedSources.insert(source) }
                }
            }
        }
        for source in connectedSources.subtracting(currentSources) {
            MIDIPortDisconnectSource(inputPort, source)
            connectedSources.remove(source)
        }

        DispatchQueue.main.async {
            self.inputCount = currentSources.count
            self.status = currentSources.isEmpty
                ? "Enabled · no MIDI inputs found"
                : "Ready · listening to \(currentSources.count) input\(currentSources.count == 1 ? "" : "s")"
        }
    }

    func stop() {
        learningActionID = nil
        learningStatus = ""
        activeControllers.removeAll()
        for source in connectedSources { MIDIPortDisconnectSource(inputPort, source) }
        connectedSources.removeAll()
        if inputPort != 0 { MIDIPortDispose(inputPort) }
        if client != 0 { MIDIClientDispose(client) }
        inputPort = 0
        client = 0
        inputCount = 0
        status = "Disabled"
    }

    func updateScenes(_ scenes: [ScenePreset]) {
        learnableActions = [
            MIDIAssignmentTarget(id: "blackout.toggle", title: "Toggle blackout"),
            MIDIAssignmentTarget(id: "cue.next", title: "Next cue"),
            MIDIAssignmentTarget(id: "cue.previous", title: "Previous cue")
        ] + scenes.map { MIDIAssignmentTarget(id: "scene.\($0.id.uuidString)", title: "Take · \($0.name)") }
    }

    func assignment(for actionID: String) -> MIDIAssignment? {
        assignments.first(where: { $0.actionID == actionID })
    }

    func beginLearning(for actionID: String) {
        guard learnableActions.contains(where: { $0.id == actionID }) else { return }
        learningActionID = actionID
        learningStatus = "Press a MIDI note or button…"
    }

    func cancelLearning() {
        learningActionID = nil
        learningStatus = "Learning cancelled"
    }

    func removeAssignment(for actionID: String) {
        assignments.removeAll(where: { $0.actionID == actionID })
        saveAssignments()
    }

    private func read(_ packetList: UnsafePointer<MIDIPacketList>) {
        let packetCount = Int(packetList.pointee.numPackets)
        guard packetCount > 0,
              let packetOffset = MemoryLayout<MIDIPacketList>.offset(of: \.packet) else { return }
        let firstPacket = UnsafeRawPointer(packetList)
            .advanced(by: packetOffset)
            .assumingMemoryBound(to: MIDIPacket.self)
        var packetPointer = UnsafeMutablePointer(mutating: firstPacket)
        for _ in 0..<packetCount {
            let packet = packetPointer.pointee
            let bytes = withUnsafeBytes(of: packet.data) { Array($0.prefix(Int(packet.length))) }
            if bytes.count >= 3 {
                receive(statusByte: bytes[0], data1: bytes[1], data2: bytes[2])
            }
            packetPointer = MIDIPacketNext(packetPointer)
        }
    }

    private func receive(statusByte: UInt8, data1: UInt8, data2: UInt8) {
        let messageType = statusByte & 0xF0
        guard messageType == 0x90 || messageType == 0xB0 else { return }
        let key = String(format: "%02X:%03d", statusByte, data1)
        let channel = Int(statusByte & 0x0F) + 1
        let messageName = String(format: "Ch %d · %@ %d", channel, messageType == 0x90 ? "Note" : "CC", data1)

        DispatchQueue.main.async {
            if let actionID = self.learningActionID {
                self.assignments.removeAll { $0.actionID == actionID || $0.messageKey == key }
                self.assignments.append(MIDIAssignment(actionID: actionID, messageKey: key, messageName: messageName))
                self.assignments.sort { $0.actionID < $1.actionID }
                self.learningActionID = nil
                self.learningStatus = "Learned \(messageName)"
                self.saveAssignments()
                return
            }

            let shouldTrigger: Bool
            if messageType == 0x90 {
                shouldTrigger = data2 > 0
            } else {
                let isActive = data2 >= 64
                let wasActive = self.activeControllers[key] ?? false
                self.activeControllers[key] = isActive
                shouldTrigger = isActive && !wasActive
            }
            guard shouldTrigger,
                  let assignment = self.assignments.first(where: { $0.messageKey == key }) else { return }
            self.sendCommand(for: assignment.actionID)
        }
    }

    private func sendCommand(for actionID: String) {
        switch actionID {
        case "blackout.toggle": commands.send(.toggleBlackout)
        case "cue.next": commands.send(.stepCue(1))
        case "cue.previous": commands.send(.stepCue(-1))
        default:
            let scenePrefix = "scene."
            if actionID.hasPrefix(scenePrefix),
               let sceneID = UUID(uuidString: String(actionID.dropFirst(scenePrefix.count))) {
                commands.send(.takeScene(sceneID))
            }
        }
    }

    private func loadAssignments() {
        guard let data = UserDefaults.standard.data(forKey: assignmentsKey),
              let decoded = try? JSONDecoder().decode([MIDIAssignment].self, from: data) else { return }
        assignments = decoded
    }

    private func saveAssignments() {
        guard let data = try? JSONEncoder().encode(assignments) else { return }
        UserDefaults.standard.set(data, forKey: assignmentsKey)
    }
}
