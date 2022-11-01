// Copyright 2013 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#import "FLTVideoPlayerPlugin.h"

#import <AVFoundation/AVFoundation.h>
#import <GLKit/GLKit.h>

#import "AVAssetTrackUtils.h"
#import "messages.g.h"

#if !__has_feature(objc_arc)
#error Code Requires ARC.
#endif

@interface FLTVideoPlayer : UIView <FlutterPlatformView, FlutterStreamHandler>
@property(readonly, nonatomic) AVQueuePlayer *player;
@property(nonatomic) NSArray<AVPlayerItem *> *items;
@property(nonatomic) FlutterEventChannel *eventChannel;
@property(nonatomic) FlutterEventSink eventSink;
@property(nonatomic, readonly) BOOL disposed;
@property(nonatomic, readonly) BOOL isPlaying;
@property(nonatomic, readonly) BOOL isComplete;
@property(nonatomic, readonly) BOOL isLooping;
@property(nonatomic, readonly) BOOL isInitialized;
- (instancetype)initWithURLS:(NSArray *)urls
                 httpHeaders:(nonnull NSDictionary<NSString *, NSString *> *)headers;
@end

static void *timeRangeContext = &timeRangeContext;
static void *statusContext = &statusContext;
static void *playbackLikelyToKeepUpContext = &playbackLikelyToKeepUpContext;
static void *playbackBufferEmptyContext = &playbackBufferEmptyContext;
static void *playbackBufferFullContext = &playbackBufferFullContext;

@implementation FLTVideoPlayer
- (instancetype)initWithAssets:(NSArray *)assets {
  NSMutableArray<NSURL *> *urls = [[NSMutableArray alloc] init];
  for (NSString *asset in assets) {
    NSString *path = [[NSBundle mainBundle] pathForResource:asset ofType:nil];
    [urls addObject:[NSURL fileURLWithPath:path]];
  }
  return [self initWithURLS:urls httpHeaders:@{}];
}

- (void)addObservers:(AVPlayerItem *)item {
  [item addObserver:self
         forKeyPath:@"loadedTimeRanges"
            options:NSKeyValueObservingOptionInitial | NSKeyValueObservingOptionNew
            context:timeRangeContext];
  [item addObserver:self
         forKeyPath:@"status"
            options:NSKeyValueObservingOptionInitial | NSKeyValueObservingOptionNew
            context:statusContext];
  [item addObserver:self
         forKeyPath:@"playbackLikelyToKeepUp"
            options:NSKeyValueObservingOptionInitial | NSKeyValueObservingOptionNew
            context:playbackLikelyToKeepUpContext];
  [item addObserver:self
         forKeyPath:@"playbackBufferEmpty"
            options:NSKeyValueObservingOptionInitial | NSKeyValueObservingOptionNew
            context:playbackBufferEmptyContext];
  [item addObserver:self
         forKeyPath:@"playbackBufferFull"
            options:NSKeyValueObservingOptionInitial | NSKeyValueObservingOptionNew
            context:playbackBufferFullContext];
}

- (void)removeObservers:(AVPlayerItem *)item {
  @try {
    [item removeObserver:self forKeyPath:@"loadedTimeRanges"];
  } @catch (NSException *exception) {}
  @try {
    [item removeObserver:self forKeyPath:@"status"];
  } @catch (NSException *exception) {}
  @try {
    [item removeObserver:self forKeyPath:@"playbackLikelyToKeepUp"];
  } @catch (NSException *exception) {}
  @try {
    [item removeObserver:self forKeyPath:@"playbackBufferEmpty"];
  } @catch (NSException *exception) {}
  @try {
    [item removeObserver:self forKeyPath:@"playbackBufferFull"];
  } @catch (NSException *exception) {
  }
}

- (void)itemDidPlayToEndTime:(NSNotification *)notification {
  if ([_player currentItem] != [notification object]) {
    return;
  }
  AVPlayerItem *item = [_player currentItem];
  [self removeObservers:item];
  [_player advanceToNextItem];
  [self addObservers:[_player currentItem]];
  if ([_player canInsertItem:item afterItem:NULL]) {
    [item seekToTime:kCMTimeZero];
    [_player insertItem:item afterItem:NULL];
  }
  if ([_player currentItem] == [_items firstObject]) {
    if (_isLooping) {
      [self sendEventWithDuration:@"loop" :[_player currentItem]];
    } else {
      _isComplete = YES;
      _isPlaying = NO;
      [self updatePlayingState];
      if (_eventSink) {
        _eventSink(@{@"event" : @"completed"});
      }
    }
  }
}

const int64_t TIME_UNSET = -9223372036854775807;

NS_INLINE int64_t FLTCMTimeToMillis(CMTime time) {
  // When CMTIME_IS_INDEFINITE return a value that matches TIME_UNSET from ExoPlayer2 on Android.
  // Fixes https://github.com/flutter/flutter/issues/48670
  if (CMTIME_IS_INDEFINITE(time)) return TIME_UNSET;
  if (time.timescale == 0) return 0;
  return time.value * 1000 / time.timescale;
}

NS_INLINE CGFloat radiansToDegrees(CGFloat radians) {
  // Input range [-pi, pi] or [-180, 180]
  CGFloat degrees = GLKMathRadiansToDegrees((float)radians);
  if (degrees < 0) {
    // Convert -90 to 270 and -180 to 180
    return degrees + 360;
  }
  // Output degrees in between [0, 360]
  return degrees;
};

- (AVMutableVideoComposition *)getVideoCompositionWithTransform:(CGAffineTransform)transform
                                                      withAsset:(AVAsset *)asset
                                                 withVideoTrack:(AVAssetTrack *)videoTrack {
  AVMutableVideoCompositionInstruction *instruction =
      [AVMutableVideoCompositionInstruction videoCompositionInstruction];
  instruction.timeRange = CMTimeRangeMake(kCMTimeZero, [asset duration]);
  AVMutableVideoCompositionLayerInstruction *layerInstruction =
      [AVMutableVideoCompositionLayerInstruction
          videoCompositionLayerInstructionWithAssetTrack:videoTrack];
  [layerInstruction setTransform:transform atTime:kCMTimeZero];

  AVMutableVideoComposition *videoComposition = [AVMutableVideoComposition videoComposition];
  instruction.layerInstructions = @[ layerInstruction ];
  videoComposition.instructions = @[ instruction ];

  // If in portrait mode, switch the width and height of the video
  CGFloat width = videoTrack.naturalSize.width;
  CGFloat height = videoTrack.naturalSize.height;
  NSInteger rotationDegrees =
      (NSInteger)round(radiansToDegrees(atan2(transform.b, transform.a)));
  if (rotationDegrees == 90 || rotationDegrees == 270) {
    width = videoTrack.naturalSize.height;
    height = videoTrack.naturalSize.width;
  }
  videoComposition.renderSize = CGSizeMake(width, height);

  float nominalFrameRate = videoTrack.nominalFrameRate;
  int fps = 30;
  if (nominalFrameRate > 0) {
    fps = (int) ceil(nominalFrameRate);
  }
  videoComposition.frameDuration = CMTimeMake(1, fps);

  return videoComposition;
}

- (instancetype)initWithURLS:(NSArray<NSURL *> *)urls
                 httpHeaders:(nonnull NSDictionary<NSString *, NSString *> *)headers {
  NSDictionary<NSString *, id> *options = nil;
  if ([headers count] != 0) {
    options = @{@"AVURLAssetHTTPHeaderFieldsKey" : headers};
  }
  NSMutableArray<AVPlayerItem *> *items = [[NSMutableArray alloc] init];
  for (NSURL *url in urls) {
    AVURLAsset *urlAsset = [AVURLAsset URLAssetWithURL:url options:options];
    AVPlayerItem *item = [AVPlayerItem playerItemWithAsset:urlAsset];
    [self setItemVideoComposition:item];
    [items addObject:item];
  }
  _items = items;
  return [self initWithPlayerItems:items];
}

- (instancetype)initWithPlayerItems:(NSArray<AVPlayerItem *> *)items {
  self = [super init];
  NSAssert(self, @"super init cannot be nil");
  [[NSNotificationCenter defaultCenter] addObserver:self
                                           selector:@selector(itemDidPlayToEndTime:)
                                               name:AVPlayerItemDidPlayToEndTimeNotification
                                             object:nil];
  _player = [[AVQueuePlayer alloc] initWithItems:items];
  _player.actionAtItemEnd = AVPlayerActionAtItemEndNone;
  [self addObservers:[_player currentItem]];
  AVPlayerLayer *playerLayer = (AVPlayerLayer *)self.layer;
  playerLayer.player = _player;

  return self;
}

- (void)observeValueForKeyPath:(NSString *)path
                      ofObject:(id)object
                        change:(NSDictionary *)change
                       context:(void *)context {
  AVPlayerItem *item = (AVPlayerItem *)object;
  if (_player.currentItem != item) {
    return;
  }
  if (context == timeRangeContext) {
    if (_eventSink) {
      NSMutableArray<NSArray<NSNumber *> *> *values = [[NSMutableArray alloc] init];
      for (NSValue *rangeValue in [item loadedTimeRanges]) {
        CMTimeRange range = [rangeValue CMTimeRangeValue];
        int64_t start = FLTCMTimeToMillis(range.start);
        [values addObject:@[ @(start), @(start + FLTCMTimeToMillis(range.duration)) ]];
      }
      _eventSink(@{@"event" : @"bufferingUpdate", @"values" : values});
    }
  } else if (context == statusContext) {
    switch (item.status) {
      case AVPlayerItemStatusFailed:
        if (_eventSink) {
          _eventSink([FlutterError
              errorWithCode:@"VideoError"
                    message:[@"Failed to load video: "
                                stringByAppendingString:[item.error localizedDescription]]
                    details:nil]);
        }
        break;
      case AVPlayerItemStatusReadyToPlay:
        if (item == [_items firstObject]) {
          [self setupEventSinkIfReadyToPlay];
          [self updatePlayingState];
        }else{
          [self sendEventWithDuration:@"transition" :[_player currentItem]];
        }
        break;
      case AVPlayerItemStatusUnknown:
        break;
    }
  } else if (context == playbackLikelyToKeepUpContext) {
    if ([[_player currentItem] isPlaybackLikelyToKeepUp]) {
      [self updatePlayingState];
      if (_eventSink) {
        _eventSink(@{@"event" : @"bufferingEnd"});
      }
    }
  } else if (context == playbackBufferEmptyContext) {
    if (_eventSink) {
      _eventSink(@{@"event" : @"bufferingStart"});
    }
  } else if (context == playbackBufferFullContext) {
    if (_eventSink) {
      _eventSink(@{@"event" : @"bufferingEnd"});
    }
  }
}

- (void)updatePlayingState {
  if (!_isInitialized) {
    return;
  }
  if (_isPlaying) {
    [_player play];
  } else {
    [_player pause];
  }
}

- (void)setupEventSinkIfReadyToPlay {
  if (_eventSink && !_isInitialized) {
    AVPlayerItem *currentItem = self.player.currentItem;
    CGSize size = currentItem.presentationSize;
    CGFloat width = size.width;
    CGFloat height = size.height;

    // Wait until tracks are loaded to check duration or if there are any videos.
    AVAsset *asset = currentItem.asset;
    if ([asset statusOfValueForKey:@"tracks" error:nil] != AVKeyValueStatusLoaded) {
      void (^trackCompletionHandler)(void) = ^{
        if ([asset statusOfValueForKey:@"tracks" error:nil] != AVKeyValueStatusLoaded) {
          // Cancelled, or something failed.
          return;
        }
        // This completion block will run on an AVFoundation background queue.
        // Hop back to the main thread to set up event sink.
        [self performSelector:_cmd onThread:NSThread.mainThread withObject:self waitUntilDone:NO];
      };
      [asset loadValuesAsynchronouslyForKeys:@[ @"tracks" ]
                           completionHandler:trackCompletionHandler];
      return;
    }

    BOOL hasVideoTracks = [asset tracksWithMediaType:AVMediaTypeVideo].count != 0;
    BOOL hasNoTracks = asset.tracks.count == 0;

    // The player has not yet initialized when it has no size, unless it is an audio-only track.
    // HLS m3u8 video files never load any tracks, and are also not yet initialized until they have
    // a size.
    if ((hasVideoTracks || hasNoTracks) && height == CGSizeZero.height &&
        width == CGSizeZero.width) {
      return;
    }
    // The player may be initialized but still needs to determine the duration.
    int64_t duration = [self duration];
    if (duration == 0) {
      return;
    }

    _isInitialized = YES;
    _eventSink(@{
      @"event" : @"initialized",
      @"duration" : @(duration),
      @"width" : @(width),
      @"height" : @(height)
    });
  }
}

- (void)setItemVideoComposition:(AVPlayerItem *) item {
  AVAsset *asset = item.asset;
  AVAssetTrack *videoTrack = [[asset tracksWithMediaType:AVMediaTypeVideo] firstObject];
  if (videoTrack != nil) {
    void (^trackCompletionHandler)(void) = ^{
      if (self->_disposed) return;
      if ([videoTrack statusOfValueForKey:@"preferredTransform"
                                    error:nil] == AVKeyValueStatusLoaded) {
        AVMutableVideoComposition *videoComposition =
        [self getVideoCompositionWithTransform:FLTGetStandardizedTransformForTrack(videoTrack)
                                     withAsset:asset
                                withVideoTrack:videoTrack];
        item.videoComposition = videoComposition;
      }
    };
    [videoTrack loadValuesAsynchronouslyForKeys:@[ @"preferredTransform" ]
                              completionHandler:trackCompletionHandler];
  }
}

- (void)sendEventWithDuration:(NSString *) event
                             :(AVPlayerItem *) item {
  if (_eventSink) {
    CGSize size = item.presentationSize;
    CGFloat width = size.width;
    CGFloat height = size.height;

    int64_t duration = [self duration];
    _eventSink(@{
      @"event" : event,
      @"duration" : @(duration),
      @"width" : @(width),
      @"height" : @(height)
    });
  }
}

- (void)play {
  if (_isComplete) {
    [self sendEventWithDuration:@"loop" :[_player currentItem]];
  }
  _isComplete = NO;
  _isPlaying = YES;
  [self updatePlayingState];
}

- (void)pause {
  _isPlaying = NO;
  [self updatePlayingState];
}

- (int64_t)mediaItemIndex {
    return [_items indexOfObject:[_player currentItem]];
}

- (int64_t)position {
  return FLTCMTimeToMillis([_player currentTime]);
}

- (int64_t)duration {
  // Note: https://openradar.appspot.com/radar?id=4968600712511488
  // `[AVPlayerItem duration]` can be `kCMTimeIndefinite`,
  // use `[[AVPlayerItem asset] duration]` instead.
  return FLTCMTimeToMillis([[[_player currentItem] asset] duration]);
}

- (void)seekTo:(int)mediaItemIndex location:(int)location {
  // TODO(stuartmorgan): Update this to use completionHandler: to only return
  // once the seek operation is complete once the Pigeon API is updated to a
  // version that handles async calls.
  if (mediaItemIndex == [self mediaItemIndex]) {
    [_player seekToTime:CMTimeMake(location, 1000)
        toleranceBefore:kCMTimeZero
         toleranceAfter:kCMTimeZero];
  } else if (mediaItemIndex < [[_player items] count]) {
    AVPlayerItem *item = [_items objectAtIndex:mediaItemIndex];
    AVPlayerItem *currentItem = [_player currentItem];
    AVPlayerItem *lastItem = [[_player items] lastObject];
    NSUInteger index = [[_player items] indexOfObject:item];
    [self removeObservers:currentItem];
    for (AVPlayerItem *item in [[_player items] subarrayWithRange:NSMakeRange(1, index - 1)]) {
      [_player removeItem:item];
      if ([_player canInsertItem:item afterItem:NULL]) {
        [_player insertItem:item afterItem:NULL];
      }
    }
    [item seekToTime:CMTimeMake(location, 1000)];
    [_player advanceToNextItem];
    [self addObservers:[_player currentItem]];
    if ([_player canInsertItem:currentItem afterItem:lastItem]) {
      [currentItem seekToTime:kCMTimeZero];
      [_player insertItem:currentItem afterItem:lastItem];
    }
    [self sendEventWithDuration:@"transition" :[_player currentItem]];
  }
}

- (void)setIsLooping:(BOOL)isLooping {
  _isLooping = isLooping;
}

- (void)setVolume:(double)volume {
  _player.volume = (float)((volume < 0.0) ? 0.0 : ((volume > 1.0) ? 1.0 : volume));
}

- (void)setPlaybackSpeed:(double)speed {
  // See https://developer.apple.com/library/archive/qa/qa1772/_index.html for an explanation of
  // these checks.
  if (speed > 2.0 && !_player.currentItem.canPlayFastForward) {
    if (_eventSink) {
      _eventSink([FlutterError errorWithCode:@"VideoError"
                                     message:@"Video cannot be fast-forwarded beyond 2.0x"
                                     details:nil]);
    }
    return;
  }

  if (speed < 1.0 && !_player.currentItem.canPlaySlowForward) {
    if (_eventSink) {
      _eventSink([FlutterError errorWithCode:@"VideoError"
                                     message:@"Video cannot be slow-forwarded"
                                     details:nil]);
    }
    return;
  }

  _player.rate = speed;
}

- (FlutterError *_Nullable)onCancelWithArguments:(id _Nullable)arguments {
  _eventSink = nil;
  return nil;
}

- (FlutterError *_Nullable)onListenWithArguments:(id _Nullable)arguments
                                       eventSink:(nonnull FlutterEventSink)events {
  _eventSink = events;
  // TODO(@recastrodiaz): remove the line below when the race condition is resolved:
  // https://github.com/flutter/flutter/issues/21483
  // This line ensures the 'initialized' event is sent when the event
  // 'AVPlayerItemStatusReadyToPlay' fires before _eventSink is set (this function
  // onListenWithArguments is called)
  [self setupEventSinkIfReadyToPlay];
  return nil;
}

/// This method allows you to dispose without touching the event channel.  This
/// is useful for the case where the Engine is in the process of deconstruction
/// so the channel is going to die or is already dead.
- (void)disposeSansEventChannel {
  _disposed = YES;
  for (AVPlayerItem *item in [_player items]) {
    [self removeObservers:item];
  }

  [self.player replaceCurrentItemWithPlayerItem:nil];
  self.items = nil;
  [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)dispose {
  [self disposeSansEventChannel];
  [_eventChannel setStreamHandler:nil];
}

- (nonnull UIView *)view {
  return self;
}

+ (Class)layerClass {
  return AVPlayerLayer.self;
}

@end

@interface FLTVideoPlayerPlugin () <FLTAVFoundationVideoPlayerApi, FlutterPlatformViewFactory>
@property(readonly, weak, nonatomic) NSObject<FlutterBinaryMessenger> *messenger;
@property(readonly, strong, nonatomic) NSMutableDictionary<NSNumber *, FLTVideoPlayer *> *playersByTextureId;
@property(readonly, strong, nonatomic) NSObject<FlutterPluginRegistrar> *registrar;
@end

@implementation FLTVideoPlayerPlugin
int texturesCount = 0;
+ (void)registerWithRegistrar:(NSObject<FlutterPluginRegistrar> *)registrar {
  FLTVideoPlayerPlugin *instance = [[FLTVideoPlayerPlugin alloc] initWithRegistrar:registrar];
  [registrar publish:instance];
  [registrar registerViewFactory:instance withId:@"com.framy.video_player"];
  FLTAVFoundationVideoPlayerApiSetup(registrar.messenger, instance);
}

- (instancetype)initWithRegistrar:(NSObject<FlutterPluginRegistrar> *)registrar {
  self = [super init];
  NSAssert(self, @"super init cannot be nil");
  _messenger = [registrar messenger];
  _registrar = registrar;
  _playersByTextureId = [NSMutableDictionary dictionaryWithCapacity:1];
  return self;
}

- (void)detachFromEngineForRegistrar:(NSObject<FlutterPluginRegistrar> *)registrar {
  [self.playersByTextureId.allValues makeObjectsPerformSelector:@selector(disposeSansEventChannel)];
  [self.playersByTextureId removeAllObjects];
  // TODO(57151): This should be commented out when 57151's fix lands on stable.
  // This is the correct behavior we never did it in the past and the engine
  // doesn't currently support it.
  // FLTAVFoundationVideoPlayerApiSetup(registrar.messenger, nil);
}

- (FLTTextureMessage *)onPlayerSetup:(FLTVideoPlayer *)player {
  int64_t textureId = texturesCount += 1;
  FlutterEventChannel *eventChannel = [FlutterEventChannel
      eventChannelWithName:[NSString stringWithFormat:@"flutter.io/videoPlayer/videoEvents%lld",
                                                      textureId]
           binaryMessenger:_messenger];
  [eventChannel setStreamHandler:player];
  player.eventChannel = eventChannel;
  self.playersByTextureId[@(textureId)] = player;
  FLTTextureMessage *result = [FLTTextureMessage makeWithTextureId:@(textureId)];
  NSLog(@"VideoPlayer: create textureId: %lld, remaining: %lu", textureId, (unsigned long)[_playersByTextureId count]);
  return result;
}

- (void)initialize:(FlutterError *__autoreleasing *)error {

  [self.playersByTextureId
      enumerateKeysAndObjectsUsingBlock:^(NSNumber *textureId, FLTVideoPlayer *player, BOOL *stop) {
        [player dispose];
      }];
  [self.playersByTextureId removeAllObjects];
}

- (FLTTextureMessage *)create:(FLTCreateMessage *)input error:(FlutterError **)error {
  FLTVideoPlayer *player;
  if (input.assets) {
    NSMutableArray<NSString *> *assetPaths = [[NSMutableArray alloc] init];
    for (NSString *asset in input.assets) {
      NSString *assetPath;
      if (input.packageName) {
        assetPath = [_registrar lookupKeyForAsset:asset fromPackage:input.packageName];
      } else {
        assetPath = [_registrar lookupKeyForAsset:asset];
      }
      [assetPaths addObject:assetPath];
    }
    player = [[FLTVideoPlayer alloc] initWithAssets:assetPaths];
    return [self onPlayerSetup:player];
  } else if (input.uris) {
    NSMutableArray<NSURL *> *urls = [[NSMutableArray alloc] init];
    for (NSString *uri in input.uris) {
      [urls addObject:[NSURL URLWithString:uri]];
    }
    player = [[FLTVideoPlayer alloc] initWithURLS:urls
                                      httpHeaders:input.httpHeaders];
    return [self onPlayerSetup:player];
  } else {
    *error = [FlutterError errorWithCode:@"video_player" message:@"not implemented" details:nil];
    return nil;
  }
}

- (void)dispose:(FLTTextureMessage *)input error:(FlutterError **)error {
  FLTVideoPlayer *player = self.playersByTextureId[input.textureId];
  [self.playersByTextureId removeObjectForKey:input.textureId];
  dispatch_async(dispatch_get_main_queue(), ^{
    [player dispose];
  });
  NSLog(@"VideoPlayer: dispose textureId: %@, remaining: %ld", input.textureId, [_playersByTextureId count]);
}

- (void)setLooping:(FLTLoopingMessage *)input error:(FlutterError **)error {
  FLTVideoPlayer *player = self.playersByTextureId[input.textureId];
  player.isLooping = input.isLooping.boolValue;
}

- (void)setVolume:(FLTVolumeMessage *)input error:(FlutterError **)error {
  FLTVideoPlayer *player = self.playersByTextureId[input.textureId];
  [player setVolume:input.volume.doubleValue];
}

- (void)setPlaybackSpeed:(FLTPlaybackSpeedMessage *)input error:(FlutterError **)error {
  FLTVideoPlayer *player = self.playersByTextureId[input.textureId];
  [player setPlaybackSpeed:input.speed.doubleValue];
}

- (void)play:(FLTTextureMessage *)input error:(FlutterError **)error {
  FLTVideoPlayer *player = self.playersByTextureId[input.textureId];
  [player play];
}

- (FLTPositionMessage *)position:(FLTTextureMessage *)input error:(FlutterError **)error {
  FLTVideoPlayer *player = self.playersByTextureId[input.textureId];
  FLTPositionMessage *result = [FLTPositionMessage makeWithTextureId:input.textureId
                                                            mediaItemIndex:@([player mediaItemIndex])
                                                            position:@([player position])];
  return result;
}

- (void)seekTo:(FLTPositionMessage *)input error:(FlutterError **)error {
  FLTVideoPlayer *player = self.playersByTextureId[input.textureId];
  [player seekTo:input.mediaItemIndex.intValue location:input.position.intValue];
}

- (void)pause:(FLTTextureMessage *)input error:(FlutterError **)error {
  FLTVideoPlayer *player = self.playersByTextureId[input.textureId];
  [player pause];
}

- (void)setMixWithOthers:(FLTMixWithOthersMessage *)input
                   error:(FlutterError *_Nullable __autoreleasing *)error {
  if (input.mixWithOthers.boolValue) {
    [[AVAudioSession sharedInstance] setCategory:AVAudioSessionCategoryPlayback
                                     withOptions:AVAudioSessionCategoryOptionMixWithOthers
                                           error:nil];
  } else {
    [[AVAudioSession sharedInstance] setCategory:AVAudioSessionCategoryPlayback error:nil];
  }
}

- (nonnull NSObject<FlutterPlatformView> *)createWithFrame:(CGRect)frame viewIdentifier:(int64_t)viewId arguments:(id _Nullable)args {
  NSNumber* textureId = [args objectForKey:@"textureId"];
  FLTVideoPlayer *player = _playersByTextureId[@(textureId.intValue)];
  return player;
}

- (NSObject<FlutterMessageCodec> *)createArgsCodec {
  return [FlutterStandardMessageCodec sharedInstance];
}

@end
