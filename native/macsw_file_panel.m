/* Native UI boundary for Wine's opt-in file dialogs. No shell or AppleScript. */
#import <AppKit/AppKit.h>
#include <sys/stat.h>
#include <unistd.h>

enum { PanelMagic = 0x4d535046, PanelVersion = 1, MaximumBytes = 1024 * 1024 };
static BOOL readWord(NSData *, NSUInteger *, uint32_t *);
static NSString *readString(NSData *, NSUInteger *);
static void appendWord(NSMutableData *, uint32_t);
static NSArray *readControls(NSData *, NSUInteger *);
static BOOL writeResponse(NSString *, NSData *);

@interface PanelController : NSObject <NSOpenSavePanelDelegate>
@property NSSavePanel *panel;
@property NSPopUpButton *formats;
@property NSArray<NSArray<NSString *> *> *extensions;
@property NSArray<NSRegularExpression *> *filenameFilters;
@property NSString *defaultExtension;
@property NSArray<NSString *> *saveExtensions;
@property BOOL saving;
@property NSString *requestPath;
@property NSString *responsePath;
@property NSArray *controls;
@property uint32_t sequence;
@property BOOL waiting;
@property BOOL hiddenForCallback;
@property NSString *lastFileName;
- (void)selectFormat:(id)sender;
- (void)reloadControls;
- (void)receiveUpdate;
@end

@implementation PanelController
- (void)selectFormat:(id)sender
{
    NSString *previousName = self.panel.nameFieldStringValue;
    NSArray *extensions = self.extensions.count ? self.extensions[self.formats.indexOfSelectedItem] : @[];
    // NSOpenPanel extension lists cannot express Creo's versioned *.prt.*.
    // Match the original filename patterns through its delegate instead.
    self.panel.allowedFileTypes = self.saving && extensions.count ? extensions : nil;
    // Filters describe the application's formats; the helper does not add
    // a save-format policy. Wine/SW still receives the selected path.
    self.panel.allowsOtherFileTypes = YES;
    if (!self.saving) [self.panel validateVisibleColumns];
    if (self.saving) {
        NSString *ext = self.saveExtensions.count ? self.saveExtensions[self.formats.indexOfSelectedItem] : self.defaultExtension;
        if ([ext rangeOfCharacterFromSet:[NSCharacterSet characterSetWithCharactersInString:@"*?/\\:"]].location != NSNotFound)
            ext = nil;
        NSString *name = self.panel.nameFieldStringValue;
        if (ext.length && name.length) {
            self.panel.nameFieldStringValue = [[name stringByDeletingPathExtension] stringByAppendingPathExtension:ext];
        }
    }
    // Wine's original type-change callback applies the new extension itself.
    // Give it the previous name so it cannot append the extension twice.
    if (sender) [self sendEvent:4 control:0 value:(uint32_t)self.formats.indexOfSelectedItem text:previousName];
}

- (BOOL)panel:(id)sender shouldEnableURL:(NSURL *)url
{
    (void)sender;
    if (!url.isFileURL) return NO;
    NSNumber *directory = nil;
    [url getResourceValue:&directory forKey:NSURLIsDirectoryKey error:nil];
    if (directory.boolValue || !self.filenameFilters.count) return YES;
    NSInteger index = self.formats.indexOfSelectedItem;
    if (index < 0 || (NSUInteger)index >= self.filenameFilters.count) return NO;
    NSString *name = url.lastPathComponent;
    return [self.filenameFilters[index] firstMatchInString:name options:0 range:NSMakeRange(0, name.length)] != nil;
}

- (BOOL)panel:(id)sender validateURL:(NSURL *)url error:(NSError **)error
{
    if (self.saving || [self panel:sender shouldEnableURL:url]) return YES;
    if (error) *error = [NSError errorWithDomain:@"com.yjbeetle.macsw.file-panel" code:1
                                      userInfo:@{NSLocalizedDescriptionKey:@"文件名不符合当前选择的文件格式。"}];
    return NO;
}

- (void)sendEvent:(uint32_t)code control:(uint32_t)control value:(uint32_t)value text:(NSString *)text
{
    if (self.waiting) return;
    NSString *name = self.panel.nameFieldStringValue;
    if (name.length && [name rangeOfCharacterFromSet:[NSCharacterSet characterSetWithCharactersInString:@"*?"]].location == NSNotFound)
        self.lastFileName = name;
    NSMutableData *packet = [NSMutableData data];
    for (NSNumber *word in @[@(PanelMagic), @(PanelVersion), @(code), @0, @0, @(control), @(value), @(self.sequence + 1)])
        appendWord(packet, word.unsignedIntValue);
    [packet appendData:[text dataUsingEncoding:NSUTF16LittleEndianStringEncoding]];
    const uint16_t zero = 0;
    [packet appendBytes:&zero length:2];
    if (!writeResponse(self.responsePath, packet)) { [self.panel cancel:nil]; return; }
    self.waiting = YES;
}

- (void)controlChanged:(NSControl *)control
{
    if (self.waiting) return;
    uint32_t value = [control isKindOfClass:NSPopUpButton.class] ? (uint32_t)((NSPopUpButton *)control).indexOfSelectedItem : 0;
    for (NSDictionary *item in self.controls)
        if ([item[@"id"] integerValue] == control.tag && [item[@"type"] unsignedIntValue] == 1) {
            self.hiddenForCallback = YES;
            [self.panel orderOut:nil];
            break;
        }
    [self sendEvent:3 control:(uint32_t)control.tag value:value
               text:[control isKindOfClass:NSTextField.class] ? control.stringValue : self.panel.nameFieldStringValue];
}

static NSString *cleanLabel(NSString *label)
{
    NSString *text = [label stringByReplacingOccurrencesOfString:@"\\(&.\\)" withString:@"" options:NSRegularExpressionSearch range:NSMakeRange(0, label.length)];
    return [text stringByReplacingOccurrencesOfString:@"&" withString:@""];
}

- (void)reloadControls
{
    NSMutableArray<NSArray<NSView *> *> *rows = [NSMutableArray array];
    if (self.formats) {
        self.formats.font = [NSFont systemFontOfSize:NSFont.systemFontSize];
        [rows addObject:@[[NSTextField labelWithString:@"文件格式："], self.formats]];
    }
    NSString *pendingLabel = nil;
    for (NSDictionary *item in self.controls) {
        NSString *label = cleanLabel(item[@"label"]);
        NSUInteger type = [item[@"type"] unsignedIntegerValue];
        if (type == 4) {
            if (label.length) pendingLabel = label;
            continue;
        }
        NSControl *control;
        if (type == 1) control = [NSButton buttonWithTitle:label target:self action:@selector(controlChanged:)];
        else if (type == 3 || type == 6) {
            NSButton *button = type == 6 ?
                [NSButton radioButtonWithTitle:label target:self action:@selector(controlChanged:)] :
                [NSButton checkboxWithTitle:label target:self action:@selector(controlChanged:)];
            button.state = [item[@"selected"] unsignedIntValue] ? NSControlStateValueOn : NSControlStateValueOff;
            control = button;
        } else if (type == 2) {
            NSPopUpButton *combo = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(0, 0, 360, 26) pullsDown:NO];
            [combo addItemsWithTitles:item[@"items"]];
            uint32_t selected = [item[@"selected"] unsignedIntValue];
            if (selected < combo.numberOfItems) [combo selectItemAtIndex:selected];
            combo.target = self; combo.action = @selector(controlChanged:);
            control = combo;
        } else if (type == 5) {
            NSTextField *edit = [NSTextField textFieldWithString:label];
            ((NSTextFieldCell *)edit.cell).sendsActionOnEndEditing = YES;
            edit.target = self; edit.action = @selector(controlChanged:);
            control = edit;
        } else control = [NSTextField labelWithString:label];
        control.tag = [item[@"id"] integerValue];
        control.enabled = [item[@"enabled"] boolValue];
        control.font = [NSFont systemFontOfSize:NSFont.systemFontSize];
        BOOL field = type == 2 || type == 5;
        NSString *rowLabel = field && pendingLabel.length ? pendingLabel : @"";
        if (type == 2 && [item[@"id"] unsignedIntValue] == 0) rowLabel = label;
        if (rowLabel.length && ![rowLabel hasSuffix:@"："] && ![rowLabel hasSuffix:@":"])
            rowLabel = [rowLabel stringByAppendingString:@"："];
        // A pair of radio choices followed by an action and its text field is
        // one form row (for example SW's prefix/suffix and Advanced controls).
        if (type == 5 && !rowLabel.length && rows.count >= 3) {
            NSView *first = rows[rows.count - 3][1];
            NSView *second = rows[rows.count - 2][1];
            NSView *action = rows.lastObject[1];
            NSUInteger firstType = 0, secondType = 0, actionType = 0;
            for (NSDictionary *candidate in self.controls) {
                NSInteger tag = [candidate[@"id"] integerValue];
                if (tag == first.tag) firstType = [candidate[@"type"] unsignedIntegerValue];
                if (tag == second.tag) secondType = [candidate[@"type"] unsignedIntegerValue];
                if (tag == action.tag) actionType = [candidate[@"type"] unsignedIntegerValue];
            }
            if (firstType == 6 && secondType == 6 && actionType == 1) {
                NSStackView *choices = [NSStackView stackViewWithViews:@[first, second]];
                choices.orientation = NSUserInterfaceLayoutOrientationVertical;
                choices.alignment = NSLayoutAttributeLeading;
                choices.spacing = 6;
                [control.widthAnchor constraintEqualToConstant:150].active = YES;
                NSStackView *line = [NSStackView stackViewWithViews:@[choices, control, action]];
                line.spacing = 12;
                [rows removeObjectsInRange:NSMakeRange(rows.count - 3, 3)];
                [rows addObject:@[[NSTextField labelWithString:@""], line]];
                continue;
            }
        }
        if (field) {
            pendingLabel = nil;
            [control.widthAnchor constraintEqualToConstant:340].active = YES;
        }
        [rows addObject:@[[NSTextField labelWithString:rowLabel], control]];
    }
    NSGridView *grid = [NSGridView gridViewWithViews:rows];
    grid.rowSpacing = 10;
    grid.columnSpacing = 10;
    if (rows.count) {
        [grid columnAtIndex:0].xPlacement = NSGridCellPlacementTrailing;
        [grid columnAtIndex:1].xPlacement = NSGridCellPlacementLeading;
        for (NSInteger i = 0; i < grid.numberOfRows; ++i) [grid rowAtIndex:i].yPlacement = NSGridCellPlacementCenter;
    }
    NSView *container = [NSView new];
    grid.translatesAutoresizingMaskIntoConstraints = NO;
    [container addSubview:grid];
    [NSLayoutConstraint activateConstraints:@[
        [grid.leadingAnchor constraintEqualToAnchor:container.leadingAnchor constant:20],
        [grid.trailingAnchor constraintLessThanOrEqualToAnchor:container.trailingAnchor constant:-20],
        [grid.topAnchor constraintEqualToAnchor:container.topAnchor constant:14],
        [grid.bottomAnchor constraintEqualToAnchor:container.bottomAnchor constant:-14]
    ]];
    NSSize size = grid.fittingSize;
    container.frame = NSMakeRect(0, 0, MAX(480, size.width + 40), size.height + 28);
    self.panel.accessoryView = container;
    if (!self.saving) ((NSOpenPanel *)self.panel).accessoryViewDisclosed = YES;
}

- (void)receiveUpdate
{
    if (!self.waiting) return;
    NSData *data = [NSData dataWithContentsOfFile:self.requestPath];
    if (data.length < 24 || data.length > MaximumBytes) return;
    NSUInteger offset = 0;
    uint32_t header[6], sequence;
    for (int i = 0; i < 6; ++i) if (!readWord(data, &offset, &header[i])) return;
    if (header[0] != PanelMagic || header[1] != PanelVersion || header[5] > 128) return;
    NSString *name = nil, *ext = nil;
    for (int i = 0; i < 4; ++i) {
        NSString *text = readString(data, &offset);
        if (!text) return;
        if (i == 2) name = text;
        if (i == 3) ext = text;
    }
    for (uint32_t i = 0; i < header[5] * 2; ++i) if (!readString(data, &offset)) return;
    if (!readWord(data, &offset, &sequence) || sequence != self.sequence + 1) return;
    NSArray *controls = readControls(data, &offset);
    if (!controls || offset != data.length) return;
    self.sequence = sequence;
    self.controls = controls;
    self.defaultExtension = ext;
    if (header[4] && header[4] <= self.formats.numberOfItems) [self.formats selectItemAtIndex:header[4] - 1];
    // SW sometimes uses '*.STEP' as a filter update, not as a document name.
    // Preserve the user's actual name across that callback.
    if (!name.length || [name rangeOfCharacterFromSet:[NSCharacterSet characterSetWithCharactersInString:@"*?"]].location != NSNotFound)
        name = self.lastFileName ?: @"";
    self.panel.nameFieldStringValue = name;
    [self selectFormat:nil];
    [self reloadControls];
    self.waiting = NO;
    if (self.hiddenForCallback) { self.hiddenForCallback = NO; [self.panel makeKeyAndOrderFront:nil]; }
}
@end

static BOOL readWord(NSData *data, NSUInteger *offset, uint32_t *value)
{
    if (*offset + 4 > data.length) return NO;
    uint32_t word;
    [data getBytes:&word range:NSMakeRange(*offset, 4)];
    *offset += 4;
    *value = CFSwapInt32LittleToHost(word);
    return YES;
}

static NSString *readString(NSData *data, NSUInteger *offset)
{
    NSUInteger start = *offset;
    while (*offset + 2 <= data.length) {
        const unsigned char *bytes = data.bytes;
        BOOL end = !bytes[*offset] && !bytes[*offset + 1];
        *offset += 2;
        if (end) return [[NSString alloc] initWithData:[data subdataWithRange:NSMakeRange(start, *offset - start - 2)]
                                            encoding:NSUTF16LittleEndianStringEncoding];
    }
    return nil;
}

static void appendWord(NSMutableData *data, uint32_t value)
{
    value = CFSwapInt32HostToLittle(value);
    [data appendBytes:&value length:4];
}

static NSArray *readControls(NSData *data, NSUInteger *offset)
{
    uint32_t count;
    if (!readWord(data, offset, &count) || count > 256) return nil;
    NSMutableArray *controls = [NSMutableArray array];
    for (uint32_t i = 0; i < count; ++i) {
        uint32_t id, type, enabled, selected, items;
        if (!readWord(data, offset, &id) || !readWord(data, offset, &type) || type < 1 || type > 6 ||
            !readWord(data, offset, &enabled) || !readWord(data, offset, &selected) ||
            !readWord(data, offset, &items) || items > 1024) return nil;
        NSString *label = readString(data, offset);
        if (!label) return nil;
        NSMutableArray *labels = [NSMutableArray array];
        for (uint32_t j = 0; j < items; ++j) {
            NSString *item = readString(data, offset);
            if (!item) return nil;
            [labels addObject:item];
        }
        [controls addObject:@{@"id":@(id), @"type":@(type), @"enabled":@(enabled), @"selected":@(selected), @"label":label, @"items":labels}];
    }
    return controls;
}

static BOOL respond(NSString *path, uint32_t status, uint32_t index, NSArray<NSURL *> *urls)
{
    NSMutableData *data = [NSMutableData data];
    for (NSNumber *word in @[@(PanelMagic), @(PanelVersion), @(status), @(index), @(urls.count)])
        appendWord(data, word.unsignedIntValue);
    for (NSURL *url in urls) {
        [data appendData:[url.path dataUsingEncoding:NSUTF16LittleEndianStringEncoding]];
        const uint16_t zero = 0;
        [data appendBytes:&zero length:2];
    }
    return writeResponse(path, data);
}

static BOOL writeResponse(NSString *path, NSData *data)
{
    // The caller exclusively creates both files; never follow a replacement link.
    int fd = open(path.fileSystemRepresentation, O_WRONLY | O_TRUNC | O_NOFOLLOW);
    if (fd < 0) return NO;
    struct stat st;
    BOOL valid = !fstat(fd, &st) && S_ISREG(st.st_mode) && st.st_uid == getuid();
    const char *bytes = data.bytes;
    NSUInteger written = 0;
    while (valid && written < data.length) {
        ssize_t count = write(fd, bytes + written, data.length - written);
        if (count <= 0) valid = NO;
        else written += count;
    }
    close(fd);
    return valid;
}

static NSArray<NSString *> *extensionsForPattern(NSString *pattern)
{
    NSMutableArray *result = [NSMutableArray array];
    BOOL allFiles = NO;
    for (NSString *raw in [pattern componentsSeparatedByString:@";"]) {
        NSString *item = [raw stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
        if ([item isEqualToString:@"*"] || [item isEqualToString:@"*.*"]) { allFiles = YES; continue; }
        // SW's CATIA list mixes "*.CATProduct" and ".CATProduct".
        // Both denote an extension; keep rejecting path/glob expressions.
        NSUInteger prefix = [item hasPrefix:@"*."] ? 2 : ([item hasPrefix:@"."] ? 1 : 0);
        if (!prefix || item.length <= prefix) return nil;
        NSString *ext = [item substringFromIndex:prefix];
        if ([ext rangeOfCharacterFromSet:[NSCharacterSet characterSetWithCharactersInString:@"*?/\\:"]].location != NSNotFound)
            return nil;
        [result addObject:ext];
    }
    return allFiles ? @[] : result;
}

// A wildcard filter is valid, but only a concrete extension may be appended.
static NSString *saveExtensionForPattern(NSString *pattern)
{
    for (NSString *raw in [pattern componentsSeparatedByString:@";"]) {
        NSArray *extensions = extensionsForPattern(raw);
        if (extensions.count) return extensions.firstObject;
    }
    return @"";
}

// Windows file filters are case-insensitive filename globs, not UTType names.
// Escape all regex syntax before translating the two supported wildcards.
static NSRegularExpression *filenameFilterForPattern(NSString *pattern)
{
    NSMutableArray *alternatives = [NSMutableArray array];
    for (NSString *raw in [pattern componentsSeparatedByString:@";"]) {
        NSString *item = [raw stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
        if (!item.length || [item rangeOfCharacterFromSet:[NSCharacterSet characterSetWithCharactersInString:@"/\\:"]].location != NSNotFound)
            return nil;
        if ([item isEqualToString:@"*.*"]) item = @"*";
        else if ([item hasPrefix:@"."]) {
            if (item.length == 1) return nil;
            item = [@"*" stringByAppendingString:item];
        }
        NSString *regex = [NSRegularExpression escapedPatternForString:item];
        regex = [regex stringByReplacingOccurrencesOfString:@"\\*" withString:@".*"];
        regex = [regex stringByReplacingOccurrencesOfString:@"\\?" withString:@"."];
        [alternatives addObject:regex];
    }
    NSString *regex = [NSString stringWithFormat:@"\\A(?:%@)\\z", [alternatives componentsJoinedByString:@"|"]];
    return [NSRegularExpression regularExpressionWithPattern:regex options:NSRegularExpressionCaseInsensitive error:nil];
}

int main(int argc, const char **argv)
{
    @autoreleasepool {
        if (argc != 3) return 2;
        NSString *request = [NSString stringWithUTF8String:argv[1]];
        NSString *response = [NSString stringWithUTF8String:argv[2]];
        int fd = open(request.fileSystemRepresentation, O_RDONLY | O_NOFOLLOW);
        if (fd < 0) return 2;
        struct stat st;
        if (fstat(fd, &st) || !S_ISREG(st.st_mode) || st.st_uid != getuid() || st.st_size < 24 || st.st_size > MaximumBytes) {
            close(fd); return 2;
        }
        NSFileHandle *handle = [[NSFileHandle alloc] initWithFileDescriptor:fd closeOnDealloc:YES];
        NSData *data = [handle readDataToEndOfFile];
        [handle closeFile];
        NSUInteger offset = 0;
        uint32_t magic, version, mode, flags, index, count;
        if (!readWord(data, &offset, &magic) || magic != PanelMagic ||
            !readWord(data, &offset, &version) || version != PanelVersion ||
            !readWord(data, &offset, &mode) || (mode != 1 && mode != 2) ||
            !readWord(data, &offset, &flags) || (flags & ~15u) ||
            !readWord(data, &offset, &index) || !readWord(data, &offset, &count) || count > 128) return 2;
        NSString *title = readString(data, &offset), *directory = readString(data, &offset);
        NSString *name = readString(data, &offset), *defaultExt = readString(data, &offset);
        if (!title || !directory || !name || !defaultExt) return 2;
        NSMutableArray *names = [NSMutableArray array], *extensions = [NSMutableArray array];
        NSMutableArray *filenameFilters = [NSMutableArray array], *saveExtensions = [NSMutableArray array];
        for (uint32_t i = 0; i < count; ++i) {
            NSString *label = readString(data, &offset), *pattern = readString(data, &offset);
            NSArray *exts = pattern ? extensionsForPattern(pattern) : nil;
            NSRegularExpression *filter = pattern ? filenameFilterForPattern(pattern) : nil;
            if (!label || !filter) {
                NSLog(@"MacSW native panel: unsupported file filter %@ (%@)", label, pattern);
                respond(response, 2, index, @[]); return 0;
            }
            [names addObject:label]; [extensions addObject:exts ?: @[]];
            [filenameFilters addObject:filter];
            [saveExtensions addObject:saveExtensionForPattern(pattern)];
        }
        uint32_t sequence;
        if (!readWord(data, &offset, &sequence)) return 2;
        NSArray *controls = readControls(data, &offset);
        if (!controls || offset != data.length || (count && (!index || index > count))) return 2;
        if (mode == 2 && (flags & 3)) return 2;

        [NSApplication sharedApplication];
        [NSUserDefaults.standardUserDefaults setBool:YES forKey:@"NSNavPanelExpandedStateForSaveMode"];
        [NSUserDefaults.standardUserDefaults setBool:YES forKey:@"NSNavPanelExpandedStateForSaveMode2"];
        [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
        [NSApp finishLaunching];
        PanelController *controller = [PanelController new];
        controller.saving = mode == 2;
        controller.extensions = extensions;
        controller.filenameFilters = filenameFilters;
        controller.saveExtensions = saveExtensions;
        controller.defaultExtension = defaultExt;
        controller.requestPath = request;
        controller.responsePath = response;
        controller.controls = controls;
        controller.sequence = sequence;
        controller.lastFileName = name;
        NSSavePanel *panel = controller.saving ? NSSavePanel.savePanel : NSOpenPanel.openPanel;
        controller.panel = panel;
        panel.delegate = controller;
        panel.title = title.length ? title : (controller.saving ? @"保存" : @"打开");
        panel.prompt = controller.saving ? @"保存" : @"打开";
        panel.nameFieldLabel = controller.saving ? @"存储为：" : @"文件名：";
        panel.showsTagField = NO;
        panel.canCreateDirectories = YES;
        panel.showsHiddenFiles = !!(flags & 4);
        panel.nameFieldStringValue = name;
        if (directory.length) panel.directoryURL = [NSURL fileURLWithPath:directory isDirectory:YES];
        if (!controller.saving) {
            NSOpenPanel *open = (NSOpenPanel *)panel;
            open.canChooseDirectories = !!(flags & 2);
            open.canChooseFiles = !(flags & 2);
            open.allowsMultipleSelection = !!(flags & 1);
            open.resolvesAliases = !(flags & 8);
        }
        if (count) {
            NSPopUpButton *formats = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(0, 0, 360, 26) pullsDown:NO];
            [formats addItemsWithTitles:names];
            [formats selectItemAtIndex:index - 1];
            formats.target = controller; formats.action = @selector(selectFormat:);
            controller.formats = formats;
            [formats.widthAnchor constraintEqualToConstant:340].active = YES;
        }
        [controller selectFormat:nil];
        [controller reloadControls];
        pid_t parent = getppid();
        NSTimer *timer = [NSTimer scheduledTimerWithTimeInterval:0.5 repeats:YES block:^(NSTimer *t) {
            (void)t;
            if (getppid() != parent || parent == 1) { controller.waiting = NO; [panel cancel:nil]; }
            [controller receiveUpdate];
        }];
        [NSRunLoop.mainRunLoop addTimer:timer forMode:NSModalPanelRunLoopMode];
        [NSApp activateIgnoringOtherApps:YES];
        NSModalResponse answer = [panel runModal];
        while (controller.waiting) {
            [NSRunLoop.mainRunLoop runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
        }
        [timer invalidate];
        NSArray *urls = answer != NSModalResponseOK ? @[] :
            (controller.saving ? @[panel.URL] : ((NSOpenPanel *)panel).URLs);
        return respond(response, answer == NSModalResponseOK ? 0 : 1,
                       count ? (uint32_t)controller.formats.indexOfSelectedItem + 1 : 0, urls) ? 0 : 2;
    }
}
