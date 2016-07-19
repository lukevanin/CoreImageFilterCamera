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

private let rotationTransform = CGAffineTransformMakeRotation(CGFloat(-M_PI * 0.5))

class ViewController: UIViewController, AVCaptureVideoDataOutputSampleBufferDelegate {

    private var context: CIContext!
    private var targetRect: CGRect!
    private var session: AVCaptureSession!
    private var filter: CIFilter!

    @IBOutlet var glView: GLKView!

    override func prefersStatusBarHidden() -> Bool {
        return true
    }

    override func viewDidAppear(animated: Bool) {
        super.viewDidAppear(animated)

        let sepiaColor = CIColor(
            red: 1.0 / 0.30078125,
            green: 1.0 / 0.5859375,
            blue: 1.0 / 0.11328125
        )

        filter = CIFilter(
            name: "CIColorMonochrome",
            withInputParameters: [
                "inputColor" : sepiaColor,
                "inputIntensity" : 1.0
            ]
        )

        // GL context

        let glContext = EAGLContext(
            API: .OpenGLES2
        )

        glView.context = glContext
        glView.enableSetNeedsDisplay = false

        context = CIContext(
            EAGLContext: glContext,
            options: [
                kCIContextOutputColorSpace: NSNull(),
                kCIContextWorkingColorSpace: NSNull(),
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

        let videoQueue = dispatch_queue_create("video-queue", DISPATCH_QUEUE_SERIAL)

        let videoOutput = AVCaptureVideoDataOutput()
        videoOutput.setSampleBufferDelegate(self, queue: videoQueue)

        session = AVCaptureSession()
        session.beginConfiguration()
        session.addInput(videoInput)
        session.addOutput(videoOutput)
        session.commitConfiguration()
        session.startRunning()
    }

    func captureOutput(captureOutput: AVCaptureOutput!, didOutputSampleBuffer sampleBuffer: CMSampleBuffer!, fromConnection connection: AVCaptureConnection!) {

        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            return
        }

        let originalImage = CIImage(
            CVPixelBuffer: pixelBuffer,
            options: [
                kCIImageColorSpace: NSNull()
            ]
        )

        let rotatedImage = originalImage.imageByApplyingTransform(rotationTransform)

        filter.setValue(rotatedImage, forKey: kCIInputImageKey)

        guard let filteredImage = filter.outputImage else {
            return
        }

        context.drawImage(filteredImage, inRect: targetRect, fromRect: filteredImage.extent)

        glView.display()
    }

    func captureOutput(captureOutput: AVCaptureOutput!, didDropSampleBuffer sampleBuffer: CMSampleBuffer!, fromConnection connection: AVCaptureConnection!) {
        let seconds = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
        print("dropped sample buffer: \(seconds)")
    }
}

