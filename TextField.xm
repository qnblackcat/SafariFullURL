#import "SafariFullURL.h"

// UIKit's side: the URL field (focus, folded first tap / unfolding, taps on wrapped
// lines), the edit menu on the selected URL, and the field editor (selection rects,
// scrolling, text position, layout).

// Private UITextSelectionRect API, forwarded by FUBSelectionRect.
@interface UITextSelectionRect (FUBPrivate)
- (UIBezierPath *)_path;
- (id)range;
- (BOOL)_drawsOwnHighlight;
- (id)_customHandleInfo;
@end

// A selection rect with a different rect, otherwise answering like the one it wraps.
// UITextSelectionRect's rect is read-only, hence the wrapper.
@interface FUBSelectionRect : UITextSelectionRect
- (instancetype)initWithRect:(CGRect)rect base:(UITextSelectionRect *)base;
@end

@implementation FUBSelectionRect {
    CGRect _rect;
    UITextSelectionRect *_base;
}

- (instancetype)initWithRect:(CGRect)rect base:(UITextSelectionRect *)base {
    if ((self = [super init])) {
        _rect = rect;
        _base = base;
    }
    return self;
}

- (CGRect)rect { return _rect; }
- (NSWritingDirection)writingDirection { return _base.writingDirection; }
- (BOOL)containsStart { return _base.containsStart; }
- (BOOL)containsEnd { return _base.containsEnd; }
- (BOOL)isVertical { return _base.isVertical; }

// A path would be drawn instead of the rect; leave it out so the new rect is used.
- (UIBezierPath *)_path { return nil; }
- (id)range { return [_base respondsToSelector:@selector(range)] ? [_base range] : nil; }
- (BOOL)_drawsOwnHighlight { return [_base respondsToSelector:@selector(_drawsOwnHighlight)] && [_base _drawsOwnHighlight]; }
- (id)_customHandleInfo { return [_base respondsToSelector:@selector(_customHandleInfo)] ? [_base _customHandleInfo] : nil; }

// Anything else UIKit asks for goes to the original.
- (id)forwardingTargetForSelector:(SEL)selector { return _base; }

@end

// Each line's selection rect is only as tall as the glyphs, a little less than the line
// pitch, so a multi-line selection shows thin gaps between lines. Stretch every rect down
// to the top of the next line's rect when the gap is small.
static NSArray<UITextSelectionRect *> *FillLineGaps(NSArray<UITextSelectionRect *> *rects, CGFloat maxGap) {
    if (rects.count < 2) return rects;
    NSMutableArray<UITextSelectionRect *> *result = [NSMutableArray arrayWithCapacity:rects.count];
    for (UITextSelectionRect *selectionRect in rects) {
        CGRect rect = selectionRect.rect;
        if (rect.size.height <= 0 || rect.size.width <= 0) {
            [result addObject:selectionRect];
            continue;
        }
        CGFloat bottom = CGRectGetMaxY(rect);
        CGFloat nextTop = CGFLOAT_MAX;
        for (UITextSelectionRect *other in rects) {
            CGRect otherRect = other.rect;
            if (otherRect.size.height <= 0 || otherRect.size.width <= 0) continue;
            CGFloat top = CGRectGetMinY(otherRect);
            if (top > bottom - 0.01 && top < nextTop) nextTop = top;
        }
        CGFloat gap = nextTop - bottom;
        if (gap > 0.01 && gap < maxGap) {
            rect.size.height += gap;
            [result addObject:[[FUBSelectionRect alloc] initWithRect:rect base:selectionRect]];
        } else {
            [result addObject:selectionRect];
        }
    }
    LOG(@"selection rects %lu, filled %lu", (unsigned long)rects.count,
        (unsigned long)[result indexesOfObjectsPassingTest:^BOOL(id rect, NSUInteger i, BOOL *stop) {
            return [rect isKindOfClass:[FUBSelectionRect class]];
        }].count);
    return result;
}

// Wrapped text comes back as several rects per line (the text, then a small piece at the
// line end) that do not start and end at the same height: the highlight gets a step at the
// end of the line. Give every rect of one line the vertical extent of all of them together.
static NSArray<UITextSelectionRect *> *AlignLineRects(NSArray<UITextSelectionRect *> *rects) {
    if (rects.count < 2) return rects;
    NSMutableArray<UITextSelectionRect *> *result = [NSMutableArray arrayWithCapacity:rects.count];
    for (UITextSelectionRect *selectionRect in rects) {
        CGRect rect = selectionRect.rect;
        CGFloat top = CGRectGetMinY(rect), bottom = CGRectGetMaxY(rect);
        for (UITextSelectionRect *other in rects) {
            CGRect otherRect = other.rect;
            // Same line when they overlap by more than half of the shorter one.
            CGFloat overlap = MIN(bottom, CGRectGetMaxY(otherRect)) - MAX(top, CGRectGetMinY(otherRect));
            if (overlap > MIN(rect.size.height, otherRect.size.height) / 2) {
                top = MIN(top, CGRectGetMinY(otherRect));
                bottom = MAX(bottom, CGRectGetMaxY(otherRect));
            }
        }
        if (fabs(top - CGRectGetMinY(rect)) > 0.01 || fabs(bottom - CGRectGetMaxY(rect)) > 0.01) {
            rect.origin.y = top;
            rect.size.height = bottom - top;
            [result addObject:[[FUBSelectionRect alloc] initWithRect:rect base:selectionRect]];
        } else {
            [result addObject:selectionRect];
        }
    }
    return result;
}

// Whether the whole (non-empty) text of the field is selected.
static BOOL SelectsAll(UITextField *field) {
    UITextRange *selection = field.selectedTextRange;
    if (!selection) return NO;
    NSInteger length = [field offsetFromPosition:field.beginningOfDocument toPosition:field.endOfDocument];
    NSInteger start = [field offsetFromPosition:field.beginningOfDocument toPosition:selection.start];
    NSInteger end = [field offsetFromPosition:field.beginningOfDocument toPosition:selection.end];
    return length > 0 && start == 0 && end == length;
}

%hook UnifiedField

// Scalar state lives in NSNumbers so a value never set reads as 0. Logos' scalar
// %property getter reads an uninitialized variable when nothing was stored yet.
%new(d@:)
- (CGFloat)fub_extra { return [objc_getAssociatedObject(self, @selector(fub_extra)) doubleValue]; }
%new(v@:d)
- (void)setFub_extra:(CGFloat)value { objc_setAssociatedObject(self, @selector(fub_extra), @(value), OBJC_ASSOCIATION_RETAIN_NONATOMIC); }
%new(B@:)
- (BOOL)fub_fits { return [objc_getAssociatedObject(self, @selector(fub_fits)) boolValue]; }
%new(v@:B)
- (void)setFub_fits:(BOOL)value { objc_setAssociatedObject(self, @selector(fub_fits), @(value), OBJC_ASSOCIATION_RETAIN_NONATOMIC); }
%new(d@:)
- (CGFloat)fub_contentHeight { return [objc_getAssociatedObject(self, @selector(fub_contentHeight)) doubleValue]; }
%new(v@:d)
- (void)setFub_contentHeight:(CGFloat)value { objc_setAssociatedObject(self, @selector(fub_contentHeight), @(value), OBJC_ASSOCIATION_RETAIN_NONATOMIC); }
%new(d@:)
- (CGFloat)fub_baseHeight { return [objc_getAssociatedObject(self, @selector(fub_baseHeight)) doubleValue]; }
%new(v@:d)
- (void)setFub_baseHeight:(CGFloat)value { objc_setAssociatedObject(self, @selector(fub_baseHeight), @(value), OBJC_ASSOCIATION_RETAIN_NONATOMIC); }
%new(d@:)
- (CGFloat)fub_stockPad { return [objc_getAssociatedObject(self, @selector(fub_stockPad)) doubleValue]; }
%new(v@:d)
- (void)setFub_stockPad:(CGFloat)value { objc_setAssociatedObject(self, @selector(fub_stockPad), @(value), OBJC_ASSOCIATION_RETAIN_NONATOMIC); }
%new(B@:)
- (BOOL)fub_wrapped { return [objc_getAssociatedObject(self, @selector(fub_wrapped)) boolValue]; }
%new(v@:B)
- (void)setFub_wrapped:(BOOL)value { objc_setAssociatedObject(self, @selector(fub_wrapped), @(value), OBJC_ASSOCIATION_RETAIN_NONATOMIC); }
%new(q@:)
- (NSInteger)fub_savedLineBreakMode { return [objc_getAssociatedObject(self, @selector(fub_savedLineBreakMode)) integerValue]; }
%new(v@:q)
- (void)setFub_savedLineBreakMode:(NSInteger)value { objc_setAssociatedObject(self, @selector(fub_savedLineBreakMode), @(value), OBJC_ASSOCIATION_RETAIN_NONATOMIC); }
%new(B@:)
- (BOOL)fub_expanded { return [objc_getAssociatedObject(self, @selector(fub_expanded)) boolValue]; }
%new(v@:B)
- (void)setFub_expanded:(BOOL)value { objc_setAssociatedObject(self, @selector(fub_expanded), @(value), OBJC_ASSOCIATION_RETAIN_NONATOMIC); }
%new(B@:)
- (BOOL)fub_sawSelectAll { return [objc_getAssociatedObject(self, @selector(fub_sawSelectAll)) boolValue]; }
%new(v@:B)
- (void)setFub_sawSelectAll:(BOOL)value { objc_setAssociatedObject(self, @selector(fub_sawSelectAll), @(value), OBJC_ASSOCIATION_RETAIN_NONATOMIC); }
%new(B@:)
- (BOOL)fub_keptOpen { return [objc_getAssociatedObject(self, @selector(fub_keptOpen)) boolValue]; }
%new(v@:B)
- (void)setFub_keptOpen:(BOOL)value { objc_setAssociatedObject(self, @selector(fub_keptOpen), @(value), OBJC_ASSOCIATION_RETAIN_NONATOMIC); }
%property (nonatomic, strong) NSParagraphStyle *fub_savedParagraphStyle;

// Safari writes the text again when editing ends (Cancel, a tapped suggestion).
- (void)setText:(NSString *)text {
    %orig;
    if (self.fub_keptOpen && !self.isFirstResponder) EndKeptOpen(self);
}

- (BOOL)becomeFirstResponder {
    BOOL wasFirstResponder = self.isFirstResponder;
    if (self.fub_keptOpen && !wasFirstResponder) {
        // Back from a dragged-away keyboard: still the same editing session, stay unfolded.
        self.fub_keptOpen = NO;
        BOOL became = %orig;
        if (became) UpdateFieldEditor((UIFieldEditor *)[self _fieldEditor]);
        return became;
    }
    if (!wasFirstResponder) {
        self.fub_expanded = NO;
        self.fub_sawSelectAll = NO;
        self.fub_stockPad = 0; // measured again while folded (font size may have changed)
    }
    BOOL became = %orig;
    if (became && !wasFirstResponder) {
        // Safari selects the whole URL while focusing. Focusing again with the URL still
        // selected from last time changes nothing, so no selection change is reported:
        // look at the selection itself. If the URL is not selected (empty field, resumed
        // edit), there is no folded first-tap state to keep: unfold. Waiting one turn of
        // the run loop also covers a select-all that Safari sends asynchronously.
        if (SelectsAll(self)) self.fub_sawSelectAll = YES;
        __weak UnifiedField *weakSelf = self;
        dispatch_async(dispatch_get_main_queue(), ^{
            UnifiedField *field = weakSelf;
            if (!field.isFirstResponder || field.fub_expanded || field.fub_sawSelectAll) return;
            if (SelectsAll(field)) {
                LOG(@"URL already selected after focus, staying on one line");
                field.fub_sawSelectAll = YES;
                return;
            }
            LOG(@"no select-all after focus, unfolding");
            field.fub_expanded = YES;
            UpdateFieldEditor((UIFieldEditor *)[field _fieldEditor]);
        });
    }
    // Layout may already have run while the field was not first responder yet.
    if (became) UpdateFieldEditor((UIFieldEditor *)[self _fieldEditor]);
    return became;
}

- (BOOL)resignFirstResponder {
    // Dragging the suggestions dismisses the keyboard, but Safari keeps editing (list and
    // Cancel stay): keep the field as it is, unfolded or still folded on its first line,
    // instead of leaving it wrapped to a broken one-liner.
    BOOL keepOpen = self.isFirstResponder && self.window && KeyboardDismissDragInProgress(self.window);
    // Resigning lays the field out again from inside %orig, before it returns: the flag
    // has to be up by then or that layout folds the field.
    if (keepOpen) {
        self.fub_keptOpen = YES;
        NoteKeptOpen(self);
    }
    BOOL resigned = %orig;
    if (keepOpen && resigned) return resigned;
    if (keepOpen) self.fub_keptOpen = NO; // resigning failed, nothing to keep
    else if (self.fub_keptOpen) return resigned; // second resign of the same dismissal
    self.fub_keptOpen = NO;
    if (resigned) {
        self.fub_expanded = NO;
        self.fub_sawSelectAll = NO;
        if (self.fub_extra > 0) ApplyExtra(self, 0);
        SFCapsuleView *capsule = CapsuleOf(self);
        if (capsule && CapsuleChromeHidden(capsule)) [capsule setNeedsLayout]; // give Cancel back
    }
    return resigned;
}

// The field editor reports every selection change here (iOS 15 to 18).
- (void)fieldEditorDidChangeSelection:(id)editor {
    %orig;
    if (ScrollsVertically(self)) ScrollCaretVisible(self);
    if (!self.isFirstResponder || self.fub_expanded) return;
    UITextRange *selection = self.selectedTextRange;
    if (!selection) return;
    if (SelectsAll(self)) {
        if (!self.fub_sawSelectAll) LOG(@"select-all after focus, staying on one line");
        self.fub_sawSelectAll = YES;
        return;
    }
    if (!self.fub_sawSelectAll) return; // still focusing; the async check above decides
    LOG(@"selection %ld..%ld, unfolding", (long)Offset(self, selection.start), (long)Offset(self, selection.end));
    self.fub_expanded = YES;
    UIFieldEditor *fe = (UIFieldEditor *)[self _fieldEditor];
    if (gUpdating) {
        dispatch_async(dispatch_get_main_queue(), ^{ UpdateFieldEditor(fe); });
    } else {
        UpdateFieldEditor(fe);
    }
}

// -[UITextField closestPositionToPoint:] replaces the point's y with the middle of the
// caret rect at the start of the document, i.e. always the first line (iOS 15 to 18
// UIKitCore). Taps, double taps, the loupe and space-bar cursor dragging all go through
// here. While the field is grown, ask the field editor with the real point instead.
- (UITextPosition *)closestPositionToPoint:(CGPoint)point {
    if (!GrownField(self)) return %orig;
    UITextPosition *position = EditorPosition(self, point, nil);
    LOG(@"closestPositionToPoint (%.1f, %.1f) -> %ld (stock %ld)", point.x, point.y,
        (long)Offset(self, position), (long)Offset(self, %orig));
    return position;
}

- (UITextPosition *)closestPositionToPoint:(CGPoint)point withinRange:(UITextRange *)range {
    if (!GrownField(self)) return %orig;
    UITextPosition *position = EditorPosition(self, point, range);
    LOG(@"closestPositionToPoint:withinRange: (%.1f, %.1f) -> %ld", point.x, point.y, (long)Offset(self, position));
    return position;
}

// The space-bar caret: scroll the text when it is dragged past the visible lines.
- (void)updateFloatingCursorAtPoint:(CGPoint)point {
    if (ScrollsVertically(self)) AutoScrollForFloatingCursor(self, point);
    %orig;
}

%end

// The URL field behind a text input (the field itself or its field editor), otherwise nil.
static UnifiedField *URLFieldOfInput(id input) {
    if ([input isKindOfClass:%c(UIFieldEditor)]) input = MSHookIvar<UITextField *>(input, "_textField");
    return [input isKindOfClass:%c(UnifiedField)] ? input : nil;
}

// Safari 27.3 keeps the URL selected on the second tap after focusing and shows the edit
// menu as usual; the field only unfolds. That tap ends in
// -[UITextSelectionInteraction _handleMultiTapGesture:] -> showSelectionCommands (the
// first tap after focusing only hides the grabbers), sent to the UITextSelectionView up
// to iOS 16 and to the _UITextInteractionEditMenuAssistant from iOS 17. The selection
// does not change, so unfold here, before the menu is placed against the (now
// multi-line) selection.
static void UnfoldForMenu(UITextInteractionAssistant *assistant) {
    UnifiedField *field = URLFieldOfInput([assistant view]);
    if (!field.isFirstResponder || !field.fub_sawSelectAll || field.fub_expanded) return;
    LOG(@"edit menu on the selected URL, unfolding with the selection kept");
    field.fub_expanded = YES;
    UpdateFieldEditor((UIFieldEditor *)[field _fieldEditor]);
}

%hook UITextSelectionView

- (void)showSelectionCommands {
    UnfoldForMenu([self interactionAssistant]);
    %orig;
}

%end

%group EditMenuAssistant // iOS 17+

%hook _UITextInteractionEditMenuAssistant

- (void)showSelectionCommands {
    UnfoldForMenu(self.interactionAssistant);
    %orig;
}

%end

%end

@interface _UITextLayoutCanvasView : UIView
@end

// Text with tall glyphs (Vietnamese: đ, ạ, ế...) makes UIKit grow the canvas holding the text
// and the caret by a few points on each side, moving it up (y -2.33, height 50.33 instead of
// 0, 45). The text container origin is pinned (textContainerOriginForTextAlignment: below), so
// nothing compensates and the text jumps up. Keep the canvas at the top of the field editor;
// the field editor clips to its own bounds anyway.
%hook _UITextLayoutCanvasView

- (void)setFrame:(CGRect)frame {
    if (frame.origin.y != 0 && [self.superview isKindOfClass:%c(UIFieldEditor)]
        && WrappedFieldInEditor((UIFieldEditor *)self.superview)) {
        LOG(@"canvas frame %@ kept at y 0", NSStringFromCGRect(frame));
        frame.origin.y = 0;
    }
    %orig(frame);
}

%end

%hook UIFieldEditor

// UITextField forwards here too, so this covers whoever draws the selection.
- (NSArray *)selectionRectsForRange:(UITextRange *)range {
    NSArray *rects = %orig;
    if (WrappedFieldInEditor(self)) rects = AlignLineRects(rects);
    UnifiedField *field = GrownFieldInEditor(self);
    return field ? FillLineGaps(rects, ceil(field.font.lineHeight / 2)) : rects;
}

- (void)setContentOffset:(CGPoint)offset {
    UnifiedField *field = WrappedFieldInEditor(self);
    if (PinsOffset(field)) offset = CGPointZero;
    else if (ScrollsVertically(field)) offset = ClampedOffset(field, self, offset);
    %orig(offset);
}

- (void)setContentOffset:(CGPoint)offset animated:(BOOL)animated {
    UnifiedField *field = WrappedFieldInEditor(self);
    if (PinsOffset(field)) { offset = CGPointZero; animated = NO; }
    else if (ScrollsVertically(field)) offset = ClampedOffset(field, self, offset);
    %orig(offset, animated);
}

// The field editor sizes its content for one long line. With more lines than the
// capsule shows, make it as tall as all the text so it can scroll vertically.
- (void)setContentSize:(CGSize)size {
    UnifiedField *field = WrappedFieldInEditor(self);
    if (ScrollsVertically(field)) {
        size.width = self.bounds.size.width;
        size.height = MAX(field.fub_contentHeight, self.bounds.size.height);
    }
    %orig(size);
}

// UIKit centers the (now multi-line) text vertically; keep the first line where the
// stock single line sits instead.
- (CGPoint)textContainerOriginForTextAlignment:(long long)alignment {
    CGPoint origin = %orig;
    UnifiedField *field = WrappedFieldInEditor(self);
    if (field) {
        if (field.isFirstResponder && !field.fub_expanded) {
            field.fub_stockPad = origin.y; // folded: one line, UIKit's own position is the stock one
        } else {
            origin.y = TopPad(field);
        }
    }
    return origin;
}

- (void)_applyCorrectTextContainerSize {
    %orig;
    UpdateFieldEditor(self);
}

%end

%ctor {
    %init;
    if (%c(_UITextInteractionEditMenuAssistant)) %init(EditMenuAssistant);
}
