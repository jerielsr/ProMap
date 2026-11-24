import Combine
import Foundation
import Network

enum ExternalControlCommand {
    case setBlackout(Bool)
    case setOutputActive(Bool)
    case setOutputIntensity(Double)
    case setSurfaceActive(UUID, Bool)
    case setSurfaceBlackout(UUID, Bool)
    case setSurfaceIntensity(UUID, Double)
    case setSurfaceActiveNamed(String, Bool)
    case setSurfaceBlackoutNamed(String, Bool)
    case setSurfaceIntensityNamed(String, Double)
    case toggleBlackout
    case stepCue(Int)
    case takeScene(UUID)
    case takeSceneNamed(String)
    case setCorner(surfaceID: UUID, cornerIndex: Int, point: NormalizedPoint)
}

final class ExternalControlManager: ObservableObject {
    @Published private(set) var httpStatus = "Disabled"
    @Published private(set) var oscStatus = "Disabled"

    let commands = PassthroughSubject<ExternalControlCommand, Never>()
    var statusProvider: (() -> Data)?

    private let queue = DispatchQueue(label: "ProMap.external-control", qos: .userInitiated)
    private let httpAccessLock = NSLock()
    private var httpRemoteAccessEnabled = false
    private var httpAccessToken = ""
    private var httpListener: NWListener?
    private var oscListener: NWListener?
    private var httpConfiguration: HTTPConfiguration?
    private var oscConfiguration: OSCConfiguration?

    private struct HTTPConfiguration: Equatable {
        let port: Int
        let remoteAccess: Bool
    }

    private struct OSCConfiguration: Equatable {
        let port: Int
    }

    private struct HTTPRequest {
        let method: String
        let path: String
        let headers: [String: String]
        let body: Data
    }

    private struct CornerRequest: Decodable {
        let x: Double
        let y: Double
    }

    private struct BooleanRequest: Decodable {
        let active: Bool?
        let value: Bool?
        let blackout: Bool?
        let name: String?
    }

    private struct NumberRequest: Decodable {
        let value: Double?
        let intensity: Double?
        let brightness: Double?
        let name: String?
    }

    private struct SceneNameRequest: Decodable {
        let name: String
    }

    private static func queryValues(in requestTarget: String) -> [String: String] {
        guard let components = URLComponents(string: "http://localhost\(requestTarget)") else { return [:] }
        return Dictionary(components.queryItems?.compactMap { item in
            item.value.map { (item.name.lowercased(), $0) }
        } ?? [], uniquingKeysWith: { _, latest in latest })
    }

    private static func booleanValue(_ value: String?) -> Bool? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() else { return nil }
        switch value {
        case "true", "1", "on", "yes": return true
        case "false", "0", "off", "no": return false
        default: return nil
        }
    }

    private func allowedCORSOrigin(_ origin: String?, request: HTTPRequest) -> String? {
        guard let origin else { return nil }
        if origin == "null" { return origin }
        guard let components = URLComponents(string: origin),
              components.scheme?.lowercased() == "http",
              let originHost = components.host?.lowercased() else { return nil }
        if ["localhost", "127.0.0.1", "::1"].contains(originHost) { return origin }

        // Permit the remote calibration page when it calls back to the exact host and port serving it.
        guard let requestHost = request.headers["host"],
              let requestComponents = URLComponents(string: "http://\(requestHost)"),
              requestComponents.host?.lowercased() == originHost,
              requestComponents.port == components.port else { return nil }
        return origin
    }

    func commandForGET(path: String, query: [String: String]) -> ExternalControlCommand? {
        switch path {
        case "/v1/blackout/on": return .setBlackout(true)
        case "/v1/blackout/off": return .setBlackout(false)
        case "/v1/blackout/toggle": return .toggleBlackout
        case "/v1/output/blackout/on": return .setBlackout(true)
        case "/v1/output/blackout/off": return .setBlackout(false)
        case "/v1/output/blackout/toggle": return .toggleBlackout
        case "/v1/output/blackout":
            return Self.booleanValue(query["value"] ?? query["blackout"]).map(ExternalControlCommand.setBlackout)
        case "/v1/output/active":
            return Self.booleanValue(query["active"] ?? query["value"]).map(ExternalControlCommand.setOutputActive)
        case "/v1/output/intensity", "/v1/output/brightness":
            guard let value = Double(query["value"] ?? query["intensity"] ?? query["brightness"] ?? ""),
                  value.isFinite, (0...1).contains(value) else { return nil }
            return .setOutputIntensity(value)
        case "/v1/surface/active":
            guard let name = query["name"], !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  let active = Self.booleanValue(query["active"] ?? query["value"]) else { return nil }
            return .setSurfaceActiveNamed(name, active)
        case "/v1/surface/blackout":
            guard let name = query["name"], !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  let blackout = Self.booleanValue(query["blackout"] ?? query["value"]) else { return nil }
            return .setSurfaceBlackoutNamed(name, blackout)
        case "/v1/surface/intensity", "/v1/surface/brightness":
            guard let name = query["name"], !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  let value = Double(query["value"] ?? query["intensity"] ?? query["brightness"] ?? ""),
                  value.isFinite, (0...1).contains(value) else { return nil }
            return .setSurfaceIntensityNamed(name, value)
        case "/v1/cue/next": return .stepCue(1)
        case "/v1/cue/previous": return .stepCue(-1)
        case "/v1/scene/take":
            guard let name = query["name"], !name.isEmpty else { return nil }
            return .takeSceneNamed(name)
        default:
            let scenePrefix = "/v1/scene/"
            if path.hasPrefix(scenePrefix), path.hasSuffix("/take") {
                let idText = String(path.dropFirst(scenePrefix.count).dropLast("/take".count))
                return UUID(uuidString: idText).map(ExternalControlCommand.takeScene)
            }
            let surfacePrefix = "/v1/surface/"
            let components = path.split(separator: "/")
            guard path.hasPrefix(surfacePrefix), components.count == 4,
                  let surfaceID = UUID(uuidString: String(components[2])) else { return nil }
            switch components[3] {
            case "active":
                return Self.booleanValue(query["active"] ?? query["value"]).map { .setSurfaceActive(surfaceID, $0) }
            case "blackout":
                return Self.booleanValue(query["blackout"] ?? query["value"]).map { .setSurfaceBlackout(surfaceID, $0) }
            case "intensity", "brightness":
                guard let value = Double(query["value"] ?? query["intensity"] ?? query["brightness"] ?? ""),
                      value.isFinite, (0...1).contains(value) else { return nil }
                return .setSurfaceIntensity(surfaceID, value)
            default:
                return nil
            }
        }
    }

    private static let calibrationHTML = #"""
    <!doctype html>
    <html lang="en">
    <head>
      <meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
      <title>ProMap Remote Calibration</title>
      <style>
        :root{color-scheme:dark;font:16px -apple-system,BlinkMacSystemFont,sans-serif;background:#11151c;color:#edf0f7}
        body{margin:0;padding:18px;max-width:620px;margin-inline:auto}h1{font-size:20px;margin:0 0 6px}
        p{color:#9aa4b5;font-size:13px}.card{background:#1b2230;border:1px solid #30394a;border-radius:12px;padding:14px;margin:12px 0}
        label{display:block;color:#aeb8c8;font-size:12px;margin:10px 0 5px}select,input,button{font:inherit;color:inherit;background:#252e3e;border:1px solid #414d61;border-radius:7px;padding:10px;width:100%;box-sizing:border-box}
        .row{display:grid;grid-template-columns:1fr 1fr;gap:10px}.corners{display:grid;grid-template-columns:repeat(4,1fr);gap:7px;margin:10px 0}
        .corners button,.actions button{width:auto}.corners button.active{background:#5365e8;border-color:#8994ff}.actions{display:flex;gap:8px;flex-wrap:wrap}.actions button{flex:1;min-width:120px}
        button{cursor:pointer}#message{min-height:20px;color:#93d6b3;font-size:12px}.small{font-size:11px}
      </style>
    </head>
    <body>
      <h1>ProMap Remote Calibration</h1>
      <p>Select a surface and corner, enter its output position, then save. Coordinates use percentages of the output canvas.</p>
      <section class="card">
        <label for="surface">Surface</label><select id="surface"></select>
        <label>Corner</label><div class="corners" id="corners"></div>
        <div class="row"><div><label for="x">X position (%)</label><input id="x" type="number" min="0" max="100" step="0.1"></div>
        <div><label for="y">Y position (%)</label><input id="y" type="number" min="0" max="100" step="0.1"></div></div>
        <div class="actions"><button id="save">Save corner</button><button id="refresh">Refresh</button></div>
      </section>
      <section class="card"><div class="actions"><button id="blackout">Toggle blackout</button><select id="scene"></select><button id="take">TAKE scene</button></div><div id="message"></div></section>
      <script>
        const token=sessionStorage.getItem('promapToken')||new URLSearchParams(location.search).get('token')||'';
        if(token)sessionStorage.setItem('promapToken',token);
        const auth={'Authorization':'Bearer '+token,'Content-Type':'application/json'};
        let state=null,cornerIndex=0;
        const surfaceSelect=document.querySelector('#surface'),sceneSelect=document.querySelector('#scene'),message=document.querySelector('#message');
        const names=['Top left','Top right','Bottom right','Bottom left'];
        function selectedSurface(){return state?.surfaces?.find(s=>s.id===surfaceSelect.value)}
        function showCorner(){const s=selectedSurface(),p=s?.corners?.[cornerIndex];if(!p)return;document.querySelector('#x').value=(p[0]*100).toFixed(1);document.querySelector('#y').value=(p[1]*100).toFixed(1);document.querySelector('#save').disabled=!!s.locked;document.querySelectorAll('.corners button').forEach((b,i)=>b.classList.toggle('active',i===cornerIndex))}
        async function refresh(){try{const r=await fetch('/v1/status',{headers:auth});if(!r.ok)throw Error('Status request failed ('+r.status+')');state=await r.json();const old=surfaceSelect.value;surfaceSelect.replaceChildren(...state.surfaces.map(s=>new Option(s.name+(s.locked?' · locked':''),s.id)));if(state.surfaces.some(s=>s.id===old))surfaceSelect.value=old;document.querySelector('#corners').replaceChildren(...names.map((n,i)=>{const b=document.createElement('button');b.textContent=n;b.onclick=()=>{cornerIndex=i;showCorner()};return b}));sceneSelect.replaceChildren(...state.scenes.map(s=>new Option(s.name,s.id)));document.querySelector('#blackout').textContent=state.blackout?'Clear blackout':'Blackout';if(!['x','y'].includes(document.activeElement.id))showCorner();message.textContent='Connected · '+(state.output||'output closed')}catch(e){message.textContent=e.message}}
        async function post(path,body={}){const r=await fetch(path,{method:'POST',headers:auth,body:JSON.stringify(body)});if(!r.ok)throw Error('Request failed ('+r.status+')')}
        surfaceSelect.onchange=showCorner;document.querySelector('#refresh').onclick=refresh;
        document.querySelector('#save').onclick=async()=>{const s=selectedSurface();if(!s)return;const x=Number(document.querySelector('#x').value)/100,y=Number(document.querySelector('#y').value)/100;try{await post('/v1/surface/'+s.id+'/corner/'+cornerIndex,{x,y});await refresh();const p=selectedSurface()?.corners?.[cornerIndex];message.textContent=p&&Math.abs(p[0]-x)<0.0001&&Math.abs(p[1]-y)<0.0001?'Corner updated':'Edit rejected; unlock the surface or use a valid convex quad'}catch(e){message.textContent=e.message}};
        document.querySelector('#blackout').onclick=async()=>{try{await post('/v1/blackout/toggle');await refresh()}catch(e){message.textContent=e.message}};
        document.querySelector('#take').onclick=async()=>{if(!sceneSelect.value)return;try{await post('/v1/scene/'+sceneSelect.value+'/take');message.textContent='Scene taken';await refresh()}catch(e){message.textContent=e.message}};
        refresh();setInterval(refresh,3000);
      </script>
    </body></html>
    """#

    func configureHTTP(enabled: Bool, port: Int, remoteAccess: Bool = false, token: String = "") {
        httpAccessLock.lock()
        httpRemoteAccessEnabled = remoteAccess
        httpAccessToken = token
        httpAccessLock.unlock()
        guard enabled else {
            guard httpConfiguration != nil || httpListener != nil else { return }
            httpConfiguration = nil
            httpListener?.stateUpdateHandler = nil
            httpListener?.cancel()
            httpListener = nil
            setHTTPStatus("Disabled")
            return
        }
        let configuration = HTTPConfiguration(port: port, remoteAccess: remoteAccess)
        guard configuration != httpConfiguration else { return }
        httpConfiguration = configuration
        httpListener?.stateUpdateHandler = nil
        httpListener?.cancel()
        httpListener = nil
        guard let listener = makeListener(transport: .tcp, port: port, remoteAccess: remoteAccess) else {
            setHTTPStatus("Invalid port")
            return
        }
        listener.stateUpdateHandler = { [weak self] state in
            guard let self, self.httpListener === listener else { return }
            self.updateStatus(state, label: "HTTP", isHTTP: true)
        }
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { connection.cancel(); return }
            connection.start(queue: self.queue)
            self.receiveHTTPRequest(on: connection, accumulated: Data())
        }
        httpListener = listener
        listener.start(queue: queue)
    }

    func configureOSC(enabled: Bool, port: Int) {
        guard enabled else {
            guard oscConfiguration != nil || oscListener != nil else { return }
            oscConfiguration = nil
            oscListener?.stateUpdateHandler = nil
            oscListener?.cancel()
            oscListener = nil
            setOSCStatus("Disabled")
            return
        }
        let configuration = OSCConfiguration(port: port)
        guard configuration != oscConfiguration else { return }
        oscConfiguration = configuration
        oscListener?.stateUpdateHandler = nil
        oscListener?.cancel()
        oscListener = nil
        guard let listener = makeListener(transport: .udp, port: port, remoteAccess: false) else {
            setOSCStatus("Invalid port")
            return
        }
        listener.stateUpdateHandler = { [weak self] state in
            guard let self, self.oscListener === listener else { return }
            self.updateStatus(state, label: "OSC", isHTTP: false)
        }
        listener.newConnectionHandler = { [weak self] connection in
            connection.start(queue: self?.queue ?? .global())
            self?.receiveOSC(on: connection)
        }
        oscListener = listener
        listener.start(queue: queue)
    }

    func stop() {
        httpConfiguration = nil
        oscConfiguration = nil
        httpListener?.stateUpdateHandler = nil
        oscListener?.stateUpdateHandler = nil
        httpListener?.cancel()
        oscListener?.cancel()
        httpListener = nil
        oscListener = nil
        setHTTPStatus("Disabled")
        setOSCStatus("Disabled")
    }

    private func makeListener(transport: NWParameters, port: Int, remoteAccess: Bool) -> NWListener? {
        guard (1...65535).contains(port), let nwPort = NWEndpoint.Port(rawValue: UInt16(port)) else { return nil }
        transport.requiredLocalEndpoint = .hostPort(host: .ipv4(remoteAccess ? .any : .loopback), port: nwPort)
        return try? NWListener(using: transport)
    }

    private func receiveHTTPRequest(on connection: NWConnection, accumulated: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] content, _, isComplete, error in
            guard let self else { connection.cancel(); return }
            var request = accumulated
            if let content { request.append(content) }
            let boundary = request.range(of: Data("\r\n\r\n".utf8))
            if let boundary {
                let headerData = request.prefix(boundary.lowerBound)
                let header = String(data: headerData, encoding: .utf8) ?? ""
                let contentLength = header.components(separatedBy: "\r\n").dropFirst()
                    .compactMap { line -> Int? in
                        let parts = line.split(separator: ":", maxSplits: 1)
                        guard parts.count == 2, parts[0].lowercased() == "content-length" else { return nil }
                        return Int(parts[1].trimmingCharacters(in: .whitespaces))
                    }
                    .first ?? 0
                let expectedLength = boundary.upperBound + max(contentLength, 0)
                if request.count < expectedLength, !isComplete, error == nil, request.count < 16_384 {
                    self.receiveHTTPRequest(on: connection, accumulated: request)
                    return
                }
                self.handleHTTPRequest(request, respondingOn: connection)
            } else if !isComplete, error == nil, request.count < 16_384 {
                self.receiveHTTPRequest(on: connection, accumulated: request)
            } else {
                self.sendHTTP(status: "400 Bad Request", body: "{\"error\":\"invalid request\"}", on: connection)
            }
        }
    }

    private func parseHTTPRequest(_ data: Data) -> HTTPRequest? {
        guard let boundary = data.range(of: Data("\r\n\r\n".utf8)),
              let header = String(data: data.prefix(boundary.lowerBound), encoding: .utf8),
              let requestLine = header.components(separatedBy: "\r\n").first else { return nil }
        let fields = requestLine.split(separator: " ")
        guard fields.count >= 2 else {
            return nil
        }
        var headers: [String: String] = [:]
        for line in header.components(separatedBy: "\r\n").dropFirst() {
            let parts = line.split(separator: ":", maxSplits: 1)
            if parts.count == 2 {
                headers[parts[0].trimmingCharacters(in: .whitespaces).lowercased()] = parts[1].trimmingCharacters(in: .whitespaces)
            }
        }
        let body = Data(data[boundary.upperBound...])
        return HTTPRequest(method: String(fields[0]).uppercased(), path: String(fields[1]), headers: headers, body: body)
    }

    private func handleHTTPRequest(_ data: Data, respondingOn connection: NWConnection) {
        guard let request = parseHTTPRequest(data) else {
            sendHTTP(status: "400 Bad Request", body: "{\"error\":\"invalid request\"}", on: connection)
            return
        }
        let method = request.method
        let fullPath = request.path
        let path = fullPath.split(separator: "?").first.map(String.init) ?? "/"
        let corsOrigin = allowedCORSOrigin(request.headers["origin"], request: request)
        if request.headers["origin"] != nil, corsOrigin == nil {
            sendHTTP(status: "403 Forbidden", body: "{\"error\":\"origin not allowed\"}", on: connection)
            return
        }

        if method == "OPTIONS" {
            guard let corsOrigin else {
                sendHTTP(status: "403 Forbidden", body: "{\"error\":\"origin not allowed\"}", on: connection)
                return
            }
            sendHTTP(status: "204 No Content", body: Data(), contentType: "application/json", on: connection, corsOrigin: corsOrigin)
            return
        }

        httpAccessLock.lock()
        let requiresToken = httpRemoteAccessEnabled
        let accessToken = httpAccessToken
        httpAccessLock.unlock()
        if requiresToken {
            let suppliedToken: String?
            if path == "/calibrate" {
                suppliedToken = URLComponents(string: "http://localhost\(fullPath)")?
                    .queryItems?.first(where: { $0.name == "token" })?.value
            } else {
                suppliedToken = request.headers["authorization"]?.hasPrefix("Bearer ") == true
                    ? String(request.headers["authorization"]!.dropFirst("Bearer ".count))
                    : nil
            }
            guard !accessToken.isEmpty, suppliedToken == accessToken else {
                sendHTTP(status: "401 Unauthorized", body: "{\"error\":\"valid bearer token required\"}", on: connection, corsOrigin: corsOrigin)
                return
            }
        }

        if method == "GET", path == "/calibrate" {
            sendHTTP(status: "200 OK", body: Self.calibrationHTML, contentType: "text/html; charset=utf-8", on: connection, corsOrigin: corsOrigin)
            return
        }

        if method == "GET", (path == "/v1/status" || path == "/status") {
            DispatchQueue.main.async { [weak self] in
                let body = self?.statusProvider?() ?? Data("{}".utf8)
                self?.sendHTTP(status: "200 OK", body: String(data: body, encoding: .utf8) ?? "{}", on: connection, corsOrigin: corsOrigin)
            }
            return
        }
        if method == "GET" {
            guard let command = commandForGET(path: path, query: Self.queryValues(in: fullPath)) else {
                sendHTTP(status: "404 Not Found", body: "{\"error\":\"unknown or invalid control\"}", on: connection, corsOrigin: corsOrigin)
                return
            }
            DispatchQueue.main.async { [weak self] in
                self?.commands.send(command)
                self?.sendHTTP(status: "202 Accepted", body: "{\"accepted\":true}", on: connection, corsOrigin: corsOrigin)
            }
            return
        }
        guard method == "POST" else {
            sendHTTP(status: "405 Method Not Allowed", body: "{\"error\":\"use GET or POST for controls\"}", on: connection, corsOrigin: corsOrigin)
            return
        }

        let command: ExternalControlCommand?
        switch path {
        case "/v1/blackout/on": command = .setBlackout(true)
        case "/v1/blackout/off": command = .setBlackout(false)
        case "/v1/blackout/toggle": command = .toggleBlackout
        case "/v1/output/blackout/on": command = .setBlackout(true)
        case "/v1/output/blackout/off": command = .setBlackout(false)
        case "/v1/output/blackout/toggle": command = .toggleBlackout
        case "/v1/output/blackout":
            if let request = try? JSONDecoder().decode(BooleanRequest.self, from: request.body),
               let blackout = request.blackout ?? request.value {
                command = .setBlackout(blackout)
            } else {
                command = nil
            }
        case "/v1/output/active":
            if let request = try? JSONDecoder().decode(BooleanRequest.self, from: request.body),
               let active = request.active ?? request.value {
                command = .setOutputActive(active)
            } else {
                command = nil
            }
        case "/v1/output/intensity", "/v1/output/brightness":
            if let request = try? JSONDecoder().decode(NumberRequest.self, from: request.body),
               let intensity = request.value ?? request.intensity ?? request.brightness,
               intensity.isFinite, (0...1).contains(intensity) {
                command = .setOutputIntensity(intensity)
            } else {
                command = nil
            }
        case "/v1/surface/active":
            if let request = try? JSONDecoder().decode(BooleanRequest.self, from: request.body),
               let name = request.name, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               let active = request.active ?? request.value {
                command = .setSurfaceActiveNamed(name, active)
            } else {
                command = nil
            }
        case "/v1/surface/blackout":
            if let request = try? JSONDecoder().decode(BooleanRequest.self, from: request.body),
               let name = request.name, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               let blackout = request.blackout ?? request.value {
                command = .setSurfaceBlackoutNamed(name, blackout)
            } else {
                command = nil
            }
        case "/v1/surface/intensity", "/v1/surface/brightness":
            if let request = try? JSONDecoder().decode(NumberRequest.self, from: request.body),
               let name = request.name, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               let intensity = request.value ?? request.intensity ?? request.brightness,
               intensity.isFinite, (0...1).contains(intensity) {
                command = .setSurfaceIntensityNamed(name, intensity)
            } else {
                command = nil
            }
        case "/v1/cue/next": command = .stepCue(1)
        case "/v1/cue/previous": command = .stepCue(-1)
        case "/v1/scene/take":
            if let scene = try? JSONDecoder().decode(SceneNameRequest.self, from: request.body) {
                command = .takeSceneNamed(scene.name)
            } else {
                command = nil
            }
        default:
            let prefix = "/v1/scene/"
            if path.hasPrefix(prefix), path.hasSuffix("/take") {
                let idText = String(path.dropFirst(prefix.count).dropLast("/take".count))
                command = UUID(uuidString: idText).map(ExternalControlCommand.takeScene)
            } else if path.hasPrefix("/v1/surface/") {
                let components = path.split(separator: "/")
                if components.count == 4,
                   let surfaceID = UUID(uuidString: String(components[2])) {
                    switch components[3] {
                    case "active":
                        if let state = try? JSONDecoder().decode(BooleanRequest.self, from: request.body),
                           let active = state.active ?? state.value {
                            command = .setSurfaceActive(surfaceID, active)
                        } else {
                            command = nil
                        }
                    case "blackout":
                        if let state = try? JSONDecoder().decode(BooleanRequest.self, from: request.body),
                           let blackout = state.blackout ?? state.value {
                            command = .setSurfaceBlackout(surfaceID, blackout)
                        } else {
                            command = nil
                        }
                    case "intensity", "brightness":
                        if let state = try? JSONDecoder().decode(NumberRequest.self, from: request.body),
                           let intensity = state.value ?? state.intensity ?? state.brightness,
                           intensity.isFinite, (0...1).contains(intensity) {
                            command = .setSurfaceIntensity(surfaceID, intensity)
                        } else {
                            command = nil
                        }
                    default:
                        command = nil
                    }
                } else if components.count == 5, components[3] == "corner",
                          let surfaceID = UUID(uuidString: String(components[2])),
                          let cornerIndex = Int(components[4]), (0..<4).contains(cornerIndex),
                          let requestPoint = try? JSONDecoder().decode(CornerRequest.self, from: request.body),
                          requestPoint.x.isFinite, requestPoint.y.isFinite,
                          (0...1).contains(requestPoint.x), (0...1).contains(requestPoint.y) {
                    command = .setCorner(
                        surfaceID: surfaceID,
                        cornerIndex: cornerIndex,
                        point: NormalizedPoint(requestPoint.x, requestPoint.y)
                    )
                } else {
                    command = nil
                }
            } else {
                command = nil
            }
        }
        guard let command else {
            sendHTTP(status: "404 Not Found", body: "{\"error\":\"unknown control or invalid value\"}", on: connection, corsOrigin: corsOrigin)
            return
        }
        DispatchQueue.main.async { [weak self] in
            self?.commands.send(command)
            self?.sendHTTP(status: "202 Accepted", body: "{\"accepted\":true}", on: connection, corsOrigin: corsOrigin)
        }
    }

    private func sendHTTP(status: String, body: String, on connection: NWConnection, corsOrigin: String? = nil) {
        sendHTTP(status: status, body: Data(body.utf8), contentType: "application/json", on: connection, corsOrigin: corsOrigin)
    }

    private func sendHTTP(status: String, body: String, contentType: String, on connection: NWConnection, corsOrigin: String? = nil) {
        sendHTTP(status: status, body: Data(body.utf8), contentType: contentType, on: connection, corsOrigin: corsOrigin)
    }

    private func sendHTTP(status: String, body: Data, contentType: String, on connection: NWConnection, corsOrigin: String? = nil) {
        var headers = "HTTP/1.1 \(status)\r\nContent-Type: \(contentType)\r\nContent-Length: \(body.count)\r\nConnection: close\r\n"
        if let corsOrigin {
            headers += "Access-Control-Allow-Origin: \(corsOrigin)\r\n"
            headers += "Access-Control-Allow-Methods: GET, POST, OPTIONS\r\n"
            headers += "Access-Control-Allow-Headers: Content-Type, Authorization\r\n"
            headers += "Vary: Origin\r\n"
        }
        headers += "\r\n"
        var response = Data(headers.utf8)
        response.append(body)
        connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
    }

    private func receiveOSC(on connection: NWConnection) {
        connection.receiveMessage { [weak self] data, _, _, error in
            guard let self else { connection.cancel(); return }
            if let data, let command = Self.command(fromOSC: data) {
                DispatchQueue.main.async { self.commands.send(command) }
            }
            if error == nil { self.receiveOSC(on: connection) } else { connection.cancel() }
        }
    }

    private enum OSCArgument {
        case integer(Int32)
        case float(Float)
        case boolean(Bool)
    }

    private static func command(fromOSC packet: Data) -> ExternalControlCommand? {
        var cursor = 0
        guard let address = readOSCString(packet, cursor: &cursor),
              let tags = readOSCString(packet, cursor: &cursor), tags.first == "," else { return nil }
        var arguments: [OSCArgument] = []
        for tag in tags.dropFirst() {
            switch tag {
            case "i":
                guard let bits: UInt32 = readOSCWord(packet, cursor: &cursor) else { return nil }
                arguments.append(.integer(Int32(bitPattern: bits.bigEndian)))
            case "f":
                guard let bits: UInt32 = readOSCWord(packet, cursor: &cursor) else { return nil }
                arguments.append(.float(Float(bitPattern: bits.bigEndian)))
            case "T": arguments.append(.boolean(true))
            case "F": arguments.append(.boolean(false))
            default: return nil
            }
        }
        switch address {
        case "/promap/blackout":
            guard let argument = arguments.first else { return .toggleBlackout }
            switch argument {
            case .integer(let value): return .setBlackout(value != 0)
            case .float(let value): return .setBlackout(value != 0)
            case .boolean(let value): return .setBlackout(value)
            }
        case "/promap/cue/next": return .stepCue(1)
        case "/promap/cue/previous": return .stepCue(-1)
        default:
            let prefix = "/promap/scene/"
            if address.hasPrefix(prefix), address.hasSuffix("/take") {
                let idText = String(address.dropFirst(prefix.count).dropLast("/take".count))
                return UUID(uuidString: idText).map(ExternalControlCommand.takeScene)
            }
            return nil
        }
    }

    private static func readOSCString(_ data: Data, cursor: inout Int) -> String? {
        guard cursor < data.count,
              let terminator = data[cursor...].firstIndex(of: 0),
              let value = String(data: data[cursor..<terminator], encoding: .utf8) else { return nil }
        cursor = ((data.distance(from: data.startIndex, to: terminator) + 4) / 4) * 4
        return value
    }

    private static func readOSCWord<T>(_ data: Data, cursor: inout Int) -> T? {
        guard cursor + MemoryLayout<T>.size <= data.count else { return nil }
        let value = data.withUnsafeBytes { raw in raw.loadUnaligned(fromByteOffset: cursor, as: T.self) }
        cursor += MemoryLayout<T>.size
        return value
    }

    private func updateStatus(_ state: NWListener.State, label: String, isHTTP: Bool) {
        let value: String
        switch state {
        case .ready:
            let port = isHTTP ? httpListener?.port : oscListener?.port
            httpAccessLock.lock()
            let remoteAccess = httpRemoteAccessEnabled
            httpAccessLock.unlock()
            if isHTTP && remoteAccess {
                value = port.map { "LAN :\($0.rawValue)" } ?? "LAN ready"
            } else {
                value = port.map { "127.0.0.1:\($0.rawValue)" } ?? "Ready"
            }
        case .failed(let error): value = "Failed: \(error.localizedDescription)"
        case .waiting(let error): value = "Waiting: \(error.localizedDescription)"
        case .cancelled: value = "Disabled"
        default: value = "Starting…"
        }
        if isHTTP { setHTTPStatus(value) } else { setOSCStatus(value) }
    }

    private func setHTTPStatus(_ value: String) {
        DispatchQueue.main.async { self.httpStatus = value }
    }

    private func setOSCStatus(_ value: String) {
        DispatchQueue.main.async { self.oscStatus = value }
    }
}
