//
//  MNPushbackStream.h
//
//  Created by Matthew Nespor on 9/1/13.
//  Copyright (c) 2013 Matthew Nespor. All rights reserved.
//

#import <Foundation/Foundation.h>

@interface MNPushbackStream : NSStream
{
    id<NSStreamDelegate> _delegate;
}

+ (instancetype)pushbackStreamWithData:(NSData *)data;
+ (instancetype)pushbackStreamWithFileAtPath:(NSString *)path;
+ (instancetype)pushbackStreamWithURL:(NSURL* )url;
- (id)initWithData:(NSData *)data;
- (id)initWithFileAtPath:(NSString *)path;
- (id)initWithURL:(NSURL *)url;
- (NSInteger)read:(uint8_t *)buffer maxLength:(NSUInteger)len;
- (BOOL)getBuffer:(uint8_t **)buffer length:(NSUInteger *)len;
- (BOOL)hasBytesAvailable;

- (void)unread:(const void *)bytes offset:(NSUInteger)offset length:(NSUInteger)len;
- (void)unreadString:(NSString*)str encoding:(NSStringEncoding)encoding;

@end
