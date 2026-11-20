#import "SafariFullURL.h"

// iPad. Everything here runs on an iPad only (the hooks are in a Logos group that %ctor starts
// when the idiom is iPad), so none of it can touch the iPhone.
//
// With the Separate tab bar layout the URL field lives in the selected item of the unified bar at
// the top: UnifiedBar > UnifiedTabBar > scroll view > item view > title container > field. While
// the URL is unfolded that bar grows downward, and Safari moves the tab bar and the page below it
// down with it. A narrow window switches Safari to the iPhone-style capsule (lowered bar): the
// field is then in a capsule, and the iPhone code (Capsule.xm) grows it, not this file.
//
// How the bar grows: SFUnifiedBar -expandedHeight is hooked to include gPadExtra. The browser's
// root controller sizes the bar and the page insets from it, but a window that does not fill the
// screen takes the bar height from the dynamic bar animator, which copies the (hooked) height only
// when the browser recomputes its geometry: ApplyExtraPad does that on every change. The views from
// the field up to the bar are stretched by hand, because the bar lays its item out at stock height.

static const CGFloat kMinPadWidth = 520; // fallback when Safari's layout flags cannot be asked, see PadLayoutUnsupported

static CGFloat gPadExtra;                // extra height of the grown unified bar, 0 when folded
static __weak UnifiedField *gPadField;   // the field whose bar is grown

// What the bar was grown through, kept so it can be folded again after the field has left the
// view hierarchy (the field is detached when editing ends from a dismissed popover, or when the
// window changes size).
static __weak UIView *gPadBar;
static __weak UIView *gPadItem;
static __weak BrowserRootViewController *gPadController;
static __weak BrowserController *gPadBrowser;
static CGFloat gPadBase;                 // stock one-line height of the item

// The stretched views are only given back during this long after the bar folds or the window changes
// size: that is when Safari rebuilds the item while we are grown. Looking for them on every layout of
// the bar (scrolling, tab changes) would walk its whole view tree each time.
static const CFTimeInterval kPadHealWindow = 2.0;
static CFTimeInterval gPadHealUntil;

BOOL FUBIsPad(void) {
    static BOOL pad;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ pad = UIDevice.currentDevice.userInterfaceIdiom == UIUserInterfaceIdiomPad; });
    return pad;
}

#pragma mark - Finding things

static SFUnifiedTabBarItemView *PadItemOf(UIView *view) {
    while (view && ![view isKindOfClass:%c(SFUnifiedTabBarItemView)]) view = view.superview;
    return (SFUnifiedTabBarItemView *)view;
}

// The field is in the unified bar's item (not in a capsule).
BOOL IsPadField(UnifiedField *field) {
    return FUBIsPad() && PadItemOf(field) != nil;
}

CGFloat PadItemHeight(UnifiedField *field) {
    return PadItemOf(field).bounds.size.height;
}

// A field that grew the bar and has not folded it yet, even if it has left the item since.
BOOL PadOwnsField(UnifiedField *field) {
    return field && field == gPadField;
}

static UnifiedField *PadGrownField(void) {
    UnifiedField *field = gPadField;
    return field && IsEditing(field) && field.fub_extra > 0 ? field : nil;
}

static UIView *PadBarOf(UIView *view) {
    while (view && ![view isKindOfClass:%c(UnifiedBar)]) view = view.superview;
    return view;
}

#pragma mark - Which layout

// Fallback only, for when the browser's root controller cannot be found: narrower than the narrowest
// window seen with the unified bar in the logs (551pt, a landscape 50/50 split); at 504pt Safari
// switches to the capsule. The size class is no help: both are compact.
static BOOL PadWindowTooNarrow(UIWindow *window) {
    return window.bounds.size.width < kMinPadWidth;
}

// Safari's layout is not the unified bar: it is the iPhone-style (lowered) bar of a narrow window.
// Ask Safari which one it is using instead of guessing from the width.
BOOL PadLayoutUnsupported(UnifiedField *field) {
    UIResponder *responder = field;
    while (responder && ![responder isKindOfClass:%c(BrowserRootViewController)]) responder = responder.nextResponder;
    BrowserRootViewController *controller = (BrowserRootViewController *)responder ?: gPadController;
    if (!controller) return PadWindowTooNarrow(field.window);
    BOOL lowered = [controller usingLoweredBar];
    BOOL unified = [controller usingUnifiedBar];
#if SAFARIFULLURL_DEBUG
    static int lastState = -1;
    int state = (lowered ? 1 : 0) | (unified ? 2 : 0);
    if (state != lastState) {
        lastState = state;
        LOG(@"iPad layout: window %@ usingLoweredBar %d usingUnifiedBar %d: %@",
            NSStringFromCGSize(field.window.bounds.size), lowered, unified,
            (lowered || !unified) ? @"not growing" : @"growing");
    }
#endif
    return lowered || !unified;
}

#pragma mark - Heights

// Give every view between the field and the unified bar the grown height: the bar lays its
// item out with the stock one, and the field must reach the bottom of the taller bar.
static void PadFixHeights(UnifiedField *field) {
    if (!field || field.fub_extra <= 0 || field != gPadField) return;
    CGFloat height = BaseHeight(field) + field.fub_extra;
    UIView *view = field;
    while (view && ![view isKindOfClass:%c(UnifiedBar)]) {
        CGRect frame = view.frame;
        if (fabs(frame.size.height - height) > 0.5) {
            frame.size.height = height;
            view.frame = frame;
        }
        view = view.superview;
    }
}

// Views we stretched can end up detached from what we track (the item is rebuilt when the window
// changes size while we are grown) and stay tall after the bar went back to stock. Whatever is left
// taller than the stock one-line height under the bar is stretched by us: give it back. Called only
// within kPadHealWindow of a fold or a resize (see gPadHealUntil).
static BOOL PadHealHeights(UIView *view, CGFloat stock) {
    BOOL changed = NO;
    BOOL ours = [view isKindOfClass:%c(UnifiedTabBar)] || [view isKindOfClass:%c(SFUnifiedTabBarItemView)]
        || [view isKindOfClass:%c(SFUnifiedTabBarItemTitleContainerView)] || [view isKindOfClass:%c(UnifiedField)]
        || ([view isKindOfClass:UIScrollView.class] && [view.superview isKindOfClass:%c(UnifiedTabBar)]);
    if (ours && view.frame.size.height > stock + 2) {
        LOG(@"heal %@ height %.1f -> %.1f", NSStringFromClass(view.class), view.frame.size.height, stock);
        CGRect frame = view.frame;
        frame.size.height = stock;
        view.frame = frame;
        [view setNeedsLayout];
        changed = YES;
    }
    for (UIView *sub in view.subviews) changed |= PadHealHeights(sub, stock);
    return changed;
}

#pragma mark - Popover

// The start page / suggestions popover hangs from the URL field's source rect, taken for the
// one-line field. Tell the presented popover again when the bar grows or shrinks.
static void PadRepositionPopover(UIView *bar) {
    if (![bar isKindOfClass:%c(UnifiedBar)]) return;
    id info = [(UnifiedBar *)bar URLOutlinePopoverSourceInfo];
    UIView *source = [info respondsToSelector:@selector(popoverSourceView)] ? [info popoverSourceView] : nil;
    if (!source) return;
    CGRect rect = [info popoverSourceRect];

    NSMutableArray<UIViewController *> *stack = [NSMutableArray array];
    UIViewController *root = bar.window.rootViewController;
    if (root) [stack addObject:root];
    while (stack.count) {
        UIViewController *controller = stack.lastObject;
        [stack removeLastObject];
        UIPresentationController *presentation = controller.presentationController;
        if ([presentation isKindOfClass:UIPopoverPresentationController.class]) {
            UIPopoverPresentationController *popover = (UIPopoverPresentationController *)presentation;
            if (popover.sourceView == source && !CGRectEqualToRect(popover.sourceRect, rect)) {
                LOG(@"popover %@ sourceRect %@ -> %@", NSStringFromClass(controller.class),
                    NSStringFromCGRect(popover.sourceRect), NSStringFromCGRect(rect));
                popover.sourceRect = rect;
            }
        }
        if (controller.presentedViewController) [stack addObject:controller.presentedViewController];
        [stack addObjectsFromArray:controller.childViewControllers];
    }
}

// Dragging the suggestions dismisses the keyboard but Safari keeps editing: the field stays
// unfolded (fub_keptOpen, see TextField.xm). On the iPhone the Cancel button or a tapped
// suggestion ends that; on the iPad (the unified bar, and the iPhone-style capsule of a narrow
// window) editing also ends when the popover goes away. Fold back then.
static void PadEndKeptOpenAfterPopover(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        UnifiedField *field = KeptOpenField();
        LOG(@"popover dismissed, kept open field %p extra %.1f", field, field.fub_extra);
        if (field) EndKeptOpen(field);
    });
}

#pragma mark - Growing and folding

// Grow or fold the bar: called by ApplyExtra (Core.xm) when the number of lines changes.
void ApplyExtraPad(UnifiedField *field, CGFloat extra) {
    UIView *item = PadItemOf(field) ?: gPadItem;
    if (field.fub_extra <= 0 && extra > 0 && item.bounds.size.height > 0) {
        field.fub_baseHeight = item.bounds.size.height;
        LOG(@"base height %.1f (iPad item)", field.fub_baseHeight);
    }
    BOOL attached = PadItemOf(field) != nil;

    UIView *bar = nil;
    BrowserRootViewController *controller = nil;
    BrowserController *browser = nil;
    if (attached) {
        UIResponder *responder = field;
        while (responder && ![responder isKindOfClass:%c(BrowserController)]) responder = responder.nextResponder;
        browser = (BrowserController *)responder;
        bar = PadBarOf(field);
        responder = field;
        while (responder && ![responder isKindOfClass:%c(BrowserRootViewController)]) responder = responder.nextResponder;
        controller = (BrowserRootViewController *)responder;
    }
    if (extra > 0) {
        gPadBar = bar;
        gPadItem = item;
        gPadController = controller;
        gPadBrowser = browser;
        gPadBase = field.fub_baseHeight;
    } else {
        // Folding: use what we grew through when the field no longer reaches the bar.
        if (!bar) bar = gPadBar;
        if (!controller) controller = gPadController;
        if (!browser) browser = gPadBrowser;
        if (gPadBase > 0) field.fub_baseHeight = gPadBase;
    }

    field.fub_extra = extra;
    gPadExtra = extra;
    gPadField = extra > 0 ? field : nil;
    if (extra <= 0) gPadHealUntil = CACurrentMediaTime() + kPadHealWindow;

    // Safari only lays the item out again when its own inputs change: hand the stock height
    // back to the views we stretched.
    if (extra <= 0 && gPadBase > 0) {
        UIView *view = item;
        while (view && view != bar) {
            CGRect frame = view.frame;
            if (frame.size.height > gPadBase + 0.5) {
                frame.size.height = gPadBase;
                view.frame = frame;
            }
            [view setNeedsLayout];
            view = view.superview;
        }
    }

    // Safari keeps the bar's height in its dynamic bar animator, copied from the (hooked) expanded
    // height only when it recomputes the geometry. Do it now, and again when the bar folds: a height
    // taken while we were grown would stay after we are folded (empty space at the top after a window
    // resize, until the next rotation).
    LOG(@"animator topBarHeight before %.1f", [controller dynamicBarAnimator].topBarHeight);
    [browser updateDynamicBarGeometry];
    LOG(@"animator topBarHeight after %.1f (BrowserController %p)", [controller dynamicBarAnimator].topBarHeight, browser);

    // Then lay the browser out again: the bar takes its new frame, the page below and the tab bar move.
    UIView *root = controller.viewIfLoaded;
    [bar setNeedsLayout];
    [root setNeedsLayout];
    [root layoutIfNeeded];
    if (extra > 0) PadFixHeights(field);
    [bar setNeedsLayout];
    PadRepositionPopover(bar);
    // The popover's source may only settle after this layout pass.
    dispatch_async(dispatch_get_main_queue(), ^{ PadRepositionPopover(bar); });
    LOG(@"ApplyExtraPad %.1f attached %d bar %@ root %p fillsScreen %d desiredHeight %.1f frameForNavigationBar %@",
        extra, attached, NSStringFromCGRect(bar.frame), root, [controller _interfaceFillsScreen],
        [controller navigationBarDesiredHeight], NSStringFromCGRect([controller _frameForNavigationBar]));
}

// Safety net: the bar is still grown but nothing is being edited any more.
static void PadResetIfStale(void) {
    if (gPadExtra <= 0 || PadGrownField()) return;
    LOG(@"stale iPad bar extra %.1f, folding", gPadExtra);
    UnifiedField *field = gPadField;
    if (field) ApplyExtraPad(field, 0);
    else {
        gPadExtra = 0;
        [gPadBar setNeedsLayout];
        [gPadController.viewIfLoaded setNeedsLayout];
    }
}

#pragma mark - Hooks

%group Pad

// The browser sizes the bar, the tab bar below it and the page insets from this height.
%hook SFUnifiedBar

- (double)expandedHeight {
    return %orig + gPadExtra;
}

%end

%hook UnifiedBar

- (void)layoutSubviews {
    %orig;

    // The window was resized (rotation, Split View, a resizable window) while editing: nothing else
    // tells us, and the grown height, the popover and the unsupported-layout check depend on it.
    static CGSize lastSize;
    UITextField *textField = self.textField;
    if ([textField isKindOfClass:%c(UnifiedField)] && IsEditing((UnifiedField *)textField) && self.window) {
        CGSize size = self.window.bounds.size;
        if (!CGSizeEqualToSize(size, lastSize)) {
            LOG(@"window resized %@ -> %@ (bar %@)", NSStringFromCGSize(lastSize), NSStringFromCGSize(size),
                NSStringFromCGRect(self.frame));
            lastSize = size;
            gPadHealUntil = CACurrentMediaTime() + kPadHealWindow;
            __weak UnifiedBar *weakSelf = self;
            UnifiedField *field = (UnifiedField *)textField;
            dispatch_async(dispatch_get_main_queue(), ^{
                // Under the capsule layout the field editor may have no width to lay out: fold directly.
                if (PadLayoutUnsupported(field) && field.fub_extra > 0) {
                    LOG(@"layout not supported while grown, folding");
                    ApplyExtra(field, 0);
                } else {
                    UpdateFieldEditor((UIFieldEditor *)[field _fieldEditor]);
                }
                PadRepositionPopover(weakSelf);
            });
        }
    } else {
        lastSize = CGSizeZero;
    }

    // Folded, just after a fold or a resize: give back whatever is still stretched.
    if (gPadExtra <= 0 && gPadBase > 0 && CACurrentMediaTime() < gPadHealUntil && PadHealHeights(self, gPadBase)) {
        [self setNeedsLayout];
        UIResponder *responder = self;
        while (responder && ![responder isKindOfClass:%c(BrowserRootViewController)]) responder = responder.nextResponder;
        [((UIViewController *)responder).viewIfLoaded setNeedsLayout];
    }

    UnifiedField *field = PadGrownField();
    if (!field) {
        if (gPadExtra > 0) dispatch_async(dispatch_get_main_queue(), ^{ PadResetIfStale(); });
        return;
    }
    PadFixHeights(field);
#if SAFARIFULLURL_DEBUG
    LOG(@"UnifiedBar layout: bounds %@ extra %.1f expandedHeight %.1f", NSStringFromCGRect(self.bounds), gPadExtra, self.expandedHeight);
    for (UIView *sub in self.subviews) LOG(@"  %@ %@", NSStringFromClass(sub.class), NSStringFromCGRect(sub.frame));
#endif
}

%end

// The bar lays the item out at the stock height: grow the views of the chain before their
// children are laid out, and again afterwards.
%hook UnifiedTabBar

- (void)layoutSubviews {
    PadFixHeights(PadGrownField());
    %orig;
    PadFixHeights(PadGrownField());
}

%end

%hook SFUnifiedTabBarItemView

- (void)layoutSubviews {
    PadFixHeights(PadGrownField());
    %orig;
    PadFixHeights(PadGrownField());
}

// No voice search button: it takes room from the URL while editing (the iPhone's capsule does the
// same, see Capsule.xm). The item view removes the button itself when told not to show it.
- (void)setShowsVoiceSearchButton:(BOOL)shows {
    %orig(NO);
}

%end

%hook SFUnifiedTabBarItemTitleContainerView

- (void)layoutSubviews {
    PadFixHeights(PadGrownField());
    %orig;
    PadFixHeights(PadGrownField());
}

%end

// The popover's source rect was taken for the one-line field: extend it down to the bottom of the
// grown item.
%hook _SFUIViewPopoverSourceInfo

- (CGRect)popoverSourceRect {
    CGRect rect = %orig;
    UnifiedField *field = PadGrownField();
    UIView *view = self.popoverSourceView;
    UIView *bar = PadBarOf(view);
    if (!field || !bar || PadBarOf(field) != bar) return rect;
    UIView *item = PadItemOf(field);
    if (!item) return rect;
    CGFloat bottom = CGRectGetMaxY([view convertRect:item.bounds fromView:item]);
    CGFloat grow = bottom - CGRectGetMaxY(rect);
    LOG(@"popoverSourceRect %@ (view %@ %@) item bottom %.1f grow %.1f", NSStringFromCGRect(rect),
        NSStringFromClass(view.class), NSStringFromCGRect(view.bounds), bottom, grow);
    if (grow > 0.5) rect.size.height += grow;
    return rect;
}

%end

%hook UnifiedField

// While grown, the clear button sits beside the last line, at the bottom right, not
// centered on the whole (taller) field.
- (CGRect)clearButtonRectForBounds:(CGRect)bounds {
    CGRect rect = %orig;
    UnifiedField *field = PadGrownField();
    if (field != self || !IsPadField(self)) return rect;
    rect.origin.y = bounds.size.height - (BaseHeight(self) + rect.size.height) / 2;
    return rect;
}

%end

%hook CatalogViewController

- (void)_popoverDismissCompletion {
    %orig;
    PadEndKeptOpenAfterPopover();
}

- (void)_dismissPopoverAnimated:(BOOL)animated dismissalReason:(long long)reason completionHandler:(id)handler {
    %orig;
    PadEndKeptOpenAfterPopover();
}

%end

%end // group Pad

%ctor {
    if (FUBIsPad()) %init(Pad);
}
