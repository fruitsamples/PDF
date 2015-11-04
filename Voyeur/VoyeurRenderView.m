//
//  VoyeurRenderView.m
//  Voyeur
//
//  Created by Joel Kraut on 7/18/05.
//  Copyright 2005 Apple Computer, Inc. All rights reserved.
//

/* IMPORTANT: This Apple software is supplied to you by Apple Computer,
Inc. ("Apple") in consideration of your agreement to the following terms,
and your use, installation, modification or redistribution of this Apple
software constitutes acceptance of these terms.  If you do not agree with
these terms, please do not use, install, modify or redistribute this Apple
software.

In consideration of your agreement to abide by the following terms, and
subject to these terms, Apple grants you a personal, non-exclusive
license, under Apple's copyrights in this original Apple software (the
"Apple Software"), to use, reproduce, modify and redistribute the Apple
Software, with or without modifications, in source and/or binary forms;
provided that if you redistribute the Apple Software in its entirety and
without modifications, you must retain this notice and the following text
and disclaimers in all such redistributions of the Apple Software.
Neither the name, trademarks, service marks or logos of Apple Computer,
Inc. may be used to endorse or promote products derived from the Apple
Software without specific prior written permission from Apple. Except as
expressly stated in this notice, no other rights or licenses, express or
implied, are granted by Apple herein, including but not limited to any
patent rights that may be infringed by your derivative works or by other
works in which the Apple Software may be incorporated.

The Apple Software is provided by Apple on an "AS IS" basis.  APPLE MAKES
NO WARRANTIES, EXPRESS OR IMPLIED, INCLUDING WITHOUT LIMITATION THE
IMPLIED WARRANTIES OF NON-INFRINGEMENT, MERCHANTABILITY AND FITNESS FOR A
PARTICULAR PURPOSE, REGARDING THE APPLE SOFTWARE OR ITS USE AND OPERATION
ALONE OR IN COMBINATION WITH YOUR PRODUCTS.

IN NO EVENT SHALL APPLE BE LIABLE FOR ANY SPECIAL, INDIRECT, INCIDENTAL OR
CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
INTERRUPTION) ARISING IN ANY WAY OUT OF THE USE, REPRODUCTION,
MODIFICATION AND/OR DISTRIBUTION OF THE APPLE SOFTWARE, HOWEVER CAUSED AND
WHETHER UNDER THEORY OF CONTRACT, TORT (INCLUDING NEGLIGENCE), STRICT
LIABILITY OR OTHERWISE, EVEN IF APPLE HAS BEEN ADVISED OF THE POSSIBILITY
OF SUCH DAMAGE. */

#import "VoyeurRenderView.h"

// for changes to the transform matrix
void op_cm(CGPDFScannerRef scanner, void *info);
void op_q(CGPDFScannerRef scanner, void *info);
void op_Q(CGPDFScannerRef scanner, void *info);
// for drawing XObjects or images
void op_Do(CGPDFScannerRef scanner, void *info);
void op_EI(CGPDFScannerRef scanner, void *info);
// for changes to the path
void op_b(CGPDFScannerRef scanner, void *info);
void op_bStar(CGPDFScannerRef scanner, void *info);
void op_c(CGPDFScannerRef scanner, void *info);
void op_h(CGPDFScannerRef scanner, void *info);
void op_l(CGPDFScannerRef scanner, void *info);
void op_m(CGPDFScannerRef scanner, void *info);
void op_n(CGPDFScannerRef scanner, void *info);
void op_re(CGPDFScannerRef scanner, void *info);
void op_s(CGPDFScannerRef scanner, void *info);
void op_v(CGPDFScannerRef scanner, void *info);
void op_y(CGPDFScannerRef scanner, void *info);
// for drawing a shading
void op_sh(CGPDFScannerRef scanner, void *info);

void outlineWalk(VoyeurNode *node, NSOutlineView *outlineView);

@implementation VoyeurRenderView

- (id)initWithFrame:(NSRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        tagsSet = [[NSMutableSet alloc] init];
		matrixStack = CFArrayCreateMutable(NULL, 0, NULL);
		currentMatrix = malloc(sizeof(CGAffineTransform));
		[self setEditable: NO];
		[[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(sizeChanged) name:NSWindowDidResizeNotification object:[self window]];
    }
    return self;
}

- (void)sizeChanged
{
	float scale = 0.0;
	NSRect rect = [self bounds];
	float ratioH = rect.size.height / [[self image] size].height;
	float ratioW = rect.size.width / [[self image] size].width;
	if ([self image])
		scale = ratioH < ratioW ? ratioH : ratioW;
	[tagsSet makeObjectsPerformSelector:@selector(setScale:) withObject:[NSNumber numberWithFloat: scale]];
}

- (bool)parseTagsFromNode:(VoyeurNode *)node
{
	// clean up
	int i;
	for(i = 0; i < CFArrayGetCount(matrixStack); ++i)
		free((CGAffineTransform *)CFArrayGetValueAtIndex(matrixStack, i));
	CFArrayRemoveAllValues(matrixStack);
	[tagsSet removeAllObjects];
	memcpy(currentMatrix, &CGAffineTransformIdentity, sizeof(CGAffineTransform));
	CGPathRelease(currentPath);
	currentPath = CGPathCreateMutable();
	CGPathRetain(currentPath);
	VoyeurNode *dict = [node pageResDictNode];
	resourceNode = dict;
	
	CGPDFContentStreamRef csStream = NULL;
	CGPDFStreamRef stream = NULL;
	CGPDFDictionaryRef resDict = NULL;
	
	if ([node type] == kCGPDFObjectTypeDictionary)
	{
		CGPDFDictionaryRef d;
		const char *name;
		CGPDFObjectGetValue([node object], kCGPDFObjectTypeDictionary, &d);
		if (CGPDFDictionaryGetName(d, "Type", &name))
			if (!strcmp(name, "Page"))
				if (CGPDFDictionaryGetStream(d, "Contents", &stream))
				{
					if (CGPDFDictionaryGetDictionary(CGPDFStreamGetDictionary(stream), "Resources", &d))
						resDict = d;
				}
	}
	else 
	{
		if ([node type] != kCGPDFObjectTypeStream)
			return NO;
		
		CGPDFObjectGetValue([node object], kCGPDFObjectTypeStream, &stream);
		if (!stream)
			return NO;
	}
	
	if (!resDict)
	{
		CGPDFObjectGetValue([dict object], kCGPDFObjectTypeDictionary, &resDict);
		if (!resDict)
			return NO;
	}
		
	csStream = CGPDFContentStreamCreateWithStream(stream, resDict, NULL);
	
	bool result = YES;
	NSArray *kids = [resourceNode children];
	NSEnumerator *enumerator = [kids objectEnumerator];
	VoyeurNode *kid;
	while ((kid = [enumerator nextObject]))
	{	
		if ([[kid name] isEqualToString:@"/XObject"] && [kid type] == kCGPDFObjectTypeDictionary)
			xObjectDictNode = kid;
		else if ([[kid name] isEqualToString:@"/Shading"] && [kid type] == kCGPDFObjectTypeDictionary)
			shadingDictNode = kid;
	}
	CGPDFScannerRef scanner;
	CGPDFOperatorTableRef table = CGPDFOperatorTableCreate();
	if (!table)
		result = NO;
	if (result)
	{
		CGPDFOperatorTableSetCallback(table, "cm", &op_cm);
		CGPDFOperatorTableSetCallback(table, "Do", &op_Do);
		CGPDFOperatorTableSetCallback(table, "EI", &op_EI);
		CGPDFOperatorTableSetCallback(table, "q", &op_q);
		CGPDFOperatorTableSetCallback(table, "Q", &op_Q);
		CGPDFOperatorTableSetCallback(table, "b", &op_b);
		CGPDFOperatorTableSetCallback(table, "b*", &op_bStar);
		CGPDFOperatorTableSetCallback(table, "c", &op_c);
		CGPDFOperatorTableSetCallback(table, "l", &op_l);
		CGPDFOperatorTableSetCallback(table, "h", &op_h);
		CGPDFOperatorTableSetCallback(table, "m", &op_m);
		CGPDFOperatorTableSetCallback(table, "n", &op_n);
		CGPDFOperatorTableSetCallback(table, "re", &op_re);
		CGPDFOperatorTableSetCallback(table, "s", &op_s);
		CGPDFOperatorTableSetCallback(table, "v", &op_v);
		CGPDFOperatorTableSetCallback(table, "y", &op_y);
		CGPDFOperatorTableSetCallback(table, "sh", &op_sh);
	}
	if (result)
	{
		scanner = CGPDFScannerCreate(csStream, table, self);
		if (!scanner)
			result = NO;
	}
	if (result)
		result = CGPDFScannerScan(scanner);
	if (table)
		CGPDFOperatorTableRelease(table);
	if (scanner)
		CGPDFScannerRelease(scanner);
	// releasing the content stream also releases the resource dictionary--bad!
//	if (csStream)
//		CGPDFContentStreamRelease(csStream);
	[self sizeChanged];
	return result;
}

- (void)drawRect:(NSRect)rect {
	[super drawRect:rect];
	[self lockFocus];
	[tagsSet makeObjectsPerformSelector:@selector(render)];
	[self unlockFocus];
}

- (void)dealloc
{
	int i;
	for(i = 0; i < CFArrayGetCount(matrixStack); ++i)
		free((CGAffineTransform *)CFArrayGetValueAtIndex(matrixStack, i));
	CFRelease(matrixStack);
	CGPathRelease(currentPath);
	CGPathRelease(previousPath);
	if (currentMatrix)
		free(currentMatrix);
	[[NSNotificationCenter defaultCenter] removeObserver:self];
	[tagsSet release];
	[super dealloc];
}
- (void)addTagForName:(const char*)n
{
	VoyeurNode *kid = nil, *xObjectKid = nil, *shadingKid = nil;
	bool isShading = NO;
	if (n != NULL)
	{
		NSString *name = [NSString stringWithFormat:@"/%s", n];
		NSArray *kids = [xObjectDictNode children];
		NSEnumerator *enumerator = [kids objectEnumerator];
		
		while ((kid = (VoyeurNode *)[enumerator nextObject]))
			if ([[kid name] isEqualToString: name])
			{
				xObjectKid = kid;
				break;
			}
		
		if (!xObjectKid)
		{
			kids = [shadingDictNode children];
			enumerator = [kids objectEnumerator];
			
			while ((kid = (VoyeurNode *)[enumerator nextObject]))
				if ([[kid name] isEqualToString: name])
				{
					shadingKid = kid;
					isShading = YES;
					break;
				}
		}
		if (!shadingKid && !xObjectKid)
			return;
	}
	xObjectTag *tag;
	if (isShading)
		tag = [[xObjectTag alloc] initWithMatrix:CGAffineTransformIdentity
											path:(CGPathIsEmpty(currentPath) ? previousPath : currentPath) 
										  target:shadingKid view:self outlineView:outlineView];
	else
		tag = [[xObjectTag alloc] initWithMatrix:(*currentMatrix) path:NULL target:xObjectKid view:self outlineView:outlineView];
	[tagsSet addObject:tag];
	[tag release];
}

- (BOOL)acceptsFirstResponder 
{
    return YES;
}

- (void)mouseDown:(NSEvent *)theEvent
{
	[tagsSet makeObjectsPerformSelector:@selector(mouseDown:) withObject:theEvent];
}

- (void)mouseUp:(NSEvent *)theEvent
{
//	[tagsSet makeObjectsPerformSelector:@selector(mouseUp:) withObject:theEvent];
	NSEnumerator *e = [tagsSet objectEnumerator];
	xObjectTag *tag;
	while ((tag = (xObjectTag*)[e nextObject]))
		if ([tag mouseUp:theEvent])
			break;
}

- (void)pushMatrix
{
	CGAffineTransform *newMatrix = malloc(sizeof(CGAffineTransform));
	if (!newMatrix)
		return;
	memcpy(newMatrix, currentMatrix, sizeof(CGAffineTransform));
	CFArrayAppendValue(matrixStack, newMatrix);
}

- (void)popMatrix
{
	size_t count = CFArrayGetCount(matrixStack);
	if (count == 0)
		return;
	if (currentMatrix)
		free(currentMatrix);
	currentMatrix = (CGAffineTransform*)CFArrayGetValueAtIndex(matrixStack, count - 1);
	CFArrayRemoveValueAtIndex(matrixStack, count - 1);
}

- (void)concatMatrix:(CGAffineTransform)m
{
	CGAffineTransform result = CGAffineTransformConcat(m, (*currentMatrix));
	memcpy(currentMatrix, &result, sizeof(CGAffineTransform));
}

- (CGMutablePathRef)currentPath
{
	return currentPath;
}

- (void)clearCurrentPath
{
	CGPathRelease(previousPath);
	previousPath = currentPath;
	currentPath = CGPathCreateMutable();
	CGPathRetain(currentPath);
}

- (const CGAffineTransform *)currentMatrix
{
	return currentMatrix;
}

@end


/* operator table functions
 */

void op_cm(CGPDFScannerRef scanner, void *info)
{
	VoyeurRenderView *self = info;
	CGAffineTransform m;
    CGPDFReal a, b, c, d, tx, ty;
	
    if (!CGPDFScannerPopNumber(scanner, &ty))
		return;
    if (!CGPDFScannerPopNumber(scanner, &tx))
		return;
    if (!CGPDFScannerPopNumber(scanner, &d))
		return;
    if (!CGPDFScannerPopNumber(scanner, &c))
		return;
    if (!CGPDFScannerPopNumber(scanner, &b))
		return;
    if (!CGPDFScannerPopNumber(scanner, &a))
		return;
    m = CGAffineTransformMake(a, b, c, d, tx, ty);
	[self concatMatrix:m];
}

void op_Do(CGPDFScannerRef scanner, void *info)
{
	VoyeurRenderView *self = info;
	const char *name;
	if (!CGPDFScannerPopName(scanner, &name))
		return;
	[self addTagForName:name];
}

void op_EI(CGPDFScannerRef scanner, void *info)
{
	VoyeurRenderView *self = info;
	[self addTagForName: NULL];
}

void op_q(CGPDFScannerRef scanner, void *info)
{
	VoyeurRenderView *self = info;
	[self pushMatrix];
}

void op_Q(CGPDFScannerRef scanner, void *info)
{
	VoyeurRenderView *self = info;
	[self popMatrix];
}

void op_b(CGPDFScannerRef scanner, void *info)
{
	VoyeurRenderView *self = info;
	CGPathCloseSubpath([self currentPath]);
}

void op_bStar(CGPDFScannerRef scanner, void *info)
{
	VoyeurRenderView *self = info;
	CGPathCloseSubpath([self currentPath]);
}

void op_c(CGPDFScannerRef scanner, void *info)
{
	VoyeurRenderView *self = info;
	CGPDFReal x1, y1, x2, y2, x3, y3;
	if (!CGPDFScannerPopNumber(scanner, &y3))
		return;
	if (!CGPDFScannerPopNumber(scanner, &x3))
		return;
	if (!CGPDFScannerPopNumber(scanner, &y2))
		return;
	if (!CGPDFScannerPopNumber(scanner, &x2))
		return;
	if (!CGPDFScannerPopNumber(scanner, &y1))
		return;
	if (!CGPDFScannerPopNumber(scanner, &x1))
		return;
	CGPathAddCurveToPoint([self currentPath], [self currentMatrix], x1, y1, x2, y2, x3, y3);
}

void op_h(CGPDFScannerRef scanner, void *info)
{
	VoyeurRenderView *self = info;
	CGPathCloseSubpath([self currentPath]);
}

void op_l(CGPDFScannerRef scanner, void *info)
{
	VoyeurRenderView *self = info;
	CGPDFReal x, y;
	if (!CGPDFScannerPopNumber(scanner, &y))
		return;
	if (!CGPDFScannerPopNumber(scanner, &x))
		return;
	CGPathAddLineToPoint([self currentPath], [self currentMatrix], x, y);
}

void op_m(CGPDFScannerRef scanner, void *info)
{
	VoyeurRenderView *self = info;
	CGPDFReal x, y;
	if (!CGPDFScannerPopNumber(scanner, &y))
		return;
	if (!CGPDFScannerPopNumber(scanner, &x))
		return;
	CGPathMoveToPoint([self currentPath], [self currentMatrix], x, y);
}

void op_n(CGPDFScannerRef scanner, void *info)
{
	VoyeurRenderView *self = info;
	[self clearCurrentPath];
}

void op_re(CGPDFScannerRef scanner, void *info)
{
	VoyeurRenderView *self = info;
	CGPDFReal x, y, width, height;
	if (!CGPDFScannerPopNumber(scanner, &height))
		return;
	if (!CGPDFScannerPopNumber(scanner, &width))
		return;
	if (!CGPDFScannerPopNumber(scanner, &y))
		return;
	if (!CGPDFScannerPopNumber(scanner, &x))
		return;
	CGPathAddRect([self currentPath], [self currentMatrix], CGRectMake(x, y, width, height));
}

void op_s(CGPDFScannerRef scanner, void *info)
{
	VoyeurRenderView *self = info;
	CGPathCloseSubpath([self currentPath]);
}

void op_v(CGPDFScannerRef scanner, void *info)
{
	VoyeurRenderView *self = info;
	CGPDFReal x2, y2, x3, y3;
	if (!CGPDFScannerPopNumber(scanner, &y3))
		return;
	if (!CGPDFScannerPopNumber(scanner, &x3))
		return;
	if (!CGPDFScannerPopNumber(scanner, &y2))
		return;
	if (!CGPDFScannerPopNumber(scanner, &x2))
		return;
	CGPoint currentPoint = CGPathGetCurrentPoint([self currentPath]);
	CGPathAddCurveToPoint([self currentPath], [self currentMatrix], currentPoint.x, currentPoint.y, x2, y2, x3, y3);
}

void op_y(CGPDFScannerRef scanner, void *info)
{
	VoyeurRenderView *self = info;
	CGPDFReal x1, y1, x3, y3;
	if (!CGPDFScannerPopNumber(scanner, &y3))
		return;
	if (!CGPDFScannerPopNumber(scanner, &x3))
		return;
	if (!CGPDFScannerPopNumber(scanner, &y1))
		return;
	if (!CGPDFScannerPopNumber(scanner, &x1))
		return;
	CGPathAddCurveToPoint([self currentPath], [self currentMatrix], x1, y1, x3, y3, x3, y3);
}

void op_sh(CGPDFScannerRef scanner, void *info)
{
	VoyeurRenderView *self = info;
	const char *name;
	if (!CGPDFScannerPopName(scanner, &name))
		return;
	[self addTagForName:name];
}


@implementation xObjectTag
-(id)initWithMatrix:(CGAffineTransform)m path:(CGPathRef)p target:(VoyeurNode *)t view:(NSImageView *)v outlineView:(NSOutlineView *)ov
{
	self = [self init];
	if (self)
	{
		matrix = m;
		if (p != NULL)
			myInitialRect = CGPathGetBoundingBox(p);
		else
			myInitialRect = CGRectMake(0, 0, 1, 1);
		target = [t retain];
		scale = 0.0;
		view = v;
		outlineView = ov;
		active = NO;
		trackingRect = -1;
		defaultColor = [[NSColor colorWithDeviceWhite:.5 alpha:.125] retain];
		clickedColor = [[NSColor colorWithDeviceWhite:.35 alpha:.25] retain];
		clicked = NO;
		CGPDFStreamRef stream = NULL;
		CGPDFDictionaryRef dict = NULL;
		CGPDFArrayRef array;
		CGPDFReal pdfReal;
		CGAffineTransform transform = CGAffineTransformIdentity;
		if (CGPDFObjectGetValue([target object], kCGPDFObjectTypeStream, &stream))
			if ((dict = CGPDFStreamGetDictionary(stream)))
			{
				if (CGPDFDictionaryGetArray(dict, "BBox", &array))
				{
					if (CGPDFArrayGetNumber(array, 0, &pdfReal))
						myInitialRect.origin.x = pdfReal;
					if (CGPDFArrayGetNumber(array, 1, &pdfReal))
						myInitialRect.origin.y = pdfReal;
					if (CGPDFArrayGetNumber(array, 2, &pdfReal))
						myInitialRect.size.width = pdfReal;
					if (CGPDFArrayGetNumber(array, 3, &pdfReal))
						myInitialRect.size.height = pdfReal;
//					NSLog(@"got bbox: %f %f %f %f", myInitialRect.origin.x, myInitialRect.origin.y, myInitialRect.size.width, myInitialRect.size.height);
				}
				if (CGPDFDictionaryGetArray(dict, "Matrix", &array))
				{
					if (CGPDFArrayGetNumber(array, 0, &pdfReal))
						transform.a = pdfReal;
					if (CGPDFArrayGetNumber(array, 1, &pdfReal))
						transform.b = pdfReal;
					if (CGPDFArrayGetNumber(array, 2, &pdfReal))
						transform.c = pdfReal;
					if (CGPDFArrayGetNumber(array, 3, &pdfReal))
						transform.d = pdfReal;
					if (CGPDFArrayGetNumber(array, 4, &pdfReal))
						transform.tx = pdfReal;
					if (CGPDFArrayGetNumber(array, 5, &pdfReal))
						transform.ty = pdfReal;
//					NSLog(@"got matrix: \n%f %f \n%f %f \n%f %f", transform.a, transform.b, transform.c, transform.d, transform.tx, transform.ty);
				}
			}
		matrix = CGAffineTransformConcat(transform, matrix);
	}
	return self;
}

-(void)setScale:(NSNumber *)s
{
	scale = [s floatValue];
	myRect = myInitialRect;
	float widthDifference = [view bounds].size.width - scale * [[view image] size].width;
	float heightDifference = [view bounds].size.height - scale * [[view image] size].height; 
	CGAffineTransform t = CGAffineTransformMakeTranslation(.5 * widthDifference, .5 * heightDifference);
	t = CGAffineTransformConcat(CGAffineTransformMakeScale(scale, scale), t);
	t = CGAffineTransformConcat(matrix, t);
	myRect = CGRectApplyAffineTransform(myRect, t);
	if (trackingRect >= 0)
		[view removeTrackingRect:trackingRect];
	trackingRect = [view addTrackingRect:*(NSRect *)&myRect owner:self userData:nil assumeInside:NO];
}

-(void)mouseEntered:(NSEvent *)theEvent
{
	clicked = NO;
	active = YES;
	[view setNeedsDisplayInRect:*(NSRect *)&myRect];
}

-(void)mouseExited:(NSEvent *)theEvent
{
	clicked = NO;
	active = NO;
	[view setNeedsDisplayInRect:*(NSRect *)&myRect];
}

- (void)mouseDown:(NSEvent *)theEvent
{
	if (!active)
		return;
	if (NSMouseInRect([view convertPoint:[theEvent locationInWindow] fromView:nil], *(NSRect *)&myRect, NO))
	{	
		clicked = YES;
		[view setNeedsDisplayInRect:*(NSRect *)&myRect];
	}
		
}

- (bool)mouseUp:(NSEvent *)theEvent
{
	if (!active)
		return NO;
	if (NSMouseInRect([view convertPoint:[theEvent locationInWindow] fromView:nil], *(NSRect *)&myRect, NO))
	{
		clicked = NO;
		[view setNeedsDisplayInRect:*(NSRect *)&myRect];
		if (target)
		{
			outlineWalk(target, outlineView);
			if ([outlineView rowForItem:target] >= 0)
			{
				[outlineView scrollRowToVisible:[outlineView rowForItem:target]];
				[outlineView selectRowIndexes:[NSIndexSet indexSetWithIndex:[outlineView rowForItem:target]] byExtendingSelection:NO];
			}
		}
		return YES;
	}
	return NO;
}

void outlineWalk(VoyeurNode *node, NSOutlineView *outlineView)
{
	if ([outlineView rowForItem:node] < 0)
		outlineWalk([node parent], outlineView);
	
	[outlineView expandItem:node];
}

-(void)render
{
	if (!active)
		return;
	[(clicked ? clickedColor : defaultColor) set];
	NSRectFillUsingOperation(*(NSRect *)&myRect, NSCompositeSourceOver);
	[[NSColor redColor] set];
	NSFrameRect(*(NSRect *)&myRect);
}

-(VoyeurNode *)target
{
	return target;
}

-(void)dealloc
{
	[target release];
	if (trackingRect >= 0)
		[view removeTrackingRect:trackingRect];
	[defaultColor release];
	[clickedColor release];
	[super dealloc];
}
@end