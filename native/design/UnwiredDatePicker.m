#import <React/RCTView.h>
#import <React/RCTViewManager.h>

#if TARGET_OS_OSX
#import <AppKit/AppKit.h>

// An AppKit date picker for `value`, milliseconds since 1970, on the clocks of `timeZone`: the
// graphical calendar choosing its day when `calendar`, otherwise the time field with its stepper
// choosing its hour and minute. Choosing one keeps the other, and `onChange` reports the new value;
// a time that a daylight-saving change skips moves to the next valid time. The calendar dims the days
// before `minimum`'s and shows `minimum`'s day for an earlier `value`, which the time field then
// moves to, and the region's calendar sets the first weekday. The time field keeps AppKit's width at
// the trailing edge. The picker sits inside a plain view, so React Native's wrapper stays out of
// accessibility and VoiceOver reaches only the picker, named by `label` and described by `hint`.
// React Native macOS 0.83.0 has no date picker; remove this view when it offers one.
@interface UnwiredDatePickerView : NSView <NSDatePickerCellDelegate>
@property (nonatomic) BOOL calendar;
@property (nonatomic) double value;
@property (nonatomic) double minimum;
@property (nonatomic, copy) NSString *timeZone;
@property (nonatomic, copy) NSString *label;
@property (nonatomic, copy) NSString *hint;
@property (nonatomic, copy) RCTDirectEventBlock onChange;
@end

@implementation UnwiredDatePickerView {
  NSDatePicker *_picker;
  BOOL _rendering;
}
- (instancetype)initWithFrame:(NSRect)frame
{
  if ((self = [super initWithFrame:frame])) {
    _picker = [NSDatePicker new];
    _picker.target = self;
    _picker.action = @selector(change);
    _picker.delegate = self;
    _picker.frame = self.bounds;
    [self addSubview:_picker];
    [self render];
  }
  return self;
}
// React Native forwards its accessibility props here, and its wrapper reports what this view does.
- (BOOL)isAccessibilityElement { return NO; }
- (void)layout
{
  [super layout];
  CGFloat width = self.calendar ? NSWidth(self.bounds) : _picker.intrinsicContentSize.width;
  _picker.frame = NSMakeRect(NSWidth(self.bounds) - width, 0, width, NSHeight(self.bounds));
}
- (void)setCalendar:(BOOL)calendar { _calendar = calendar; [self render]; self.needsLayout = YES; }
- (void)setValue:(double)value { _value = value; [self render]; }
- (void)setMinimum:(double)minimum { _minimum = minimum; [self render]; }
- (void)setTimeZone:(NSString *)timeZone { _timeZone = [timeZone copy]; [self render]; }
- (void)setLabel:(NSString *)label { _label = [label copy]; _picker.accessibilityLabel = label; }
- (void)setHint:(NSString *)hint { _hint = [hint copy]; _picker.accessibilityHelp = hint; }
- (NSCalendar *)clocks
{
  NSCalendar *clocks = [NSCalendar.autoupdatingCurrentCalendar copy];
  NSTimeZone *zone = self.timeZone == nil ? nil : [NSTimeZone timeZoneWithName:self.timeZone];
  clocks.timeZone = zone ?: NSTimeZone.localTimeZone;
  return clocks;
}
- (void)render
{
  _rendering = YES;
  NSCalendar *clocks = [self clocks];
  _picker.calendar = clocks;
  _picker.timeZone = clocks.timeZone;
  if (self.calendar) {
    _picker.datePickerStyle = NSDatePickerStyleClockAndCalendar;
    _picker.datePickerElements = NSDatePickerElementFlagYearMonthDay;
    _picker.bezeled = NO;
    _picker.bordered = NO;
    _picker.drawsBackground = NO;
    _picker.minDate = self.minimum > 0
        ? [clocks startOfDayForDate:[NSDate dateWithTimeIntervalSince1970:self.minimum / 1000]]
        : nil;
  } else {
    _picker.datePickerStyle = NSDatePickerStyleTextFieldAndStepper;
    _picker.datePickerElements = NSDatePickerElementFlagHourMinute;
    _picker.bezeled = YES;
    _picker.minDate = nil;
  }
  // The value the picker reported comes back unchanged, so a time being typed keeps its place.
  NSDate *value = [NSDate dateWithTimeIntervalSince1970:self.value / 1000];
  if (![_picker.dateValue isEqualToDate:value]) _picker.dateValue = value;
  _rendering = NO;
}
// The calendar's arrow keys change its day without sending its action, so its changes report once
// AppKit applies them.
- (void)datePickerCell:(NSDatePickerCell *)cell
    validateProposedDateValue:(NSDate **)proposedDateValue
                 timeInterval:(NSTimeInterval *)proposedTimeInterval
{
  if (self.calendar && !_rendering) dispatch_async(dispatch_get_main_queue(), ^{ [self change]; });
}
- (void)change
{
  NSCalendar *clocks = [self clocks];
  NSDate *current = [NSDate dateWithTimeIntervalSince1970:self.value / 1000];
  NSDate *day = [NSDate dateWithTimeIntervalSince1970:MAX(self.value, self.minimum) / 1000];
  NSDateComponents *next = [clocks components:NSCalendarUnitEra | NSCalendarUnitYear | NSCalendarUnitMonth |
                                              NSCalendarUnitDay
                                     fromDate:self.calendar ? _picker.dateValue : day];
  NSDateComponents *time = [clocks components:NSCalendarUnitHour | NSCalendarUnitMinute
                                     fromDate:self.calendar ? current : _picker.dateValue];
  next.hour = time.hour;
  next.minute = time.minute;
  NSDate *chosen = [clocks dateFromComponents:next];
  if (chosen != nil && self.onChange) self.onChange(@{@"value" : @(chosen.timeIntervalSince1970 * 1000)});
}
@end

@interface UnwiredDatePickerManager : RCTViewManager
@end

@implementation UnwiredDatePickerManager
RCT_EXPORT_MODULE(UnwiredDatePicker)
RCT_EXPORT_VIEW_PROPERTY(calendar, BOOL)
RCT_EXPORT_VIEW_PROPERTY(value, double)
RCT_EXPORT_VIEW_PROPERTY(minimum, double)
RCT_EXPORT_VIEW_PROPERTY(timeZone, NSString)
RCT_EXPORT_VIEW_PROPERTY(label, NSString)
RCT_EXPORT_VIEW_PROPERTY(hint, NSString)
RCT_EXPORT_VIEW_PROPERTY(onChange, RCTDirectEventBlock)
- (NSView *)view { return [UnwiredDatePickerView new]; }
@end

#endif
