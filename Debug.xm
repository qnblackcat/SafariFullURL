#import "SafariFullURL.h"

#if !SAFARIFULLURL_DEBUG
#error "Debug.xm is for debug builds only (make SAFARIFULLURL_DEBUG=1)"
#endif

// Logging only; the Makefile builds this file only with SAFARIFULLURL_DEBUG=1. Follows the
// grey space-bar caret, selection changes and text changes (with the call stack) so their
// order shows up in the log.

%hook UITextSelectionView

- (void)beginFloatingCursorAtPoint:(CGPoint)point {
    LOG(@"selView beginFloatingCursor (%.1f, %.1f)", point.x, point.y);
    %orig;
}

- (CGPoint)floatingCursorPositionForPoint:(CGPoint)point lineSnapping:(BOOL)snapping {
    CGPoint result = %orig;
    LOG(@"selView floatingCursorPosition (%.1f, %.1f) snap=%d -> (%.1f, %.1f)",
        point.x, point.y, snapping, result.x, result.y);
    return result;
}

- (void)updateFloatingCursorAtPoint:(CGPoint)point animated:(BOOL)animated {
    LOG(@"selView updateFloatingCursor (%.1f, %.1f) animated=%d", point.x, point.y, animated);
    %orig;
}

- (void)endFloatingCursor {
    LOG(@"selView endFloatingCursor");
    %orig;
}

%end

// Where the first line of text sits, to see why it moves when a Vietnamese letter is typed.
static void CollectFragmentViews(UIView *view, NSMutableArray *out) {
    if ([NSStringFromClass(view.class) containsString:@"LayoutFragmentView"]) [out addObject:view];
    for (UIView *sub in view.subviews) CollectFragmentViews(sub, out);
}

static void LogTextPosition(NSString *tag, UnifiedField *field) {
    UIFieldEditor *fe = (UIFieldEditor *)[field _fieldEditor];
    if (!fe) return;
    NSMutableArray *fragments = [NSMutableArray array];
    CollectFragmentViews(fe, fragments);
    NSMutableString *frames = [NSMutableString string];
    for (UIView *v in fragments) {
        [frames appendFormat:@" %@ bounds %@ layerPos %@ subs", NSStringFromCGRect(v.frame), NSStringFromCGRect(v.bounds), NSStringFromCGPoint(v.layer.position)];
        for (CALayer *l in v.layer.sublayers) [frames appendFormat:@" %@", NSStringFromCGRect(l.frame)];
    }
    NSString *lineRect = @"-";
    NSLayoutManager *layout = fe.textContainer.layoutManager;
    if (layout && field.text.length) lineRect = NSStringFromCGRect([layout lineFragmentRectForGlyphAtIndex:0 effectiveRange:NULL]);
    NSString *font = @"-";
    if (field.text.length) {
        UIFont *f = [field.attributedText attribute:NSFontAttributeName atIndex:0 effectiveRange:NULL];
        font = f ? [NSString stringWithFormat:@"%@ %.1f lh %.2f", f.fontName, f.pointSize, f.lineHeight] : @"nil";
    }
    NSMutableString *subs = [NSMutableString string];
    for (UIView *sub in fe.subviews) {
        [subs appendFormat:@" [%@ frame %@ bounds %@ center %@ tf %@]", NSStringFromClass(sub.class), NSStringFromCGRect(sub.frame),
            NSStringFromCGRect(sub.bounds), NSStringFromCGPoint(sub.center), NSStringFromCGAffineTransform(sub.transform)];
    }
    LOG(@"POSVIEWS %@ fe.contentInset %@ adjusted %@ safe %@ field.bounds %@ fe.layer.bounds %@ fe.contentSize %@ subviews%@",
        tag, NSStringFromUIEdgeInsets(fe.contentInset), NSStringFromUIEdgeInsets(fe.adjustedContentInset),
        NSStringFromUIEdgeInsets(fe.safeAreaInsets), NSStringFromCGRect(field.bounds), NSStringFromCGRect(fe.layer.bounds),
        NSStringFromCGSize(fe.contentSize), subs);
    LOG(@"POS %@ text \"%@\" origin %@ stockPad %.2f TopPad %.2f expanded %d fe.offset %@ fe.bounds %@ fragments%@ tk1Line0 %@ font0 %@ field.font %@ lh %.2f",
        tag, field.text, NSStringFromCGPoint([fe textContainerOrigin]), field.fub_stockPad, TopPad(field),
        field.fub_expanded, NSStringFromCGPoint(fe.contentOffset), NSStringFromCGRect(fe.bounds), frames, lineRect,
        font, field.font.fontName, field.font.lineHeight);
}

// Everything that moves the text between two text changes: marked text (Telex/VNI composing),
// the fragment view being re-framed, and layout passes of the field editor.
@interface _UITextLayoutFragmentView : UIView
@end

%hook _UITextLayoutFragmentView

- (void)setFrame:(CGRect)frame {
    if (!CGRectEqualToRect(frame, self.frame)) {
        LOG(@"fragmentView setFrame %@ -> %@ (offset %.3f)", NSStringFromCGRect(self.frame), NSStringFromCGRect(frame), frame.origin.y - self.frame.origin.y);
    }
    %orig;
}

- (void)setCenter:(CGPoint)center {
    if (!CGPointEqualToPoint(center, self.center)) LOG(@"fragmentView setCenter %@ -> %@", NSStringFromCGPoint(self.center), NSStringFromCGPoint(center));
    %orig;
}

- (void)setBounds:(CGRect)bounds {
    if (!CGRectEqualToRect(bounds, self.bounds)) LOG(@"fragmentView setBounds %@ -> %@", NSStringFromCGRect(self.bounds), NSStringFromCGRect(bounds));
    %orig;
}

%end

@interface _UITextLayoutCanvasView : UIView
@end

%hook _UITextLayoutCanvasView

- (void)setBounds:(CGRect)bounds {
    if (!CGRectEqualToRect(bounds, self.bounds)) LOG(@"canvasView setBounds %@ -> %@", NSStringFromCGRect(self.bounds), NSStringFromCGRect(bounds));
    %orig;
}

- (void)setFrame:(CGRect)frame {
    if (!CGRectEqualToRect(frame, self.frame)) LOG(@"canvasView setFrame %@ -> %@", NSStringFromCGRect(self.frame), NSStringFromCGRect(frame));
    %orig;
}

%end

%hook UIFieldEditor

- (void)layoutSubviews {
    %orig;
    UnifiedField *field = MSHookIvar<UnifiedField *>(self, "_textField");
    if ([field isKindOfClass:%c(UnifiedField)] && field.isFirstResponder) LogTextPosition(@"fe layoutSubviews", field);
}

%end

%hook UnifiedField

- (void)setMarkedText:(NSString *)markedText selectedRange:(NSRange)range {
    LOG(@"setMarkedText \"%@\" sel %@", markedText, NSStringFromRange(range));
    %orig;
    LogTextPosition(@"after setMarkedText", self);
}

- (void)unmarkText {
    LOG(@"unmarkText (marked \"%@\")", [self textInRange:self.markedTextRange]);
    %orig;
    LogTextPosition(@"after unmarkText", self);
}

- (void)setText:(NSString *)text {
    LOG(@"setText \"%@\" (was %lu chars)\n%@", text, (unsigned long)self.text.length,
        [[[NSThread callStackSymbols] subarrayWithRange:NSMakeRange(1, 10)] componentsJoinedByString:@"\n"]);
    %orig;
}

- (void)setAttributedText:(NSAttributedString *)text {
    LOG(@"setAttributedText \"%@\" (was %lu chars)\n%@", text.string, (unsigned long)self.text.length,
        [[[NSThread callStackSymbols] subarrayWithRange:NSMakeRange(1, 10)] componentsJoinedByString:@"\n"]);
    %orig;
}

- (void)insertText:(NSString *)text {
    LOG(@"insertText \"%@\"", text);
    %orig;
}

- (void)fieldEditorDidChange:(id)editor {
    %orig;
    LOG(@"fieldEditorDidChange text \"%@\"\n%@", self.text,
        [[[NSThread callStackSymbols] subarrayWithRange:NSMakeRange(1, 12)] componentsJoinedByString:@"\n"]);
    LogTextPosition(@"change", self);
    __weak UnifiedField *weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{ LogTextPosition(@"change+1 turn", weakSelf); });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 300 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
        LogTextPosition(@"change+300ms", weakSelf);
    });
}

- (void)setSelectedTextRange:(UITextRange *)range {
    LOG(@"setSelectedTextRange %ld..%ld", (long)Offset(self, range.start), (long)Offset(self, range.end));
    %orig;
}

- (void)beginFloatingCursorAtPoint:(CGPoint)point {
    LOG(@"field beginFloatingCursor (%.1f, %.1f) grown=%d", point.x, point.y, GrownField(self) != nil);
    %orig;
}

- (void)endFloatingCursor {
    LOG(@"field endFloatingCursor");
    %orig;
    LOG(@"field endFloatingCursor done, caret %ld", (long)Offset(self, self.selectedTextRange.end));
}

%end

// iPad probe: which views host the URL field there? Dumps, once the field has focus (and
// again after a moment, for the unfolded state), the device and window, the chain of views
// from the field up to the window, the siblings of its nearest bar-like ancestor, and every
// view of interest in the window with its frame in window coordinates.

static NSString *Describe(UIView *view, UIView *window) {
    CGRect inWindow = [view.superview convertRect:view.frame toView:window];
    return [NSString stringWithFormat:@"%@ %p frame %@ inWindow %@ hidden %d alpha %.2f",
            NSStringFromClass(view.class), view, NSStringFromCGRect(view.frame),
            NSStringFromCGRect(inWindow), view.hidden, view.alpha];
}

static void DumpTree(UIView *view, UIView *window, int depth, int maxDepth) {
    LOG(@"  %*s%@", depth * 2, "", Describe(view, window));
    if (depth >= maxDepth) return;
    for (UIView *sub in view.subviews) DumpTree(sub, window, depth + 1, maxDepth);
}

static BOOL IsInteresting(UIView *view) {
    NSString *name = NSStringFromClass(view.class);
    for (NSString *prefix in @[@"SFCapsule", @"_SFNavigationBar", @"NavigationBar", @"SFUnifiedTabBar",
                               @"UnifiedTabBar", @"TabBar", @"BrowserToolbar", @"SFBarRegistration",
                               @"UnifiedField", @"SFNavigationBar"]) {
        if ([name hasPrefix:prefix]) return YES;
    }
    return NO;
}

static void FindInteresting(UIView *view, UIView *window, int depth) {
    if (IsInteresting(view)) LOG(@"  [%d] %@", depth, Describe(view, window));
    for (UIView *sub in view.subviews) FindInteresting(sub, window, depth + 1);
}

static void ProbeField(UnifiedField *field, NSString *tag) {
    UIWindow *window = field.window;
    UIUserInterfaceIdiom idiom = UIDevice.currentDevice.userInterfaceIdiom;
    LOG(@"=== probe %@: idiom %ld (1 = iPad) iOS %@ window %@ hSize %ld vSize %ld text \"%@\"",
        tag, (long)idiom, UIDevice.currentDevice.systemVersion, NSStringFromCGRect(window.bounds),
        (long)window.traitCollection.horizontalSizeClass, (long)window.traitCollection.verticalSizeClass, field.text);
    LOG(@"field first responder %d, selection %@", field.isFirstResponder, field.selectedTextRange);

    LOG(@"-- ancestors of the field, from the field up");
    UIView *view = field;
    UIView *bar = nil; // the first ancestor with a bar-like class name
    while (view) {
        LOG(@"  %@", Describe(view, window));
        if (!bar && view != field && IsInteresting(view)) bar = view;
        view = view.superview;
    }

    LOG(@"-- tree under %@ (depth 4)", bar ? NSStringFromClass(bar.class) : @"the field's grandparent");
    UIView *root = bar ?: field.superview.superview ?: field.superview;
    if (root) DumpTree(root, window, 0, 4);

    LOG(@"-- bar-like views in the window");
    FindInteresting(window, window, 0);

    UIViewController *controller = nil;
    for (UIResponder *r = field; r; r = r.nextResponder) {
        if ([r isKindOfClass:UIViewController.class]) { controller = (UIViewController *)r; break; }
    }
    LOG(@"-- responder chain");
    for (UIResponder *r = field; r; r = r.nextResponder) LOG(@"  %@ %p", NSStringFromClass(r.class), r);
    LOG(@"nearest view controller: %@ safeArea %@", controller.class, controller ? NSStringFromUIEdgeInsets(controller.view.safeAreaInsets) : @"-");
    LOG(@"=== end probe %@", tag);
}

%hook UnifiedField

- (BOOL)becomeFirstResponder {
    BOOL became = %orig;
    if (became) {
        __weak UnifiedField *weakSelf = self;
        // Tap the address bar once, wait, then tap it a second time: both states get logged.
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.6 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            if (weakSelf.isFirstResponder) ProbeField(weakSelf, @"after focus");
        });
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(4.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            if (weakSelf.isFirstResponder) ProbeField(weakSelf, @"4s after focus");
        });
    }
    return became;
}

%end

// The classes the iPad may use instead of the capsule: log when they are told to expand.
@interface NavigationBar : UIView
@end

%hook NavigationBar

- (void)setExpanded:(BOOL)expanded textFieldSelectionRange:(NSRange)range {
    LOG(@"NavigationBar %p setExpanded:%d range %@ frame %@", self, expanded, NSStringFromRange(range), NSStringFromCGRect(self.frame));
    %orig;
}

%end

// Settings page (prefs/): the Enabled switch is in com.qn.safarifullurl, and the page posts
// a notification when it changes.
BOOL gFUBEnabled = YES;

static void ReloadPrefs(void) {
    CFStringRef domain = CFSTR("com.qn.safarifullurl");
    CFPreferencesAppSynchronize(domain);
    id value = CFBridgingRelease(CFPreferencesCopyAppValue(CFSTR("enabled"), domain));
    gFUBEnabled = value ? [value boolValue] : YES;
    LOG(@"settings: enabled %d", gFUBEnabled);
}

static void PrefsChanged(CFNotificationCenterRef center, void *observer, CFNotificationName name, const void *object, CFDictionaryRef info) {
    ReloadPrefs();
}

%ctor {
    %init;
    ReloadPrefs();
    CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL, PrefsChanged,
        CFSTR("com.qn.safarifullurl/settingschanged"), NULL, CFNotificationSuspensionBehaviorCoalesce);
}
