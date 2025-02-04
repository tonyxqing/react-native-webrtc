#if !TARGET_OS_TV

#import "VideoCaptureController.h"

#import <AVFoundation/AVFoundation.h>
#import <AssetsLibrary/ALAssetsLibrary.h>
#import <ImageIO/ImageIO.h>
#import <React/RCTLog.h>

@interface VideoCaptureController ()

@property(nonatomic, strong) RTCCameraVideoCapturer *capturer;
@property(nonatomic, strong) AVCaptureDeviceFormat *selectedFormat;
@property(nonatomic, strong) AVCaptureDevice *device;
@property(nonatomic, copy) NSString *deviceId;
@property(nonatomic, assign) BOOL running;
@property(nonatomic, assign) BOOL usingFrontCamera;
@property(nonatomic, assign) int width;
@property(nonatomic, assign) int height;
@property(nonatomic, assign) int frameRate;

@end

@implementation VideoCaptureController

typedef NS_ENUM(NSInteger, RCTCameraCaptureTarget) {
    RCTCameraCaptureTargetMemory = 0,
    RCTCameraCaptureTargetDisk = 1,
    RCTCameraCaptureTargetTemp = 2,
    RCTCameraCaptureTargetCameraRoll = 3
};

AVCaptureStillImageOutput *stillImageOutput = nil;

- (void)takePicture:(NSDictionary *)options
    successCallback:(RCTResponseSenderBlock)successCallback
      errorCallback:(RCTResponseSenderBlock)errorCallback {
    NSInteger captureTarget = [[options valueForKey:@"captureTarget"] intValue];
    NSInteger maxSize = [[options valueForKey:@"maxSize"] intValue];
    CGFloat jpegQuality = [[options valueForKey:@"maxJpegQuality"] floatValue];
    if (jpegQuality < 0) {
        jpegQuality = 0;
    } else if (jpegQuality > 1) {
        jpegQuality = 1;
    }
    [stillImageOutput
        captureStillImageAsynchronouslyFromConnection:[stillImageOutput connectionWithMediaType:AVMediaTypeVideo]
                                    completionHandler:^(CMSampleBufferRef imageDataSampleBuffer, NSError *error) {
                                        if (imageDataSampleBuffer) {
                                            NSData *imageData = [AVCaptureStillImageOutput
                                                jpegStillImageNSDataRepresentation:imageDataSampleBuffer];
                                            // Create image source
                                            CGImageSourceRef source =
                                                CGImageSourceCreateWithData((CFDataRef)imageData, NULL);
                                            // Get all the metadata in the image
                                            NSMutableDictionary *imageMetadata = [(NSDictionary *)CFBridgingRelease(
                                                CGImageSourceCopyPropertiesAtIndex(source, 0, NULL)) mutableCopy];
                                            // Create cgimage
                                            CGImageRef CGImage = CGImageSourceCreateImageAtIndex(source, 0, NULL);
                                            // Resize cgimage
                                            CGImage = [self resizeCGImage:CGImage maxSize:maxSize];
                                            // Rotate it
                                            CGImageRef rotatedCGImage;
                                            // Get metadata orientation
                                            if ([[UIDevice currentDevice] orientation] ==
                                                UIInterfaceOrientationLandscapeLeft) {
                                                if (self->_usingFrontCamera) {
                                                    rotatedCGImage = [self newCGImageRotatedByAngle:CGImage angle:0]; 
                                                }
                                                else {
                                                    rotatedCGImage = [self newCGImageRotatedByAngle:CGImage angle:180];
                                                }
                                            } else if ([[UIDevice currentDevice] orientation] ==
                                                UIInterfaceOrientationLandscapeRight) {
                                                if (self->_usingFrontCamera) {
                                                    rotatedCGImage = [self newCGImageRotatedByAngle:CGImage angle:180];
                                                }
                                                else {
                                                    rotatedCGImage = [self newCGImageRotatedByAngle:CGImage angle:0];
                                                }
                                            } else if ([[UIDevice currentDevice] orientation] ==
                                                UIInterfaceOrientationPortrait) {
                                                if (self->_usingFrontCamera) {
                                                    rotatedCGImage = [self newCGImageRotatedByAngle:CGImage angle:90];
                                                }
                                                else {
                                                    rotatedCGImage = [self newCGImageRotatedByAngle:CGImage angle:270];
                                                }
                                            } else {
                                                if (self->_usingFrontCamera) {
                                                    rotatedCGImage = [self newCGImageRotatedByAngle:CGImage angle:270];
                                                }
                                                else {
                                                    rotatedCGImage = [self newCGImageRotatedByAngle:CGImage angle:90];
                                                }
                                            }
                                            /*
                                            if (metadataOrientation == 6) {
                                                rotatedCGImage = [self newCGImageRotatedByAngle:CGImage angle:270];
                                            } else if (metadataOrientation == 1) {
                                                rotatedCGImage = [self newCGImageRotatedByAngle:CGImage angle:0];
                                            } else if (metadataOrientation == 3) {
                                                rotatedCGImage = [self newCGImageRotatedByAngle:CGImage angle:180];
                                            } else {
                                                rotatedCGImage = [self newCGImageRotatedByAngle:CGImage angle:0];
                                            }*/
                                            CGImageRelease(CGImage);
                                            // Erase metadata orientation
                                            [imageMetadata removeObjectForKey:(NSString *)kCGImagePropertyOrientation];
                                            // Erase stupid TIFF stuff
                                            [imageMetadata
                                                removeObjectForKey:(NSString *)kCGImagePropertyTIFFDictionary];
                                            // Create destination thing
                                            NSMutableData *rotatedImageData = [NSMutableData data];
                                            CGImageDestinationRef destinationRef =
                                                CGImageDestinationCreateWithData((CFMutableDataRef)rotatedImageData,
                                                                                 CGImageSourceGetType(source),
                                                                                 1,
                                                                                 NULL);
                                            CFRelease(source);
                                            // Set compression
                                            NSDictionary *properties = @{
                                                (__bridge NSString *)
                                                kCGImageDestinationLossyCompressionQuality : @(jpegQuality)
                                            };
                                            CGImageDestinationSetProperties(destinationRef,
                                                                            (__bridge CFDictionaryRef)properties);
                                            // Add the image to the destination, reattaching metadata
                                            CGImageDestinationAddImage(
                                                destinationRef, rotatedCGImage, (CFDictionaryRef)imageMetadata);
                                            // And write
                                            CGImageDestinationFinalize(destinationRef);
                                            CFRelease(destinationRef);
                                            [self saveImage:rotatedImageData
                                                     target:captureTarget
                                                   metadata:imageMetadata
                                                    success:successCallback
                                                      error:errorCallback];
                                        } else {
                                            errorCallback(@[ error.description ]);
                                        }
                                    }];
}
- (CGImageRef)resizeCGImage:(CGImageRef)image maxSize:(int)maxSize {
    size_t originalWidth = CGImageGetWidth(image);
    size_t originalHeight = CGImageGetHeight(image);
    // only resize if image larger than maxSize
    if (originalWidth <= maxSize && originalHeight <= maxSize) {
        return image;
    }
    size_t newWidth = originalWidth;
    size_t newHeight = originalHeight;
    // first check if we need to scale width
    if (originalWidth > maxSize) {
        // scale width to fit
        newWidth = maxSize;
        // scale height to maintain aspect ratio
        newHeight = (newWidth * originalHeight) / originalWidth;
    }
    // then check if we need to scale even with the new height
    if (newHeight > maxSize) {
        // scale height to fit instead
        newHeight = maxSize;
        // scale width to maintain aspect ratio
        newWidth = (newHeight * originalWidth) / originalHeight;
    }
    // create context, keeping original image properties
    CGColorSpaceRef colorspace = CGImageGetColorSpace(image);
    CGContextRef context = CGBitmapContextCreate(NULL,
                                                 newWidth,
                                                 newHeight,
                                                 CGImageGetBitsPerComponent(image),
                                                 CGImageGetBytesPerRow(image),
                                                 colorspace,
                                                 CGImageGetAlphaInfo(image));
    CGColorSpaceRelease(colorspace);
    if (context == NULL)
        return image;
    // draw image to context (resizing it)
    CGContextDrawImage(context, CGRectMake(0, 0, newWidth, newHeight), image);
    // extract resulting image from context
    CGImageRef imgRef = CGBitmapContextCreateImage(context);
    CGContextRelease(context);
    return imgRef;
}
- (void)saveImage:(NSData *)imageData
           target:(NSInteger)target
         metadata:(NSDictionary *)metadata
          success:(RCTResponseSenderBlock)successCallback
            error:(RCTResponseSenderBlock)errorCallback {
    if (target == RCTCameraCaptureTargetMemory) {
        NSString *base64encodedImage = [imageData base64EncodedStringWithOptions:0];
        successCallback(@[ base64encodedImage ]);
        return;
    } else if (target == RCTCameraCaptureTargetDisk) {
        NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
        NSString *documentsDirectory = [paths firstObject];
        NSFileManager *fileManager = [NSFileManager defaultManager];
        NSString *fullPath = [[documentsDirectory stringByAppendingPathComponent:[[NSUUID UUID] UUIDString]]
            stringByAppendingPathExtension:@"jpg"];
        [fileManager createFileAtPath:fullPath contents:imageData attributes:nil];
        successCallback(@[ fullPath ]);
        return;
    } else if (target == RCTCameraCaptureTargetCameraRoll) {
        [[[ALAssetsLibrary alloc] init] writeImageDataToSavedPhotosAlbum:imageData
                                                                metadata:metadata
                                                         completionBlock:^(NSURL *url, NSError *error) {
                                                             if (error == nil) {
                                                                 successCallback(@[ [url absoluteString] ]);
                                                             } else {
                                                                 errorCallback(@[ error.description ]);
                                                             }
                                                         }];
        return;
    } else if (target == RCTCameraCaptureTargetTemp) {
        NSString *fileName = [[NSProcessInfo processInfo] globallyUniqueString];
        NSString *fullPath = [NSString stringWithFormat:@"%@%@.jpg", NSTemporaryDirectory(), fileName];
        // TODO: check if image successfully stored
        [imageData writeToFile:fullPath atomically:YES];
        successCallback(@[ fullPath ]);
        // NSError* error;
        // [imageData writeToFile:fullPath atomically:YES error:&error];
        // if(error != nil) {
        //     errorCallback(@[error.description]);
        // } else {
        //     successCallback(@[fullPath])
        // }
    }
}
- (CGImageRef)newCGImageRotatedByAngle:(CGImageRef)imgRef angle:(CGFloat)angle {
    CGFloat angleInRadians = angle * (M_PI / 180);
    CGFloat width = CGImageGetWidth(imgRef);
    CGFloat height = CGImageGetHeight(imgRef);
    CGRect imgRect = CGRectMake(0, 0, width, height);
    CGAffineTransform transform = CGAffineTransformMakeRotation(angleInRadians);
    CGRect rotatedRect = CGRectApplyAffineTransform(imgRect, transform);
    CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
    CGContextRef bmContext = CGBitmapContextCreate(NULL,
                                                   rotatedRect.size.width,
                                                   rotatedRect.size.height,
                                                   8,
                                                   0,
                                                   colorSpace,
                                                   (CGBitmapInfo)kCGImageAlphaPremultipliedFirst);
    // if (self.mirrorImage) {
    //     CGAffineTransform transform = CGAffineTransformMakeTranslation(rotatedRect.size.width, 0.0);
    //     transform = CGAffineTransformScale(transform, -1.0, 1.0);
    //     CGContextConcatCTM(bmContext, transform);
    // }
    CGContextSetAllowsAntialiasing(bmContext, TRUE);
    CGContextSetInterpolationQuality(bmContext, kCGInterpolationNone);
    CGColorSpaceRelease(colorSpace);
    CGContextTranslateCTM(bmContext, +(rotatedRect.size.width / 2), +(rotatedRect.size.height / 2));
    CGContextRotateCTM(bmContext, angleInRadians);
    CGContextTranslateCTM(bmContext, -(rotatedRect.size.width / 2), -(rotatedRect.size.height / 2));
    CGContextDrawImage(
        bmContext,
        CGRectMake((rotatedRect.size.width - width) / 2.0f, (rotatedRect.size.height - height) / 2.0f, width, height),
        imgRef);
    CGImageRef rotatedImage = CGBitmapContextCreateImage(bmContext);
    CFRelease(bmContext);
    return rotatedImage;
}
- (instancetype)initWithCapturer:(RTCCameraVideoCapturer *)capturer andConstraints:(NSDictionary *)constraints {
    self = [super init];
    if (self) {
        self.capturer = capturer;
        self.running = NO;

        // Default to the front camera.
        self.usingFrontCamera = YES;

        self.deviceId = constraints[@"deviceId"];
        self.width = [constraints[@"width"] intValue];
        self.height = [constraints[@"height"] intValue];
        self.frameRate = [constraints[@"frameRate"] intValue];

        id facingMode = constraints[@"facingMode"];

        if (facingMode && [facingMode isKindOfClass:[NSString class]]) {
            AVCaptureDevicePosition position;
            if ([facingMode isEqualToString:@"environment"]) {
                position = AVCaptureDevicePositionBack;
            } else if ([facingMode isEqualToString:@"user"]) {
                position = AVCaptureDevicePositionFront;
            } else {
                // If the specified facingMode value is not supported, fall back
                // to the front camera.
                position = AVCaptureDevicePositionFront;
            }

            self.usingFrontCamera = position == AVCaptureDevicePositionFront;
        }
    }

    return self;
}

- (void)dealloc {
    self.device = NULL;
}

- (void)startCapture {
    if (self.deviceId) {
        self.device = [AVCaptureDevice deviceWithUniqueID:self.deviceId];
    }
    if (!self.device) {
        AVCaptureDevicePosition position =
            self.usingFrontCamera ? AVCaptureDevicePositionFront : AVCaptureDevicePositionBack;
        self.device = [self findDeviceForPosition:position];
    }

    if (!self.device) {
        RCTLogWarn(@"[VideoCaptureController] No capture devices found!");

        return;
    }

    AVCaptureDeviceFormat *format = [self selectFormatForDevice:self.device
                                                withTargetWidth:self.width
                                               withTargetHeight:self.height];
    if (!format) {
        RCTLogWarn(@"[VideoCaptureController] No valid formats for device %@", self.device);

        return;
    }

    self.selectedFormat = format;

    RCTLog(@"[VideoCaptureController] Capture will start");

    // Starting the capture happens on another thread. Wait for it.
    dispatch_semaphore_t semaphore = dispatch_semaphore_create(0);

    __weak VideoCaptureController *weakSelf = self;
    [self.capturer
        startCaptureWithDevice:self.device
                        format:format
                           fps:self.frameRate
             completionHandler:^(NSError *err) {
                 if (err) {
                     RCTLogError(@"[VideoCaptureController] Error starting capture: %@", err);
                 } else {
                     AVCaptureSession *capSession = _capturer.captureSession;
                     if (stillImageOutput != nil) {
                         [capSession removeOutput:stillImageOutput];
                         stillImageOutput = nil;
                     }

                     stillImageOutput = [[AVCaptureStillImageOutput alloc] init];
                     [stillImageOutput setHighResolutionStillImageOutputEnabled:true];
                     NSDictionary *outputSettings = @{AVVideoCodecKey : AVVideoCodecJPEG};
                     [stillImageOutput setOutputSettings:outputSettings];
                     if ([capSession canAddOutput:stillImageOutput]) {
                         [capSession addOutput:stillImageOutput];
                     } else {
                         NSLog(@"[VideoCaptureController] Failed to add stillImageOutput, snapshot is not working");
                     }

                     RCTLog(@"[VideoCaptureController] Capture started");
                     weakSelf.running = YES;
                 }
                 dispatch_semaphore_signal(semaphore);
             }];

    dispatch_semaphore_wait(semaphore, DISPATCH_TIME_FOREVER);
}

- (void)stopCapture {
    if (!self.running)
        return;

    RCTLog(@"[VideoCaptureController] Capture will stop");
    // Stopping the capture happens on another thread. Wait for it.
    dispatch_semaphore_t semaphore = dispatch_semaphore_create(0);

    __weak VideoCaptureController *weakSelf = self;
    [self.capturer stopCaptureWithCompletionHandler:^{
        if (stillImageOutput != nil) {
            stillImageOutput = nil;
        }
        RCTLog(@"[VideoCaptureController] Capture stopped");
        weakSelf.running = NO;
        weakSelf.device = nil;

        dispatch_semaphore_signal(semaphore);
    }];

    dispatch_semaphore_wait(semaphore, DISPATCH_TIME_FOREVER);
}

- (void)switchCamera {
    self.usingFrontCamera = !self.usingFrontCamera;
    self.deviceId = nil;
    self.device = nil;

    [self startCapture];
}

#pragma mark NSKeyValueObserving

- (void)observeValueForKeyPath:(NSString *)keyPath
                      ofObject:(id)object
                        change:(NSDictionary<NSKeyValueChangeKey, id> *)change
                       context:(void *)context {
    if (@available(iOS 11.1, *)) {
        if ([object isKindOfClass:[AVCaptureDevice class]] && [keyPath isEqualToString:@"systemPressureState"]) {
            AVCaptureDevice *device = (AVCaptureDevice *)object;
            AVCaptureSystemPressureLevel pressureLevel =
                ((AVCaptureSystemPressureState *)change[NSKeyValueChangeNewKey]).level;
            if (pressureLevel == AVCaptureSystemPressureLevelSerious ||
                pressureLevel == AVCaptureSystemPressureLevelCritical) {
                RCTLogWarn(
                    @"[VideoCaptureController] Reached elevated system pressure level: %@. Throttling frame rate.",
                    pressureLevel);
                [self throttleFrameRateForDevice:device];
            } else if (pressureLevel == AVCaptureSystemPressureLevelNominal) {
                RCTLogWarn(@"[VideoCaptureController] Restored normal system pressure level. Resetting frame rate to "
                           @"default.");
                [self resetFrameRateForDevice:device];
            }
        }
    }
}

- (void)registerSystemPressureStateObserverForDevice:(AVCaptureDevice *)device {
    if (@available(iOS 11.1, *)) {
        [device addObserver:self forKeyPath:@"systemPressureState" options:NSKeyValueObservingOptionNew context:nil];
    }
}

- (void)removeObserverForDevice:(AVCaptureDevice *)device {
    if (@available(iOS 11.1, *)) {
        [device removeObserver:self forKeyPath:@"systemPressureState"];
    }
}

#pragma mark Private

- (void)setDevice:(AVCaptureDevice *)device {
    if (_device) {
        [self removeObserverForDevice:_device];
    }
    if (device) {
        [self registerSystemPressureStateObserverForDevice:device];
    }

    _device = device;
}

- (AVCaptureDevice *)findDeviceForPosition:(AVCaptureDevicePosition)position {
    NSArray<AVCaptureDevice *> *captureDevices = [RTCCameraVideoCapturer captureDevices];
    for (AVCaptureDevice *device in captureDevices) {
        if (device.position == position) {
            return device;
        }
    }

    return [captureDevices firstObject];
}

- (AVCaptureDeviceFormat *)selectFormatForDevice:(AVCaptureDevice *)device
                                 withTargetWidth:(int)targetWidth
                                withTargetHeight:(int)targetHeight {
    NSArray<AVCaptureDeviceFormat *> *formats = [RTCCameraVideoCapturer supportedFormatsForDevice:device];
    AVCaptureDeviceFormat *selectedFormat = nil;
    int currentDiff = INT_MAX;

    for (AVCaptureDeviceFormat *format in formats) {
        CMVideoDimensions dimension = CMVideoFormatDescriptionGetDimensions(format.formatDescription);
        FourCharCode pixelFormat = CMFormatDescriptionGetMediaSubType(format.formatDescription);
        int diff = abs(targetWidth - dimension.width) + abs(targetHeight - dimension.height);
        if (diff < currentDiff) {
            selectedFormat = format;
            currentDiff = diff;
        } else if (diff == currentDiff && pixelFormat == [_capturer preferredOutputPixelFormat]) {
            selectedFormat = format;
        }
    }

    return selectedFormat;
}

- (void)throttleFrameRateForDevice:(AVCaptureDevice *)device {
    NSError *error = nil;

    [device lockForConfiguration:&error];
    if (error) {
        RCTLog(@"[VideoCaptureController] Could not lock device for configuration: %@", error);
        return;
    }

    device.activeVideoMinFrameDuration = CMTimeMake(1, 20);
    device.activeVideoMaxFrameDuration = CMTimeMake(1, 15);

    [device unlockForConfiguration];
}

- (void)resetFrameRateForDevice:(AVCaptureDevice *)device {
    NSError *error = nil;

    [device lockForConfiguration:&error];
    if (error) {
        RCTLog(@"[VideoCaptureController] Could not lock device for configuration: %@", error);
        return;
    }

    device.activeVideoMinFrameDuration = kCMTimeInvalid;
    device.activeVideoMaxFrameDuration = kCMTimeInvalid;

    [device unlockForConfiguration];
}

@end

#endif