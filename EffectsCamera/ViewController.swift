//
//  ViewController.swift
//  EffectsCamera
//
//  Created by Luke Van In on 2016/07/19.
//  Copyright © 2016 Luke Van In. All rights reserved.
//

import UIKit
import GLKit
import AVFoundation
import Photos

private let gpuEnabled = true // Set to true to render to the GPU. Set to false to use the sofware renderer.

//private let videoSize = CGSize(width: 1080, height: 1920) // Portrait
private let videoSize = CGSize(width: 1920, height: 1080) // Landscape

private let cameraTransform = CGAffineTransformMakeRotation(CGFloat(-M_PI * 0.5)) // clockwise
private let outputTransform = CGAffineTransformMakeRotation(CGFloat(M_PI * 0.5)) // counter-clockwise
//private let rotationTransform = CGAffineTransformIdentity

class ViewController: UIViewController, AVCaptureVideoDataOutputSampleBufferDelegate {

    private let syncQueue = dispatch_queue_create("sync-queue", DISPATCH_QUEUE_SERIAL)

    private var previewContext: CIContext!
    private var outputContext: CIContext!

    private var targetRect: CGRect!
    private var session: AVCaptureSession!
    private var filter: CIFilter!

    private var cameraOutput: AVCaptureVideoDataOutput!

    private var assetWriterInput: AVAssetWriterInput?
    private var assetWriter: AVAssetWriter?

    private var sessionStarted = false {
        didSet {
            dispatch_async(dispatch_get_main_queue()) {
                if self.sessionStarted {
                    self.stateView.backgroundColor = UIColor.redColor().colorWithAlphaComponent(0.8)
                    self.stateLabel.text = "RECORDING"
                }
                else {
                    self.stateView.backgroundColor = UIColor.blackColor().colorWithAlphaComponent(0.8)
                    self.stateLabel.text = "HOLD TO RECORD"
                }
            }
        }
    }

    @IBOutlet var glView: GLKView!
    @IBOutlet var stateView: UIView!
    @IBOutlet var stateLabel: UILabel!

    override func prefersStatusBarHidden() -> Bool {
        return true
    }

    override func viewDidAppear(animated: Bool) {
        super.viewDidAppear(animated)

        print("")
        print("video dimensions: \(videoSize)")
        print("gpu: \(gpuEnabled)")
        print("")

        let monochromeFilter = CIFilter(
            name: "CIColorMonochrome",
            withInputParameters: [
                "inputColor" : CIColor(
                    red: 1.0,
                    green: 1.0,
                    blue: 1.0
                ),
                "inputIntensity" : 1.0
            ]
        )

        let noirFilter = CIFilter(
            name: "CIPhotoEffectNoir",
            withInputParameters: nil
        )

        filter = noirFilter

        // Context to render to video file.
        let outputGLContext = EAGLContext(
            API: .OpenGLES2
        )

        outputContext = CIContext(
            EAGLContext: outputGLContext,
            options: [
                kCIContextOutputColorSpace: NSNull(),
                kCIContextWorkingColorSpace: NSNull(),
                kCIContextUseSoftwareRenderer: NSNumber(booleanLiteral: !gpuEnabled)
            ]
        )

        // Context to display preview.
        let previewGLContext = EAGLContext(
            API: .OpenGLES2
        )

        glView.context = previewGLContext
        glView.enableSetNeedsDisplay = false

        previewContext = CIContext(
            EAGLContext: previewGLContext,
            options: [
                kCIContextOutputColorSpace: NSNull(),
                kCIContextWorkingColorSpace: NSNull(),
                kCIContextUseSoftwareRenderer: NSNumber(booleanLiteral: !gpuEnabled)
            ]
        )


        let screenSize = UIScreen.mainScreen().bounds.size
        let screenScale = UIScreen.mainScreen().scale

        targetRect = CGRect(
            x: 0,
            y: 0,
            width: screenSize.width * screenScale,
            height: screenSize.height * screenScale
        )

        // Setup capture session.

        let cameraDevice = AVCaptureDevice.defaultDeviceWithMediaType(AVMediaTypeVideo)

        let videoInput = try? AVCaptureDeviceInput(
            device: cameraDevice
        )

        cameraOutput = AVCaptureVideoDataOutput()
        cameraOutput.videoSettings = [
            String(kCVPixelBufferPixelFormatTypeKey): NSNumber(unsignedInt: kCVPixelFormatType_32BGRA)
            ]
        cameraOutput.setSampleBufferDelegate(self, queue: syncQueue)

        session = AVCaptureSession()
        session.beginConfiguration()
        session.addInput(videoInput)
        session.addOutput(cameraOutput)
        session.commitConfiguration()
        session.startRunning()
    }

    func captureOutput(captureOutput: AVCaptureOutput!, didOutputSampleBuffer sampleBuffer: CMSampleBuffer!, fromConnection connection: AVCaptureConnection!) {

        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            return
        }


        let filter = self.filter.copy() as! CIFilter

        // Create a CIImage from the video pixel buffer.
        let originalImage = CIImage(
            CVPixelBuffer: pixelBuffer,
            options: [
                kCIImageColorSpace: NSNull()
            ]
        )

        filter.setValue(originalImage, forKey: kCIInputImageKey)

        guard let filteredImage = filter.outputImage else {
            return
        }

        // Draw the filtered image to the OpenGL context.
        outputContext.drawImage(filteredImage, inRect: self.targetRect, fromRect: filteredImage.extent)

        // Append filtered image to output.
        let time = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let duration = CMSampleBufferGetDuration(sampleBuffer)
        self.appendImage(filteredImage, time: time, duration: duration)

        // Update the GLView to display the filtered image.
        let previewImage = filteredImage.imageByApplyingTransform(cameraTransform)
        previewContext.drawImage(previewImage, inRect: self.targetRect, fromRect: previewImage.extent)
        performSelectorOnMainThread(#selector(updateView), withObject: nil, waitUntilDone: false)
    }

    @objc private func updateView() {
        glView.display()
    }

    private func appendImage(image: CIImage, time: CMTime, duration: CMTime) {

        guard let assetWriterInput = self.assetWriterInput else {
            return
        }

        guard assetWriterInput.readyForMoreMediaData else {
            print("cannot append sample buffer, writer not ready: \(CMTimeGetSeconds(time))")
            return
        }

        assert(CGSizeEqualToSize(image.extent.size, videoSize), "Input image size \(image.extent.size) does not match expected size \(videoSize).")

        // Create pixel buffer
        let options = [
            String(kCVPixelBufferPixelFormatTypeKey): NSNumber(unsignedInt: kCVPixelFormatType_32BGRA),
            String(kCVPixelBufferWidthKey): NSNumber(integerLiteral: Int(videoSize.width)),
            String(kCVPixelBufferHeightKey): NSNumber(integerLiteral: Int(videoSize.height)),
            String(kCVPixelBufferOpenGLESCompatibilityKey): NSNumber(booleanLiteral: true),
            String(kCVPixelBufferIOSurfacePropertiesKey): NSDictionary()
        ]

        var pixelBuffer: CVPixelBuffer?

        CVPixelBufferCreate(
            kCFAllocatorSystemDefault,
            Int(videoSize.width),
            Int(videoSize.height),
            kCVPixelFormatType_32BGRA, // kCVPixelFormatType_420YpCbCr8Planar
            options,
            &pixelBuffer
        )

        if pixelBuffer == nil {
            print("Cannot allocate pixel buffer")
            return
        }

        // Render the image to pixel buffer.
        let bounds = CGRect(
            origin: CGPointZero,
            size: videoSize
        )

        CVPixelBufferLockBaseAddress(pixelBuffer!, 0)
        outputContext.render(image, toCVPixelBuffer: pixelBuffer!, bounds: bounds, colorSpace: nil)
        CVPixelBufferUnlockBaseAddress(pixelBuffer!, 0)


        // Create sample buffer from image.
        var timingInfo = CMSampleTimingInfo(
            duration: CMTime(),
            presentationTimeStamp: time,
            decodeTimeStamp: kCMTimeInvalid
        )

        var videoInfo: CMVideoFormatDescription?
        CMVideoFormatDescriptionCreateForImageBuffer(kCFAllocatorDefault, pixelBuffer!, &videoInfo)

        if videoInfo == nil {
            print("Cannot create video format description")
            return
        }

        var sampleBuffer: CMSampleBufferRef?
        CMSampleBufferCreateForImageBuffer(kCFAllocatorDefault, pixelBuffer!, true, nil, nil, videoInfo!, &timingInfo, &sampleBuffer)

        if sampleBuffer == nil {
            print("Cannot create sample buffer")
            return
        }

        // Append the sample buffer to asset writer.
        if !sessionStarted {

            assetWriter?.startSessionAtSourceTime(time)
            sessionStarted = true
        }

        assetWriterInput.appendSampleBuffer(sampleBuffer!)
//        print("appended sample buffer: \(CMTimeGetSeconds(time))")
    }

    func captureOutput(captureOutput: AVCaptureOutput!, didDropSampleBuffer sampleBuffer: CMSampleBuffer!, fromConnection connection: AVCaptureConnection!) {
//        let seconds = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
//        print("dropped sample buffer: \(seconds)")
    }

    override func touchesBegan(touches: Set<UITouch>, withEvent event: UIEvent?) {
        beginRecording()
    }

    override func touchesEnded(touches: Set<UITouch>, withEvent event: UIEvent?) {
        endRecording()
    }

    private func beginRecording() {

        guard assetWriter == nil else {
            return
        }

        // Create a url for a temporary file in the caches directory.
        guard let directory = NSFileManager.defaultManager().URLsForDirectory(.CachesDirectory, inDomains: .UserDomainMask).first else {
            return
        }

        let file = directory.URLByAppendingPathComponent(NSUUID().UUIDString).URLByAppendingPathExtension("mov")

        do {

            // Create the asset writer.
            let assetWriter = try AVAssetWriter(
                URL: file,
                fileType: AVFileTypeQuickTimeMovie
            )

            // Add an input to the asset writer. Sample buffers are appending to the input.
            var settings = cameraOutput.recommendedVideoSettingsForAssetWriterWithOutputFileType(AVFileTypeQuickTimeMovie) as? [String: AnyObject]
            settings?[AVVideoWidthKey] = NSNumber(integerLiteral: Int(videoSize.width))
            settings?[AVVideoHeightKey] = NSNumber(integerLiteral: Int(videoSize.height))

            let input = AVAssetWriterInput(
                mediaType: AVMediaTypeVideo,
                outputSettings: settings,
                sourceFormatHint: nil
            )
            input.expectsMediaDataInRealTime = true
            input.transform = outputTransform

            assetWriter.addInput(input)

            // Start writing
            assetWriter.startWriting()

            // Set class variables.
            self.assetWriter = assetWriter
            self.assetWriterInput = input
        }
        catch {
            print("Cannot create asset writer: \(error)")
        }
    }

    private func endRecording() {

        assetWriterInput = nil

        dispatch_sync(syncQueue) {
            self.sessionStarted = false
        }

        guard let assetWriter = self.assetWriter else {
            return
        }

        assetWriter.finishWritingWithCompletionHandler() {
            switch assetWriter.status {
            case .Failed:
                print("Cannot save asset: \(assetWriter.error)")
            case .Cancelled:
                print("Cancelled saving asset: \(assetWriter.outputURL)")
            case .Completed:
                print("Saved asset to file: \(assetWriter.outputURL)")
                self.trySaveFileToLibrary(assetWriter.outputURL)
            default:
                break
            }
        }

        self.assetWriter = nil
    }

    private func trySaveFileToLibrary(file: NSURL) {

        let status = PHPhotoLibrary.authorizationStatus()

        if status == .Restricted || status == .Denied {
            return // Recording disabled, and cannot be enabled
        }

        switch status {

        case .Restricted:
            print("Cannot save video, access to photos restricted.")

        case .Denied:
            print("Cannot save video, user denied access.")

        case .NotDetermined:
            PHPhotoLibrary.requestAuthorization() { status in
                self.saveFileToLibrary(file)
            }

        case .Authorized:
            self.saveFileToLibrary(file)
        }
    }

    private func saveFileToLibrary(file: NSURL) {

        guard PHPhotoLibrary.authorizationStatus() == .Authorized else {
            print("Cannot save video, access not authorized.")
            return
        }

        PHPhotoLibrary.sharedPhotoLibrary().performChanges(
            {
                let request = PHAssetCreationRequest.creationRequestForAsset()
                let options = PHAssetResourceCreationOptions()
                options.shouldMoveFile = true
                request.addResourceWithType(.Video, fileURL: file, options: options)
            },
            completionHandler: { success, error in
                if let error = error {
                    print("Cannot save to library: \(error)")
                }
                else {
                    print("Saved to library")
                }
            }
        )
    }
}

