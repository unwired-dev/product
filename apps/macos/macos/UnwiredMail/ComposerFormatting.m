#import <Cocoa/Cocoa.h>
#import <objc/runtime.h>

// The composer's JavaScript owns the body's Semantic Document, but its render reaches the text view
// ~100 ms after a key press, and RCTUITextView types every character in its default attributes. So
// Command-B, -I and -U and the text typed after them show here first, the same way the document
// will mark them: the render that follows then matches what is shown instead of changing it.

typedef NS_ENUM(NSInteger, Typing) {
  // Typed text takes the marks of the text before it, or at a line's start the text after it.
  TypingNeighbour,
  // Marks toggled at the caret apply to the text typed there next.
  TypingToggled,
  // Only JavaScript knows the marks typed text takes: on focusing a composer, after a key or control
  // this does not show, or after an edit that changes the text before the caret. The shown text may
  // also predate it. Typed text shows unmarked until JavaScript has it.
  TypingAwaitingText,
  // JavaScript has the text typed since; the render that follows shows the marks it typed with.
  TypingAwaitingRender,
};

// The focused body, and its composer's identifier "composer-body<composer>".
static __weak NSTextView *body;
static NSString *composer;
static Typing typing;
static NSDictionary<NSAttributedStringKey, id> *toggled;
// The characters the body's latest edit inserted, and whether an edit moved its selection.
static NSRange inserted = {NSNotFound, 0};
static BOOL edited;

static NSString *composerOf(NSView *text)
{
  for (NSView *view = text; view != nil; view = view.superview) {
    if ([view.accessibilityIdentifier hasPrefix:@"composer-body"]) return view.accessibilityIdentifier;
  }
  return nil;
}

static NSTextView *composerBody(id responder)
{
  if (![responder isKindOfClass:NSTextView.class] || [responder isFieldEditor]) return nil;
  NSString *identifier = composerOf(responder);
  if (identifier == nil) return nil;
  if (body != responder || ![composer isEqualToString:identifier]) {
    body = responder;
    composer = identifier;
    typing = TypingAwaitingText;
    toggled = nil;
  }
  return responder;
}

// React Native's attributes for the body's own text, which RCTUITextView also types in.
@protocol UnwiredDefaultTextAttributes
@property (nonatomic, copy) NSDictionary<NSAttributedStringKey, id> *defaultTextAttributes;
@end

static NSDictionary<NSAttributedStringKey, id> *base(NSTextView *view)
{
  return [view respondsToSelector:@selector(defaultTextAttributes)]
      ? [(id<UnwiredDefaultTextAttributes>)view defaultTextAttributes] : view.typingAttributes;
}

static void forget(Typing next)
{
  typing = next;
  toggled = nil;
}

// Whether a line starts like a list item's marker, which takes no marks. A paragraph can start
// with the same text, so only JavaScript can tell which marks such a line's text takes.
// shortcut: lists show shortcuts and typed marks when JavaScript renders; pass the document's
// markers to native code if lists need them in the next frame.
static BOOL listLike(NSString *text, NSUInteger start, NSUInteger contentsEnd)
{
  static NSRegularExpression *markers;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    markers = [NSRegularExpression regularExpressionWithPattern:@"(?:• |[0-9]+\\. )" options:0 error:nil];
  });
  NSRange found = [markers rangeOfFirstMatchInString:text options:NSMatchingAnchored
                                               range:NSMakeRange(start, contentsEnd - start)];
  return found.location != NSNotFound;
}

// The attributes of the text `range` replaced: the character before it, or at a line's start the
// one after it, as the document chooses the marks typed text takes. Nil in a line that starts like
// a list item.
static NSDictionary<NSAttributedStringKey, id> *neighbour(NSTextView *view, NSRange range)
{
  NSString *text = view.string;
  NSUInteger start, contentsEnd;
  [text getLineStart:&start end:NULL contentsEnd:&contentsEnd forRange:NSMakeRange(range.location, 0)];
  if (listLike(text, start, contentsEnd)) return nil;
  NSUInteger from = range.location > start ? range.location - 1
      : NSMaxRange(range) < contentsEnd ? NSMaxRange(range) : NSNotFound;
  if (from == NSNotFound || [text characterAtIndex:from] == NSAttachmentCharacter) return base(view);
  return [view.textStorage attributesAtIndex:from effectiveRange:NULL];
}

static BOOL sameColor(NSColor *a, NSColor *b)
{
  if (a == b || [a isEqual:b]) return YES;
  NSColor *x = [a colorUsingColorSpace:NSColorSpace.sRGBColorSpace];
  NSColor *y = [b colorUsingColorSpace:NSColorSpace.sRGBColorSpace];
  return x != nil && y != nil && fabs(x.redComponent - y.redComponent) < 0.002
      && fabs(x.greenComponent - y.greenComponent) < 0.002 && fabs(x.blueComponent - y.blueComponent) < 0.002
      && fabs(x.alphaComponent - y.alphaComponent) < 0.002;
}

// Paragraph text in the body's own font: a heading's size, a quote's color or a code font already
// look marked, so only JavaScript can tell their marks apart.
static BOOL plain(NSDictionary<NSAttributedStringKey, id> *attributes, NSTextView *view)
{
  NSFont *font = attributes[NSFontAttributeName];
  NSFont *own = base(view)[NSFontAttributeName];
  return font != nil && [font.familyName isEqualToString:[NSFont systemFontOfSize:own.pointSize].familyName]
      && [font.familyName isEqualToString:own.familyName] && font.pointSize == own.pointSize
      && sameColor(attributes[NSForegroundColorAttributeName], base(view)[NSForegroundColorAttributeName]);
}

static BOOL has(NSDictionary<NSAttributedStringKey, id> *attributes, unichar mark)
{
  if (mark == 'u') return [attributes[NSUnderlineStyleAttributeName] integerValue] != 0;
  NSFontDescriptorSymbolicTraits traits = [attributes[NSFontAttributeName] fontDescriptor].symbolicTraits;
  return (traits & (mark == 'b' ? NSFontDescriptorTraitBold : NSFontDescriptorTraitItalic)) != 0;
}

// The attributes React Native renders for the mark set on or off: underline is a single line, and
// bold and italic are the system font at weight 700 and in its italic face.
static NSDictionary<NSAttributedStringKey, id> *marked(
    NSDictionary<NSAttributedStringKey, id> *attributes, unichar mark, BOOL on)
{
  NSMutableDictionary<NSAttributedStringKey, id> *result = attributes.mutableCopy;
  if (mark == 'u') {
    result[NSUnderlineStyleAttributeName] = on ? @(NSUnderlineStyleSingle) : nil;
    return result;
  }
  CGFloat size = [attributes[NSFontAttributeName] pointSize];
  BOOL bold = mark == 'b' ? on : has(attributes, 'b');
  BOOL italic = mark == 'i' ? on : has(attributes, 'i');
  NSFont *font = [NSFont systemFontOfSize:size weight:bold ? NSFontWeightBold : NSFontWeightRegular];
  if (italic) {
    NSFontDescriptor *descriptor = [font.fontDescriptor
        fontDescriptorWithSymbolicTraits:font.fontDescriptor.symbolicTraits | NSFontDescriptorTraitItalic];
    font = [NSFont fontWithDescriptor:descriptor size:size];
  }
  result[NSFontAttributeName] = font;
  return result;
}

// Toggles the mark on the selected text, as the document does: added unless all of it has it.
// Line breaks are not text a mark covers. Returns whether the mark shows.
static BOOL formatSelection(NSTextView *view, NSRange selection, unichar mark)
{
  NSTextStorage *storage = view.textStorage;
  NSString *text = storage.string;
  NSMutableArray<NSValue *> *covered = [NSMutableArray array];
  for (NSUInteger at = selection.location; at < NSMaxRange(selection);) {
    NSUInteger start, end, contentsEnd;
    [text getLineStart:&start end:&end contentsEnd:&contentsEnd forRange:NSMakeRange(at, 0)];
    if (listLike(text, start, contentsEnd)) return NO;
    NSUInteger from = MAX(at, start);
    NSUInteger to = MIN(NSMaxRange(selection), contentsEnd);
    if (to > from) [covered addObject:[NSValue valueWithRange:NSMakeRange(from, to - from)]];
    at = end;
  }
  __block BOOL known = covered.count > 0, all = YES;
  for (NSValue *range in covered) {
    if ([text rangeOfString:@"\uFFFC" options:0 range:range.rangeValue].location != NSNotFound) return NO;
    [storage enumerateAttributesInRange:range.rangeValue options:0
        usingBlock:^(NSDictionary<NSAttributedStringKey, id> *attributes, NSRange run, BOOL *stop) {
      known = known && plain(attributes, view);
      all = all && has(attributes, mark);
    }];
  }
  if (!known) return NO;
  [storage beginEditing];
  for (NSValue *range in covered) {
    [storage enumerateAttributesInRange:range.rangeValue options:0
        usingBlock:^(NSDictionary<NSAttributedStringKey, id> *attributes, NSRange run, BOOL *stop) {
      [storage setAttributes:marked(attributes, mark, !all) range:run];
    }];
  }
  [storage endEditing];
  // Attribute changes otherwise wait a display frame that typed text does not.
  [view displayIfNeeded];
  // Reported like typing, so React Native drops JavaScript renders from before it.
  inserted = NSMakeRange(NSNotFound, 0);
  [view didChangeText];
  return YES;
}

// Shows Command-B, -I or -U the way the document will, if this can know how.
static BOOL showMark(NSTextView *view, NSEventModifierFlags flags, NSString *key)
{
  unichar mark = key.length == 1 ? [key characterAtIndex:0] : 0;
  if (flags != NSEventModifierFlagCommand || (mark != 'b' && mark != 'i' && mark != 'u') || !view.isEditable
      || view.hasMarkedText || view.selectedRanges.count != 1 || typing >= TypingAwaitingText) {
    return NO;
  }
  NSRange selection = view.selectedRange;
  if (selection.length > 0) return formatSelection(view, selection, mark);
  NSDictionary<NSAttributedStringKey, id> *current = typing == TypingToggled ? toggled : neighbour(view, selection);
  if (current == nil || !plain(current, view)) return NO;
  toggled = marked(current, mark, !has(current, mark));
  typing = TypingToggled;
  return YES;
}

static NSEvent *keyDown(NSEvent *event)
{
  NSEventModifierFlags flags = event.modifierFlags & NSEventModifierFlagDeviceIndependentFlagsMask
      & ~(NSEventModifierFlagCapsLock | NSEventModifierFlagNumericPad | NSEventModifierFlagFunction);
  NSTextView *view = composerBody(event.window.firstResponder);
  // A key outside the body, as on a focused format bar control, or a Command key not shown here,
  // as Undo or Paste, may change the body or its typing marks.
  if (view == nil ? body != nil
                  : (flags & NSEventModifierFlagCommand) && !showMark(view, flags, event.charactersIgnoringModifiers)) {
    forget(TypingAwaitingText);
  }
  return event;
}

// The composer's JavaScript is handling a control or Undo that changes the body or the marks typed
// text takes; only it knows how.
void UnwiredForgetComposerTyping(NSString *identifier)
{
  if ([identifier isEqualToString:composer]) forget(TypingAwaitingText);
}

void UnwiredInstallComposerFormatting(void)
{
  // Each JavaScript span carries its own event emitter, so a render after marks shown here
  // replaces the whole text with the same characters, and on Mac React Native then keeps only a
  // collapsed caret. Keep a selected range across that so the next shortcut formats it.
  Method method = class_getInstanceMethod(NSClassFromString(@"RCTUITextView"), @selector(setAttributedText:));
  void (*setAttributedText)(id, SEL, NSAttributedString *) = (void *)method_getImplementation(method);
  method_setImplementation(method, imp_implementationWithBlock(^(NSTextView *view, NSAttributedString *text) {
    NSRange selection = view.selectedRange;
    BOOL same = selection.length > 0 && [view.string isEqualToString:text.string];
    setAttributedText(view, @selector(setAttributedText:), text);
    // React Native applies only a render made after JavaScript had every edit reported to it.
    if (view == body && typing == TypingAwaitingRender) typing = TypingNeighbour;
    if (same) view.selectedRange = selection;
  }));
  [NSEvent addLocalMonitorForEventsMatchingMask:NSEventMaskKeyDown handler:^NSEvent *(NSEvent *event) {
    return keyDown(event);
  }];
  // A click outside the body, as on the format bar, may toggle marks only JavaScript knows.
  [NSEvent addLocalMonitorForEventsMatchingMask:NSEventMaskLeftMouseDown handler:^NSEvent *(NSEvent *event) {
    NSScrollView *scroll = body.enclosingScrollView;
    if (body != nil && !NSPointInRect([scroll convertPoint:event.locationInWindow fromView:nil], scroll.bounds)) {
      forget(TypingAwaitingText);
    }
    return event;
  }];
  [NSNotificationCenter.defaultCenter addObserverForName:NSTextStorageDidProcessEditingNotification
      object:nil queue:nil usingBlock:^(NSNotification *notification) {
    NSTextStorage *storage = notification.object;
    if (body == nil || body.textStorage != storage || !(storage.editedMask & NSTextStorageEditedCharacters)) return;
    inserted = storage.editedRange;
    if (!edited) {
      edited = YES;
      // Selection changes this turn follow the edit; later ones are the user's.
      dispatch_async(dispatch_get_main_queue(), ^{ edited = NO; });
    }
  }];
  [NSNotificationCenter.defaultCenter addObserverForName:NSTextViewDidChangeSelectionNotification
      object:nil queue:nil usingBlock:^(NSNotification *notification) {
    // Moving the caret anywhere but past typed text ends marks toggled for typing; regaining focus
    // reports the selection without moving it.
    NSTextView *view = composerBody(notification.object);
    NSValue *old = notification.userInfo[@"NSOldSelectedCharacterRange"];
    if (view != nil && !edited && typing < TypingAwaitingText
        && !(old != nil && NSEqualRanges(old.rangeValue, view.selectedRange))) {
      forget(TypingNeighbour);
    }
  }];
  // Posted for the user's edits only, not for the text React Native renders.
  [NSNotificationCenter.defaultCenter addObserverForName:NSTextDidChangeNotification
      object:nil queue:nil usingBlock:^(NSNotification *notification) {
    NSTextView *view = notification.object;
    NSRange range = inserted;
    inserted = NSMakeRange(NSNotFound, 0);
    // formatSelection reports its own edit.
    if (view != body || range.location == NSNotFound) return;
    BOOL typed = range.length > 0 && !view.hasMarkedText && NSMaxRange(range) <= view.textStorage.length
        && [[view.string substringWithRange:range]
               rangeOfCharacterFromSet:[NSCharacterSet characterSetWithCharactersInString:@"\n\uFFFC"]].location
            == NSNotFound;
    // Deletions, line breaks, images and input method text change the text before the caret, but
    // JavaScript keeps the marks toggled for typing.
    if (!typed) {
      if (typing != TypingToggled) forget(TypingAwaitingText);
      return;
    }
    if (typing == TypingAwaitingRender) return;
    // JavaScript types this with its own marks; once its render shows them, text typed after can
    // take them here.
    if (typing == TypingAwaitingText) {
      typing = TypingAwaitingRender;
      return;
    }
    NSDictionary<NSAttributedStringKey, id> *attributes = typing == TypingToggled ? toggled : neighbour(view, range);
    if (attributes == nil) return;
    NSRange same;
    if ([[view.textStorage attributesAtIndex:range.location longestEffectiveRange:&same inRange:range]
            isEqualToDictionary:attributes] && NSEqualRanges(same, range)) {
      return;
    }
    [view.textStorage setAttributes:attributes range:range];
  }];
}
