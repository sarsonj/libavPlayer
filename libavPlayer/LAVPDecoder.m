//
//  LAVPDecoder.m
//  libavPlayer
//
//  Created by Takashi Mochizuki on 11/06/18.
//  Copyright 2011 MyCometG3. All rights reserved.
//
/*
 This file is part of livavPlayer.
 
 livavPlayer is free software; you can redistribute it and/or modify
 it under the terms of the GNU General Public License as published by
 the Free Software Foundation; either version 2 of the License, or
 (at your option) any later version.
 
 livavPlayer is distributed in the hope that it will be useful,
 but WITHOUT ANY WARRANTY; without even the implied warranty of
 MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 GNU General Public License for more details.
 
 You should have received a copy of the GNU General Public License
 along with libavPlayer; if not, write to the Free Software
 Foundation, Inc., 51 Franklin St, Fifth Floor, Boston, MA  02110-1301  USA
 */

#import "LAVPDecoder.h"

extern double get_master_clock(VideoState *is);
extern void stream_seek(VideoState *is, int64_t pos, int64_t rel, int seek_by_bytes);
extern void stream_pause(VideoState *is);
extern void stream_close(VideoState *is);
extern VideoState* stream_open(id opaque, NSURL *sourceURL);
extern void alloc_picture(void *opaque);
extern void video_refresh_timer(void *opaque);
extern int hasImage(void *opaque, double_t targetpts);
extern int copyImage(void *opaque, double_t *targetpts, uint8_t* data, const int pitch) ;
extern int hasImageCurrent(void *opaque);
extern int copyImageCurrent(void *opaque, double_t *targetpts, uint8_t* data, int pitch) ;
extern AudioQueueParameterValue getVolume(VideoState *is);
extern void setVolume(VideoState *is, AudioQueueParameterValue volume);
extern double_t stream_playRate(VideoState *is);
extern void stream_setPlayRate(VideoState *is, double_t newRate);

#pragma mark -

@interface LAVPDecoder (internal)

- (void) allocPicture;

@end


@implementation LAVPDecoder

- (id) initWithURL:(NSURL *)sourceURL error:(NSError **)errorPtr
{
	self = [super init];
	if (self) {
		is = stream_open(self, sourceURL);
		if (is) {
			[NSThread detachNewThreadSelector:@selector(threadMain) toTarget:self withObject:nil];
			
			int retry = 150;	// 1.5 sec max
			while(retry--) {
				usleep(10*1000);
				
				if (is->pictq_size) break;
			}
			if (retry < 0) 
				NSLog(@"ERROR: stream_open timeout detected.");
			stream_pause(is);
		} else {
			[self release];
			self = nil;
		}
	}
	
	return self;
}

- (void) invalidate
{
	// perform clean up
	if (is && is->decoderThread) {
		NSThread *dt = is->decoderThread;
		[dt retain];
		[dt cancel];
		while (![dt isFinished]) {
			usleep(10*1000);
		}
		[dt release];
		dt = NULL;
		
		stream_close(is);
		is = NULL;
	}
	if (pb) {
		CVPixelBufferRelease(pb);
		pb = NULL;
	}
}

- (void) finalize
{
	[self invalidate];
	
	[super finalize];
}

- (void) dealloc
{
	[self invalidate];
	[super dealloc];
}

- (void) threadMain
{
	NSAutoreleasePool *pool = [NSAutoreleasePool new];
	
	// Prepare thread runloop
	NSRunLoop* runLoop = [NSRunLoop currentRunLoop];
	
	is->decoderThread = [NSThread currentThread];
	
	NSTimer *timer = [NSTimer scheduledTimerWithTimeInterval:1.0/120 
													  target:self 
													selector:@selector(refreshPicture) 
													userInfo:nil 
													 repeats:YES];
	[runLoop addTimer:timer forMode:NSRunLoopCommonModes];
	
	// 
	NSThread *dt = [NSThread currentThread];
	while ( ![dt isCancelled] ) {
		NSAutoreleasePool *p = [NSAutoreleasePool new];
		
		//NSLog(@"pos = %04.3f (sec)", [self position]/1.0e6);
		
		[runLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
		
		[p drain];
	}
	
	[timer invalidate];
	
	[pool drain];
}

- (void) allocPicture
{
	alloc_picture(is);
}

- (void) refreshPicture
{
	video_refresh_timer(is);
}

- (CVPixelBufferRef) createDummyCVPixelBufferWithSize:(NSSize)size {
	OSType format = '2vuy';	//k422YpCbCr8CodecType
	size_t width = size.width, height = size.height;
	CFDictionaryRef attr = NULL;
	CVPixelBufferRef pixelbuffer = NULL;
	
	assert(width * height > 0);
	CVReturn result = CVPixelBufferCreate(kCFAllocatorDefault, 
										  width, height, format, attr, &pixelbuffer);
	assert (result == kCVReturnSuccess && pixelbuffer);
	
	return pixelbuffer;
}

- (BOOL) readyForPTS:(double_t)pts
{
	// pts is in sec.
	
	if (hasImage(is, pts)) {
		return YES;
	}
	return NO;
}

- (CVPixelBufferRef) getPixelBufferForPTS:(double_t*)pts
{
	// pts is in sec.
	
	if (!pb) {
		pb = [self createDummyCVPixelBufferWithSize:NSMakeSize(is->width, is->height)];
	}
	
	double_t currentpts = *pts;
	
	// Get current buffer for pts
	CVPixelBufferLockBaseAddress(pb, 0);
	
	uint8_t* data = CVPixelBufferGetBaseAddress(pb);
	int pitch = CVPixelBufferGetBytesPerRow(pb);
	int ret = copyImage(is, &currentpts, data, pitch);
	
	CVPixelBufferUnlockBaseAddress(pb, 0);
	
	//
	if (ret == 1) {
		*pts = currentpts;
		return pb;
	} else if (ret == 2) {
		*pts = currentpts;
		return pb;
	}
	return NULL;
}

- (BOOL) readyForCurrent
{
	if (hasImageCurrent(is)) {
		return YES;
	}
	return NO;
}

- (CVPixelBufferRef) getPixelBufferForCurrent:(double_t*)pts
{
	// returned pts is in sec.
	
	if (!pb) {
		pb = [self createDummyCVPixelBufferWithSize:NSMakeSize(is->width, is->height)];
	}
	
	double_t currentpts=0.0;
	
	// Get current buffer for now
	CVPixelBufferLockBaseAddress(pb, 0);
	
	uint8_t* data = CVPixelBufferGetBaseAddress(pb);
	int pitch = CVPixelBufferGetBytesPerRow(pb);
	int ret = copyImageCurrent(is, &currentpts, data, pitch);
	
	CVPixelBufferUnlockBaseAddress(pb, 0);
	
	//
	if (ret == 1) {
		*pts = currentpts;
		return pb;
	} else if (ret == 2) {
		*pts = currentpts;
		return pb;
	}
	return NULL;
}

- (NSSize) frameSize
{
	NSSize size = NSMakeSize(is->width, is->height);
	
	if (is->video_st && is->video_st->codec) {
		AVRational sRatio = is->video_st->sample_aspect_ratio;
		AVRational cRatio = is->video_st->codec->sample_aspect_ratio;
		
		if (sRatio.num * sRatio.den) {
			// Use stream aspect ratio
			size = NSMakeSize(is->width * sRatio.num / sRatio.den, is->height);
		} else if (cRatio.num * cRatio.den) {
			// Use codec aspect ratio
			size = NSMakeSize(is->width * cRatio.num / cRatio.den, is->height);
		}
	}
	
	//NSLog(@"size = %@", NSStringFromSize(size));
	return size;
}

- (CGFloat) rate
{
	if (!is)
		return 0.0f;
	else if (is->ic && is->ic->duration <= 0)
		return 0.0f;
	
	if (is->paused) 
		return 0.0f;
	else 
		return stream_playRate(is);
}

- (void) setRate:(CGFloat)rate
{
	/* note: only accept 0.0 and positive */
	if (!is || rate < 0.0) {
		return;
	}
	
	if (rate > 0) {
		stream_setPlayRate(is, rate);
		if (is && is->paused) {
			stream_pause(is);
		}
	} else {
		if (is && !is->paused) {
			stream_pause(is);
		}
	}
}

- (int64_t) duration
{
	// duration is in AV_TIME_BASE value.
	// avutil.h defines timebase for AVFormatContext - in usec.
	
	if (is && is->ic) {
		return is->ic->duration;
	}
	return 0;
}

- (int64_t) position
{
	// position is in AV_TIME_BASE value.
	// avutil.h defines timebase for AVFormatContext - in usec.
	
	if (is && is->ic) {
		return get_master_clock(is) * 1e6;
	}
	return 0;
}

- (int64_t) setPosition:(int64_t)pos blocking:(BOOL)blocking;
{
	// position is in AV_TIME_BASE value.
	// avutil.h defines timebase for AVFormatContext - in usec.
	
	if (is && is->ic) {
		int64_t ts = FFMIN(is->ic->duration , FFMAX(0, pos));
		
		if (is->ic->start_time != AV_NOPTS_VALUE)
			ts += is->ic->start_time;
		
		stream_seek(is, ts, 0, 0);
		
		{
			// Wait till avformat_seek_file() is completed
			int count = 0, limit = 100;
			for (; limit > count; count++) {
				usleep(10*1000);
				if (!is->seek_req) break;
			}
		}
		{
			// seek wait - blocking
			double_t rate = [self rate];
			if (!rate) [self setRate:8.0];
			if (blocking) {
				// wait till time error is less than allowed drift
				double_t diff = get_master_clock(is) - ts/1.0e6;
				double_t prev = is->ic->duration;
				double_t drift = (rate == 0.0) ? 1.0/25 : 1.0/2;
				int count = 0, limit = (rate == 0.0) ? 300 : 100;
				
				//NSLog(@"diff = %.3f", diff);
				for	(;limit>count;count++) {
					diff = get_master_clock(is) - ts/1.0e6;
					if (fabs(diff) < 1.0) {
						if ( (diff < 0 && -diff < drift) || (diff >= 0 && diff > prev) ) 
							break;
					}
					prev = diff;
					
					if (is->paused) break;
					
					usleep(10*1000);
				}
				//NSLog(@"diff = %.3f %d %@", diff, count, ((limit > count) ? @"" : @"timeout"));
				
				if (limit == count) {
					NSLog(@"ERROR:%@: Seek timeout (offset = %.3f sec)", [self class], diff);
				}
			} else {
				usleep(50*1000);	// give some time to prepare new image
			}
			[self setRate:0.0];
		}
		
		return ts;
	}
	return 0;
}

- (Float32) volume
{
	Float32 volume = 0.0;
	if (is && is->audio_stream >= 0) {
		volume = getVolume(is);
	}
	return volume;
}

- (void) setVolume:(Float32)volume
{
	AudioQueueParameterValue newVolume = volume;
	if (is && is->audio_stream >= 0) {
		setVolume(is, newVolume);
	}
}

- (BOOL) eof
{
	return (is->eof ? YES : NO);
}

@end
