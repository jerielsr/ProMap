import XCTest
@testable import ProMap

final class ProjectionModelTests: XCTestCase {
    func testRectangleHomographyKeepsNormalizedCoordinates() throws {
        let point = NormalizedPoint(0.23, 0.71)
        let mapped = try XCTUnwrap(ProjectiveTransform.outputToSource(point, corners: ProjectionSurface.rectanglePoints))
        XCTAssertEqual(mapped.x, point.x, accuracy: 0.000001)
        XCTAssertEqual(mapped.y, point.y, accuracy: 0.000001)
    }

    func testPerspectiveTransformRoundTripsPoints() throws {
        let corners = [
            NormalizedPoint(0.18, 0.12), NormalizedPoint(0.81, 0.08),
            NormalizedPoint(0.92, 0.87), NormalizedPoint(0.09, 0.94)
        ]
        let sourcePoint = NormalizedPoint(0.38, 0.64)
        let outputPoint = try XCTUnwrap(ProjectiveTransform.sourceToOutput(sourcePoint, corners: corners))
        let restored = try XCTUnwrap(ProjectiveTransform.outputToSource(outputPoint, corners: corners))
        XCTAssertEqual(restored.x, sourcePoint.x, accuracy: 0.000001)
        XCTAssertEqual(restored.y, sourcePoint.y, accuracy: 0.000001)
    }

    func testCrossMaskIncludesArmsAndExcludesCorners() {
        XCTAssertTrue(ProjectiveTransform.contains(NormalizedPoint(0.5, 0.15), in: ProjectionSurface.crossPoints))
        XCTAssertTrue(ProjectiveTransform.contains(NormalizedPoint(0.15, 0.5), in: ProjectionSurface.crossPoints))
        XCTAssertFalse(ProjectiveTransform.contains(NormalizedPoint(0.1, 0.1), in: ProjectionSurface.crossPoints))
    }

    func testMappingDocumentRoundTripsSurfaceGeometryAndSourcePath() throws {
        var surface = ProjectionSurface.cross()
        surface.sourcePath = "/tmp/cross-loop.mov"
        surface.corners[0] = NormalizedPoint(0.21, 0.17)
        surface.brightness = 0.72
        surface.colorCorrection = SurfaceColorCorrection(contrast: 1.2, saturation: 0.7, exposure: 0.5, redGain: 1.1)
        surface.contentTransform = SurfaceContentTransform(
            zoomX: 1.8,
            zoomY: 1.2,
            offsetX: 0.1,
            offsetY: -0.05,
            rotationDegrees: 12,
            isFlippedHorizontally: true
        )
        surface.additionalMaskPaths = [
            ProjectionMaskPath(
                name: "Window cutout",
                operation: .exclude,
                points: [
                    NormalizedPoint(0.4, 0.2), NormalizedPoint(0.6, 0.2),
                    NormalizedPoint(0.6, 0.4), NormalizedPoint(0.4, 0.4)
                ]
            )
        ]
        let outputExclusion = ProjectionMaskPath(
            name: "Light fitting",
            operation: .exclude,
            points: [
                NormalizedPoint(0.1, 0.1), NormalizedPoint(0.2, 0.1),
                NormalizedPoint(0.2, 0.2), NormalizedPoint(0.1, 0.2)
            ]
        )
        let output = ProjectionOutput(
            name: "Projector 2",
            width: 2560,
            height: 1440,
            exclusionPaths: [outputExclusion],
            exclusionFeather: 0.012
        )
        let original = MappingDocument(surfaces: [surface], outputs: [.main, output])
        let encoded = try JSONEncoder().encode(original)
        let restored = try JSONDecoder().decode(MappingDocument.self, from: encoded)

        XCTAssertEqual(restored.formatVersion, MappingDocument.currentVersion)
        XCTAssertEqual(restored.surfaces, [surface])
        XCTAssertEqual(restored.sourcePaths, ["/tmp/cross-loop.mov"])
        XCTAssertEqual(restored.outputs, [.main, output])
    }

    func testLegacyMappingWithoutColorCorrectionStillLoads() throws {
        let data = Data("""
        {
          "formatVersion": 1,
          "surfaces": [{
            "id": "A7D3AF49-E9F2-4F36-8C34-147A44C06334",
            "name": "Legacy",
            "corners": [{"x":0,"y":0},{"x":1,"y":0},{"x":1,"y":1},{"x":0,"y":1}],
            "maskKind": "Rectangle",
            "maskPoints": [{"x":0,"y":0},{"x":1,"y":0},{"x":1,"y":1},{"x":0,"y":1}],
            "isMaskInverted": false,
            "sourcePath": null,
            "usesLayerStack": false,
            "isVisible": true,
            "isLocked": false,
            "isBlackout": false,
            "brightness": 1,
            "opacity": 1
          }]
        }
        """.utf8)

        let restored = try JSONDecoder().decode(MappingDocument.self, from: data)

        XCTAssertEqual(restored.surfaces.first?.name, "Legacy")
        XCTAssertNil(restored.surfaces.first?.colorCorrection)
        XCTAssertNil(restored.surfaces.first?.contentTransform)
        XCTAssertNil(restored.outputs?.first?.exclusionPaths)
    }

    func testColorCorrectionClampsOutOfRangeValues() {
        let correction = SurfaceColorCorrection(
            contrast: 3,
            saturation: -1,
            exposure: 20,
            gamma: 0,
            redGain: .infinity,
            greenGain: -2,
            blueGain: 8
        ).sanitized()

        XCTAssertEqual(correction.contrast, 2)
        XCTAssertEqual(correction.saturation, 0)
        XCTAssertEqual(correction.exposure, 4)
        XCTAssertEqual(correction.gamma, 0.1)
        XCTAssertEqual(correction.redGain, 1)
        XCTAssertEqual(correction.greenGain, 0)
        XCTAssertEqual(correction.blueGain, 2)
    }

    func testContentTransformClampsZoomPositionAndRotation() {
        let transform = SurfaceContentTransform(
            zoomX: 20,
            zoomY: -2,
            offsetX: 3,
            offsetY: -.infinity,
            rotationDegrees: .nan
        ).sanitized()

        XCTAssertEqual(transform.zoomX, 10)
        XCTAssertEqual(transform.zoomY, 0.1)
        XCTAssertEqual(transform.offsetX, 1)
        XCTAssertEqual(transform.offsetY, 0)
        XCTAssertEqual(transform.rotationDegrees, 0)
    }

    func testHueRotationKeepsNegativeAnglesAndClampsLimits() {
        let effect = SurfaceEffect(kind: .hueRotation, radius: -270).sanitized()
        XCTAssertEqual(effect.radius, -180)
    }

    func testContentAndOutputMaskEditsUndoTogetherWithGeometry() {
        let session = RenderSession()
        let surfaceID = session.surfaces[0].id
        let outputID = ProjectionOutput.mainID
        let exclusion = ProjectionMaskPath(
            name: "Window",
            operation: .exclude,
            points: [
                NormalizedPoint(0.2, 0.2), NormalizedPoint(0.3, 0.2),
                NormalizedPoint(0.3, 0.3), NormalizedPoint(0.2, 0.3)
            ]
        )

        session.updateContentTransform(on: surfaceID) { $0.zoomX = 2 }
        XCTAssertEqual(session.surfaces[0].contentTransform?.zoomX, 2)
        session.undoGeometry()
        XCTAssertNil(session.surfaces[0].contentTransform)

        session.updateOutputMaskConfiguration(outputID) { output in
            output.exclusionPaths = [exclusion]
            output.exclusionFeather = 0.02
        }
        XCTAssertEqual(session.outputs[0].exclusionPaths, [exclusion])
        XCTAssertEqual(session.outputs[0].exclusionFeather, 0.02)
        session.undoGeometry()
        XCTAssertNil(session.outputs[0].exclusionPaths)
        XCTAssertEqual(session.outputs[0].exclusionFeather, 0)
    }

    func testCaptureDeviceReferenceIsStable() {
        let first = MediaSource.captureReference(forDeviceID: "USB Camera / serial 01")
        let second = MediaSource.captureReference(forDeviceID: "USB Camera / serial 01")

        XCTAssertEqual(first, second)
        XCTAssertTrue(first.hasPrefix("capture://"))
        XCTAssertFalse(first.contains("USB Camera"))
    }

    func testNDIReferencesPreserveManualAddressAndLegacyNames() throws {
        let manual = NDISourceDescriptor(name: "Stage Camera", url: "10.0.0.24:5960")
        let restoredManual = try XCTUnwrap(NDISourceDescriptor.descriptor(from: manual.reference))
        XCTAssertEqual(restoredManual.name, manual.name)
        XCTAssertEqual(restoredManual.url, manual.url)

        let discovered = NDISourceDescriptor(name: "Mixer Output", url: "")
        XCTAssertEqual(NDISourceDescriptor.sourceName(from: discovered.reference), discovered.name)
        XCTAssertNil(NDISourceDescriptor.sourceURL(from: discovered.reference))
    }

    func testLegacyShowWithoutColorCorrectionStillLoads() throws {
        let surfaceID = "A7D3AF49-E9F2-4F36-8C34-147A44C06334"
        let data = Data("""
        {
          "formatVersion": 1,
          "surfaces": [{
            "id": "\(surfaceID)", "name": "Legacy",
            "corners": [{"x":0,"y":0},{"x":1,"y":0},{"x":1,"y":1},{"x":0,"y":1}],
            "maskKind": "Rectangle",
            "maskPoints": [{"x":0,"y":0},{"x":1,"y":0},{"x":1,"y":1},{"x":0,"y":1}],
            "isMaskInverted": false, "sourcePath": null, "usesLayerStack": true,
            "isVisible": true, "isLocked": false, "isBlackout": false, "brightness": 1, "opacity": 1
          }],
          "layers": [],
          "scenes": [{
            "id": "3F239BC2-DF72-4EC1-B725-C3D10DDFE866", "name": "Legacy Cue", "layers": [],
            "surfaces": [{
              "surfaceID": "\(surfaceID)", "sourcePath": null, "usesLayerStack": true,
              "isVisible": true, "isBlackout": false, "isMaskInverted": false, "brightness": 1, "opacity": 1
            }]
          }]
        }
        """.utf8)

        let restored = try JSONDecoder().decode(ShowDocument.self, from: data)

        XCTAssertEqual(restored.scenes.first?.name, "Legacy Cue")
        XCTAssertNil(restored.surfaces.first?.colorCorrection)
        XCTAssertNil(restored.scenes.first?.surfaces.first?.colorCorrection)
    }

    func testShowDocumentRestoresScenesAndPlaybackState() throws {
        var surface = ProjectionSurface(name: "Ceiling")
        surface.colorCorrection = SurfaceColorCorrection(saturation: 0.8, blueGain: 1.2, isInverted: true)
        let layer = SavedLayerState(
            sourcePath: "/tmp/ambient.mov",
            isEnabled: true,
            opacity: 0.8,
            isPlaying: true,
            playbackTime: 12.5
        )
        let scene = ScenePreset(name: "Worship", layers: [layer], surfaces: [SceneSurfaceState(surface: surface)])
        let show = ShowDocument(surfaces: [surface], layers: [layer], scenes: [scene])
        let restored = try JSONDecoder().decode(ShowDocument.self, from: JSONEncoder().encode(show))

        XCTAssertEqual(restored.formatVersion, ShowDocument.currentVersion)
        XCTAssertEqual(restored.scenes, [scene])
        XCTAssertEqual(restored.layers.first?.playbackTime, 12.5)
        XCTAssertEqual(restored.mediaPaths, ["/tmp/ambient.mov"])
        XCTAssertEqual(restored.surfaces.first?.colorCorrection, surface.colorCorrection)
        XCTAssertEqual(restored.scenes.first?.surfaces.first?.colorCorrection, surface.colorCorrection)
    }

    func testNDIAudioDelayAndMaskAudioStateRoundTripInShow() throws {
        var cross = ProjectionSurface.cross()
        cross.name = "Church Cross"
        cross.sourcePath = "ndi://Camera%20A"
        let surfaceState = SceneSurfaceState(
            surface: cross,
            audioMuted: false,
            audioVolume: 0.65,
            audioDelayMilliseconds: 125
        )
        let layerState = SavedLayerState(
            sourcePath: cross.sourcePath!,
            isAudioMuted: false,
            audioVolume: 0.4,
            audioDelayMilliseconds: 80
        )
        let scene = ScenePreset(name: "Service", layers: [layerState], surfaces: [surfaceState])
        let sourceAudio = SavedSourceAudioState(
            sourcePath: cross.sourcePath!,
            audioMuted: false,
            audioVolume: 0.65,
            audioDelayMilliseconds: 125
        )
        let show = ShowDocument(
            surfaces: [cross],
            layers: [layerState],
            scenes: [scene],
            sourceAudio: [sourceAudio]
        )

        let restored = try JSONDecoder().decode(ShowDocument.self, from: JSONEncoder().encode(show))

        XCTAssertEqual(restored.sourceAudio, [sourceAudio])
        XCTAssertEqual(restored.layers.first?.audioDelayMilliseconds, 80)
        XCTAssertEqual(restored.scenes.first?.surfaces.first?.audioDelayMilliseconds, 125)
        XCTAssertEqual(restored.scenes.first?.surfaces.first?.audioMuted, false)
        XCTAssertEqual(restored.mediaPaths, [cross.sourcePath!])
        XCTAssertEqual(SavedSourceAudioState(
            sourcePath: cross.sourcePath!,
            audioMuted: true,
            audioVolume: 1.2,
            audioDelayMilliseconds: 900
        ).audioDelayMilliseconds, 500)
    }

    func testFreeShowSurfaceRoutesAcceptNamesAndBoundIntensity() {
        let control = ExternalControlManager()

        guard case .setSurfaceBlackoutNamed("Church Cross", true)? = control.commandForGET(
            path: "/v1/surface/blackout",
            query: ["name": "Church Cross", "value": "true"]
        ) else {
            return XCTFail("Expected a named surface blackout command")
        }
        guard case .setSurfaceIntensityNamed("Ceiling", 0.5)? = control.commandForGET(
            path: "/v1/surface/intensity",
            query: ["name": "Ceiling", "value": "0.5"]
        ) else {
            return XCTFail("Expected a named surface intensity command")
        }
        XCTAssertNil(control.commandForGET(
            path: "/v1/surface/intensity",
            query: ["name": "Ceiling", "value": "2"]
        ))
    }

    func testCueReorderingAndOperatorMetadataPersist() throws {
        let session = RenderSession()
        let welcome = session.captureScene(named: "Welcome")
        let worship = session.captureScene(named: "Worship")
        session.setSceneOperatorNotes("Start after the walk-in", for: welcome.id)
        session.setSceneAutoAdvance(95, for: welcome.id)
        session.moveScene(welcome.id, by: 1)

        let document = ShowDocument(
            surfaces: session.surfaces,
            layers: session.layers.map(\.savedState),
            scenes: session.scenes
        )
        let restored = try JSONDecoder().decode(ShowDocument.self, from: JSONEncoder().encode(document))

        XCTAssertEqual(session.scenes.map(\.id), [worship.id, welcome.id])
        XCTAssertEqual(restored.scenes.map(\.id), [worship.id, welcome.id])
        XCTAssertEqual(restored.scenes.last?.operatorNotes, "Start after the walk-in")
        XCTAssertEqual(restored.scenes.last?.autoAdvanceAfter, 95)
    }

    func testQuadValidationRejectsCrossedCorners() {
        let crossed = [
            NormalizedPoint(0, 0), NormalizedPoint(1, 1),
            NormalizedPoint(1, 0), NormalizedPoint(0, 1)
        ]
        XCTAssertFalse(ProjectiveTransform.isConvexQuad(crossed))
        XCTAssertTrue(ProjectionSurface.main.hasUsableGeometry)
    }

    func testSceneRecallLeavesCalibratedCornersUntouched() {
        let session = RenderSession()
        var originallyCaptured = session.surfaces[0]
        originallyCaptured.colorCorrection = SurfaceColorCorrection(saturation: 0.6, isSepia: true)
        let scene = ScenePreset(name: "Worship", layers: [], surfaces: [SceneSurfaceState(surface: originallyCaptured)])
        var calibrated = session.surfaces[0]
        calibrated.corners[0] = NormalizedPoint(0.14, 0.09)
        calibrated.colorCorrection = SurfaceColorCorrection(contrast: 1.4)
        session.updateSurface(calibrated)

        session.recallScene(scene, sources: [], transitionDuration: 0)

        XCTAssertEqual(session.surfaces[0].corners, calibrated.corners)
        XCTAssertEqual(session.surfaces[0].sourcePath, originallyCaptured.sourcePath)
        XCTAssertEqual(session.surfaces[0].colorCorrection, originallyCaptured.colorCorrection)
    }

    func testVisualGeneratorReferencesRoundTripAcrossShowFiles() throws {
        for generator in VisualGenerator.presets {
            let reference = generator.reference
            let restoredGenerator = try XCTUnwrap(VisualGenerator(reference: reference))
            XCTAssertEqual(restoredGenerator.title, generator.title)
            XCTAssertEqual(restoredGenerator.kind, generator.kind)
            XCTAssertEqual(restoredGenerator.reference, reference)

            let layer = SavedLayerState(sourcePath: reference)
            let document = ShowDocument(surfaces: [.main], layers: [layer], scenes: [])
            let restoredDocument = try JSONDecoder().decode(ShowDocument.self, from: JSONEncoder().encode(document))
            XCTAssertEqual(restoredDocument.mediaPaths, [reference])
        }
    }
}
