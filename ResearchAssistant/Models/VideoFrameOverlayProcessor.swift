//
//  VideoFrameOverlayProcessor.swift
//  ResearchAssistant
//
//  Created by Moore, Andrew on 9/13/19.
//  Copyright © 2019 Andrew Moore. All rights reserved.
//

import Foundation
import AVFoundation
import Combine
import UIKit

class VideoFrameOverlayProcessor: ObservableObject, Identifiable {
    
    private let defaultFrameSampleSize = 1500
    
    @Published var combinedImage: UIImage?
    @Published var progress: String
    
    var id = UUID()
    
    let url: URL
    let asset: AVURLAsset
    let videoTrack: AVAssetTrack?
    
    var fileSizeInBytes: Int {
        do {
            let resources = try url.resourceValues(forKeys:[.fileSizeKey])
            let fileSize = resources.fileSize!
            return fileSize
        } catch {
            return 0
        }
    }
    
    var fileDetails: String {
        "Name: \(url.absoluteURL.lastPathComponent)\n" +
        "Size: \(String(format: "%.1f", (Double(fileSizeInBytes) / 1000000.0))) MB\n" +
        "Frame Rate: \(Int((videoTrack?.nominalFrameRate ?? 0.0).rounded())) fps\n" +
        "Duration: \(String(format: "%.1f", asset.duration.seconds)) sec\n" +
        "Total frames: \(Int(asset.duration.seconds * Double(videoTrack?.nominalFrameRate ?? 0.0))) \n"
    }
    
    init(videoFileURL: URL) {
        progress = ""
        url = videoFileURL
        asset = AVURLAsset(url: url)
        videoTrack = asset.tracks(withMediaType: .video).first
    }
    func analyzeVideo(completion: ((URL?)->Void)?) {
        analyzeVideo(requestedDurationToAnalyze: asset.duration.seconds, completion: completion)
    }
    
    func analyzeVideo(requestedDurationToAnalyze: Double, completion: ((URL?)->Void)?) {
        
        let totalFrames = Int(asset.duration.seconds * Double(videoTrack?.nominalFrameRate ?? 0.0))
        let sampleSize = defaultFrameSampleSize > totalFrames ? totalFrames : defaultFrameSampleSize
        
        let secondsToAnalyze = requestedDurationToAnalyze > asset.duration.seconds ? asset.duration.seconds : requestedDurationToAnalyze
        
        var sampleTimes: [NSValue] = []
        let totalTimeLength = Int(secondsToAnalyze * Double(asset.duration.timescale))
        let step = totalTimeLength / sampleSize
        
        for i in 0 ..< sampleSize {
            let cmTime = CMTimeMake(value: Int64(i * step), timescale: Int32(asset.duration.timescale))
            sampleTimes.append(NSValue(time: cmTime))
        }
        
        let generator = AVAssetImageGenerator(asset: asset)
        generator.requestedTimeToleranceAfter = .zero
        generator.requestedTimeToleranceBefore = .zero
        generator.generateCGImagesAsynchronously(forTimes: sampleTimes) { (requestedTime, image, time2, result, error) in
            
            guard error == nil, let image = image else {
                return
            }

            var currentCombinedImage = self.combinedImage
            if let firstRequestedTime = sampleTimes.first, firstRequestedTime == NSValue(time: requestedTime) {
                currentCombinedImage = UIImage(cgImage: image)
                
                DispatchQueue.main.async {
                    self.combinedImage = currentCombinedImage
                }
            }
            
            let newCombinedImage = self.combine(imageOne: currentCombinedImage, with: self.processByPixel(in: UIImage(cgImage: image))!)
            
            DispatchQueue.main.async {
                self.progress = "Adding frame @ \(requestedTime.seconds) sec"
                self.combinedImage = newCombinedImage
            }
            
            if let lastRequestedTime = sampleTimes.last, lastRequestedTime == NSValue(time: requestedTime) {
                let newFile = NSURL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("MyImage.png")
                
                do {
                    try self.combinedImage?.pngData()?.write(to: newFile!, options: [.atomic])
                    completion?(newFile)
                } catch {
                    completion?(nil)
                }
            }
        }
    }
    
    func combine(imageOne: UIImage?, with imageTwo: UIImage) -> UIImage {
        
        let size = CGSize(width: imageTwo.size.width, height: imageTwo.size.height)
        UIGraphicsBeginImageContextWithOptions(size, false, 0.0)
        
        imageOne?.draw(in: CGRect(x: 0, y: 0, width: size.width, height: size.height), blendMode: .normal, alpha: 1)
        imageTwo.draw(in: CGRect(x: 0, y: 0, width: size.width, height: size.height), blendMode: .normal, alpha: 1)

        let newCombinedImage = UIGraphicsGetImageFromCurrentImageContext()!
        UIGraphicsEndImageContext()
        
        return newCombinedImage
    }
    
    func processByPixel(in image: UIImage) -> UIImage? {

        guard let inputCGImage = image.cgImage else {
            return nil
        }
        
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let width = inputCGImage.width
        let height = inputCGImage.height
        let bytesPerPixel = 4
        let bitsPerComponent = 8
        let bytesPerRow = bytesPerPixel * width
        let bitmapInfo = RGBA32.bitmapInfo

        guard let context =
            CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: bitsPerComponent,
                bytesPerRow: bytesPerRow,
                space: colorSpace,
                bitmapInfo: bitmapInfo) else {
            return nil
        }
        context.draw(inputCGImage, in: CGRect(x: 0, y: 0, width: width, height: height))

        guard let buffer = context.data else { return nil }

        let pixelBuffer = buffer.bindMemory(to: RGBA32.self, capacity: width * height)

        for row in 0 ..< Int(height) {
            for column in 0 ..< Int(width) {
                let offset = row * width + column
                
                if pixelBuffer[offset].redComponent >  50 ||
                    pixelBuffer[offset].greenComponent >  50 ||
                    pixelBuffer[offset].blueComponent > 50 {
                    pixelBuffer[offset] = .transparent
                }
            }
        }

        let outputCGImage = context.makeImage()!
        let outputImage = UIImage(cgImage: outputCGImage, scale: image.scale, orientation: image.imageOrientation)

        return outputImage
    }
    
    struct RGBA32: Equatable {
        
        static let transparent = RGBA32(red: 0, green: 0, blue: 0, alpha: 0)
        static let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Little.rawValue

        static func ==(lhs: RGBA32, rhs: RGBA32) -> Bool {
            return lhs.color == rhs.color
        }
        
        private var color: UInt32

        var redComponent: UInt8 {
            return UInt8((color >> 24) & 255)
        }

        var greenComponent: UInt8 {
            return UInt8((color >> 16) & 255)
        }

        var blueComponent: UInt8 {
            return UInt8((color >> 8) & 255)
        }

        var alphaComponent: UInt8 {
            return UInt8((color >> 0) & 255)
        }

        init(red: UInt8, green: UInt8, blue: UInt8, alpha: UInt8) {
            let red = UInt32(red)
            let green = UInt32(green)
            let blue = UInt32(blue)
            let alpha = UInt32(alpha)
            color = (red << 24) | (green << 16) | (blue << 8) | (alpha << 0)
        }
    }
}

