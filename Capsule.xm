#import "SafariFullURL.h"

// Safari's side: the capsule grows upward, its keyboard backdrop follows, the voice
// search button goes away and the clear button moves next to the last line.

%hook SFCapsuleView

- (void)layoutSubviews {
    UnifiedField *field = GrownFieldForCapsule(self);
    CGFloat height = field ? BaseHeight(field) + field.fub_extra : 0;
    if (field && self.bounds.size.height < height - 1) {
        CGFloat grow = height - self.bounds.size.height;
        CGRect bounds = self.bounds;
        bounds.size.height = height;
        CGPoint center = self.center;
        center.y -= grow / 2; // grow upward, keep the bottom edge
        self.bounds = bounds;
        self.center = center;
    }
    %orig;
}

// iOS 16+: the background and content frames come from these two methods, which ignore
// our taller bounds. iOS 15.0 has neither (its layoutSubviews derives both from bounds
// minus _backgroundInsets, so growing the bounds above is enough); the hooking library
// skips a method that does not exist, so these simply stay inactive there.
- (CGRect)_backgroundFrame {
    CGRect frame = %orig;
    return GrownFieldForCapsule(self) ? self.bounds : frame;
}

- (CGRect)_boundsForContent {
    CGRect frame = %orig;
    return GrownFieldForCapsule(self) ? self.bounds : frame;
}

%end

%hook SFCapsuleCollectionView

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
