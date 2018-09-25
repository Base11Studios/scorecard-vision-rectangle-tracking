/*
    View Controller containing live rectangle detection.
 */

import UIKit
import AVKit
import Vision

class ViewController: UIViewController, AVCaptureVideoDataOutputSampleBufferDelegate {
    
    // Main view for showing camera content.
    @IBOutlet weak var previewView: UIView?
    
    // AVCapture variables to hold sequence data
    var session: AVCaptureSession?
    var previewLayer: AVCaptureVideoPreviewLayer?
    var videoDataOutput: AVCaptureVideoDataOutput?
    var videoDataOutputQueue: DispatchQueue?
    var captureDevice: AVCaptureDevice?
    var captureDeviceResolution: CGSize = CGSize()
    
    // Layer UI for drawing Vision results
    var rootLayer: CALayer?
    var detectionOverlayLayer: CALayer?
    var detectedRectangleShapeLayer: CAShapeLayer?
    
    // Vision requests
    private var rectDetectionRequests: [VNDetectRectanglesRequest]?
    private var rectTrackingRequests: [VNTrackObjectRequest]?
    
    lazy var rectSequenceRequestHandler = VNSequenceRequestHandler()
    
    lazy var avUtil = AVUtility()
    
    // MARK: UIViewController overrides

    override func viewDidLoad() {
        super.viewDidLoad()
        
        self.session = self.setupAVCaptureSession()
        
        self.prepareRectangleVisionRequest()
        
        self.session?.startRunning()
    }
    
    // Ensure that the interface stays locked in Portrait.
    override var supportedInterfaceOrientations: UIInterfaceOrientationMask {
        return .portrait
    }
    
    // Ensure that the interface stays locked in Portrait.
    override var preferredInterfaceOrientationForPresentation: UIInterfaceOrientation {
        return .portrait
    }
    
    // MARK: AVCapture Setup
    
    /// - Tag: CreateCaptureSession
    fileprivate func setupAVCaptureSession() -> AVCaptureSession? {
        let captureSession = AVCaptureSession()
        do {
            let inputDevice = try avUtil.configureBackCamera(for: captureSession)
            self.configureVideoDataOutput(for: inputDevice.device, resolution: inputDevice.resolution, captureSession: captureSession)
            self.designatePreviewLayer(for: captureSession)
            return captureSession
        } catch let executionError as NSError {
            self.presentError(executionError)
        } catch {
            self.presentErrorAlert(message: "An unexpected failure has occured")
        }
        
        self.teardownAVCapture()
        
        return nil
    }
    
    
    
    /// - Tag: CreateSerialDispatchQueue
    fileprivate func configureVideoDataOutput(for inputDevice: AVCaptureDevice, resolution: CGSize, captureSession: AVCaptureSession) {
        
        let videoDataOutput = AVCaptureVideoDataOutput()
        videoDataOutput.alwaysDiscardsLateVideoFrames = true
        
        // Create a serial dispatch queue used for the sample buffer delegate as well as when a still image is captured.
        // A serial dispatch queue must be used to guarantee that video frames will be delivered in order.
        let videoDataOutputQueue = DispatchQueue(label: "com.example.apple-samplecode.VisionFaceTrack")
        videoDataOutput.setSampleBufferDelegate(self, queue: videoDataOutputQueue)
        
        if captureSession.canAddOutput(videoDataOutput) {
            captureSession.addOutput(videoDataOutput)
        }
        
        videoDataOutput.connection(with: .video)?.isEnabled = true
        
        if let captureConnection = videoDataOutput.connection(with: AVMediaType.video) {
            if captureConnection.isCameraIntrinsicMatrixDeliverySupported {
                captureConnection.isCameraIntrinsicMatrixDeliveryEnabled = true
            }
        }
        
        self.videoDataOutput = videoDataOutput
        self.videoDataOutputQueue = videoDataOutputQueue
        
        self.captureDevice = inputDevice
        self.captureDeviceResolution = resolution
    }
    
    /// - Tag: DesignatePreviewLayer
    fileprivate func designatePreviewLayer(for captureSession: AVCaptureSession) {
        let videoPreviewLayer = AVCaptureVideoPreviewLayer(session: captureSession)
        self.previewLayer = videoPreviewLayer
        
        videoPreviewLayer.name = "CameraPreview"
        videoPreviewLayer.backgroundColor = UIColor.black.cgColor
        videoPreviewLayer.videoGravity = AVLayerVideoGravity.resizeAspectFill
        
        if let previewRootLayer = self.previewView?.layer {
            self.rootLayer = previewRootLayer
            
            previewRootLayer.masksToBounds = true
            videoPreviewLayer.frame = previewRootLayer.bounds
            previewRootLayer.addSublayer(videoPreviewLayer)
        }
    }
    
    // Removes infrastructure for AVCapture as part of cleanup.
    fileprivate func teardownAVCapture() {
        self.videoDataOutput = nil
        self.videoDataOutputQueue = nil
        
        if let previewLayer = self.previewLayer {
            previewLayer.removeFromSuperlayer()
            self.previewLayer = nil
        }
    }
    
    // MARK: Helper Methods for Error Presentation
    
    fileprivate func presentErrorAlert(withTitle title: String = "Unexpected Failure", message: String) {
        let alertController = UIAlertController(title: title, message: message, preferredStyle: .alert)
        self.present(alertController, animated: true)
    }
    
    fileprivate func presentError(_ error: NSError) {
        self.presentErrorAlert(withTitle: "Failed with error \(error.code)", message: error.localizedDescription)
    }
    
    // Try preparing a rectangle Vision Request
    fileprivate func prepareRectangleVisionRequest() {
        
        var rectRequests = [VNTrackObjectRequest]()
        
        let rectDetectionRequest = VNDetectRectanglesRequest(completionHandler: { (request, error) in
            
            if error == nil {
                NSLog("RectDetection error: \(String(describing: error)).")
            }
            
            guard let rectDetectionRequest = request as? VNDetectRectanglesRequest,
                let results = rectDetectionRequest.results as? [VNRectangleObservation] else  {
                    return
            }
            
            DispatchQueue.main.async {
                // Add observations to the rect tracking list
                for observation in results {
                    let rectTrackingRequest = VNTrackObjectRequest(detectedObjectObservation: observation)
                    rectRequests.append(rectTrackingRequest)
                }
                self.rectTrackingRequests = rectRequests
            }
        })
        
        // Start with detection. Find rectangle, then track it
        self.rectDetectionRequests = [rectDetectionRequest]
        
        self.rectSequenceRequestHandler = VNSequenceRequestHandler()
        
        // set up RECTANGLE vision drawing layers
        self.setupVisionDrawingLayersForRectangles()
    }
    
    // MARK: Drawing Vision Observations
    
    fileprivate func setupVisionDrawingLayersForRectangles() {
        let captureDeviceResolution = self.captureDeviceResolution
        
        let captureDeviceBounds = CGRect(x: 0,
                                         y: 0,
                                         width: captureDeviceResolution.width,
                                         height: captureDeviceResolution.height)
        
        let captureDeviceBoundsCenterPoint = CGPoint(x: captureDeviceBounds.midX,
                                                     y: captureDeviceBounds.midY)
        
        let normalizedCenterPoint = CGPoint(x: 0.5, y: 0.5)
        
        guard let rootLayer = self.rootLayer else {
            self.presentErrorAlert(message: "view was not property initialized")
            return
        }
        
        let overlayLayer = CALayer()
        overlayLayer.name = "DetectionOverlay"
        overlayLayer.masksToBounds = true
        overlayLayer.anchorPoint = normalizedCenterPoint
        overlayLayer.bounds = captureDeviceBounds
        overlayLayer.position = CGPoint(x: rootLayer.bounds.midX, y: rootLayer.bounds.midY)
        
        let rectangleShapeLayer = CAShapeLayer()
        rectangleShapeLayer.name = "RectangleOutlineLayer"
        rectangleShapeLayer.bounds = captureDeviceBounds
        rectangleShapeLayer.anchorPoint = normalizedCenterPoint
        rectangleShapeLayer.position = captureDeviceBoundsCenterPoint
        rectangleShapeLayer.fillColor = UIColor.white.withAlphaComponent(0.2).cgColor
        rectangleShapeLayer.strokeColor = UIColor.blue.withAlphaComponent(0.7).cgColor
        rectangleShapeLayer.lineWidth = 25
        rectangleShapeLayer.lineJoin = .round
        rectangleShapeLayer.shadowOpacity = 0.8
        rectangleShapeLayer.shadowRadius = 8
        
        overlayLayer.addSublayer(rectangleShapeLayer)
        rootLayer.addSublayer(overlayLayer)
        
        self.detectionOverlayLayer = overlayLayer
        self.detectedRectangleShapeLayer = rectangleShapeLayer
        
        self.updateLayerGeometry()
    }
    
    fileprivate func updateLayerGeometry() {
        guard let overlayLayer = self.detectionOverlayLayer,
            let rootLayer = self.rootLayer,
            let previewLayer = self.previewLayer
            else {
            return
        }
        
        CATransaction.setValue(NSNumber(value: true), forKey: kCATransactionDisableActions)
        
        let videoPreviewRect = previewLayer.layerRectConverted(fromMetadataOutputRect: CGRect(x: 0, y: 0, width: 1, height: 1))
        
        var rotation: CGFloat
        var scaleX: CGFloat
        var scaleY: CGFloat
        
        // Rotate the layer into screen orientation.
        switch UIDevice.current.orientation {
        case .portraitUpsideDown:
            rotation = 180
            scaleX = videoPreviewRect.width / captureDeviceResolution.width
            scaleY = videoPreviewRect.height / captureDeviceResolution.height
            
        case .landscapeLeft:
            rotation = 90
            scaleX = videoPreviewRect.height / captureDeviceResolution.width
            scaleY = scaleX
            
        case .landscapeRight:
            rotation = -90
            scaleX = videoPreviewRect.height / captureDeviceResolution.width
            scaleY = scaleX
            
        default:
            rotation = 0
            scaleX = videoPreviewRect.width / captureDeviceResolution.width
            scaleY = videoPreviewRect.height / captureDeviceResolution.height
        }
        
        // Scale and mirror the image to ensure upright presentation.
        let affineTransform = CGAffineTransform(rotationAngle: avUtil.radiansForDegrees(rotation))
            .scaledBy(x: scaleX, y: scaleY)
        overlayLayer.setAffineTransform(affineTransform)
        
        // Cover entire screen UI.
        let rootLayerBounds = rootLayer.bounds
        overlayLayer.position = CGPoint(x: rootLayerBounds.midX, y: rootLayerBounds.midY)
    }
    
    fileprivate func drawRectangleObservations(_ rectObservations: [VNRectangleObservation]) {
        
        guard let rectangleShapeLayer = self.detectedRectangleShapeLayer else {
            return
        }
        
        CATransaction.begin()
        
        CATransaction.setValue(NSNumber(value: true), forKey: kCATransactionDisableActions)
        
        let rectanglePath = CGMutablePath()
        
        for rectObservation in rectObservations {
            let points = [rectObservation.bottomLeft, rectObservation.bottomRight, rectObservation.topRight, rectObservation.topLeft]
            let convertedPoints = points.map { self.convertFromCamera($0) }
            let rectPath = getBoxPath(points: convertedPoints)
            
            rectanglePath.addPath(rectPath)
        }
        
        rectangleShapeLayer.path = rectanglePath
        self.detectedRectangleShapeLayer = rectangleShapeLayer
        
        self.updateLayerGeometry()
        
        CATransaction.commit()
    }
    
    func convertFromCamera(_ point: CGPoint) -> CGPoint {
        
        let transform = CGAffineTransform.identity
            .scaledBy(x: 1, y: -1)
            .translatedBy(x: 0, y: -self.captureDeviceResolution.height)
            .scaledBy(x: self.captureDeviceResolution.width, y: self.captureDeviceResolution.height)
        
        return point.applying(transform)
        
    }
    
    private func getBoxPath(points: [CGPoint]) -> CGPath {
        let path = UIBezierPath()
        path.move(to: points.last!)
        points.forEach { point in
            path.addLine(to: point)
        }
        return path.cgPath
    }
    
    // MARK: AVCaptureVideoDataOutputSampleBufferDelegate
    
    public func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        
        var requestHandlerOptions: [VNImageOption: AnyObject] = [:]
        
        let cameraIntrinsicData = CMGetAttachment(sampleBuffer, key: kCMSampleBufferAttachmentKey_CameraIntrinsicMatrix, attachmentModeOut: nil)
        if cameraIntrinsicData != nil {
            requestHandlerOptions[VNImageOption.cameraIntrinsics] = cameraIntrinsicData
        }
        
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            NSLog("Failed to obtain a CVPixelBuffer for the current output frame.")
            return
        }
        
        let exifOrientation = avUtil.exifOrientationForCurrentDeviceOrientation()
        
        guard let requests = self.rectTrackingRequests, !requests.isEmpty else {
            // No tracking object detected, so perform initial detection
            let imageRequestHandler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer,
                                                            orientation: exifOrientation,
                                                            options: requestHandlerOptions)
            
            do {
                guard let detectRequests = self.rectDetectionRequests else {
                    return
                }
                try imageRequestHandler.perform(detectRequests)
            } catch let error as NSError {
                NSLog("Failed to perform FaceRectangleRequest: %@", error)
            }
            return
        }
        
        do {
            try self.rectSequenceRequestHandler.perform(requests,
                                                     on: pixelBuffer,
                                                     orientation: exifOrientation)
        } catch let error as NSError {
            NSLog("Failed to perform SequenceRequest: %@", error)
        }
        
        // Setup the next round of tracking.
        var newTrackingRequests = [VNTrackObjectRequest]()
        for trackingRequest in requests {
            
            guard let results = trackingRequest.results else {
                return
            }
            
            guard let observation = results[0] as? VNDetectedObjectObservation else {
                return
            }
            
            if !trackingRequest.isLastFrame {
                if observation.confidence > 0.3 {
                    trackingRequest.inputObservation = observation
                } else {
                    trackingRequest.isLastFrame = true
                }
                newTrackingRequests.append(trackingRequest)
            }
        }
        self.rectTrackingRequests = newTrackingRequests
        
        if newTrackingRequests.isEmpty {
            // Nothing to track, so abort.
            return
        }
        
        // Perform face landmark tracking on detected faces.
        var rectLandmarkRequests = [VNDetectRectanglesRequest]()
        
        // Perform landmark detection on tracked faces.
        for _ in newTrackingRequests {
            
            let rectLandmarksRequest = VNDetectRectanglesRequest { (request, error) in
                if error != nil {
                    NSLog("RectLandmarks error: \(String(describing: error))")
                }
                
                guard let rectRequest = request as? VNDetectRectanglesRequest,
                    let results = rectRequest.results as? [VNRectangleObservation] else {
                        return;
                }
                
                DispatchQueue.main.async {
                    self.drawRectangleObservations(results)
                }
            }
            
            // Continue to track detected facial landmarks.
            rectLandmarkRequests.append(rectLandmarksRequest)
            
            let imageRequestHandler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer,
                                                            orientation: exifOrientation,
                                                            options: requestHandlerOptions)
            
            do {
                try imageRequestHandler.perform(rectLandmarkRequests)
            } catch let error as NSError {
                NSLog("Failed to perform FaceLandmarkRequest: %@", error)
            }
        }
    }
}
