// PDUtilityMenu.m — the ••• menu, in the family's menu shape.
//
// SunPad, MeleePad and GalaxyPad hang one titled menu off the ellipsis:
// Display, Controls and Audio, a game-data group, Help & Feedback (Report a
// Problem…, Share Diagnostic Log, About) and a destructive end action last.
// DarkPad keeps that shape. The engine owns the main thread and pumps the run
// loop only in its default mode, which a system UIMenu never finishes
// presenting under, so the menu is drawn here in the system menu's style and
// shown in the settings window, which already owns pausing and focus return.
// Detailed sliders and imports stay on the Settings page; the menu opens it at
// the matching section.
#import "PDUtilityMenu.h"

#import "PDAudio.h"
#import "PDController.h"
#import "PDDefaults.h"
#import "PDGyro.h"
#import "PDSettingsViewController.h"
#import "PDShell.h"
#import "PDTouchOverlay.h"
#import "PDVision.h"

#import <GameController/GameController.h>
#include <build_stamp.h>
#include <sys/sysctl.h>

static NSString *const kRepositoryURL = @"https://github.com/chrissotraidis/darkpad";

static BOOL sCanEndSession;

// --- model ------------------------------------------------------------------

/** One row: an action, a choice/toggle (stays open), or a submenu. */
@interface PDMenuNode : NSObject
@property (nonatomic, copy) NSString *title;
@property (nonatomic, copy, nullable) NSString *subtitle;
@property (nonatomic, copy, nullable) NSString *symbol;
@property (nonatomic) BOOL checked;
@property (nonatomic) BOOL disabled;
@property (nonatomic) BOOL destructive;
/** Choices and toggles refresh the open menu instead of closing it. */
@property (nonatomic) BOOL keepsOpen;
@property (nonatomic, copy, nullable) void (^handler)(void);
/** Submenu rows: sections of child rows. */
@property (nonatomic, copy, nullable) NSArray<NSArray<PDMenuNode *> *> *sections;
@end
@implementation PDMenuNode
@end

static PDMenuNode *pdAction(NSString *title, NSString *symbol, void (^handler)(void))
{
	PDMenuNode *n = [PDMenuNode new];
	n.title = title; n.symbol = symbol; n.handler = handler;
	return n;
}

static PDMenuNode *pdSubmenu(NSString *title, NSString *symbol, NSArray<NSArray<PDMenuNode *> *> *sections)
{
	PDMenuNode *n = [PDMenuNode new];
	n.title = title; n.symbol = symbol; n.sections = sections;
	return n;
}

static PDMenuNode *pdToggle(NSString *title, NSString *symbol, NSString *key)
{
	PDMenuNode *n = pdAction(title, symbol, ^{
		[NSUserDefaults.standardUserDefaults setBool:!PDDefBool(key) forKey:key];
		[PDSettingsViewController applyDefaultsChange];
	});
	n.checked = PDDefBool(key);
	n.keepsOpen = YES;
	return n;
}

/** One checkmarked choice per value of an integer setting, as a submenu. */
static PDMenuNode *pdChoices(NSString *title, NSString *symbol, NSString *key,
	NSArray<NSString *> *titles, NSArray<NSNumber *> *values, NSArray<NSString *> *subtitles)
{
	NSMutableArray<PDMenuNode *> *rows = [NSMutableArray array];
	NSInteger current = PDDefInt(key);
	NSString *selected = nil;
	for (NSUInteger i = 0; i < titles.count; i++) {
		NSInteger value = values[i].integerValue;
		PDMenuNode *choice = pdAction(titles[i], nil, ^{
			[NSUserDefaults.standardUserDefaults setInteger:value forKey:key];
			[PDSettingsViewController applyDefaultsChange];
		});
		if (i < subtitles.count && subtitles[i].length) choice.subtitle = subtitles[i];
		choice.checked = current == value;
		choice.keepsOpen = YES;
		if (choice.checked) selected = titles[i];
		[rows addObject:choice];
	}
	PDMenuNode *menu = pdSubmenu(title, symbol, @[ rows ]);
	menu.subtitle = selected;
	return menu;
}

@interface PDUtilityMenu ()
+ (NSArray<NSArray<PDMenuNode *> *> *)rootSections;
+ (void)confirmControllerLayout;
+ (void)confirmEndSession;
+ (void)reportProblem;
+ (void)shareDiagnosticLog;
+ (void)presentAbout;
@end

// --- presentation -----------------------------------------------------------

/** After the menu window has handed back, on the next main-queue turn. */
static void pdAfterMenu(dispatch_block_t block)
{
	dispatch_async(dispatch_get_main_queue(), block);
}

static void pdOpenSettings(NSString *section)
{
	pdAfterMenu(^{
		[PDSettingsViewController present];
		if (section) [PDSettingsViewController scrollToSectionContaining:section];
	});
}

static UIFont *pdRounded(CGFloat size, UIFontWeight weight)
{
	UIFontDescriptor *d = [[UIFont systemFontOfSize:size weight:weight].fontDescriptor
		fontDescriptorWithDesign:UIFontDescriptorSystemDesignDefault];
	return [UIFontMetrics.defaultMetrics scaledFontForFont:[UIFont fontWithDescriptor:d size:size]];
}

/** The system menu's look: glass panel, leading symbols, chevrons into submenus. */
@interface PDMenuPanelController : UIViewController
@end

@implementation PDMenuPanelController {
	UIVisualEffectView *_panel;
	UIScrollView *_scroll;
	UIStackView *_stack;
	NSMutableArray<NSString *> *_path;   // submenu titles from the root
}

- (void)viewDidLoad
{
	[super viewDidLoad];
	_path = [NSMutableArray array];
	self.view.backgroundColor = UIColor.clearColor;
	self.view.accessibilityViewIsModal = YES;
	UIButton *outside = [UIButton buttonWithType:UIButtonTypeCustom];
	outside.frame = self.view.bounds;
	outside.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
	outside.accessibilityLabel = @"Close DarkPad menu";
	[outside addTarget:self action:@selector(close) forControlEvents:UIControlEventTouchUpInside];
	[self.view addSubview:outside];

	_panel = [[UIVisualEffectView alloc] initWithEffect:
		[UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemThickMaterialDark]];
	_panel.layer.cornerRadius = 22;
	_panel.layer.cornerCurve = kCACornerCurveContinuous;
	_panel.clipsToBounds = YES;
	_panel.layer.borderWidth = 0.5;
	_panel.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.18].CGColor;
	_panel.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
	[self.view addSubview:_panel];
	_scroll = [UIScrollView new];
	_scroll.alwaysBounceVertical = NO;
	[_panel.contentView addSubview:_scroll];
	_stack = [UIStackView new];
	_stack.axis = UILayoutConstraintAxisVertical;
	[_scroll addSubview:_stack];
	[self reload];
}

- (BOOL)accessibilityPerformEscape { [self close]; return YES; }
- (void)close { [PDSettingsViewController dismiss]; }

/** The current level of the menu, rebuilt from live settings. */
- (NSArray<NSArray<PDMenuNode *> *> *)currentSections
{
	NSArray<NSArray<PDMenuNode *> *> *sections = [PDUtilityMenu rootSections];
	for (NSString *title in _path) {
		PDMenuNode *found = nil;
		for (NSArray<PDMenuNode *> *section in sections)
			for (PDMenuNode *n in section)
				if (n.sections && [n.title isEqualToString:title]) found = n;
		if (!found) { [_path removeAllObjects]; return [PDUtilityMenu rootSections]; }
		sections = found.sections;
	}
	return sections;
}

- (void)reload
{
	for (UIView *v in _stack.arrangedSubviews) [v removeFromSuperview];
	UILabel *header = [UILabel new];
	header.font = pdRounded(13, UIFontWeightSemibold);
	header.textColor = UIColor.secondaryLabelColor;
	header.text = PDUtilityMenu.title;
	if (_path.count) {
		[_stack addArrangedSubview:[self backRow]];
		[_stack addArrangedSubview:[self separator:1]];
	} else {
		UIView *wrap = [UIView new];
		header.translatesAutoresizingMaskIntoConstraints = NO;
		[wrap addSubview:header];
		[NSLayoutConstraint activateConstraints:@[
			[header.leadingAnchor constraintEqualToAnchor:wrap.leadingAnchor constant:18],
			[header.trailingAnchor constraintEqualToAnchor:wrap.trailingAnchor constant:-18],
			[header.topAnchor constraintEqualToAnchor:wrap.topAnchor constant:12],
			[header.bottomAnchor constraintEqualToAnchor:wrap.bottomAnchor constant:-6],
		]];
		[_stack addArrangedSubview:wrap];
	}
	NSArray<NSArray<PDMenuNode *> *> *sections = [self currentSections];
	for (NSUInteger s = 0; s < sections.count; s++) {
		if (s) [_stack addArrangedSubview:[self separator:8]];
		for (PDMenuNode *node in sections[s]) [_stack addArrangedSubview:[self rowForNode:node]];
	}
	[self.view setNeedsLayout];
}

- (UIView *)separator:(CGFloat)height
{
	UIView *v = [UIView new];
	v.backgroundColor = height > 1 ? [UIColor colorWithWhite:0 alpha:0.28] : UIColor.separatorColor;
	[v.heightAnchor constraintEqualToConstant:height > 1 ? height : 0.5].active = YES;
	return v;
}

/** A menu row: fixed icon column, title over optional subtitle, optional chevron. */
- (UIControl *)rowWithTitle:(NSString *)title subtitle:(nullable NSString *)subtitle
	symbol:(nullable NSString *)symbol tint:(UIColor *)tint bold:(BOOL)bold chevron:(BOOL)chevron
{
	UIButton *row = [UIButton buttonWithType:UIButtonTypeSystem];
	row.accessibilityLabel = title;
	UIImageView *icon = [UIImageView new];
	icon.contentMode = UIViewContentModeCenter;
	icon.tintColor = tint;
	if (symbol.length) {
		icon.image = [UIImage systemImageNamed:symbol withConfiguration:
			[UIImageSymbolConfiguration configurationWithPointSize:17 weight:bold ? UIImageSymbolWeightSemibold : UIImageSymbolWeightRegular]];
	}
	UILabel *name = [UILabel new];
	name.text = title;
	name.font = pdRounded(17, bold ? UIFontWeightSemibold : UIFontWeightRegular);
	name.textColor = tint;
	UIStackView *text = [[UIStackView alloc] initWithArrangedSubviews:@[ name ]];
	text.axis = UILayoutConstraintAxisVertical;
	text.spacing = 1;
	if (subtitle.length) {
		UILabel *detail = [UILabel new];
		detail.text = subtitle;
		detail.font = pdRounded(13, UIFontWeightRegular);
		detail.textColor = UIColor.secondaryLabelColor;
		detail.numberOfLines = 2;
		[text addArrangedSubview:detail];
	}
	NSMutableArray *parts = [NSMutableArray arrayWithObjects:icon, text, nil];
	if (chevron) {
		UIImageView *next = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"chevron.forward"
			withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:13 weight:UIImageSymbolWeightSemibold]]];
		next.tintColor = UIColor.tertiaryLabelColor;
		[next setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
		[parts addObject:next];
	}
	UIStackView *line = [[UIStackView alloc] initWithArrangedSubviews:parts];
	line.alignment = UIStackViewAlignmentCenter;
	line.spacing = 12;
	line.userInteractionEnabled = NO;
	line.translatesAutoresizingMaskIntoConstraints = NO;
	[row addSubview:line];
	[NSLayoutConstraint activateConstraints:@[
		[icon.widthAnchor constraintEqualToConstant:28],
		[line.leadingAnchor constraintEqualToAnchor:row.leadingAnchor constant:16],
		[line.trailingAnchor constraintEqualToAnchor:row.trailingAnchor constant:-16],
		[line.topAnchor constraintEqualToAnchor:row.topAnchor constant:10],
		[line.bottomAnchor constraintEqualToAnchor:row.bottomAnchor constant:-10],
		[row.heightAnchor constraintGreaterThanOrEqualToConstant:48],
	]];
	return row;
}

- (UIView *)backRow
{
	UIControl *back = [self rowWithTitle:_path.lastObject subtitle:nil symbol:@"chevron.backward"
		tint:UIColor.labelColor bold:YES chevron:NO];
	back.accessibilityLabel = [NSString stringWithFormat:@"Back from %@", _path.lastObject];
	[back addTarget:self action:@selector(goBack) forControlEvents:UIControlEventTouchUpInside];
	return back;
}

- (UIView *)rowForNode:(PDMenuNode *)node
{
	UIColor *tint = node.destructive ? UIColor.systemRedColor : UIColor.labelColor;
	if (node.disabled) tint = UIColor.tertiaryLabelColor;
	NSString *symbol = node.checked ? @"checkmark" : node.symbol;
	UIControl *row = [self rowWithTitle:node.title subtitle:node.subtitle symbol:symbol tint:tint
		bold:NO chevron:node.sections != nil];
	row.enabled = !node.disabled;
	row.accessibilityValue = node.checked ? @"Selected" : node.subtitle;
	__weak typeof(self) weakSelf = self;
	[row addAction:[UIAction actionWithHandler:^(__kindof UIAction *a) {
		(void)a;
		[weakSelf activate:node];
	}] forControlEvents:UIControlEventTouchUpInside];
	return row;
}

- (void)activate:(PDMenuNode *)node
{
	if (node.sections) {
		[_path addObject:node.title];
		[self reload];
		return;
	}
	if (node.keepsOpen) {
		if (node.handler) node.handler();
		[self reload];
		return;
	}
	// Actions close the menu first; their flows present afterwards.
	[PDSettingsViewController dismiss];
	if (node.handler) node.handler();
}

- (void)goBack
{
	[_path removeLastObject];
	[self reload];
}

- (void)viewDidLayoutSubviews
{
	[super viewDidLayoutSubviews];
	UIEdgeInsets inset = self.view.safeAreaInsets;
	BOOL tablet = self.traitCollection.userInterfaceIdiom == UIUserInterfaceIdiomPad;
	CGFloat width = MIN(tablet ? 320 : 290, self.view.bounds.size.width - inset.left - inset.right - 24);
	CGSize fit = [_stack systemLayoutSizeFittingSize:CGSizeMake(width, UILayoutFittingCompressedSize.height)
		withHorizontalFittingPriority:UILayoutPriorityRequired verticalFittingPriority:UILayoutPriorityFittingSizeLevel];
	CGRect anchor = [self.view convertRect:PDUtilityMenuFrame(self.view.window) fromView:self.view.window];
	CGFloat top = CGRectGetMaxY(anchor) + 10;
	CGFloat available = MAX(120, self.view.bounds.size.height - MAX(inset.bottom, 12) - top - 8);
	CGFloat left = MAX(inset.left + 12, CGRectGetMaxX(anchor) - width);
	_panel.frame = CGRectMake(left, top, width, MIN(fit.height, available));
	_scroll.frame = _panel.contentView.bounds;
	_stack.frame = CGRectMake(0, 0, width, fit.height);
	_scroll.contentSize = _stack.bounds.size;
}

@end

@implementation PDUtilityMenu

+ (void)noteEngineFrame
{
	sCanEndSession = mainIosCanEndSession() != 0;
}

+ (NSString *)title
{
	NSString *version = [NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleShortVersionString"] ?: @(PD_IOS_MARKETING_VERSION);
	return [NSString stringWithFormat:@"DarkPad %@", version];
}

+ (void)present
{
	[PDSettingsViewController presentPanel:[PDMenuPanelController new]];
}

// --- the menu ---------------------------------------------------------------

+ (NSArray<NSArray<PDMenuNode *> *> *)rootSections
{
	// Display
	NSMutableArray<PDMenuNode *> *display = [NSMutableArray arrayWithObject:
		pdChoices(@"Art Profile", @"paintpalette", PDDefGraphicsProfile,
			@[ @"Original", @"Enhanced", @"Remaster" ], @[ @0, @1, @2 ],
			@[ @"N64 art", @"2× filtering and your texture pack", @"Your Xbox 360 art" ])];
	const NSInteger high = PDPanelHighHz();
	if (high > 60 && !PDDefBool(PDDefHide60On120)) {
		[display addObject:pdChoices(@"Frame Rate", @"gauge.with.dots.needle.67percent", PDDefRefreshHz,
			@[ @"60 Hz", [NSString stringWithFormat:@"%ld Hz", (long)high] ], @[ @60, @(high) ],
			@[ @"Recommended", @"Experimental: some game timing runs fast" ])];
	}
#if !TARGET_OS_VISION
	[display addObject:pdChoices(@"Render Resolution", @"square.resize", PDDefRenderScalePct,
		@[ @"Native", @"75%", @"50%" ], @[ @100, @75, @50 ],
		@[ @"Sharpest · applies next launch", @"Applies next launch", @"Fastest · applies next launch" ])];
#endif
	[display addObject:pdToggle(@"Show FPS Counter", @"speedometer", PDDefShowFPS)];
	PDMenuNode *displayMenu = pdSubmenu(@"Display", @"display", @[ display ]);

	// Controls
	PDMenuNode *edit = pdAction(@"Edit Touch Controls", @"hand.draw", ^{
		pdAfterMenu(^{ [PDTouchOverlay.current beginLayoutEditing]; });
	});
	PDMenuNode *onScreen = pdChoices(@"On-Screen Controls", @"hand.tap", PDDefTouchMode,
		@[ @"Auto", @"On", @"Off" ], @[ @0, @1, @2 ], @[ @"Hidden while a controller is connected", @"", @"" ]);
	PDMenuNode *touchSettings = pdAction(@"Touch Control Settings…", @"slider.horizontal.3", ^{
		pdOpenSettings(@"Touch Controls");
	});
	PDMenuNode *preset = pdAction(@"Use GoldenPad Controller Layout…", @"gamecontroller", ^{
		pdAfterMenu(^{ [PDUtilityMenu confirmControllerLayout]; });
	});
	PDMenuNode *controllerSettings = pdAction(@"Controller Settings…", @"slider.horizontal.3", ^{
		pdOpenSettings(@"Controller");
	});
	NSMutableArray<NSArray<PDMenuNode *> *> *controls = [NSMutableArray arrayWithArray:@[
		@[ edit, onScreen, touchSettings ],
		@[ preset, controllerSettings ],
	]];
#if !TARGET_OS_VISION
	PDMenuNode *gyro = pdToggle(@"Gyro While Aiming", @"gyroscope", PDDefGyroEnabled);
	gyro.subtitle = @"Experimental";
	PDMenuNode *recenter = pdAction(@"Recenter Gyro", @"scope", ^{ [PDGyro.shared recenter]; });
	recenter.keepsOpen = YES;
	recenter.disabled = !PDDefBool(PDDefGyroEnabled);
	[controls addObject:@[ gyro, recenter ]];
#endif
	PDMenuNode *controlsMenu = pdSubmenu(@"Controls", @"gamecontroller", controls);

	// Audio
	NSMutableArray<PDMenuNode *> *levels = [NSMutableArray array];
	const NSInteger volume = (NSInteger)lroundf(PDDefFloat(PDDefAudioMasterVolume) * 100.0f);
	for (NSNumber *level in @[ @25, @50, @75, @100 ]) {
		PDMenuNode *choice = pdAction([NSString stringWithFormat:@"%@%%", level], nil, ^{
			[NSUserDefaults.standardUserDefaults setFloat:level.floatValue / 100.0f forKey:PDDefAudioMasterVolume];
			[PDSettingsViewController applyDefaultsChange];
		});
		choice.checked = volume == level.integerValue;
		choice.keepsOpen = YES;
		[levels addObject:choice];
	}
	PDMenuNode *volumeMenu = pdSubmenu(@"Main Volume", @"speaker.wave.2", @[ levels ]);
	volumeMenu.subtitle = [NSString stringWithFormat:@"%ld%%", (long)volume];
	NSMutableArray<PDMenuNode *> *modes = [NSMutableArray array];
	NSInteger mode = PDDefInt(PDDefAudioSessionMode);
	for (NSUInteger i = 0; i < PDAudio.modeTitles.count; i++) {
		PDMenuNode *choice = pdAction(PDAudio.modeTitles[i], nil, ^{
			[NSUserDefaults.standardUserDefaults setInteger:(NSInteger)i forKey:PDDefAudioSessionMode];
			[PDAudio settingsChanged];
		});
		choice.subtitle = i < PDAudio.modeDetails.count ? PDAudio.modeDetails[i] : nil;
		choice.checked = mode == (NSInteger)i;
		choice.keepsOpen = YES;
		[modes addObject:choice];
	}
	PDMenuNode *otherAudio = pdSubmenu(@"Other App Audio", @"music.note", @[ modes ]);
	otherAudio.subtitle = mode >= 0 && mode < (NSInteger)PDAudio.modeTitles.count ? PDAudio.modeTitles[(NSUInteger)mode] : nil;
	PDMenuNode *audioMenu = pdSubmenu(@"Audio", @"speaker.wave.2", @[ @[
		volumeMenu, pdToggle(@"Mute Game Audio", @"speaker.slash", PDDefAudioMute), otherAudio,
	] ]);

	// Add-ons and game data
	PDMenuNode *addons = pdSubmenu(@"Add-ons & Game Data", @"shippingbox", @[ @[
		pdAction(@"Texture Packs…", @"photo.stack", ^{ pdOpenSettings(@"Texture Packs"); }),
		pdAction(@"Xbox 360 Art…", @"sparkles", ^{ pdOpenSettings(@"Xbox 360 Art"); }),
		pdAction(@"GoldenEye 007 (GE Plus)…", @"star.circle", ^{ pdOpenSettings(@"GoldenEye"); }),
	] ]);
	PDMenuNode *allSettings = pdAction(@"All Settings…", @"gearshape", ^{ pdOpenSettings(nil); });

	// Help & Feedback
	PDMenuNode *help = pdSubmenu(@"Help & Feedback", @"questionmark.circle", @[ @[
		pdAction(@"Report a Problem…", @"exclamationmark.bubble", ^{ pdAfterMenu(^{ [PDUtilityMenu reportProblem]; }); }),
		pdAction(@"Share Diagnostic Log", @"square.and.arrow.up", ^{ pdAfterMenu(^{ [PDUtilityMenu shareDiagnosticLog]; }); }),
		pdAction(@"Build & Performance…", @"waveform.path.ecg", ^{ pdOpenSettings(@"Diagnostics"); }),
	], @[
		pdAction(@"About DarkPad", @"info.circle", ^{ pdAfterMenu(^{ [PDUtilityMenu presentAbout]; }); }),
		pdAction(@"DarkPad on GitHub", @"arrow.up.right.square", ^{
			[UIApplication.sharedApplication openURL:[NSURL URLWithString:kRepositoryURL] options:@{} completionHandler:nil];
		}),
	] ]);

	PDMenuNode *end = pdAction(@"End Mission or Match…", @"stop.circle", ^{
		pdAfterMenu(^{ [PDUtilityMenu confirmEndSession]; });
	});
	end.destructive = YES;
	end.disabled = !sCanEndSession;
	if (!sCanEndSession) end.subtitle = @"Available during a mission or match";

	return @[
		@[ displayMenu, controlsMenu, audioMenu ],
		@[ addons, allSettings ],
		@[ help ],
		@[ end ],
	];
}

// --- flows ------------------------------------------------------------------

+ (void)present:(UIViewController *)controller
{
	[PDSettingsViewController presentModal:controller];
}

+ (UIAlertController *)alert:(NSString *)title message:(NSString *)message
{
	UIAlertController *a = [UIAlertController alertControllerWithTitle:title message:message
		preferredStyle:UIAlertControllerStyleAlert];
	return a;
}

/** A cancel that closes the flow's window and resumes the game. */
+ (UIAlertAction *)closeAction:(NSString *)title
{
	return [UIAlertAction actionWithTitle:title style:UIAlertActionStyleCancel
		handler:^(UIAlertAction *a) { (void)a; [PDSettingsViewController dismiss]; }];
}

+ (void)confirmControllerLayout
{
	UIAlertController *confirm = [self alert:@"GoldenPad Controller Layout"
		message:@"RT fire • LT aim • LB crouch\nA/Y/RB weapon • B/X use\nLeft-stick click reload • Right-stick click alternate fire • View/Back weapon wheel\n\nReplaces controller bindings for all players. Keyboard and D-pad bindings stay unchanged."];
	[confirm addAction:[self closeAction:@"Cancel"]];
	[confirm addAction:[UIAlertAction actionWithTitle:@"Apply" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
		(void)a;
		[PDShell.shared enqueue:^{
			NSString *result = [PDController applyGoldenpadLayout];
			dispatch_async(dispatch_get_main_queue(), ^{
				UIAlertController *done = [self alert:@"Controller Layout" message:result];
				[done addAction:[self closeAction:@"OK"]];
				[PDSettingsViewController presentModal:done];
			});
		}];
	}]];
	[self present:confirm];
}

+ (void)confirmEndSession
{
	UIAlertController *confirm = [self alert:@"End this mission or match?"
		message:@"An unfinished mission restarts from the beginning next time. Completed progress is kept. A match ends at its results screen."];
	[confirm addAction:[self closeAction:@"Keep Playing"]];
	[confirm addAction:[UIAlertAction actionWithTitle:@"End" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *a) {
		(void)a;
		[PDSettingsViewController dismiss];
		[PDShell.shared enqueue:^{
			if (mainIosEndSession()) {
				pdIosSaveConfigNow();
			}
		}];
	}]];
	[self present:confirm];
}

+ (NSString *)versionLine
{
	NSBundle *b = NSBundle.mainBundle;
	return [NSString stringWithFormat:@"DarkPad %@ (build %@)",
		[b objectForInfoDictionaryKey:@"CFBundleShortVersionString"] ?: @"?",
		[b objectForInfoDictionaryKey:@"CFBundleVersion"] ?: @"?"];
}

+ (void)presentAbout
{
	NSString *message = [NSString stringWithFormat:
		@"%@\n%s\n\nPerfect Dark, native on iPhone and iPad. Built on the Perfect Dark decompilation and PC port, Dab's Mod, rebelancap's perfect-dark-ios, SDL2, curl and ANGLE. Each keeps its own license.\n\nNo game data is included. DarkPad is not affiliated with Rare, Microsoft or Nintendo.",
		[self versionLine], PD_IOS_BUILD_STAMP];
	UIAlertController *about = [self alert:@"About DarkPad" message:message];
	[about addAction:[UIAlertAction actionWithTitle:@"View on GitHub" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
		(void)a;
		[PDSettingsViewController dismiss];
		[UIApplication.sharedApplication openURL:[NSURL URLWithString:kRepositoryURL] options:@{} completionHandler:nil];
	}]];
	[about addAction:[self closeAction:@"Done"]];
	[self present:about];
}

// --- diagnostics ------------------------------------------------------------

static NSString *pdMachine(void)
{
	char name[64] = {0};
	size_t size = sizeof(name) - 1;
	if (sysctlbyname("hw.machine", name, &size, NULL, 0) != 0) return @"unknown";
	NSString *machine = @(name);
#if TARGET_OS_SIMULATOR
	NSString *sim = NSProcessInfo.processInfo.environment[@"SIMULATOR_MODEL_IDENTIFIER"];
	if (sim.length) machine = [NSString stringWithFormat:@"%@ (Simulator on %@)", sim, machine];
#endif
	return machine;
}

/** Private paths never leave the device: the container becomes <app>. */
static NSString *pdRedact(NSString *text)
{
	NSString *home = NSHomeDirectory();
	if (home.length) text = [text stringByReplacingOccurrencesOfString:home withString:@"<app>"];
	return text;
}

static NSString *pdTail(NSString *path, NSUInteger limit)
{
	NSFileHandle *f = [NSFileHandle fileHandleForReadingAtPath:path];
	if (!f) return nil;
	unsigned long long size = [f seekToEndOfFile];
	[f seekToFileOffset:size > limit ? size - limit : 0];
	NSData *data = [f readDataToEndOfFile];
	[f closeFile];
	NSString *text = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding]
		?: [[NSString alloc] initWithData:data encoding:NSISOLatin1StringEncoding];
	return text ? pdRedact(text) : nil;
}

+ (NSString *)technicalSummary
{
	UIDevice *device = UIDevice.currentDevice;
	NSMutableString *s = [NSMutableString string];
	[s appendFormat:@"App: %@\nShell build: %s\n", [self versionLine], PD_IOS_BUILD_STAMP];
	[s appendFormat:@"Device: %@ (%@)\nOS: %@ %@\n", pdMachine(),
		device.userInterfaceIdiom == UIUserInterfaceIdiomPad ? @"iPad" : @"iPhone",
		device.systemName, device.systemVersion];
	[s appendFormat:@"Thermal state: %ld\nLow Power Mode: %@\n", (long)NSProcessInfo.processInfo.thermalState,
		NSProcessInfo.processInfo.lowPowerModeEnabled ? @"on" : @"off"];
	NSArray *profiles = @[ @"Original", @"Enhanced", @"Remaster" ];
	NSInteger profile = PDDefInt(PDDefGraphicsProfile);
	[s appendFormat:@"Art profile: %@\nFrame rate: %ld Hz\nResolution: %ld%%\n",
		profile >= 0 && profile < 3 ? profiles[(NSUInteger)profile] : @"?",
		(long)PDDefInt(PDDefRefreshHz), (long)PDDefInt(PDDefRenderScalePct)];
	[s appendFormat:@"On-screen controls: %@\nControl style: %@\nGyro: %@\n",
		@[ @"Auto", @"On", @"Off" ][(NSUInteger)MAX(0, MIN(2, PDDefInt(PDDefTouchMode)))],
		PDDefInt(PDDefControlStyle) == 1 ? @"N64 (digital)" : @"Dual analogue",
		PDDefBool(PDDefGyroEnabled) ? @"on" : @"off"];
	NSMutableArray *pads = [NSMutableArray array];
	for (GCController *pad in GCController.controllers) {
		[pads addObject:pad.productCategory ?: @"controller"];
	}
	[s appendFormat:@"Controllers: %@\n", pads.count ? [pads componentsJoinedByString:@", "] : @"none"];
	return s;
}

+ (nullable NSURL *)writeReportWithID:(NSString *)reportID answers:(nullable NSArray<NSString *> *)answers
{
	NSString *created = [[NSISO8601DateFormatter new] stringFromDate:NSDate.date];
	NSMutableString *report = [NSMutableString stringWithFormat:@"DarkPad diagnostic log\nReport ID: %@\nCreated: %@\n\n",
		reportID, created];
	if (answers.count) {
		[report appendFormat:@"== Problem ==\nWhat went wrong: %@\nWhat I was doing: %@\n\n",
			answers[0].length ? answers[0] : @"(not given)",
			answers.count > 1 && answers[1].length ? answers[1] : @"(not given)"];
	}
	[report appendFormat:@"== Technical context ==\n%@\n", [self technicalSummary]];
	NSString *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
	// The shell's own records. The ROM, saves, pd.ini and imported art are never read.
	for (NSString *name in @[ @"heartbeat.txt", @"crash.txt", @"hang.txt", @"touch-watchdog.txt",
			@"launch-beacon.txt", @"lifecycle.txt", @"pd.log" ]) {
		NSString *text = pdTail([docs stringByAppendingPathComponent:name], 96 * 1024);
		if (text.length) [report appendFormat:@"\n== %@ ==\n%@\n", name, text];
	}
	NSURL *url = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:
		[NSString stringWithFormat:@"DarkPad-Diagnostic-%@.log", reportID]]];
	NSError *error = nil;
	if (![report writeToURL:url atomically:YES encoding:NSUTF8StringEncoding error:&error]) {
		NSLog(@"perfectdark: [report] could not write %@: %@", url.lastPathComponent, error);
		return nil;
	}
	return url;
}

+ (NSString *)newReportID
{
	return [NSString stringWithFormat:@"DP-%@", [NSUUID.UUID.UUIDString substringToIndex:8]];
}

+ (void)share:(NSURL *)url then:(nullable dispatch_block_t)next
{
	UIActivityViewController *share = [[UIActivityViewController alloc] initWithActivityItems:@[ url ]
		applicationActivities:nil];
	share.completionWithItemsHandler = ^(UIActivityType type, BOOL completed, NSArray *items, NSError *error) {
		(void)type; (void)completed; (void)items; (void)error;
		if (next) next(); else [PDSettingsViewController dismiss];
	};
	[PDSettingsViewController presentModal:share];
}

+ (void)shareDiagnosticLog
{
	NSURL *url = [self writeReportWithID:[self newReportID] answers:nil];
	if (url) {
		[self share:url then:nil];
		return;
	}
	UIAlertController *failed = [self alert:@"Diagnostic Log Unavailable" message:@"DarkPad could not write the log. Try again after restarting the app."];
	[failed addAction:[self closeAction:@"OK"]];
	[self present:failed];
}

+ (void)reportProblem
{
	UIAlertController *prompt = [self alert:@"Report a Problem"
		message:@"Describe the problem briefly. DarkPad creates a diagnostic log you can review and share before you open GitHub. Nothing is uploaded automatically. The log never includes your ROM, saves or imported art. GitHub issues are public."];
	[prompt addTextFieldWithConfigurationHandler:^(UITextField *field) {
		field.placeholder = @"What went wrong?";
		field.clearButtonMode = UITextFieldViewModeWhileEditing;
	}];
	[prompt addTextFieldWithConfigurationHandler:^(UITextField *field) {
		field.placeholder = @"What were you doing? (optional)";
		field.clearButtonMode = UITextFieldViewModeWhileEditing;
	}];
	[prompt addAction:[self closeAction:@"Cancel"]];
	__weak UIAlertController *weakPrompt = prompt;
	UIAlertAction *create = [UIAlertAction actionWithTitle:@"Create Diagnostic Log…" style:UIAlertActionStyleDefault
		handler:^(UIAlertAction *a) {
			(void)a;
			NSArray<NSString *> *answers = @[ weakPrompt.textFields[0].text ?: @"", weakPrompt.textFields[1].text ?: @"" ];
			NSString *reportID = [self newReportID];
			NSURL *url = [self writeReportWithID:reportID answers:answers];
			if (!url) {
				[self offerGitHubForReport:reportID file:nil answers:answers];
				return;
			}
			[self share:url then:^{ [self offerGitHubForReport:reportID file:url.lastPathComponent answers:answers]; }];
		}];
	[prompt addAction:create];
	prompt.preferredAction = create;
	[self present:prompt];
}

+ (void)offerGitHubForReport:(NSString *)reportID file:(nullable NSString *)file answers:(NSArray<NSString *> *)answers
{
	NSString *message = file
		? [NSString stringWithFormat:@"Open GitHub to finish the report, then attach %@ yourself. If the problem is visual, add a screenshot too.", file]
		: @"The diagnostic log could not be written. You can still open GitHub and describe the problem.";
	UIAlertController *ready = [self alert:@"Diagnostic Log Ready" message:message];
	[ready addAction:[self closeAction:@"Not Now"]];
	UIAlertAction *open = [UIAlertAction actionWithTitle:@"Open GitHub" style:UIAlertActionStyleDefault
		handler:^(UIAlertAction *a) {
			(void)a;
			[PDSettingsViewController dismiss];
			[self openIssueForReport:reportID answers:answers];
		}];
	[ready addAction:open];
	ready.preferredAction = open;
	[self present:ready];
}

+ (void)openIssueForReport:(NSString *)reportID answers:(NSArray<NSString *> *)answers
{
	NSString *problem = answers.firstObject.length ? answers.firstObject : @"DarkPad problem";
	if (problem.length > 100) problem = [problem substringToIndex:100];
	UIDevice *device = UIDevice.currentDevice;
	NSString *body = [NSString stringWithFormat:
		@"**What went wrong**\n%@\n\n**What I was doing**\n%@\n\n**Device**\n%@, %@ %@\n\n**DarkPad**\n%@\n\n**Report ID**\n%@\n\nPlease attach DarkPad-Diagnostic-%@.log. Do not attach ROMs, saves or extracted art.",
		answers.firstObject.length ? answers.firstObject : @"",
		answers.count > 1 && answers[1].length ? answers[1] : @"",
		pdMachine(), device.systemName, device.systemVersion, [self versionLine], reportID, reportID];
	NSURLComponents *components = [NSURLComponents componentsWithString:[kRepositoryURL stringByAppendingString:@"/issues/new"]];
	components.queryItems = @[
		[NSURLQueryItem queryItemWithName:@"title" value:[NSString stringWithFormat:@"[Bug]: %@", problem]],
		[NSURLQueryItem queryItemWithName:@"body" value:body],
	];
	if (components.URL) {
		[UIApplication.sharedApplication openURL:components.URL options:@{} completionHandler:nil];
	}
}

@end
