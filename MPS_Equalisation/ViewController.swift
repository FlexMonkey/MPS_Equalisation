//
//  ViewController.swift
//  MPS_Equalisation
//
//  Created by Simon Gladman on 07/05/2016.
//  Copyright © 2016 Simon Gladman. All rights reserved.
//

import UIKit
import MetalPerformanceShaders
import Accelerate.vImage

class ViewController: UIViewController {

    lazy var segmentedControl: UISegmentedControl =
    {
        let control = UISegmentedControl(items: [
            "Original",
            "vImage Equalization",
            "vImage Stretch",
            "MPS Equalization",
            "Core Image"])
        
        control.addTarget(
            self,
            action: #selector(ViewController.segmentedControlHandler),
            forControlEvents: .ValueChanged)
        
        control.selectedSegmentIndex = 0
        
        return control
    }()
    
    let imageView = UIImageView()
    var histogramDisplay = HistogramDisplay()
    
    let inputImage = CIImage(image: UIImage(named: "sky.jpg")!)!
    
    lazy var device: MTLDevice =
    {
        return MTLCreateSystemDefaultDevice()!
    }()
    
    lazy var ciContext: CIContext =
    {
        [unowned self] in
        
        return CIContext(MTLDevice: self.device)
    }()
    
    func segmentedControlHandler()
    {
        let startTime = CFAbsoluteTimeGetCurrent()
        
        switch segmentedControl.selectedSegmentIndex
        {
        case 1:
            vImageEqualizationRender()
        case 2:
            vImageStretchRender()
        case 3:
            mpsEqualizationRender()
        case 4:
            ciRender()
        default:
            displayOriginal()
        }
        
        let endTime = (CFAbsoluteTimeGetCurrent() - startTime)
        print(segmentedControl.titleForSegmentAtIndex(segmentedControl.selectedSegmentIndex)!, "execution time", endTime)
    }
    
    func displayOriginal()
    {
        displayImage(ciImage: inputImage)
    }
    
    func ciRender()
    {
        guard let filter = inputImage.autoAdjustmentFiltersWithOptions(nil).filter({ $0.name == "CIToneCurve"}).first else
        {
            return
        }
        
        filter.setValue(inputImage, forKey: kCIInputImageKey)

        displayImage(ciImage: filter.outputImage!)
    }

    func vImageEqualizationRender()
    {
        let filter = HistogramEqualization()
        
        filter.inputImage = inputImage
        
        let outputImage = filter.outputImage!

        displayImage(ciImage: outputImage)
    }
    
    func vImageStretchRender()
    {
        let filter = ContrastStretch()
        
        filter.inputImage = inputImage
        
        let outputImage = filter.outputImage!
        
        displayImage(ciImage: outputImage)
    }
    
    func mpsEqualizationRender()
    {
        let commandQueue = device.newCommandQueue()
        
        let commandBuffer = commandQueue.commandBuffer()
        
        let textureDescriptor = MTLTextureDescriptor.texture2DDescriptorWithPixelFormat(
            .RGBA8Unorm,
            width: Int(inputImage.extent.width),
            height: Int(inputImage.extent.height),
            mipmapped: false)
        
        let colorSpace = CGColorSpaceCreateDeviceRGB()!
        
        let inputTexture = device.newTextureWithDescriptor(textureDescriptor)
        let destinationTexture = device.newTextureWithDescriptor(textureDescriptor)
        
        ciContext.render(
            inputImage,
            toMTLTexture: inputTexture,
            commandBuffer: commandBuffer,
            bounds: inputImage.extent,
            colorSpace: colorSpace)
        
        var histogramInfo = MPSImageHistogramInfo(
            numberOfHistogramEntries: 256,
            histogramForAlpha: true,
            minPixelValue: vector_float4(0,0,0,0),
            maxPixelValue: vector_float4(1,1,1,1)) ;
        
        let calculation = MPSImageHistogram(
            device: device,
            histogramInfo: &histogramInfo)
  
        let histogramInfoBuffer = device.newBufferWithBytes(
            &histogramInfo,
            length: sizeofValue(histogramInfo),
            options: MTLResourceOptions.CPUCacheModeDefaultCache)
        
        calculation.encodeToCommandBuffer(
            commandBuffer,
            sourceTexture: inputTexture,
            histogram: histogramInfoBuffer,
            histogramOffset: 0)
        
        let equalization = MPSImageHistogramEqualization(
            device: device,
            histogramInfo: &histogramInfo)
        
        equalization.encodeTransformToCommandBuffer(
            commandBuffer,
            sourceTexture: inputTexture,
            histogram: histogramInfoBuffer,
            histogramOffset: 0)
        
        equalization.encodeToCommandBuffer(
            commandBuffer,
            sourceTexture: inputTexture,
            destinationTexture: destinationTexture)
        
        commandBuffer.commit()
        
        let ciImage = CIImage(MTLTexture: destinationTexture, options: [kCIImageColorSpace: colorSpace])
        
        displayImage(ciImage: ciImage)
    }
    
    func displayImage(ciImage ciImage: CIImage)
    {
        let imageRef = ciContext.createCGImage(ciImage, fromRect: ciImage.extent)
        
        displayImage(imageRef: imageRef)
    }
    
    func displayImage(imageRef imageRef: CGImage)
    {
        let uiImage = UIImage(CGImage: imageRef)
        
        imageView.image = uiImage
        
        histogramDisplay.imageRef = imageRef
    }
    
    override func viewDidLoad()
    {
        super.viewDidLoad()
        
        view.addSubview(segmentedControl)
        view.addSubview(imageView)
        view.addSubview(histogramDisplay)
        
        imageView.contentMode = .ScaleAspectFill
        
        displayOriginal()
    }

    override func viewDidLayoutSubviews()
    {
        segmentedControl.frame = CGRect(
            x: 0,
            y: topLayoutGuide.length,
            width: view.frame.width,
            height: segmentedControl.intrinsicContentSize().height).insetBy(dx: 20, dy: 0)
        
        let workingHeight = view.frame.height - topLayoutGuide.length - segmentedControl.intrinsicContentSize().height
        
        histogramDisplay.frame = CGRect(
            x: 0,
            y: topLayoutGuide.length + segmentedControl.intrinsicContentSize().height,
            width: view.frame.width,
            height: workingHeight / 2).insetBy(dx: 20, dy: 20)
        
        imageView.frame =  CGRect(
            x: 0,
            y: topLayoutGuide.length + segmentedControl.intrinsicContentSize().height + (workingHeight / 2),
            width: view.frame.width,
            height: workingHeight / 2).insetBy(dx: 20, dy: 20)

    }

}

// MARK: vImage backed Core Image filters...

var format = vImage_CGImageFormat(
    bitsPerComponent: 8,
    bitsPerPixel: 32,
    colorSpace: nil,
    bitmapInfo: CGBitmapInfo(
        rawValue: CGImageAlphaInfo.Last.rawValue),
    version: 0,
    decode: nil,
    renderingIntent: .RenderingIntentDefault)

class HistogramEqualization: CIFilter
{
    var inputImage: CIImage?
    
    override var attributes: [String : AnyObject]
    {
        return [
            kCIAttributeFilterDisplayName: "Histogram Equalization",
            "inputImage": [kCIAttributeIdentity: 0,
                kCIAttributeClass: "CIImage",
                kCIAttributeDisplayName: "Image",
                kCIAttributeType: kCIAttributeTypeImage]
        ]
    }
    
    lazy var ciContext: CIContext =
        {
            return CIContext()
    }()
    
    override var outputImage: CIImage?
    {
        guard let inputImage = inputImage else
        {
            return nil
        }
        
        let imageRef = ciContext.createCGImage(
            inputImage,
            fromRect: inputImage.extent)
        
        var imageBuffer = vImage_Buffer()
        
        vImageBuffer_InitWithCGImage(
            &imageBuffer,
            &format,
            nil,
            imageRef,
            UInt32(kvImageNoFlags))
        
        let pixelBuffer = malloc(CGImageGetBytesPerRow(imageRef) * CGImageGetHeight(imageRef))
        
        var outBuffer = vImage_Buffer(
            data: pixelBuffer,
            height: UInt(CGImageGetHeight(imageRef)),
            width: UInt(CGImageGetWidth(imageRef)),
            rowBytes: CGImageGetBytesPerRow(imageRef))
        
        
        vImageEqualization_ARGB8888(
            &imageBuffer,
            &outBuffer,
            UInt32(kvImageNoFlags))
        
        let outImage = CIImage(fromvImageBuffer: outBuffer)
        
        free(imageBuffer.data)
        free(pixelBuffer)
        
        return outImage!
    }
}

class ContrastStretch: CIFilter
{
    var inputImage: CIImage?
    
    override var attributes: [String : AnyObject]
    {
        return [
            kCIAttributeFilterDisplayName: "Contrast Stretch",
            "inputImage": [kCIAttributeIdentity: 0,
                kCIAttributeClass: "CIImage",
                kCIAttributeDisplayName: "Image",
                kCIAttributeType: kCIAttributeTypeImage]
        ]
    }
    
    lazy var ciContext: CIContext =
        {
            return CIContext()
    }()
    
    override var outputImage: CIImage?
    {
        guard let inputImage = inputImage else
        {
            return nil
        }
        
        let imageRef = ciContext.createCGImage(
            inputImage,
            fromRect: inputImage.extent)
        
        var imageBuffer = vImage_Buffer()
        
        vImageBuffer_InitWithCGImage(
            &imageBuffer,
            &format,
            nil,
            imageRef,
            UInt32(kvImageNoFlags))
        
        let pixelBuffer = malloc(CGImageGetBytesPerRow(imageRef) * CGImageGetHeight(imageRef))
        
        var outBuffer = vImage_Buffer(
            data: pixelBuffer,
            height: UInt(CGImageGetHeight(imageRef)),
            width: UInt(CGImageGetWidth(imageRef)),
            rowBytes: CGImageGetBytesPerRow(imageRef))
        
        vImageContrastStretch_ARGB8888(
            &imageBuffer,
            &outBuffer,
            UInt32(kvImageNoFlags))
        
        let outImage = CIImage(fromvImageBuffer: outBuffer)
        
        free(imageBuffer.data)
        free(pixelBuffer)
        
        return outImage!
    }
}


extension CIImage
{
    convenience init?(fromvImageBuffer: vImage_Buffer)
    {
        var mutableBuffer = fromvImageBuffer
        var error = vImage_Error()
        
        let cgImage = vImageCreateCGImageFromBuffer(
            &mutableBuffer,
            &format,
            nil,
            nil,
            UInt32(kvImageNoFlags),
            &error)
        
        self.init(CGImage: cgImage.takeRetainedValue())
    }
}
