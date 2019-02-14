//
//  SRScreenRecorder.h
//  ScreenRecorder
//
//  Created by kishikawa katsumi on 2012/12/26.
//  Copyright (c) 2012年 kishikawa katsumi. All rights reserved.
//

#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>

typedef NS_ENUM(NSInteger, ScreenRecorderStatue) {
    ScreenRecorderStatueNone,   //默认状态
    ScreenRecorderStatueIng,    //录制中
    ScreenRecorderStatueEnd,    //录制结束
};

typedef NSString *(^SRScreenRecorderOutputFilenameBlock)(void);

@interface SRScreenRecorder : NSObject

@property (retain, nonatomic, readonly) UIWindow *window; // A window to be recorded.
@property (assign, nonatomic) NSInteger frameInterval;
@property (assign, nonatomic) NSUInteger autosaveDuration; // in second, default value is 600 (10 minutes).
@property (assign, nonatomic) BOOL showsTouchPointer;
@property (copy, nonatomic) SRScreenRecorderOutputFilenameBlock filenameBlock;
@property (nonatomic, assign, readonly) ScreenRecorderStatue screenRecorderStatue;

- (instancetype)initWithWindow:(UIWindow *)window;
//开始录制
- (void)startRecording;
//停止录制
- (void)stopRecording:(void (^)(NSURL *filePath))block;


@end
