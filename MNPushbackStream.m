//
//  MNPushbackStream.m
//
//  Created by Matthew Nespor on 9/1/13.
//  Copyright (c) 2013 Matthew Nespor. All rights reserved.
//

#import "MNPushbackStream.h"

@interface MNPushbackStream () <NSStreamDelegate>

// using composition instead of subclassing because NSInputStream subclasses blow up on [super initWithData:]
// cf. https://devforums.apple.com/message/31098

@property (strong, nonatomic) NSInputStream* impl;
@property (strong, nonatomic) NSInputStream* pushedReader;
@property (strong, nonatomic) NSMutableData* pushedBytes;
@property (nonatomic) BOOL isOpen;
@property (strong, nonatomic) NSMutableArray* runLoops;
@property (strong, nonatomic) NSMutableArray* modes;

- (void)stream:(NSStream *)aStream handleEvent:(NSStreamEvent)eventCode;
- (void)pop:(NSUInteger)len;

@end

@implementation MNPushbackStream

#pragma mark - initialization

+ (instancetype)pushbackStreamWithData:(NSData *)data
{
    MNPushbackStream* result = [[MNPushbackStream alloc] initWithData:data];
    return result;
}

+ (instancetype)pushbackStreamWithFileAtPath:(NSString *)path
{
    MNPushbackStream* result = [[MNPushbackStream alloc] initWithFileAtPath:path];
    return result;
}

+ (instancetype)pushbackStreamWithURL:(NSURL *)url
{
    MNPushbackStream* result = [[MNPushbackStream alloc] initWithURL:url];
    return result;
}

- (id)initWithData:(NSData *)data
{
    self = [super init];
    if (self)
    {
        self->_impl = [[NSInputStream alloc] initWithData:data];
        self->_runLoops = [[NSMutableArray alloc] init];
        self->_modes = [[NSMutableArray alloc] init];
    }
    
    return self;
}

- (id)initWithFileAtPath:(NSString *)path
{
    self = [super init];
    if (self)
    {
        self->_impl = [[NSInputStream alloc] initWithFileAtPath:path];
        self->_runLoops = [[NSMutableArray alloc] init];
        self->_modes = [[NSMutableArray alloc] init];
    }
    
    return self;
}

- (id)initWithURL:(NSURL *)url
{
    self = [super init];
    if (self)
    {
        self->_impl = [[NSInputStream alloc] initWithURL:url];
        self->_runLoops = [[NSMutableArray alloc] init];
        self->_modes = [[NSMutableArray alloc] init];
    }
    
    return self;
}

#pragma mark - public methods

- (void)unread:(const void *)bytes offset:(NSUInteger)offset length:(NSUInteger)len
{
    self.pushedReader = nil;
    NSData* unreadData = [NSData dataWithBytes:(bytes + offset) length:len];
    
    if (self.pushedBytes)
        [self.pushedBytes appendData:unreadData];
    else
        self.pushedBytes = [unreadData mutableCopy];
    
    self.pushedReader = [NSInputStream inputStreamWithData:self.pushedBytes];
    self.pushedReader.delegate = self.delegate;
}

- (void)unreadString:(NSString *)str encoding:(NSStringEncoding)encoding
{
    [self unread:[str dataUsingEncoding:encoding].bytes offset:0 length:str.length];
}

- (void)open
{
    [self.impl open];
    [self.pushedReader open];
    self.isOpen = YES;
}

- (void)close
{
    [self.impl close];
    [self.pushedReader close];
    self.isOpen = NO;
}

- (void)scheduleInRunLoop:(NSRunLoop *)aRunLoop forMode:(NSString *)mode
{
    [self.runLoops addObject:aRunLoop];
    [self.modes addObject:mode];
    [self.impl scheduleInRunLoop:aRunLoop forMode:mode];
    [self.pushedReader scheduleInRunLoop:aRunLoop forMode:mode];
}

- (void)removeFromRunLoop:(NSRunLoop *)aRunLoop forMode:(NSString *)mode
{
    NSUInteger idx = [self.runLoops indexOfObject:aRunLoop];
    [self.runLoops removeObject:aRunLoop];
    [self.modes removeObjectAtIndex:idx];
    [self.impl removeFromRunLoop:aRunLoop forMode:mode];
    [self.pushedReader removeFromRunLoop:aRunLoop forMode:mode];
}

- (id<NSStreamDelegate>)delegate
{
    return self->_delegate;
}

- (void)setDelegate:(id<NSStreamDelegate>)aDelegate
{
    self->_delegate = aDelegate;
    
    if (aDelegate)
    {
        self.impl.delegate = self;
        self.pushedReader.delegate = self;
    }
    else
    {
        self.impl.delegate = nil;
        self.pushedReader.delegate = nil;
    }
}

#pragma mark - Stuff that looks like NSInputStream

- (NSInteger)read:(uint8_t *)buffer maxLength:(NSUInteger)len
{
    if (!self.pushedBytes || ![self.pushedReader hasBytesAvailable]) // Nothing has been pushed back
        return [self.impl read:buffer maxLength:len];
    
    assert(self.isOpen && "tried to read from a closed stream");
    
    uint8_t* pushedbuf = malloc(len * sizeof(uint8_t));
    NSInteger pushedReadResult = [self.pushedReader read:pushedbuf maxLength:len];
    
    if (pushedReadResult < 0)
    {
        NSLog(@"%@:read:maxLength: Failed to read pushed bytes", self);
        free(pushedbuf);
        return pushedReadResult;
    }
    else if (pushedReadResult == 0 || ![self.impl hasBytesAvailable]) // pushed bytes > len OR can't read from super
    {
        memcpy(buffer, pushedbuf, len * sizeof(uint8_t));
        free(pushedbuf);
        [self pop:(pushedReadResult > 0 ? pushedReadResult : len)];
        return pushedReadResult;
    }
    else // (pushedReadResult > 0), so read all pushed bytes AND super has bytes available; start reading from super
    {
        NSMutableData* aggregateReadData = [[NSData dataWithBytes:pushedbuf
                                                           length:pushedReadResult * sizeof(uint8_t)] mutableCopy];
        free(pushedbuf);
        [self pop:pushedReadResult];
        
        NSUInteger remainderLen = len - pushedReadResult;
        uint8_t* remainderbuf = malloc(remainderLen * sizeof(uint8_t));
        NSInteger remainderReadResult = [self.impl read:remainderbuf maxLength:remainderLen];
        
        if (remainderReadResult < 0)
        {
            NSLog(@"%@:read:maxLength: Failed to read non-pushed bytes", self);
            free(remainderbuf);
            return remainderReadResult;
        }
        else if (remainderReadResult == 0) // Pushed bytes <= len, but unread bytes + pushed bytes > len
        {
            [aggregateReadData appendData:[NSData dataWithBytes:remainderbuf
                                                         length:remainderLen * sizeof(uint8_t)]];
            free(remainderbuf);
            memcpy(buffer, aggregateReadData.bytes, len * sizeof(uint8_t));
            return remainderReadResult;
        }
        else // (remainderReadResult > 0), so pushed bytes + unread bytes < len
        {
            [aggregateReadData appendData:[NSData dataWithBytes:remainderbuf
                                                         length:remainderReadResult * sizeof(uint8_t)]];
            free(remainderbuf);
            memcpy(buffer, aggregateReadData.bytes, len * sizeof(uint8_t));
            return (remainderReadResult + pushedReadResult);
        }
    }
}

- (BOOL)getBuffer:(uint8_t **)buffer length:(NSUInteger *)len
{
    return NO;
}

- (BOOL)hasBytesAvailable
{
    return ([self.pushedReader hasBytesAvailable] || [self.impl hasBytesAvailable]);
}

#pragma mark - NSStreamDelegate

- (void)stream:(NSStream *)aStream handleEvent:(NSStreamEvent)eventCode
{
    if ([self.delegate respondsToSelector:@selector(stream:handleEvent:)])
        [self.delegate stream:self handleEvent:eventCode];
}

#pragma mark - Private

- (void)pop:(NSUInteger)len
{
    if (!self.pushedBytes)
        return;
    
    self.pushedReader = nil;
    
    if (len >= self.pushedBytes.length)
        self.pushedBytes = nil;
    else
    {
        self.pushedBytes = [[NSData dataWithBytes:(self.pushedBytes.bytes + len) length:(self.pushedBytes.length - len)] mutableCopy];
        self.pushedReader = [NSInputStream inputStreamWithData:self.pushedBytes];
        self.pushedReader.delegate = self.delegate;
    }
}

- (void)setPushedReader:(NSInputStream *)pushedReader
{
    [self.pushedReader close];
    self->_pushedReader = pushedReader;
    pushedReader.delegate = self;
    if (self.isOpen)
        [pushedReader open];
    for (NSRunLoop* aRunLoop in self.runLoops)
        [pushedReader scheduleInRunLoop:aRunLoop forMode:self.modes[[self.runLoops indexOfObject:aRunLoop]]];
}

@end
