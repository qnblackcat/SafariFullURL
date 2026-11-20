#import "SafariFullURL.h"

// Everything that is not a hook: finding the field, measuring the wrapped text and
// resizing the capsule around it.

static const NSInteger kMaxLines = 9;          // most lines the capsule shows,
static const CGFloat kMaxScreenShare = 1.0 / 3; // and never more than this share of the window
static const CGFloat kBaseHeight = 45;          // one-line capsule height until it is measured

#if SAFARIFULLURL_DEBUG
void FUBLog(NSString *format, ...) {
    va_list args;
    va_start(args, format);
    NSString *message = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);

    static NSFileHandle *handle;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSString *path = [NSTemporaryDirectory() stringByAppendingPathComponent:@"SafariFullURL.log"];
        [[NSFileManager defaultManager] createFileAtPath:path contents:nil attributes:nil];
        handle = [NSFileHandle fileHandleForWritingAtPath:path];
        NSLog(@"[SafariFullURL] log file: %@", path);
    });
    NSString *line = [NSString stringWithFormat:@"%.3f %@\n", CACurrentMediaTime(), message];
    @synchronized (handle) {
        [handle seekToEndOfFile];
        [handle writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
    }
    NSLog(@"[SafariFullURL] %@", message);
}
#endif

CGFloat gExtra = 0;
CGFloat gTopExtra = 0;
BOOL gUpdating = NO;

// The field has focus, or lost it only because the keyboard was dragged away while
// Safari is still editing (suggestions and Cancel stay): it keeps its unfolded look.
BOOL IsEditing(UnifiedField *field) {
    return field.isFirstResponder || field.fub_keptOpen;
}

// A finger is dragging a scroll view other than the field's own editor: UIKit dismisses
// the keyboard on drag, and that is what resigns the field.
BOOL KeyboardDismissDragInProgress(UIWindow *window) {
    NSMutableArray<UIView *> *stack = [NSMutableArray arrayWithObject:window];
    while (stack.count) {
        UIView *view = stack.lastObject;
        [stack removeLastObject];
        if ([view isKindOfClass:%c(UIFieldEditor)]) continue;
        if ([view isKindOfClass:UIScrollView.class] && (((UIScrollView *)view).isDragging || ((UIScrollView *)view).isTracking)) return YES;
        [stack addObjectsFromArray:view.subviews];
    }
    return NO;
}

// The field that kept its unfolded look after the keyboard was dragged away, so whoever notices
// that editing really ended (the iPad popover going away) can fold it again. Both the iPad's
// bar and the iPhone-style capsule of a narrow iPad window come through here.
static __weak UnifiedField *gKeptOpenField;

void NoteKeptOpen(UnifiedField *field) {
    gKeptOpenField = field;
}

UnifiedField *KeptOpenField(void) {
    UnifiedField *field = gKeptOpenField;
    return field.fub_keptOpen ? field : nil;
}

// Editing really ended (Cancel, a tapped suggestion, a new text): fold back to stock.
void EndKeptOpen(UnifiedField *field) {
    if (!field.fub_keptOpen) return;
    field.fub_keptOpen = NO;
    field.fub_expanded = NO;
    field.fub_sawSelectAll = NO;
    if (field.fub_extra > 0) ApplyExtra(field, 0);
    SFCapsuleView *capsule = CapsuleOf(field);
    [capsule setNeedsLayout];
    UpdateFieldEditor((UIFieldEditor *)[field _fieldEditor]);
}

// The URL field if it is being edited and currently grown, otherwise nil.
UnifiedField *GrownField(UITextField *tf) {
    if (![tf isKindOfClass:%c(UnifiedField)] || !IsEditing((UnifiedField *)tf)) return nil;
    UnifiedField *field = (UnifiedField *)tf;
    return field.fub_extra > 0 ? field : nil;
}

UnifiedField *GrownFieldInEditor(UIFieldEditor *fe) {
    return GrownField(MSHookIvar<UITextField *>(fe, "_textField"));
}

// The URL field being edited with wrapping on, grown or still on one line.
UnifiedField *WrappedFieldInEditor(UIFieldEditor *fe) {
    UITextField *tf = MSHookIvar<UITextField *>(fe, "_textField");
    if (![tf isKindOfClass:%c(UnifiedField)] || !IsEditing((UnifiedField *)tf)) return nil;
    UnifiedField *field = (UnifiedField *)tf;
    return field.fub_wrapped ? field : nil;
}

// Keep the first row in view: all rows fit, or the field is still on one line.
BOOL PinsOffset(UnifiedField *field) {
    return field && (field.fub_extra > 0 ? field.fub_fits : !field.fub_expanded);
}

// The grown field has more lines than it shows: its text scrolls vertically.
BOOL ScrollsVertically(UnifiedField *field) {
    return field && field.fub_extra > 0 && !field.fub_fits;
}

static BOOL gScrollingToCaret; // ScrollCaretVisible is moving the text

// UIKit scrolls the field editor sideways for its one long line and back to the top;
// with wrapped text only vertical scrolling is ours to decide. Keep x at 0, keep the
// current y unless we (or a finger) move it, and stay inside the text.
CGPoint ClampedOffset(UnifiedField *field, UIFieldEditor *fe, CGPoint offset) {
    CGFloat maxY = MAX(0, field.fub_contentHeight - fe.bounds.size.height);
    CGFloat y = (gScrollingToCaret || fe.isDragging || fe.isDecelerating) ? offset.y : fe.contentOffset.y;
    return CGPointMake(0, MIN(MAX(y, 0), maxY));
}

// The space-bar caret cannot leave the visible text: UIKit clamps its point (field
// editor content coordinates) to the visible lines. While it sits on the top or bottom
// edge, scroll a little on each update (they keep coming while the finger rests).
void AutoScrollForFloatingCursor(UnifiedField *field, CGPoint point) {
    UIFieldEditor *fe = (UIFieldEditor *)[field _fieldEditor];
    CGFloat pad = TopPad(field);
    CGFloat top = fe.contentOffset.y + pad;
    CGFloat bottom = fe.contentOffset.y + fe.bounds.size.height - pad;
    CGFloat step = ceil(field.font.lineHeight / 4);
    CGFloat dy = point.y <= top + 1 ? -step : point.y >= bottom - 1 ? step : 0;
    if (dy == 0) return;
    CGFloat maxY = MAX(0, field.fub_contentHeight - fe.bounds.size.height);
    CGFloat y = MIN(MAX(fe.contentOffset.y + dy, 0), maxY);
    if (fabs(y - fe.contentOffset.y) < 0.5) return;
    gScrollingToCaret = YES;
    fe.contentOffset = CGPointMake(0, y);
    gScrollingToCaret = NO;
}

// Scroll the text so the line with the caret (the end of the selection) shows in full.
void ScrollCaretVisible(UnifiedField *field) {
    UIFieldEditor *fe = (UIFieldEditor *)[field _fieldEditor];
    UITextRange *selection = fe.selectedTextRange;
    if (!selection) return;
    CGRect caret = [fe caretRectForPosition:selection.end];
    if (CGRectIsNull(caret) || CGRectIsInfinite(caret) || !isfinite(caret.origin.y)) return;
    CGFloat pad = TopPad(field);
    CGFloat height = fe.bounds.size.height;
    CGFloat y = fe.contentOffset.y;
    if (CGRectGetMinY(caret) - pad < y) y = CGRectGetMinY(caret) - pad;
    else if (CGRectGetMaxY(caret) + pad > y + height) y = CGRectGetMaxY(caret) + pad - height;
    if (fabs(y - fe.contentOffset.y) < 0.5) return;
    LOG(@"scroll to caret: y %.1f -> %.1f", fe.contentOffset.y, y);
    gScrollingToCaret = YES;
    fe.contentOffset = CGPointMake(0, y);
    gScrollingToCaret = NO;
}

#if SAFARIFULLURL_DEBUG
// Character offset of a position, for logging.
NSInteger Offset(UITextField *field, UITextPosition *position) {
    return position ? [field offsetFromPosition:field.beginningOfDocument toPosition:position] : -1;
}
#endif

// Position under a point (field coordinates) from the field editor. The editor answers
// "start of document" for points that fall in the thin gap between two wrapped lines;
// while dragging with the space bar that sends the caret, and the grey caret snapping
// after it, to the first line for a frame. A point below the first line can never mean
// offset 0, so probe a few points up and down until we land on a line.
UITextPosition *EditorPosition(UnifiedField *field, CGPoint point, UITextRange *range) {
    UIFieldEditor *editor = (UIFieldEditor *)[field _fieldEditor];
    point = [field convertPoint:point toView:editor]; // the text may be scrolled
    CGFloat firstLineBottom = CGRectGetMaxY([editor caretRectForPosition:editor.beginningOfDocument]);
    CGFloat reach = ceil(field.font.lineHeight / 2);
    UITextPosition *first = nil;
    for (CGFloat dy = 0; dy <= reach; dy++) {
        for (int sign = 1; sign >= -1; sign -= 2) {
            if (dy == 0 && sign < 0) continue;
            CGPoint probe = CGPointMake(point.x, point.y + sign * dy);
            UITextPosition *position = range ? [editor closestPositionToPoint:probe withinRange:range]
                                             : [editor closestPositionToPoint:probe];
            if (!first) first = position;
            if (!position) continue;
            if (probe.y <= firstLineBottom || [field comparePosition:position toPosition:field.beginningOfDocument] != NSOrderedSame) {
                if (dy > 0) LOG(@"EditorPosition (%.1f, %.1f) hit the line gap, used y %+.0f", point.x, point.y, sign * dy);
                return position;
            }
        }
    }
    return first;
}

// The grown field whose capsule this is, otherwise nil.
UnifiedField *GrownFieldForCapsule(SFCapsuleView *capsule) {
    UIView *content = capsule.contentView;
    if (![content isKindOfClass:%c(SFCapsuleURLField)]) return nil;
    return GrownField(((SFCapsuleURLField *)content).textField);
}

SFCapsuleView *CapsuleOf(UIView *view) {
    while (view && ![view isKindOfClass:%c(SFCapsuleView)]) view = view.superview;
    return (SFCapsuleView *)view;
}

// The capsule sits in the upper half of the window (Single Tab layout): it grows downward.
// Growing never takes its center across the middle of the window (at most a third of the
// window), so the answer does not flip while it grows.
BOOL CapsuleAtTop(SFCapsuleView *capsule) {
    UIWindow *window = capsule.window;
    if (!window) return NO;
    CGRect frame = [capsule convertRect:capsule.bounds toView:window];
    return CGRectGetMidY(frame) < window.bounds.size.height / 2;
}

// A capsule at the top whose URL is unfolded (one line or several): it hides the Cancel
// button and takes its room.
BOOL CapsuleUnfoldedAtTop(SFCapsuleView *capsule) {
    UIView *content = capsule.contentView;
    if (![content isKindOfClass:%c(SFCapsuleURLField)]) return NO;
    UITextField *textField = ((SFCapsuleURLField *)content).textField;
    if (![textField isKindOfClass:%c(UnifiedField)] || !IsEditing((UnifiedField *)textField)) return NO;
    return FUB_ENABLED() && ((UnifiedField *)textField).fub_expanded && CapsuleAtTop(capsule);
}

// Stock height of the one-line capsule (Dynamic Type and Bold Text change it).
// Measured from the capsule the first time it is asked for, while the field is still one
// line: the first line is positioned from this before the field ever grows.
CGFloat BaseHeight(UnifiedField *field) {
    if (field.fub_baseHeight <= 0 && field.fub_extra <= 0) {
        CGFloat height = IsPadField(field) ? PadItemHeight(field) : CapsuleOf(field).bounds.size.height;
        if (height > 0) {
            field.fub_baseHeight = height;
            LOG(@"base height %.1f (measured on first use)", height);
        }
    }
    return field.fub_baseHeight > 0 ? field.fub_baseHeight : kBaseHeight;
}

// Gap above the first line, so it sits where the stock single line is: the position UIKit
// gave it while the URL was folded, or centered in the one-line capsule until it has.
CGFloat TopPad(UnifiedField *field) {
    if (field.fub_stockPad > 0) return field.fub_stockPad;
    return (BaseHeight(field) - field.font.lineHeight) / 2;
}

// iPhone (and the iPhone-style capsule of a narrow iPad window): portrait only, the bottom capsule
// grows upward, the top one (Single Tab layout) downward; in landscape, keep stock behaviour.
// iPad unified bar: grows downward in every orientation, unless Safari is not using that bar (Pad.xm).
static BOOL ShouldGrow(UnifiedField *field) {
    UIWindow *window = field.window;
    if (!window) return NO;
    if (!FUB_ENABLED()) return NO;
    if (IsPadField(field)) return !PadLayoutUnsupported(field);
    CGSize size = window.bounds.size;
    if (size.width > size.height) return NO;
    return CapsuleOf(field) != nil;
}

// Resize everything around the field after the number of lines changed.
void ApplyExtra(UnifiedField *field, CGFloat extra) {
    LOG(@"ApplyExtra %p %.1f -> %.1f", field, field.fub_extra, extra);
    // A field that is already out of the view hierarchy is no longer "an iPad field", but its
    // bar is still grown.
    if (IsPadField(field) || PadOwnsField(field)) {
        ApplyExtraPad(field, extra);
        return;
    }
    SFCapsuleView *capsule = CapsuleOf(field);
    if (field.fub_extra <= 0 && extra > 0 && capsule.bounds.size.height > 0) {
        field.fub_baseHeight = capsule.bounds.size.height;
        LOG(@"base height %.1f", field.fub_baseHeight);
    }
    // The keyboard backdrop and the input accessory only follow a capsule at the bottom.
    BOOL atTop = CapsuleAtTop(capsule);
    field.fub_extra = extra;
    gExtra = atTop ? 0 : extra;
    gTopExtra = atTop ? extra : 0;

    UIView *collection = capsule.superview;
    if (atTop && [collection isKindOfClass:%c(SFCapsuleCollectionView)]) {
        [(SFCapsuleCollectionView *)collection invalidateHeightForCapsuleContentView:capsule.contentView];
        // The page below only moves once the browser's root view lays out again.
        UIResponder *responder = collection;
        while (responder && ![responder isKindOfClass:%c(BrowserRootViewController)]) responder = responder.nextResponder;
        UIView *root = ((UIViewController *)responder).viewIfLoaded;
        [root setNeedsLayout];
        [root layoutIfNeeded];
    }

    UIView *accessory = field.inputAccessoryView;
    if (!atTop && [accessory isKindOfClass:%c(SFCapsuleInputAccessorySpacerView)]) {
        SFCapsuleInputAccessorySpacerView *spacer = (SFCapsuleInputAccessorySpacerView *)accessory;
        static const void *kBaseKey = &kBaseKey;
        NSNumber *base = objc_getAssociatedObject(spacer, kBaseKey);
        if (!base) {
            base = @(spacer.capsuleHeight);
            objc_setAssociatedObject(spacer, kBaseKey, base, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        spacer.capsuleHeight = base.doubleValue + extra;
    }

    if ([collection isKindOfClass:%c(SFCapsuleCollectionView)]) {
        [(SFCapsuleCollectionView *)collection _layOutKeyboardBackdrop];
    }
    [capsule setNeedsLayout];
    [collection setNeedsLayout];
    [collection layoutIfNeeded];
}

// Switch the field editor between character wrapping (ours) and the stock single
// truncated line, remembering what the stock settings were.
static void SetWrapping(UnifiedField *field, UIFieldEditor *fe, BOOL wrap) {
    NSTextContainer *container = fe.textContainer;
    NSParagraphStyle *current = field.defaultTextAttributes[NSParagraphStyleAttributeName];

    if (wrap) {
        if (!field.fub_wrapped) {
            field.fub_wrapped = YES;
            field.fub_savedLineBreakMode = container.lineBreakMode;
            field.fub_savedParagraphStyle = current;
        }
        // Give the container room for every line, or only the first one while the field is
        // not unfolded (otherwise the top of the second row shows under it, also after the
        // keyboard was dragged away from a folded field). Only touch it when something
        // changed: resizing it invalidates layout, which runs this pass again.
        CGFloat width = fe.bounds.size.width;
        BOOL folded = !(IsEditing(field) && field.fub_expanded);
        CGFloat height = folded ? ceil(field.font.lineHeight * 1.5) : 10000;
        if (container.lineBreakMode != NSLineBreakByCharWrapping || container.size.width != width
            || container.size.height != height) {
            container.lineBreakMode = NSLineBreakByCharWrapping;
            container.size = CGSizeMake(width, height);
        }
        // The default paragraph style truncates the tail; without this the text keeps a "…".
        if (current.lineBreakMode != NSLineBreakByCharWrapping) {
            NSMutableParagraphStyle *style = current ? [current mutableCopy] : [NSMutableParagraphStyle new];
            style.lineBreakMode = NSLineBreakByCharWrapping;
            NSMutableDictionary *attributes = [field.defaultTextAttributes mutableCopy];
            attributes[NSParagraphStyleAttributeName] = style;
            field.defaultTextAttributes = attributes;
        }
    } else if (field.fub_wrapped) {
        field.fub_wrapped = NO;
        container.lineBreakMode = (NSLineBreakMode)field.fub_savedLineBreakMode;
        NSMutableDictionary *attributes = [field.defaultTextAttributes mutableCopy];
        attributes[NSParagraphStyleAttributeName] = field.fub_savedParagraphStyle; // nil removes it
        field.defaultTextAttributes = attributes;
        field.fub_savedParagraphStyle = nil;
        LOG(@"wrapping off");
    }
}

static BOOL IsUsableRect(CGRect rect) {
    return !CGRectIsNull(rect) && !CGRectIsInfinite(rect) && isfinite(rect.origin.y) && isfinite(rect.size.height);
}

typedef NS_ENUM(NSInteger, FUBLayoutKind) { FUBLayoutNone, FUBLayoutTextKit1, FUBLayoutTextKit2 };

#if SAFARIFULLURL_DEBUG
static NSString *LayoutKindName(FUBLayoutKind kind) {
    switch (kind) {
        case FUBLayoutTextKit1: return @"TextKit 1";
        case FUBLayoutTextKit2: return @"TextKit 2";
        default: return @"none";
    }
}
#endif

// Every line as the field editor laid it out, in text container coordinates (only its
// vertical extent matters). Returns FUBLayoutNone when the layout cannot be measured
// right now (the caller then keeps the current size).
static FUBLayoutKind MeasureRows(UnifiedField *field, UIFieldEditor *fe, NSMutableArray<NSValue *> *rows) {
    [rows removeAllObjects];
    NSTextContainer *container = fe.textContainer;

    // An empty field has no line fragments to enumerate (TextKit 2 reports none), but it
    // is one line: without this, deleting everything kept the capsule at its old height.
    if (field.text.length == 0) {
        [rows addObject:[NSValue valueWithCGRect:CGRectMake(0, 0, 0, ceil(field.font.lineHeight))]];
        return container.layoutManager ? FUBLayoutTextKit1 : FUBLayoutTextKit2;
    }

    NSLayoutManager *layout = container.layoutManager;
    if (layout) {
        [layout ensureLayoutForTextContainer:container];
        [layout enumerateLineFragmentsForGlyphRange:[layout glyphRangeForTextContainer:container]
                                         usingBlock:^(CGRect rect, CGRect used, NSTextContainer *c, NSRange range, BOOL *stop) {
            [rows addObject:[NSValue valueWithCGRect:rect]];
        }];
        if (rows.count == 0) return FUBLayoutNone;
        for (NSValue *row in rows) if (!IsUsableRect(row.CGRectValue)) return FUBLayoutNone;
        return FUBLayoutTextKit1;
    }

    NSTextLayoutManager *textLayout = container.textLayoutManager;
    if (textLayout) {
        [textLayout enumerateTextLayoutFragmentsFromLocation:textLayout.documentRange.location
                                                     options:NSTextLayoutFragmentEnumerationOptionsEnsuresLayout
                                                  usingBlock:^BOOL(NSTextLayoutFragment *fragment) {
            CGPoint origin = fragment.layoutFragmentFrame.origin;
            for (NSTextLineFragment *line in fragment.textLineFragments) {
                CGRect rect = line.typographicBounds;
                [rows addObject:[NSValue valueWithCGRect:CGRectOffset(rect, origin.x, origin.y)]];
            }
            return YES;
        }];
        BOOL usable = rows.count > 0;
        for (NSValue *row in rows) if (!IsUsableRect(row.CGRectValue)) usable = NO;
        if (usable) return FUBLayoutTextKit2;
        [rows removeAllObjects];
        // Nothing laid out yet.
    }

    return FUBLayoutNone;
}

// Bottom of row i.
static CGFloat RowBottom(NSArray<NSValue *> *rows, NSInteger i) {
    return CGRectGetMaxY(rows[i].CGRectValue);
}

// How many lines the capsule may show: kMaxLines, fewer with large text so it never
// takes more than kMaxScreenShare of the window.
static NSInteger MaxShownLines(UnifiedField *field, NSArray<NSValue *> *rows) {
    CGFloat pitch = rows.count > 1 ? RowBottom(rows, 1) - RowBottom(rows, 0) : ceil(field.font.lineHeight);
    if (pitch <= 0) return kMaxLines;
    CGFloat room = field.window.bounds.size.height * kMaxScreenShare - BaseHeight(field);
    NSInteger lines = (NSInteger)floor(room / pitch) + 1;
    return MAX(1, MIN(kMaxLines, lines));
}

#if SAFARIFULLURL_DEBUG
// Where the field editor and its subviews sit, to see how the text is placed.
static void LogGeometry(NSString *tag, UnifiedField *field, UIFieldEditor *fe) {
    LOG(@"%@ field %@ fe frame %@ bounds %@ offset %@ size %@ origin %@ container %@",
        tag, NSStringFromCGRect(field.frame), NSStringFromCGRect(fe.frame), NSStringFromCGRect(fe.bounds),
        NSStringFromCGPoint(fe.contentOffset), NSStringFromCGSize(fe.contentSize),
        NSStringFromCGPoint([fe textContainerOrigin]), NSStringFromCGSize(fe.textContainer.size));
    LOG(@"  wrapped %p (fub_wrapped %d, first responder %d) TopPad %.1f lineHeight %.1f base %.1f class %@",
        WrappedFieldInEditor(fe), field.fub_wrapped, field.isFirstResponder, TopPad(field), field.font.lineHeight,
        BaseHeight(field), NSStringFromClass(fe.class));
    for (UIView *sub in fe.subviews) {
        LOG(@"  %@ frame %@ bounds %@ hidden %d", NSStringFromClass(sub.class), NSStringFromCGRect(sub.frame),
            NSStringFromCGRect(sub.bounds), sub.hidden);
    }
}
#else
#define LogGeometry(...) do {} while (0)
#endif

// Wrap the field editor, measure the text, and grow or shrink the capsule to match.
void UpdateFieldEditor(UIFieldEditor *fe) {
    if (gUpdating) return;
    UnifiedField *field = MSHookIvar<UnifiedField *>(fe, "_textField");
    if (![field isKindOfClass:%c(UnifiedField)]) return;
    if (fe.bounds.size.width <= 0) return;

    gUpdating = YES;
    BOOL remeasure = NO;
    if (!ShouldGrow(field)) {
        if (field.fub_extra > 0) ApplyExtra(field, 0);
        SetWrapping(field, fe, NO);
    } else if (IsEditing(field) && !field.fub_expanded) {
        // Like Safari 27.3: the first tap selects the URL and keeps the one-line field;
        // it unfolds on the second tap or once the selection changes (typing, cursor
        // moves). Wrapping stays on, with the container one row tall (SetWrapping), so
        // unfolding only has to make room for the other rows.
        SetWrapping(field, fe, YES);
        if (field.fub_extra > 0) ApplyExtra(field, 0);
        if (!CGPointEqualToPoint(fe.contentOffset, CGPointZero)) fe.contentOffset = CGPointZero;
        LogGeometry(@"collapsed", field, fe);
    } else if (!IsEditing(field)) {
        // Only the field being edited grows; layout passes after editing ended must not
        // grow it (and the keyboard backdrop) again.
        SetWrapping(field, fe, YES);
        if (field.fub_extra > 0) ApplyExtra(field, 0);
    } else {
        SetWrapping(field, fe, YES);
        NSMutableArray<NSValue *> *rows = [NSMutableArray array];
        FUBLayoutKind kind = MeasureRows(field, fe, rows);
        if (kind == FUBLayoutNone) {
            LOG(@"measure skipped: layout not ready");
        } else {
            NSInteger lines = rows.count;
            NSInteger maxShown = MaxShownLines(field, rows);
            NSInteger shown = MIN(lines, maxShown);
            CGFloat extra = shown > 1 ? ceil(RowBottom(rows, shown - 1) - RowBottom(rows, 0)) : 0;
            field.fub_fits = lines <= maxShown;
            field.fub_contentHeight = ceil(RowBottom(rows, lines - 1) + 2 * TopPad(field));
            if (field.fub_fits && !CGPointEqualToPoint(fe.contentOffset, CGPointZero)) fe.contentOffset = CGPointZero;
            BOOL resized = fabs(field.fub_extra - extra) > 0.5;
            if (resized) {
                LOG(@"lines %ld extra %.1f (%@)", (long)lines, extra, LayoutKindName(kind));
                ApplyExtra(field, extra);
                // Resizing the capsule lays the field editor out again, and UIKit resets the
                // container to its one-line width (40000) while gUpdating keeps our
                // _applyCorrectTextContainerSize hook out. Wrap again.
                SetWrapping(field, fe, YES);
                LogGeometry(@"grown", field, fe);
                remeasure = YES;
            }
            if (ScrollsVertically(field)) {
                fe.contentSize = fe.contentSize; // re-applied through our setContentSize: hook
                ScrollCaretVisible(field);
            }
        }
    }
    gUpdating = NO;

    // Resizing the capsule can change the width the text wraps at (the top capsule takes
    // the Cancel button's room when it unfolds), so the line count just measured may be
    // stale: measure once more. It settles as soon as the height stops changing.
    if (remeasure) {
        dispatch_async(dispatch_get_main_queue(), ^{ UpdateFieldEditor(fe); });
    }

    // Unfolding to a line count that does not change the height still switches the top
    // capsule's chrome (background, Cancel button); lay it out again once, not on every pass.
    SFCapsuleView *capsule = CapsuleOf(field);
    if (capsule && CapsuleChromeHidden(capsule) != CapsuleUnfoldedAtTop(capsule)) [capsule setNeedsLayout];
}
