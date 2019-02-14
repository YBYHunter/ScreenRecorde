//
//  SRScreenRecorder.m
//  ScreenRecorder
//
//  Created by kishikawa katsumi on 2012/12/26.
//  Copyright (c) 2012年 kishikawa katsumi. All rights reserved.
//

//ios 将音频和图片合成为视频
//https://www.jianshu.com/p/ae2262711abe

#import "SRScreenRecorder.h"
#import "STAudioManager.h"
#import "AACEncoder.h"

#import "KTouchPointerWindow.h"

#ifndef APPSTORE_SAFE
#define APPSTORE_SAFE 1
#endif

#define DEFAULT_FRAME_INTERVAL 2
#define DEFAULT_AUTOSAVE_DURATION 600
#define TIME_SCALE 600

static NSInteger counter;

#if !APPSTORE_SAFE
CGImageRef UICreateCGImageFromIOSurface(CFTypeRef surface);
#ifndef __IPHONE_11_0
CVReturn CVPixelBufferCreateWithIOSurface(
                                          CFAllocatorRef allocator,
                                          CFTypeRef surface,
                                          CFDictionaryRef pixelBufferAttributes,
                                          CVPixelBufferRef *pixelBufferOut);
#endif

@interface UIWindow (ScreenRecorder)
+ (IOSurfaceRef)createScreenIOSurface;
+ (IOSurfaceRef)createIOSurfaceFromScreen:(UIScreen *)screen;
- (IOSurfaceRef)createIOSurface;
- (IOSurfaceRef)createIOSurfaceWithFrame:(CGRect)frame;
@end
#endif

@interface SRScreenRecorder () <STAudioManagerDelegate>

@property (nonatomic, assign) BOOL haveStartedSession;
@property (strong, nonatomic) AVAssetWriter *writer;
@property (strong, nonatomic) AVAssetWriterInput *writerInput; //输入帧图片
@property (strong, nonatomic) AVAssetWriterInputPixelBufferAdaptor *writerInputPixelBufferAdaptor;
@property (strong, nonatomic) CADisplayLink *displayLink;
@property (nonatomic, strong) STAudioManager *audioManager;
@property (nonatomic, assign) BOOL isRecording;
@property (nonatomic, assign) BOOL allowWriteAudio;
@property (nonatomic, strong) NSURL *currentVideoUrl;
@property(nonatomic, copy) NSString *audioFilePath;
@property (nonatomic, strong) NSFileHandle *audiFileHandle;
@property(nonatomic, strong) AACEncoder *aacEncoder;

@end

@implementation SRScreenRecorder {
	CFAbsoluteTime firstFrameTime;
    CFTimeInterval startTimestamp;
    BOOL shouldRestart;

    dispatch_queue_t recorderQueue;
}

- (instancetype)initWithWindow:(UIWindow *)window
{
    self = [super init];
    if (self) {
        _window = window;
        _frameInterval = DEFAULT_FRAME_INTERVAL;
        _autosaveDuration = DEFAULT_AUTOSAVE_DURATION;
        _showsTouchPointer = YES;
        _isRecording = NO;
        _allowWriteAudio = NO;
        _currentVideoUrl = nil;
        _screenRecorderStatue = ScreenRecorderStatueNone;
        
        counter++;
        NSString *recorderLabel = [NSString stringWithFormat:@"com.kishikawakatsumi.screen_recorder_recorder-%@", @(counter)];
        recorderQueue = dispatch_queue_create([recorderLabel cStringUsingEncoding:NSUTF8StringEncoding], NULL);

        [self setupNotifications];
        
        
        
    }
    return self;
}

- (void)dealloc
{
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [self stopRecording:nil];
}

#pragma mark Setup

- (void)setupAssetWriterWithURL:(NSURL *)outputURL
{
    NSError *error = nil;
    
    self.writer = [[AVAssetWriter alloc] initWithURL:outputURL fileType:AVFileTypeQuickTimeMovie error:&error];
    NSParameterAssert(self.writer);
    if (error) {
        NSLog(@"Error: %@", [error localizedDescription]);
    }
    
    UIScreen *mainScreen = [UIScreen mainScreen];
#if APPSTORE_SAFE
    CGSize size = mainScreen.bounds.size;
#else
    CGRect nativeBounds = [mainScreen nativeBounds];
    CGSize size = nativeBounds.size;
#endif
    
    NSDictionary *outputSettings = @{AVVideoCodecKey : AVVideoCodecH264, AVVideoWidthKey : @(size.width), AVVideoHeightKey : @(size.height)};
    self.writerInput = [AVAssetWriterInput assetWriterInputWithMediaType:AVMediaTypeVideo outputSettings:outputSettings];
	self.writerInput.expectsMediaDataInRealTime = YES;
    NSDictionary *sourcePixelBufferAttributes = @{(NSString *)kCVPixelBufferPixelFormatTypeKey : @(kCVPixelFormatType_32ARGB)};
    self.writerInputPixelBufferAdaptor = [AVAssetWriterInputPixelBufferAdaptor assetWriterInputPixelBufferAdaptorWithAssetWriterInput:self.writerInput sourcePixelBufferAttributes:sourcePixelBufferAttributes];
    NSParameterAssert(self.writerInput);
    NSParameterAssert([self.writer canAddInput:self.writerInput]);
    [self.writer addInput:self.writerInput];
    
	firstFrameTime = CFAbsoluteTimeGetCurrent();
}

- (void)setupTouchPointer
{
    if (self.showsTouchPointer) {
        KTouchPointerWindowInstall();
    } else {
        KTouchPointerWindowUninstall();
    }
}

- (void)setupNotifications
{
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(applicationDidEnterBackground:) name:UIApplicationDidEnterBackgroundNotification object:nil];
}

- (void)setupTimer
{
    self.displayLink = [CADisplayLink displayLinkWithTarget:self selector:@selector(captureFrame:)];
    self.displayLink.frameInterval = self.frameInterval;
    [self.displayLink addToRunLoop:[NSRunLoop currentRunLoop] forMode:NSRunLoopCommonModes];
}

#pragma mark Recording

- (void)startRecording
{
    if (_screenRecorderStatue == ScreenRecorderStatueIng) {
        return;
    }
    _screenRecorderStatue = ScreenRecorderStatueIng;
    //test code
    [self setupTouchPointer];

    //生成视频地址(无声音)
    NSURL *outputFileURL = [self outputFileURL];
    _currentVideoUrl = outputFileURL;
    //开启录制屏幕
    [self setupAssetWriterWithURL:outputFileURL];
    [self setupTimer];
    [self.writer startWriting];
    [self.writer startSessionAtSourceTime:kCMTimeZero];
    
    _audioFilePath = [[self outputAudioFileURL] path];
    _audiFileHandle = [NSFileHandle fileHandleForWritingAtPath:_audioFilePath];
    [self.audioManager startRunning];
    NSLog(@"开始录制");
}

- (void)stopRecording:(void (^)(NSURL *filePath))block
{
    if (_screenRecorderStatue == ScreenRecorderStatueEnd) {
        return;
    }
    NSLog(@"录制结束");
    _isRecording = NO;
    [self.displayLink invalidate];
    startTimestamp = 0.0;
    [self.audioManager stopRunning];
    
    dispatch_async(recorderQueue, ^{
        if (self.writer.status != AVAssetWriterStatusCompleted && self.writer.status != AVAssetWriterStatusUnknown) {
            [self.writerInput markAsFinished];
        }
        [self.writer finishWritingWithCompletionHandler:^ {
             [self restartRecordingIfNeeded];
             dispatch_async(dispatch_get_main_queue(), ^{
                 //开始合并视频和音频
                 [self addAudioToVideoAudioPath:_audioFilePath block:^(NSURL *filePath) {
                     if (block) {
                         block(filePath);
                     }
                     _screenRecorderStatue = ScreenRecorderStatueEnd;
                 }];
             });
         }];
    });
}

- (void)restartRecordingIfNeeded
{
    if (shouldRestart) {
        shouldRestart = NO;
        dispatch_async(recorderQueue, ^{
            dispatch_async(dispatch_get_main_queue(), ^
                           {
                               [self startRecording];
                           });
        });
    }
}

- (void)rotateFile
{
    shouldRestart = YES;
    dispatch_async(recorderQueue, ^{
        [self stopRecording:nil];
    });
}

- (void)captureFrame:(CADisplayLink *)displayLink
{
    dispatch_async(recorderQueue, ^{
        if (self.writerInput.readyForMoreMediaData) {
            CVReturn status = kCVReturnSuccess;
            CVPixelBufferRef buffer = NULL;
            CFTypeRef backingData;
#if APPSTORE_SAFE || TARGET_IPHONE_SIMULATOR
            __block UIImage *screenshot = nil;
            dispatch_sync(dispatch_get_main_queue(), ^{
                screenshot = [self screenshot];
            });
            CGImageRef image = screenshot.CGImage;

            CGDataProviderRef dataProvider = CGImageGetDataProvider(image);
            CFDataRef data = CGDataProviderCopyData(dataProvider);
            backingData = CFDataCreateMutableCopy(kCFAllocatorDefault, CFDataGetLength(data), data);
            CFRelease(data);

            const UInt8 *bytePtr = CFDataGetBytePtr(backingData);

            status = CVPixelBufferCreateWithBytes(kCFAllocatorDefault,
                                                  CGImageGetWidth(image),
                                                  CGImageGetHeight(image),
                                                  kCVPixelFormatType_32BGRA,
                                                  (void *)bytePtr,
                                                  CGImageGetBytesPerRow(image),
                                                  NULL,
                                                  NULL,
                                                  NULL,
                                                  &buffer);
            NSParameterAssert(status == kCVReturnSuccess && buffer);
#else
            IOSurfaceRef surface = [self.window createIOSurface];
            backingData = surface;

            NSDictionary *pixelBufferAttributes = @{(NSString *)kCVPixelBufferPixelFormatTypeKey : @(kCVPixelFormatType_32BGRA)};
            status = CVPixelBufferCreateWithIOSurface(NULL, surface, (__bridge CFDictionaryRef _Nullable)(pixelBufferAttributes), &buffer);
            NSParameterAssert(status == kCVReturnSuccess && buffer);
#endif
            if (buffer) {
                CFAbsoluteTime currentTime = CFAbsoluteTimeGetCurrent();
                CFTimeInterval elapsedTime = currentTime - firstFrameTime;
                CMTime presentTime =  CMTimeMake(elapsedTime * TIME_SCALE, TIME_SCALE);
                
                if(![self.writerInputPixelBufferAdaptor appendPixelBuffer:buffer withPresentationTime:presentTime]) {
                    [self stopRecording:nil];
                }
                self.allowWriteAudio = YES;
                
                CVPixelBufferRelease(buffer);
            }

            CFRelease(backingData);
        }
    });
    
    if (startTimestamp == 0.0) {
        startTimestamp = displayLink.timestamp;
    }
    
    NSTimeInterval dalta = displayLink.timestamp - startTimestamp;
    
    if (self.autosaveDuration > 0 && dalta > self.autosaveDuration) {
        startTimestamp = 0.0;
        [self rotateFile];
    }
}

// 将声音添加到视频里面
- (void)addAudioToVideoAudioPath:(NSString *)audioPath block:(void (^)(NSURL *filePath))block{
    //初始化audioAsset
    AVURLAsset *audioAsset = [[AVURLAsset alloc]initWithURL:[NSURL fileURLWithPath:audioPath] options:nil];
    //初始化videoAsset
    AVURLAsset *videoAsset = [[AVURLAsset alloc]initWithURL:_currentVideoUrl options:nil];
    //初始化合成类
    AVMutableComposition *mixComposition = [AVMutableComposition composition];
    //初始化设置轨道type为AVMediaTypeAudio
    AVMutableCompositionTrack *compositionCommentaryTrack = [mixComposition addMutableTrackWithMediaType:AVMediaTypeAudio preferredTrackID:kCMPersistentTrackID_Invalid];
    //根据音频时常添加到设置里面
    [compositionCommentaryTrack insertTimeRange:CMTimeRangeMake(kCMTimeZero, audioAsset.duration) ofTrack:[[audioAsset tracksWithMediaType:AVMediaTypeAudio] objectAtIndex:0] atTime:kCMTimeZero error:nil];
    //初始化设置轨道type为VideoTrack
    AVMutableCompositionTrack *compositionVideoTrack = [mixComposition addMutableTrackWithMediaType:AVMediaTypeVideo preferredTrackID:kCMPersistentTrackID_Invalid];
    //设置视频时长等
    [compositionVideoTrack insertTimeRange:CMTimeRangeMake(kCMTimeZero, videoAsset.duration)ofTrack:[[videoAsset tracksWithMediaType:AVMediaTypeVideo] objectAtIndex:0] atTime:kCMTimeZero error:nil];
    //初始化导出类
    AVAssetExportSession* assetExport = [[AVAssetExportSession alloc] initWithAsset:mixComposition presetName:AVAssetExportPresetPassthrough];
    //导出路径
    NSString *exportPath = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).lastObject stringByAppendingPathComponent:@"screen_complete.mov"];;
    NSURL *exportUrl = [NSURL fileURLWithPath:exportPath];
    
    if ([[NSFileManager defaultManager] fileExistsAtPath:exportPath]) {
        [[NSFileManager defaultManager] removeItemAtPath:exportPath error:nil];
    }
    else {
        [[NSFileManager defaultManager] createFileAtPath:exportPath contents:nil attributes:nil];
    }
    
    assetExport.outputFileType = AVFileTypeQuickTimeMovie;
    assetExport.outputURL = exportUrl;
    assetExport.shouldOptimizeForNetworkUse = YES;
    //导出
    NSLog(@"开始合并");
    [assetExport exportAsynchronouslyWithCompletionHandler:^{
        if (block) {
            block(exportUrl);
        }
        NSLog(@"合并完成");
        //删除无声音的视频文件
        [[NSFileManager defaultManager] removeItemAtPath:[_currentVideoUrl path] error:nil];
        //删除音频文件
        [[NSFileManager defaultManager] removeItemAtPath:audioPath error:nil];
    }];
}

- (void)convertToMP4
{
    NSString *filePath = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).lastObject stringByAppendingPathComponent:@"filePath.mov"];;
    NSString *mp4FilePath = [filePath stringByReplacingOccurrencesOfString:@"mov" withString:@"mp4"];
    
    dispatch_queue_t queue = dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0);
    dispatch_async(queue, ^{
        AVURLAsset *avAsset = [AVURLAsset URLAssetWithURL:[NSURL fileURLWithPath:filePath] options:nil];
        NSArray *compatiblePresets = [AVAssetExportSession exportPresetsCompatibleWithAsset:avAsset];
        if ([compatiblePresets containsObject:AVAssetExportPresetHighestQuality]) {
            AVAssetExportSession *exportSession = [[AVAssetExportSession alloc] initWithAsset:avAsset presetName:AVAssetExportPresetHighestQuality];
            exportSession.outputURL = [NSURL fileURLWithPath:mp4FilePath];
            exportSession.outputFileType = AVFileTypeMPEG4;
            if ([[NSFileManager defaultManager] fileExistsAtPath:mp4FilePath])
            {
                [[NSFileManager defaultManager] removeItemAtPath:mp4FilePath error:nil];
            }
            [exportSession exportAsynchronouslyWithCompletionHandler:^(void)
             {
                 switch (exportSession.status) {
                     case AVAssetExportSessionStatusUnknown: {
                         NSLog(@"AVAssetExportSessionStatusUnknown");
                         break;
                     }
                     case AVAssetExportSessionStatusWaiting: {
                         NSLog(@"AVAssetExportSessionStatusWaiting");
                         break;
                     }
                     case AVAssetExportSessionStatusExporting: {
                         NSLog(@"AVAssetExportSessionStatusExporting");
                         break;
                     }
                     case AVAssetExportSessionStatusFailed: {
                         NSLog(@"AVAssetExportSessionStatusFailed error:%@", exportSession.error);
                         break;
                     }
                     case AVAssetExportSessionStatusCompleted: {
                         NSLog(@"AVAssetExportSessionStatusCompleted");
                         dispatch_async(dispatch_get_main_queue(),^{
                             //Completed
                         });
                         break;
                     }
                     default: {
                         NSLog(@"AVAssetExportSessionStatusCancelled");
                         break;
                     }
                 }
             }];
        }
    });
}

- (UIImage *)screenshot
{
    UIScreen *mainScreen = [UIScreen mainScreen];
    CGSize imageSize = mainScreen.bounds.size;
    UIGraphicsBeginImageContextWithOptions(imageSize, NO, 0);
    
    CGContextRef context = UIGraphicsGetCurrentContext();
    
    NSArray *windows = [[UIApplication sharedApplication] windows];
    for (UIWindow *window in windows) {
        if (![window respondsToSelector:@selector(screen)] || window.screen == mainScreen) {
            CGContextSaveGState(context);
            
            CGContextTranslateCTM(context, window.center.x, window.center.y);
            CGContextConcatCTM(context, [window transform]);
            CGContextTranslateCTM(context,
                                  -window.bounds.size.width * window.layer.anchorPoint.x,
                                  -window.bounds.size.height * window.layer.anchorPoint.y);
            
            [window.layer.presentationLayer renderInContext:context];
            
            CGContextRestoreGState(context);
        }
    }
    
    UIImage *image = UIGraphicsGetImageFromCurrentImageContext();
    
    UIGraphicsEndImageContext();
    
    return image;
}


#pragma mark - STAudioManagerDelegate

- (void)audioCaptureOutput:(AVCaptureOutput *)captureOutput didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer fromConnection:(AVCaptureConnection *)connection {
    __weak __typeof(self)weakSelf = self;
    [self.aacEncoder encodeSampleBuffer:sampleBuffer completionBlock:^(NSData *encodedData, NSError *error) {
        [weakSelf.audiFileHandle writeData:encodedData];
    }];
}

#pragma mark Background tasks

- (void)applicationDidEnterBackground:(NSNotification *)notification
{
    [self stopRecording:nil];
}

#pragma mark - getter

- (STAudioManager *)audioManager {
    if (_audioManager == nil) {
        _audioManager = [[STAudioManager alloc] init];
        _audioManager.delegate = self;
    }
    return _audioManager;
}

- (AACEncoder *)aacEncoder {
    if (_aacEncoder == nil) {
        _aacEncoder = [[AACEncoder alloc] init];
    }
    return _aacEncoder;
}

#pragma mark - Utility methods

- (NSString *)documentDirectory
{
	NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
	NSString *documentsDirectory = [paths objectAtIndex:0];
	return documentsDirectory;
}

- (NSString *)defaultFilename
{
    time_t timer;
    time(&timer);
    NSString *timestamp = [NSString stringWithFormat:@"%ld", timer];
    return [NSString stringWithFormat:@"%@.mov", timestamp];
}

- (NSString *)defaultAudioFilename
{
    time_t timer;
    time(&timer);
    NSString *timestamp = [NSString stringWithFormat:@"%ld", timer];
    return [NSString stringWithFormat:@"%@.aac", timestamp];
}

- (BOOL)existsFile:(NSString *)filename
{
    NSString *path = [self.documentDirectory stringByAppendingPathComponent:filename];
    NSFileManager *fileManager = [[NSFileManager alloc] init];
    BOOL isDirectory;
    return [fileManager fileExistsAtPath:path isDirectory:&isDirectory] && !isDirectory;
}

- (NSString *)nextFilename:(NSString *)filename
{
    static NSInteger fileCounter;
    
    fileCounter++;
    NSString *pathExtension = [filename pathExtension];
    filename = [[[filename stringByDeletingPathExtension] stringByAppendingString:[NSString stringWithFormat:@"-%@", @(fileCounter)]] stringByAppendingPathExtension:pathExtension];
    
    if ([self existsFile:filename]) {
        return [self nextFilename:filename];
    }
    
    return filename;
}

- (NSURL *)outputFileURL
{    
    if (!self.filenameBlock) {
        __block SRScreenRecorder *wself = self;
        self.filenameBlock = ^(void) {
            return [wself defaultFilename];
        };
    }
    
    NSString *filename = self.filenameBlock();
    if ([self existsFile:filename]) {
        filename = [self nextFilename:filename];
    }
    
    NSString *path = [self.documentDirectory stringByAppendingPathComponent:filename];
    return [NSURL fileURLWithPath:path];
}

- (NSURL *)outputAudioFileURL {
    NSString *filename = [self defaultAudioFilename];
    if ([self existsFile:filename]) {
        filename = [self nextFilename:filename];
    }
    
    NSString *path = [self.documentDirectory stringByAppendingPathComponent:filename];
    [[NSFileManager defaultManager] removeItemAtPath:path error:nil];
    [[NSFileManager defaultManager] createFileAtPath:path contents:nil attributes:nil];
    return [NSURL fileURLWithPath:path];
}

- (BOOL)checkMediaStatus:(NSString *)mediaType {
    AVAuthorizationStatus authStatus = [AVCaptureDevice authorizationStatusForMediaType:mediaType];
    
    BOOL res;
    
    switch (authStatus) {
        case AVAuthorizationStatusNotDetermined:
        case AVAuthorizationStatusDenied:
        case AVAuthorizationStatusRestricted:
            res = NO;
            break;
        case AVAuthorizationStatusAuthorized:
            res = YES;
            break;
    }
    return res;
}

+ (NSError *)cannotSetupInputError {
    NSString *localizedDescription = NSLocalizedString(@"Recording cannot be started", nil);
    NSString *localizedFailureReason = NSLocalizedString(@"Cannot setup asset writer input.", nil);
    NSDictionary *errorDict = @{ NSLocalizedDescriptionKey : localizedDescription,
                                 NSLocalizedFailureReasonErrorKey : localizedFailureReason };
    return [NSError errorWithDomain:@"com.apple.dts.samplecode" code:0 userInfo:errorDict];
}

@end
