#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/macsw-panel-filters.XXXXXX")"
trap 'rm -rf "$TEST_DIR"' EXIT
cat > "$TEST_DIR/test.m" <<'OBJC'
#define main panel_application_main
#include "native/macsw_file_panel.m"
#undef main
static void check(NSString *pattern, NSArray *expected)
{
    NSArray *actual = extensionsForPattern(pattern);
    if (!(actual == expected || [actual isEqualToArray:expected])) {
        NSLog(@"filter %@: expected %@, got %@", pattern, expected, actual);
        exit(1);
    }
}
static void matches(NSString *pattern, NSString *name, BOOL expected)
{
    NSRegularExpression *filter = filenameFilterForPattern(pattern);
    BOOL actual = filter && [filter firstMatchInString:name options:0 range:NSMakeRange(0, name.length)] != nil;
    if (actual != expected) { NSLog(@"pattern %@ filename %@: unexpected match %d", pattern, name, actual); exit(1); }
}
int main(void)
{
    @autoreleasepool {
        check(@"*.CATPART;*.CATPART;.CATProduct;*.CATProduct", (@[@"CATPART", @"CATPART", @"CATProduct", @"CATProduct"]));
        check(@" *.step ; *.stp ", (@[@"step", @"stp"]));
        check(@"*.SLDPRT;*.SLDASM;*.SLDDRW", (@[@"SLDPRT", @"SLDASM", @"SLDDRW"]));
        check(@"*.*", @[]);
        check(@"*", @[]);
        check(@"*.SLDPRT;*.*", @[]);
        check(@".", nil);
        check(@"*.", nil);
        check(@"*.prt.*", nil);
        check(@"*.foo/bar", nil);
        check(@".foo\\bar", nil);
        check(@".foo:bar", nil);
        check(@".foo?", nil);
        matches(@"*.PRT;*.PRT.*;*.XPR;*.ASM;*.ASM.*;*.XAS", @"模型.prt.42", YES);
        matches(@"*.PRT;*.PRT.*;*.XPR;*.ASM;*.ASM.*;*.XAS", @"assembly.ASM.7", YES);
        matches(@"*.PRT;*.PRT.*", @"model.prt", YES);
        matches(@"*.PRT;*.PRT.*", @"model.prtfoo", NO);
        matches(@"*.PRT;*.PRT.*", @"model.step", NO);
        matches(@"*.CATPART;.CATProduct", @"模型.catproduct", YES);
        matches(@"*.CATPART;.CATProduct", @"模型.catproduct.bak", NO);
        matches(@"*.*", @"README", YES);
        matches(@" *.step ; *.stp ", @"model.STEP", YES);
        matches(@"part?.sldprt", @"part1.sldprt", YES);
        matches(@"part?.sldprt", @"part12.sldprt", NO);
        matches(@"model[1].prt", @"model[1].prt", YES);
        matches(@"model[1].prt", @"model1.prt", NO);
        for (NSString *bad in @[@"", @".", @"*.prt;", @"../*.prt", @"C:\\*.prt"])
            if (filenameFilterForPattern(bad)) { NSLog(@"accepted invalid filter %@", bad); exit(1); }
        for (NSArray *pair in @[@[@"*.PRT;*.PRT.*", @"PRT"], @[@"*.PRT.*;*.PRT", @"PRT"],
                               @[@"*.prt.*", @""], @[@"*.*", @""], @[@"part?.prt", @""],
                               @[@".CATProduct", @"CATProduct"], @[@"*.STEP;*.stp", @"STEP"]]) {
            if (![saveExtensionForPattern(pair[0]) isEqualToString:pair[1]]) {
                NSLog(@"incorrect save extension for %@", pair[0]); exit(1);
            }
        }
        puts("Native panel filter tests passed");
    }
    return 0;
}
OBJC
xcrun clang -fobjc-arc -Wall -Wextra -Werror -Wno-deprecated-declarations \
  -I "$ROOT" -framework AppKit "$TEST_DIR/test.m" -o "$TEST_DIR/test"
"$TEST_DIR/test"
