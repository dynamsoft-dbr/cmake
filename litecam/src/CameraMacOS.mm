#include "Camera.h"
#include <iostream>
#import <AVFoundation/AVFoundation.h>
#include <mutex>
#include <condition_variable>

@interface CaptureDelegate : NSObject <AVCaptureVideoDataOutputSampleBufferDelegate>
{
    FrameData *frame;
    std::mutex *frameMutex;
    std::condition_variable *frameCondition;
    bool *frameReady;
}

- (instancetype)initWithFrame:(FrameData *)frame
                    frameMutex:(std::mutex *)frameMutex
               frameCondition:(std::condition_variable *)frameCondition
                   frameReady:(bool *)frameReady;

@end

@implementation CaptureDelegate

- (instancetype)initWithFrame:(FrameData *)frame
                    frameMutex:(std::mutex *)frameMutex
               frameCondition:(std::condition_variable *)frameCondition
                   frameReady:(bool *)frameReady {
    self = [super init];
    if (self) {
        self->frame = frame;
        self->frameMutex = frameMutex;
        self->frameCondition = frameCondition;
        self->frameReady = frameReady;
    }
    return self;
}

- (void)captureOutput:(AVCaptureOutput *)output
 didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer
        fromConnection:(AVCaptureConnection *)connection {
    CVImageBufferRef imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer);
    if (!imageBuffer) {
        std::cerr << "Failed to get image buffer." << std::endl;
        return;
    }

    CVPixelBufferLockBaseAddress(imageBuffer, kCVPixelBufferLock_ReadOnly);

    size_t bytesPerRow = CVPixelBufferGetBytesPerRow(imageBuffer);
    size_t height = CVPixelBufferGetHeight(imageBuffer);
    size_t width = CVPixelBufferGetWidth(imageBuffer);
    void *baseAddress = CVPixelBufferGetBaseAddress(imageBuffer);

    {
        std::lock_guard<std::mutex> lock(*frameMutex);

        frame->width = width;
        frame->height = height;
        frame->size = width * height * 3;
        frame->rgbData = new unsigned char[frame->size];

        OSType pixelFormat = CVPixelBufferGetPixelFormatType(imageBuffer);
        if (pixelFormat == kCVPixelFormatType_32BGRA) {
            unsigned char *src = (unsigned char *)baseAddress;
            unsigned char *dst = frame->rgbData;

            for (size_t y = 0; y < height; ++y) {
                for (size_t x = 0; x < width; ++x) {
                    size_t offset = y * bytesPerRow + x * 4;
                    dst[0] = src[offset + 2]; // R
                    dst[1] = src[offset + 1]; // G
                    dst[2] = src[offset + 0]; // B
                    dst += 3;
                }
            }
        } else {
            std::cerr << "Unsupported pixel format." << std::endl;
        }

        *frameReady = true;
    }

    frameCondition->notify_one();

    CVPixelBufferUnlockBaseAddress(imageBuffer, kCVPixelBufferLock_ReadOnly);
}


@end

// Camera class implementation for macOS
Camera::Camera() noexcept: captureSession(nullptr), frameWidth(1920), frameHeight(1080) {}

Camera::~Camera()
{
    Release();
}

bool Camera::Open(int cameraIndex)
{
    @autoreleasepool {
        // Get available capture devices
        NSArray<AVCaptureDevice *> *devices = [AVCaptureDevice devicesWithMediaType:AVMediaTypeVideo];
        if (cameraIndex >= [devices count])
        {
            std::cerr << "Camera index out of range." << std::endl;
            return false;
        }

        AVCaptureDevice *device = devices[cameraIndex];

        NSError *error = nil;
        AVCaptureDeviceInput *input = [AVCaptureDeviceInput deviceInputWithDevice:device error:&error];
        if (!input)
        {
            std::cerr << "Error creating device input: " << [[error localizedDescription] UTF8String] << std::endl;
            return false;
        }

        AVCaptureSession *cs = [[AVCaptureSession alloc] init];
        captureSession = (void *)cs;
        if (![cs canAddInput:input])
        {
            std::cerr << "Cannot add device input to session." << std::endl;
            return false;
        }
        [cs addInput:input];

        // Configure output
        AVCaptureVideoDataOutput *output = [[AVCaptureVideoDataOutput alloc] init];
        output.videoSettings = @{(NSString *)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA)};
        output.alwaysDiscardsLateVideoFrames = YES;

        videoOutput = (void *)output;

        if (![cs canAddOutput:output])
        {
            std::cerr << "Cannot add video output to session." << std::endl;
            return false;
        }
        [cs addOutput:output];

        [cs startRunning];

        return true;
    }
}

void Camera::Release() {
    if (captureSession) {
        AVCaptureSession *session = (__bridge AVCaptureSession *)captureSession;
        [session stopRunning];
        captureSession = nullptr;
    }

    if (videoOutput) {
        videoOutput = nullptr;
    }
}

FrameData Camera::CaptureFrame() {
    static FrameData frame;
    static std::mutex frameMutex;
    static std::condition_variable frameCondition;
    static bool frameReady = false;

    @autoreleasepool {
        if (!captureSession || !videoOutput) {
            std::cerr << "Capture session is not initialized." << std::endl;
            return frame;
        }

        AVCaptureSession *session = (__bridge AVCaptureSession *)captureSession;
        AVCaptureVideoDataOutput *output = (__bridge AVCaptureVideoDataOutput *)videoOutput;

        CaptureDelegate *delegate = [[CaptureDelegate alloc] initWithFrame:&frame
                                                                frameMutex:&frameMutex
                                                           frameCondition:&frameCondition
                                                               frameReady:&frameReady];
        [output setSampleBufferDelegate:delegate queue:dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0)];

        std::unique_lock<std::mutex> lock(frameMutex);
        frameCondition.wait(lock, [&]() { return frameReady; });
        frameReady = false;
        frameWidth = frame.width;
        frameHeight = frame.height;
        return frame;
    }
}

bool Camera::SetResolution(int width, int height)
{
    frameWidth = width;
    frameHeight = height;

    if (captureSession)
    {
        AVCaptureSession *session = (__bridge AVCaptureSession *)captureSession;
        [session beginConfiguration];

        // Iterate over formats and find the one with the desired resolution
        for (AVCaptureDeviceFormat *format in [[session.inputs.firstObject device] formats])
        {
            CMVideoDimensions dimensions = CMVideoFormatDescriptionGetDimensions(format.formatDescription);
            if (dimensions.width == width && dimensions.height == height)
            {
                NSError *error = nil;
                AVCaptureDevice *device = [session.inputs.firstObject device];

                // Lock for configuration
                if ([device lockForConfiguration:&error])
                {
                    // Set the active format
                    [device setActiveFormat:format];

                    // Verify the resolution was set by checking the active format
                    CMVideoDimensions currentDimensions = CMVideoFormatDescriptionGetDimensions(device.activeFormat.formatDescription);
                    if (currentDimensions.width == width && currentDimensions.height == height)
                    {
                        std::cout << "Resolution set successfully to " << width << "x" << height << std::endl;
                    }
                    else
                    {
                        std::cerr << "Failed to set resolution." << std::endl;
                    }

                    // Unlock configuration
                    [device unlockForConfiguration];
                    break;
                }
                else
                {
                    std::cerr << "Error setting resolution: " << [[error localizedDescription] UTF8String] << std::endl;
                }
            }
        }

        [session commitConfiguration];
    }

    return true;
}


std::vector<CaptureDeviceInfo> ListCaptureDevices()
{
    @autoreleasepool {
        std::vector<CaptureDeviceInfo> devicesInfo;

        NSArray<AVCaptureDevice *> *devices = [AVCaptureDevice devicesWithMediaType:AVMediaTypeVideo];
        for (AVCaptureDevice *device in devices)
        {
            CaptureDeviceInfo info = {};
            strncpy(info.friendlyName, [[device localizedName] UTF8String], sizeof(info.friendlyName) - 1);
            devicesInfo.push_back(info);
        }

        return devicesInfo;
    }
}

std::vector<MediaTypeInfo> Camera::ListSupportedMediaTypes()
{
    std::vector<MediaTypeInfo> mediaTypes;

    AVCaptureSession *session = (__bridge AVCaptureSession *)captureSession;

    if (!session || session.inputs.count == 0) {
        std::cerr << "No inputs found in capture session." << std::endl;
        return mediaTypes;
    }

    AVCaptureDeviceInput *input = (__bridge AVCaptureDeviceInput *)session.inputs.firstObject;
    AVCaptureDevice *device = input.device;

    if (!device) {
        std::cerr << "No device found." << std::endl;
        return mediaTypes;
    }

    for (AVCaptureDeviceFormat *format in device.formats) {
        MediaTypeInfo mediaType = {};
        CMFormatDescriptionRef formatDescription = format.formatDescription;
        FourCharCode mediaSubType = CMFormatDescriptionGetMediaSubType(formatDescription);

        // Store width and height
        CMVideoDimensions dimensions = CMVideoFormatDescriptionGetDimensions(formatDescription);
        mediaType.width = dimensions.width;
        mediaType.height = dimensions.height;

        // Convert mediaSubType to a string
        snprintf(mediaType.subtypeName, sizeof(mediaType.subtypeName), "Format %.4s", (char *)&mediaSubType);

        mediaTypes.push_back(mediaType);
    }

    return mediaTypes;
}