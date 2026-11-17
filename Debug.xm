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

%hook UnifiedField

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
