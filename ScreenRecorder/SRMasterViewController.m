//
//  SRMasterViewController.m
//  ScreenRecorder
//
//  Created by kishikawa katsumi on 2012/12/26.
//  Copyright (c) 2012 kishikawa katsumi. All rights reserved.
//

#import "SRMasterViewController.h"
#import "SRDetailViewController.h"
#import "SRScreenRecorder.h"

@interface SRMasterViewController ()
@property (nonatomic, strong) NSMutableArray *objects;  //测试使用
@property (nonatomic, strong) UIButton *endButton;      //
@property (nonatomic, strong) UIButton *startButton;

@property (nonatomic, strong) SRScreenRecorder *screenRecorder;
@property (nonatomic, strong) NSURL *currentOutputFileURL;
@property (nonatomic, strong) AVPlayer *player;
@property (nonatomic, strong) AVPlayerLayer *playerLayer;

@end

@implementation SRMasterViewController

- (void)awakeFromNib
{
    [super awakeFromNib];
}

- (void)viewDidLoad
{
    [super viewDidLoad];
    
    self.navigationItem.leftBarButtonItem = self.editButtonItem;
    UIBarButtonItem *addButton = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemAdd target:self action:@selector(insertNewObject:)];
    self.navigationItem.rightBarButtonItem = addButton;
    
    [self.view addSubview:self.endButton];
    [self.view addSubview:self.startButton];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    
    self.endButton.frame = CGRectMake(100, 0, 44, 44);
    self.startButton.frame = CGRectMake(100, 54, 44, 44);
}


- (void)insertNewObject:(id)sender
{
    if (self.playerLayer) {
        [self.playerLayer removeFromSuperlayer];
        self.playerLayer = nil;
        return;
    }
    if (!_objects) {
        _objects = [[NSMutableArray alloc] init];
    }
    [_objects insertObject:[NSDate date] atIndex:0];
    NSIndexPath *indexPath = [NSIndexPath indexPathForRow:0 inSection:0];
    [self.tableView insertRowsAtIndexPaths:@[indexPath] withRowAnimation:UITableViewRowAnimationAutomatic];
}

#pragma mark - 按钮方法

- (void)startButtonAction {
    [self.screenRecorder startRecording];
}

- (void)endButtonAction {
    __weak __typeof(self)weakSelf = self;
    [self.screenRecorder stopRecording:^(NSURL *filePath) {
        NSLog(@"endButtonAction - filePath:%@",filePath);
        //打印LOG
        [weakSelf getVideoInfoWithSourcePath:[filePath path]];
        dispatch_async(dispatch_get_main_queue(), ^{
            AVPlayerItem *item = [[AVPlayerItem alloc]initWithURL:filePath];
            weakSelf.player = [[AVPlayer alloc]initWithPlayerItem:item];
            weakSelf.playerLayer = [AVPlayerLayer playerLayerWithPlayer:weakSelf.player];
            weakSelf.playerLayer.frame = CGRectMake(0, 0, [UIScreen mainScreen].bounds.size.width, 300);
            weakSelf.playerLayer.backgroundColor = [UIColor cyanColor].CGColor;
            weakSelf.playerLayer.videoGravity = AVLayerVideoGravityResizeAspect;
            [weakSelf.view.layer addSublayer:weakSelf.playerLayer];
            [weakSelf.player play];
        });
    }];
}

- (NSDictionary *)getVideoInfoWithSourcePath:(NSString *)path {
    if (path == nil) {
        return nil;
    }
    AVURLAsset * asset = [AVURLAsset assetWithURL:[NSURL fileURLWithPath:path]];
    CMTime time = [asset duration];
    int seconds = ceil(time.value/time.timescale);
    
    NSInteger fileSize = [[NSFileManager defaultManager] attributesOfItemAtPath:path error:nil].fileSize;
    
    NSLog(@"fileSize - %ld",fileSize);
    NSLog(@"seconds - %d",seconds);
    
    return @{@"size" : @(fileSize),
             @"duration" : @(seconds)};
}

#pragma mark - Table View

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView
{
    return 1;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section
{
    return _objects.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
    static NSString *CellIdentifier = @"Cell";
    UITableViewCell *cell;
    if ([tableView respondsToSelector:@selector(dequeueReusableCellWithIdentifier:forIndexPath:)]) {
        cell = [tableView dequeueReusableCellWithIdentifier:CellIdentifier forIndexPath:indexPath];
    } else {
        cell = [tableView dequeueReusableCellWithIdentifier:CellIdentifier];
        if (!cell) {
            cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:CellIdentifier];
        }
    }

    NSDate *object = _objects[indexPath.row];
    cell.textLabel.text = [object description];
    return cell;
}

- (BOOL)tableView:(UITableView *)tableView canEditRowAtIndexPath:(NSIndexPath *)indexPath
{
    return YES;
}

- (void)tableView:(UITableView *)tableView commitEditingStyle:(UITableViewCellEditingStyle)editingStyle forRowAtIndexPath:(NSIndexPath *)indexPath
{
    if (editingStyle == UITableViewCellEditingStyleDelete) {
        [_objects removeObjectAtIndex:indexPath.row];
        [tableView deleteRowsAtIndexPaths:@[indexPath] withRowAnimation:UITableViewRowAnimationFade];
    } else if (editingStyle == UITableViewCellEditingStyleInsert) {
        // Create a new instance of the appropriate class, insert it into the array, and add a new row to the table view.
    }
}

- (void)prepareForSegue:(UIStoryboardSegue *)segue sender:(id)sender
{
    if ([[segue identifier] isEqualToString:@"showDetail"]) {
        NSIndexPath *indexPath = [self.tableView indexPathForSelectedRow];
        NSDate *object = _objects[indexPath.row];
        [[segue destinationViewController] setDetailItem:object];
    }
}


#pragma mark - getter

- (UIButton *)endButton {
    if (_endButton == nil) {
        _endButton = [[UIButton alloc] init];
        _endButton.backgroundColor = [UIColor redColor];
        [_endButton setTitle:@"end" forState:UIControlStateNormal];
        [_endButton addTarget:self action:@selector(endButtonAction) forControlEvents:UIControlEventTouchUpInside];
    }
    return _endButton;
}

- (UIButton *)startButton {
    if (_startButton == nil) {
        _startButton = [[UIButton alloc] init];
        _startButton.backgroundColor = [UIColor redColor];
        [_startButton setTitle:@"start" forState:UIControlStateNormal];
        [_startButton addTarget:self action:@selector(startButtonAction) forControlEvents:UIControlEventTouchUpInside];
    }
    return _startButton;
}

- (SRScreenRecorder *)screenRecorder {
    if (_screenRecorder == nil) {
        _screenRecorder = [[SRScreenRecorder alloc] initWithWindow:[UIApplication sharedApplication].keyWindow];
    }
    return _screenRecorder;
}


- (void)didReceiveMemoryWarning
{
    [super didReceiveMemoryWarning];
}

@end
