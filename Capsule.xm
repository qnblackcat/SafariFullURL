#import "SafariFullURL.h"
#import <objc/runtime.h>
#import <version.h>

// Safari's side: the capsule grows (upward at the bottom, downward at the top, where the page
// below it moves too), the keyboard backdrop of a bottom capsule follows, the voice search
// button goes away and the clear button moves next to the last line.

static const void *kBackingKey = &kBackingKey; // solid background we add to a top capsule
static const void *kHiddenKey = &kHiddenKey;   // set on the Cancel button when we hid it

// The top capsule currently shows our full-width chrome (solid background, no Cancel).
BOOL CapsuleChromeHidden(SFCapsuleView *capsule) {
    UIView *backing = objc_getAssociatedObject(capsule, kBackingKey);
    return backing && !backing.hidden;
}

// Empty space is the list's table view itself being hit: a row, a section title or the
// gap between sections hits a cell or a header view on top of it. (Elsewhere, such as the
// start page or a web page, Safari already cancels on a tap outside the capsule.)
static BOOL IsBlankSpace(UIView *view) {
    return [view isKindOfClass:UITableView.class];
}

// While the Cancel button is hidden, a tap on empty space below the capsule (nothing
// there: no row, no text, no button) cancels the editing, like pressing the button.
@interface FUBBlankTapHandler : NSObject <UIGestureRecognizerDelegate>
@property (nonatomic, weak) SFCapsuleView *capsule;
@property (nonatomic, strong) UITapGestureRecognizer *recognizer;
@end

@implementation FUBBlankTapHandler

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)recognizer shouldReceiveTouch:(UITouch *)touch {
    return IsBlankSpace(touch.view);
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)recognizer shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)other {
    return YES;
}

- (void)tapped:(UITapGestureRecognizer *)tap {
    UIView *cancel = self.capsule.accessoryView; // hidden, but still wired to Safari's cancel
    if ([cancel isKindOfClass:UIControl.class]) [(UIControl *)cancel sendActionsForControlEvents:UIControlEventTouchUpInside];
}

@end

// Keep a tap recognizer on the capsule's window while its Cancel button is hidden.
static void UpdateBlankTap(SFCapsuleView *capsule, BOOL active) {
    static const void *kHandlerKey = &kHandlerKey;
    UIWindow *window = capsule.window;
    FUBBlankTapHandler *handler = objc_getAssociatedObject(window, kHandlerKey);
    if (!handler) {
        if (!active || !window) return;
        handler = [FUBBlankTapHandler new];
        handler.recognizer = [[UITapGestureRecognizer alloc] initWithTarget:handler action:@selector(tapped:)];
        handler.recognizer.delegate = handler;
        handler.recognizer.cancelsTouchesInView = NO;
        [window addGestureRecognizer:handler.recognizer];
        objc_setAssociatedObject(window, kHandlerKey, handler, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    handler.capsule = capsule;
    handler.recognizer.enabled = active;
}

%hook SFCapsuleView

- (void)layoutSubviews {
    UnifiedField *field = GrownFieldForCapsule(self);
    CGFloat height = field ? BaseHeight(field) + field.fub_extra : 0;
    if (field && self.bounds.size.height < height - 1) {
        CGFloat grow = height - self.bounds.size.height;
        CGRect bounds = self.bounds;
        bounds.size.height = height;
        CGPoint center = self.center;
        // Keep the edge toward the screen edge: grow upward at the bottom, downward at the top.
        center.y += CapsuleAtTop(self) ? grow / 2 : -grow / 2;
        self.bounds = bounds;
        self.center = center;
    }
    %orig;

    // Single Tab layout, while the URL is unfolded (even when it is back to one line, so
    // nothing jumps as lines come and go): Safari's capsule background is translucent, so
    // the page below and the edge of the stock one-line bar show through the taller
    // capsule. Swap it for a solid fill of the same tone, and hide the Cancel button
    // (tapping the page below cancels); both come back afterwards.
    BOOL unfolded = CapsuleUnfoldedAtTop(self);

    // iOS 15 has no -_backgroundFrame / -_boundsForContent to hook (see below): its layout
    // leaves room for the Cancel button even when hidden, so give the width back by hand.
    if (unfolded && !IS_IOS_OR_NEWER(iOS_16_0)) {
        self.backgroundView.frame = self.bounds;
        self.contentContainer.frame = self.bounds;
    }

    UIView *backing = objc_getAssociatedObject(self, kBackingKey);
    if (unfolded) {
        if (!backing) {
            backing = [UIView new];
            backing.userInteractionEnabled = NO;
            objc_setAssociatedObject(self, kBackingKey, backing, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            [self insertSubview:backing atIndex:0];
        }
        backing.hidden = NO;
        backing.backgroundColor = UIColor.systemGray5Color;
        backing.frame = self.backgroundView.frame; // wherever Safari put the stock background
        backing.layer.cornerRadius = self.backgroundCornerRadius;
        backing.layer.cornerCurve = kCACornerCurveContinuous;
        self.backgroundView.hidden = YES;
    } else if (backing && !backing.hidden) {
        backing.hidden = YES;
        self.backgroundView.hidden = NO;
    }

    UIView *accessory = self.accessoryView;
    if (unfolded) {
        if (accessory && !accessory.hidden) {
            accessory.hidden = YES;
            objc_setAssociatedObject(accessory, kHiddenKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
    } else if ([objc_getAssociatedObject(accessory, kHiddenKey) boolValue]) {
        accessory.hidden = NO;
        objc_setAssociatedObject(accessory, kHiddenKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    UpdateBlankTap(self, unfolded);
}

// iOS 16+: the background and content frames come from these two methods, which ignore
// our taller bounds. iOS 15.0 has neither (its layoutSubviews derives both from bounds
// minus _backgroundInsets, so growing the bounds above is enough); the hooking library
// skips a method that does not exist, so these simply stay inactive there.
- (CGRect)_backgroundFrame {
    CGRect frame = %orig;
    return GrownFieldForCapsule(self) || CapsuleUnfoldedAtTop(self) ? self.bounds : frame;
}

- (CGRect)_boundsForContent {
    CGRect frame = %orig;
    return GrownFieldForCapsule(self) || CapsuleUnfoldedAtTop(self) ? self.bounds : frame;
}

%end

%hook SFCapsuleCollectionView

// Single Tab layout: make Safari itself see a taller capsule, so it moves the page below
// it (the bottom capsule grows over the page instead, see SFCapsuleView above).
// iOS 16+ takes a third argument; iOS 15 has only the two-argument form (the hooking
// library skips whichever one the running iOS does not have).
- (double)_selectedCapsuleHeightForWidth:(double)width state:(long long)state ignoringKeyboard:(BOOL)ignoring {
    return %orig + gTopExtra;
}

- (double)_selectedCapsuleHeightForWidth:(double)width state:(long long)state {
    return %orig + gTopExtra;
}

- (void)_layOutKeyboardBackdrop {
    %orig;
    if (gExtra <= 0) return;
    UIView *backdrop = MSHookIvar<UIView *>(self, "_keyboardBackdropView");
    CGRect frame = backdrop.frame;
    frame.origin.y -= gExtra;
    frame.size.height += gExtra;
    backdrop.frame = frame;
}

%end

%hook SFCapsuleURLField

// No voice search button: it takes room from the URL while editing. Safari removes the
// button and its constraints itself when told not to show it.
- (id)initWithTextField:(UITextField *)textField {
    self = %orig;
    if (self) [self setShowsVoiceSearchButton:NO];
    return self;
}

- (void)setShowsVoiceSearchButton:(BOOL)shows {
    %orig(NO);
}

// While grown, stretch the text field over the whole height of the capsule (its width
// stays Safari's, so every line stops before the clear button's column, as in Safari 27.3)
// and move the clear button down beside the last line.
// On iOS 15 SFCapsuleURLField lays out with Auto Layout and does not override
// layoutSubviews; the hook is then added to SFCapsuleURLField itself (calling UIView's as
// the original), not to UIView.
- (void)layoutSubviews {
    %orig;
    UnifiedField *field = GrownField(self.textField);
    if (!field) return;

    CGRect frame = field.frame;
    frame.origin.y = 0;
    frame.size.height = self.bounds.size.height;
    if (!CGRectEqualToRect(frame, field.frame)) field.frame = frame;

    UIView *clear = MSHookIvar<UIView *>(self, "_clearTextButton");
    if (clear.superview == self) {
        CGRect button = clear.frame;
        button.origin.y = self.bounds.size.height - (BaseHeight(field) + button.size.height) / 2;
        if (!CGRectEqualToRect(button, clear.frame)) clear.frame = button;
    }
}

%end
