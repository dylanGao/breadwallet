//
//  ZNFirstViewController.m
//  ZincWallet
//
//  Created by Aaron Voisine on 5/8/13.
//  Copyright (c) 2013 Aaron Voisine <voisine@gmail.com>
//
//  Permission is hereby granted, free of charge, to any person obtaining a copy
//  of this software and associated documentation files (the "Software"), to deal
//  in the Software without restriction, including without limitation the rights
//  to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
//  copies of the Software, and to permit persons to whom the Software is
//  furnished to do so, subject to the following conditions:
//
//  The above copyright notice and this permission notice shall be included in
//  all copies or substantial portions of the Software.
//
//  THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
//  IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
//  FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
//  AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
//  LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
//  OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
//  THE SOFTWARE.

#import "ZNPayViewController.h"
#import "ZNAmountViewController.h"
#import "ZNWallet.h"
#import "ZNWallet+Utils.h"
#import "ZNPaymentRequest.h"
#import "ZNKey.h"
#import "ZNTransaction.h"
#import "ZNButton.h"
#import "ZNStoryboardSegue.h"
#import "NSString+Base58.h"
#import "MBProgressHUD.h"
#import "AFNetworking.h"
#import "NSData+SRB64Additions.h"
#import <QuartzCore/QuartzCore.h>

//#define CONNECT_TIMEOUT 5.0
#define BUTTON_HEIGHT   44.0
#define BUTTON_MARGIN   10.0
#define CLIPBOARD_ID    @"clipboard"
#define QR_ID           @"qr"
#define URL_ID          @"url"

@interface ZNPayViewController ()

//@property (nonatomic, strong) GKSession *session;
@property (nonatomic, strong) NSMutableArray *requests;
@property (nonatomic, strong) NSMutableArray *requestIDs;
@property (nonatomic, strong) NSMutableArray *requestButtons;
@property (nonatomic, strong) NSString *addressInWallet;
@property (nonatomic, strong) id urlObserver, activeObserver;
@property (nonatomic, strong) ZNPaymentRequest *request;
@property (nonatomic, strong) ZNTransaction *sweepTx, *tx, *txWithFee;
@property (nonatomic, strong) ZBarReaderViewController *zbarController;
@property (nonatomic, strong) NSUserDefaults *defs;

@property (nonatomic, strong) IBOutlet UILabel *label;
@property (nonatomic, strong) IBOutlet UIButton *infoButton;
@property (nonatomic, strong) IBOutlet UIView *scanTipView, *clipboardTipView, *pageTipView;

@end

@implementation ZNPayViewController

- (void)viewDidLoad
{
    [super viewDidLoad];
    // Do any additional setup after loading the view, typically from a nib.
    
    //TODO: add a field for manually entering a payment address
    //TODO: make title use dynamic font size
    //BUG: clipboard button title is offcenter (ios7 specific font layout bug?)
    ZNWallet *w = [ZNWallet sharedInstance];
    ZNPaymentRequest *req = [ZNPaymentRequest new];
    
    req.label = @"scan QR code";
    
    self.defs = [NSUserDefaults standardUserDefaults];
    self.requests = [NSMutableArray arrayWithObject:req];
    self.requestIDs = [NSMutableArray arrayWithObject:QR_ID];
    self.requestButtons = [NSMutableArray array];
    
    self.urlObserver =
        [[NSNotificationCenter defaultCenter] addObserverForName:ZNURLNotification object:nil queue:nil
        usingBlock:^(NSNotification *note) {
            NSURL *url = note.userInfo[@"url"];
            
            if ([url.scheme isEqual:@"zinc"] && [url.host isEqual:@"x-callback-url"] && [url.path isEqual:@"/tx"]) {
                __block NSString *status = nil;
                
                [[url.query componentsSeparatedByString:@"&"]
                enumerateObjectsUsingBlock:^(id obj, NSUInteger idx, BOOL *stop) {
                    NSArray *tuple = [obj componentsSeparatedByString:@"="];
                    
                    if (tuple.count == 2 && [tuple[0] isEqual:@"status"]) status = tuple[1];
                }];
            
                if ([status isEqual:@"sent"]) {
                    NSUInteger idx = [self.requests indexOfObject:self.request];
                    
                    if (self.tx) [w registerTransaction:self.tx];
                    
                    if ([self.requestIDs indexOfObject:QR_ID] != idx) {
                        if ([self.requestIDs indexOfObject:CLIPBOARD_ID] == idx) {
                            [[UIPasteboard generalPasteboard] setString:@""];
                        }
                        
                        [self.requestIDs removeObjectAtIndex:idx];
                        [self.requests removeObjectAtIndex:idx];
                    }
                    
                    [self reset:nil];
                }
                else if ([status isEqual:@"canceled"]) [self cancel:nil];
            }
            else if ([url.scheme isEqual:@"bitcoin"]) {
                ZNPaymentRequest *req = [ZNPaymentRequest requestWithURL:url];
        
                if (! req.label.length) req.label = req.paymentAddress;
                
                if (req.amount > 0 && [req.label rangeOfString:[w stringForAmount:req.amount]].location == NSNotFound) {
                    req.label = [NSString stringWithFormat:@"%@ - %@", req.label,
                                 [[ZNWallet sharedInstance] stringForAmount:req.amount]];
                }
        
                if ([self.requestIDs indexOfObject:URL_ID] != NSNotFound) {
                    [self.requests removeObjectAtIndex:[self.requestIDs indexOfObject:URL_ID]];
                    [self.requestIDs removeObjectAtIndex:[self.requestIDs indexOfObject:URL_ID]];
                }
        
                [self.requests insertObject:req atIndex:0];
                [self.requestIDs insertObject:URL_ID atIndex:0];
            }
        }];
    
    self.activeObserver =
        [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidBecomeActiveNotification object:nil
        queue:nil usingBlock:^(NSNotification *note) {
            // if a tx was sent to safari and we returned to the app not from a zinc: url, something went wrong, so
            // fall back on sending from within the app
            if (self.tx) {
                uint64_t txAmount = [w transactionAmount:self.tx] - [w transactionChange:self.tx];
                NSString *amount = [NSString stringWithFormat:@"%@ (%@)", [w stringForAmount:txAmount],
                                    [w localCurrencyStringForAmount:txAmount]];

                [[[UIAlertView alloc] initWithTitle:@"confirm payment" message:[w transactionTo:self.tx] delegate:self
                  cancelButtonTitle:@"cancel" otherButtonTitles:amount, nil] show];
            }
        
            [self layoutButtonsAnimated:YES]; // check the clipboard for changes
        }];
    
}

- (void)dealloc
{
    if (self.urlObserver) [[NSNotificationCenter defaultCenter] removeObserver:self.urlObserver];
    if (self.activeObserver) [[NSNotificationCenter defaultCenter] removeObserver:self.activeObserver];
}

- (void)viewWillAppear:(BOOL)animated
{
    [super viewWillAppear:animated];
 
    [self reset:nil];
    
//    self.session = [[GKSession alloc] initWithSessionID:GK_SESSION_ID
//                    displayName:[UIDevice.currentDevice.name stringByAppendingString:@" Wallet"]
//                    sessionMode:GKSessionModeClient];
//    self.session.delegate = self;
//    [self.session setDataReceiveHandler:self withContext:nil];
//    self.session.available = YES;
}

- (void)viewDidAppear:(BOOL)animated
{
    [self layoutButtonsAnimated:YES];
}

- (void)viewWillDisappear:(BOOL)animated
{
//    self.session.available = NO;
//    [self.session disconnectFromAllPeers];
//    self.session = nil;

    [self hideTips];

    [super viewWillDisappear:animated];
}

- (void)checkClipboard
{
    ZNWallet *w = [ZNWallet sharedInstance];
    ZNPaymentRequest *req = [ZNPaymentRequest requestWithString:[[[UIPasteboard generalPasteboard] string]
                             stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]]];
    
    if (! req.isValid) {
        req.data = nil;
        req.label = @"pay address from clipboard";
    }
    
    if (! req.label.length) req.label = req.paymentAddress;
    
    if (req.amount > 0 && [req.label rangeOfString:[w stringForAmount:req.amount]].location == NSNotFound) {
        req.label = [NSString stringWithFormat:@"%@ - %@", req.label, [w stringForAmount:req.amount]];
    }
    
    if ([self.requestIDs indexOfObject:CLIPBOARD_ID] < self.requests.count) {
        [self.requests removeObjectAtIndex:[self.requestIDs indexOfObject:CLIPBOARD_ID]];
        [self.requestIDs removeObject:CLIPBOARD_ID];
    }

    if ([self.requests indexOfObjectPassingTest:^BOOL(id obj, NSUInteger idx, BOOL *stop) {
            return [req.label isEqual:[obj label]] ? (*stop = YES) : NO;
        }] == NSNotFound) {
        [self.requests addObject:req];
        [self.requestIDs addObject:CLIPBOARD_ID];
    }
}

- (void)layoutButtonsAnimated:(BOOL)animated
{
    [self checkClipboard];

    while (self.requests.count > self.requestButtons.count) {
        ZNButton *button = [ZNButton buttonWithType:UIButtonTypeCustom];
        UISwipeGestureRecognizer *g = [[UISwipeGestureRecognizer alloc] initWithTarget:self
                                       action:@selector(swipeLeft:)];
        
        button.style = ZNButtonStyleBlue;
        button.imageEdgeInsets = UIEdgeInsetsMake(0, -10, 0, 10);
        button.alpha = animated ? 0 : 1;
        button.frame = CGRectMake(BUTTON_MARGIN*2, self.view.frame.size.height/2 + (BUTTON_HEIGHT + BUTTON_MARGIN*2)*
                                  (self.requestButtons.count - self.requests.count/2.0 - 0.5),
                                  self.view.frame.size.width - BUTTON_MARGIN*4, BUTTON_HEIGHT);
        [button addTarget:self action:@selector(doIt:) forControlEvents:UIControlEventTouchUpInside];

        g.cancelsTouchesInView = YES;
        g.direction = UISwipeGestureRecognizerDirectionLeft;
        [button addGestureRecognizer:g];
        [self.view addSubview:button];
        [self.requestButtons addObject:button];
    }

    void (^block)(void) = ^{
        [self.requestButtons enumerateObjectsUsingBlock:^(id obj, NSUInteger idx, BOOL *stop) {
            CGPoint c = CGPointMake([obj center].x, self.view.frame.size.height/2 +
                                    (BUTTON_HEIGHT + BUTTON_MARGIN*2)*(idx - self.requests.count/2.0));
            
            [obj setCenter:c];
            
            if (self.request) {
                [obj setEnabled:NO];
                [obj setAlpha:idx < self.requests.count ? 0.5 : 0];
            }
            else {
                [obj setEnabled:YES];
                [obj setAlpha:idx < self.requests.count ? 1 : 0];
            }

            if (idx < self.requestIDs.count && [self.requestIDs[idx] isEqual:QR_ID]) {
                [obj setImage:[UIImage imageNamed:@"cameraguide-blue-small.png"] forState:UIControlStateNormal];
                [obj setImage:[UIImage imageNamed:@"cameraguide-small.png"] forState:UIControlStateHighlighted];
            }
            else {
                [obj setImage:nil forState:UIControlStateNormal];
                [obj setImage:nil forState:UIControlStateHighlighted];
            }

            if (idx < self.requests.count) {
                ZNPaymentRequest *req = self.requests[idx];
                
                if ([req.label rangeOfString:BTC].location != NSNotFound) {
                    [obj titleLabel].font = [UIFont fontWithName:@"HelveticaNeue" size:15];
                }
                else [obj titleLabel].font = [UIFont fontWithName:@"HelveticaNeue-Light" size:17];

                [obj setTitle:req.label forState:UIControlStateNormal];

                if ([self.addressInWallet isEqual:req.paymentAddress]) [obj setEnabled:NO];
            }
        }];
        
        self.label.center = CGPointMake(self.label.center.x,
                                        [self.requestButtons[0] center].y - BUTTON_HEIGHT - BUTTON_MARGIN/2);
        self.infoButton.center = CGPointMake(self.infoButton.center.x, self.label.center.y + 1.0);
    };
    
    if (animated) {
        [UIView animateWithDuration:SEGUE_DURATION animations:block completion:^(BOOL finished) {
            while (self.requestButtons.count > self.requests.count) {
                [self.requestButtons.lastObject removeFromSuperview];
                [self.requestButtons removeLastObject];
            }
        }];
    }
    else {
        block();

        while (self.requestButtons.count > self.requests.count) {
            [self.requestButtons.lastObject removeFromSuperview];
            [self.requestButtons removeLastObject];
        }
    }    
}

- (ZBarReaderViewController *)zbarController
{
    if (! _zbarController) {
        _zbarController = [ZBarReaderViewController new];
        _zbarController.readerDelegate = self;
        _zbarController.cameraOverlayView =
        [[UIImageView alloc] initWithImage:[UIImage imageNamed:@"cameraguide.png"]];
        
        CGPoint c = _zbarController.view.center;
        
        _zbarController.cameraOverlayView.center = CGPointMake(c.x, c.y - 10.0);
    }
    
    return _zbarController;
}

- (void)verifyWebApp:(void (^)(BOOL verified))completion;
{
    if ([[_defs stringForKey:WEBAPP_VERSION_KEY] doubleValue] > DBL_EPSILON) {
        if (completion) completion(YES);
        return;
    }

    AFHTTPRequestOperation *op = [[AFHTTPRequestOperation alloc] initWithRequest:[NSURLRequest
                                  requestWithURL:[NSURL URLWithString:WEBAPP_BASEURL WEBAPP_PATH]
                                  cachePolicy:NSURLRequestReloadIgnoringCacheData timeoutInterval:WEBAPP_TIMEOUT]];
    
    [op setCompletionBlockWithSuccess:^(AFHTTPRequestOperation *operation, id responseObject) {
        NSRegularExpression *re = [NSRegularExpression regularExpressionWithPattern:
                                   @"<meta\\s+name\\s*=\\s*[\"']version[\"']\\s+content\\s*=\\s*[\"']([^\"'>]*)"
                                   options:NSRegularExpressionCaseInsensitive error:nil];
        NSString *s = operation.responseString;
        NSTextCheckingResult *match = [re firstMatchInString:s options:0 range:NSMakeRange(0, [s length])];

        [[NSNotificationCenter defaultCenter] postNotificationName:walletSyncFinishedNotification object:nil];

        //TODO: verify webapp sha hash or signature
        if (match) {
            [_defs setObject:[s substringWithRange:[match rangeAtIndex:1]] forKey:WEBAPP_VERSION_KEY];
            [_defs synchronize];
            
            if (completion) completion(YES);
            return;
        }

        if (completion) completion(NO);
    } failure:^(AFHTTPRequestOperation *operation, NSError *error) {
        [[NSNotificationCenter defaultCenter] postNotificationName:walletSyncFinishedNotification object:nil];
        
        if (completion) completion(NO);
    }];
    
    [[NSNotificationCenter defaultCenter] postNotificationName:walletSyncStartedNotification object:nil];
    [op start];
}

- (void)confirmTransaction
{
    if (! self.tx) return;

    ZNWallet *w = [ZNWallet sharedInstance];
    uint64_t txAmount = [w transactionAmount:self.tx] - [w transactionChange:self.tx];
    NSString *amount = [NSString stringWithFormat:@"%@ (%@)", [w stringForAmount:txAmount],
                        [w localCurrencyStringForAmount:txAmount]];
    
#if APPSTORE
    [self verifyWebApp:^(BOOL verified) {
        if (! verified) {
            // something went wrong so fall back on sending tx from app
            [[[UIAlertView alloc] initWithTitle:@"confirm payment" message:[w transactionTo:self.tx] delegate:self
              cancelButtonTitle:@"cancel" otherButtonTitles:amount, nil] show];
            return;
        }

        NSLog(@"signing transaction");
        [w signTransaction:self.tx];
    
        if (! [self.tx isSigned]) {
            [[[UIAlertView alloc] initWithTitle:@"couldn't make payment" message:@"error signing bitcoin transaction"
              delegate:nil cancelButtonTitle:@"ok" otherButtonTitles:nil] show];
            [self reset:nil];
            return;
        }
    
        NSLog(@"signed transaction:\n%@", [self.tx toHex]);
    
        NSString *url = [NSString stringWithFormat:WEBAPP_BASEURL WEBAPP_PATH @"#%@:%@:%@", self.tx.toHex,
                         [w transactionTo:self.tx],
                         [amount stringByAddingPercentEscapesUsingEncoding:NSUTF8StringEncoding]];

        //TODO: check for duplicate transactions
        [[UIApplication sharedApplication] openURL:[NSURL URLWithString:url]];
    }];
    return;
#endif

    [[[UIAlertView alloc] initWithTitle:@"confirm payment" message:[w transactionTo:self.tx] delegate:self
      cancelButtonTitle:@"cancel" otherButtonTitles:amount, nil] show];
}

- (void)confirmRequest
{
    if (! self.request.isValid) {
        if ([self.requests indexOfObject:self.request] == [self.requestIDs indexOfObject:CLIPBOARD_ID]) {
            [[[UIAlertView alloc] initWithTitle:nil message:@"the clipboard doesn't contain a valid bitcoin address"
              delegate:nil cancelButtonTitle:@"ok" otherButtonTitles:nil] show];
        }
        else {
            [[[UIAlertView alloc] initWithTitle:@"not a valid bitcoin address" message:self.request.paymentAddress
              delegate:nil cancelButtonTitle:@"ok" otherButtonTitles:nil] show];
        }

        [self reset:nil];
        return;
    }
    
    ZNWallet *w = [ZNWallet sharedInstance];
    
    if ([w containsAddress:self.request.paymentAddress]) {
        [[[UIAlertView alloc] initWithTitle:nil message:@"this payment address is already in your wallet" delegate:nil
          cancelButtonTitle:@"ok" otherButtonTitles:nil] show];
        
        self.addressInWallet = self.request.paymentAddress;
        [self reset:nil];
    }
    else if (self.request.amount == 0) {
        ZNAmountViewController *c = [self.storyboard instantiateViewControllerWithIdentifier:@"ZNAmountViewController"];
        
        c.delegate = self;
        c.request = self.request;
        c.navigationItem.title = [NSString stringWithFormat:@"%@ (%@)", [w stringForAmount:w.balance],
                                  [w localCurrencyStringForAmount:w.balance]];
        
        self.view.superview.clipsToBounds = YES;
        [ZNStoryboardSegue segueFrom:self.navigationController.topViewController to:c completion:^{
            self.view.superview.clipsToBounds = NO;
        }];
    }
    else if (self.request.amount < TX_MIN_OUTPUT_AMOUNT) {
        [[[UIAlertView alloc] initWithTitle:@"couldn't make payment" message:[@"bitcoin payments can't be less than "
          stringByAppendingString:[w stringForAmount:TX_MIN_OUTPUT_AMOUNT]] delegate:nil cancelButtonTitle:@"ok"
          otherButtonTitles:nil] show];
        [self cancel:nil];
    }
    else {
        self.tx = [w transactionFor:self.request.amount to:self.request.paymentAddress withFee:NO];
        self.txWithFee = [w transactionFor:self.request.amount to:self.request.paymentAddress withFee:YES];
        
        uint64_t txFee = self.txWithFee ? [w transactionFee:self.txWithFee] : self.tx.standardFee;
        NSString *fee = [w stringForAmount:txFee];
        NSString *localCurrencyFee = [w localCurrencyStringForAmount:txFee];
        NSTimeInterval t = [w timeUntilFree:self.tx];
        
        if (! self.tx) {
            [[[UIAlertView alloc] initWithTitle:@"insufficient funds" message:nil delegate:nil cancelButtonTitle:@"ok"
              otherButtonTitles:nil] show];
            [self cancel:nil];
        }
        else if (t > DBL_EPSILON) {//(t == DBL_MAX) {
            [[[UIAlertView alloc] initWithTitle:nil//@"transaction fee"
              message:[NSString stringWithFormat:@"the bitcoin network will receive a fee of %@ (%@)", fee,
              localCurrencyFee] delegate:self cancelButtonTitle:@"cancel"
              otherButtonTitles:[NSString stringWithFormat:@"+ %@ (%@)", fee, localCurrencyFee], nil] show];
        }
//        else if (t > DBL_EPSILON) {
//            int minutes = t/60, hours = t/(60*60), days = t/(60*60*24);
//            NSString *time = [NSString stringWithFormat:@"%d %@%@", days ? days : (hours ? hours : minutes),
//                              days ? @"day" : (hours ? @"hour" : @"minutes"),
//                              days > 1 ? @"s" : (days == 0 && hours > 1 ? @"s" : @"")];
//            
//            [[[UIAlertView alloc]
//              initWithTitle:[NSString stringWithFormat:@"%@ (%@) transaction fee recommended", fee, localCurrencyFee]
//              message:[NSString stringWithFormat:@"estimated confirmation time with no fee: %@", time] delegate:self
//              cancelButtonTitle:nil otherButtonTitles:@"no fee",
//              [NSString stringWithFormat:@"+ %@ (%@)", fee, localCurrencyFee], nil] show];
//        }
        else [self confirmTransaction];
    }
}

- (void)confirmSweep:(NSString *)privKey
{
    if (! [privKey isValidBitcoinPrivateKey]) return;
    
    ZNWallet *w = [ZNWallet sharedInstance];
    MBProgressHUD *hud = [MBProgressHUD showHUDAddedTo:self.view animated:YES];
    
    hud.mode = MBProgressHUDModeIndeterminate;
    hud.labelText = @"checking private key balance...";
    hud.labelFont = [UIFont fontWithName:@"HelveticaNeue" size:15.0];

    [w sweepPrivateKey:privKey withFee:YES completion:^(ZNTransaction *tx, NSError *error) {
        [hud hide:YES];

        if (error) {
            [[[UIAlertView alloc] initWithTitle:nil message:error.localizedDescription delegate:self
              cancelButtonTitle:@"ok" otherButtonTitles:nil] show];
            [self reset:nil];
            return;
        }
        
        __block uint64_t fee = tx.standardFee, amount = fee;
        
        [tx.outputAmounts enumerateObjectsUsingBlock:^(id obj, NSUInteger idx, BOOL *stop) {
            amount += [obj unsignedLongLongValue];
        }];

        self.sweepTx = tx;
        [[[UIAlertView alloc] initWithTitle:nil
          message:[NSString stringWithFormat:@"Sweep %@ (%@) from this private key into your wallet? "
          "The bitcoin network will receive a fee of %@ (%@).", [w stringForAmount:amount],
          [w localCurrencyStringForAmount:amount], [w stringForAmount:fee], [w localCurrencyStringForAmount:fee]]
          delegate:self cancelButtonTitle:@"cancel" otherButtonTitles:[NSString stringWithFormat:@"%@ (%@)",
          [w stringForAmount:amount], [w localCurrencyStringForAmount:amount]], nil] show];
    }];
}

- (BOOL)hideTips
{
    if (self.scanTipView.alpha < 0.5 && self.clipboardTipView.alpha < 0.5 && self.pageTipView.alpha < 0.5) return NO;
    
    [UIView animateWithDuration:UINavigationControllerHideShowBarDuration animations:^{
        self.scanTipView.alpha = self.clipboardTipView.alpha = self.pageTipView.alpha = 0.0;
    }];
    
    return YES;
}

- (BOOL)nextTip
{
    if (self.scanTipView.alpha < 0.5 && self.clipboardTipView.alpha < 0.5 && self.pageTipView.alpha < 0.5) return NO;
    
    if (self.scanTipView.alpha > 0.5) {
        UIButton *b = self.requestButtons[[self.requestIDs indexOfObject:CLIPBOARD_ID]];
    
        [self.view bringSubviewToFront:self.clipboardTipView];
        self.clipboardTipView.center = CGPointMake(self.clipboardTipView.center.x, b.frame.origin.y +
                                                   b.frame.size.height + self.scanTipView.frame.size.height/2 - 10);
    }
    
    [UIView animateWithDuration:UINavigationControllerHideShowBarDuration animations:^{
        if (self.scanTipView.alpha > 0.5) {
            self.scanTipView.alpha = 0.0;
            self.clipboardTipView.alpha = 1.0;
        }
        else if (self.clipboardTipView.alpha > 0.5) {
            self.clipboardTipView.alpha = 0.0;
            self.pageTipView.alpha = 1.0;
        }
        else if (self.pageTipView.alpha > 0.5) self.pageTipView.alpha = 0.0;
    }];
    
    return YES;
}

#pragma mark - IBAction

- (IBAction)swipeLeft:(id)sender
{
    [self.parentViewController performSelector:@selector(page:) withObject:nil];
}

- (IBAction)info:(id)sender
{
    if ([self nextTip]) return;
    
    UIButton *b = self.requestButtons[[self.requestIDs indexOfObject:QR_ID]];
    
    [self.view bringSubviewToFront:self.scanTipView];
    self.scanTipView.center = CGPointMake(self.scanTipView.center.x,
                                          b.frame.origin.y + 10 - self.scanTipView.frame.size.height/2);
    
    [UIView animateWithDuration:UINavigationControllerHideShowBarDuration animations:^{
        self.scanTipView.alpha = 1.0;
    }];
}

- (IBAction)next:(id)sender
{
    [self nextTip];
}

- (IBAction)doIt:(id)sender
{
    if ([self nextTip]) return;

    NSUInteger idx = [self.requestButtons indexOfObject:sender];
    
    if ([self.requestIDs indexOfObject:QR_ID] == idx) {
        [self.navigationController presentViewController:self.zbarController animated:YES completion:^{
            NSLog(@"present qr reader complete");
        }];
        
        // hide zbarController.view info button
        for (UIView *v in self.zbarController.view.subviews) {
            for (id t in v.subviews) {
                if ([t isKindOfClass:[UIToolbar class]] && [[t items] count] > 0) {
                    [t setItems:@[[t items][0]]];
                }
            }
        }
        return;
    }
    
    [sender setEnabled:NO];
    self.request = self.requests[idx];
    [self confirmRequest];
}

- (IBAction)reset:(id)sender
{
    if ([self.requests indexOfObject:self.request] == [self.requestIDs indexOfObject:QR_ID]) {
        self.request.data = nil;
        self.request.label = @"scan QR code";
    }
    
    self.tx = self.txWithFee = self.sweepTx = nil;
    self.request = nil;
            
    if (self.navigationController.topViewController != self.parentViewController) {
        [self.navigationController popToRootViewControllerAnimated:YES];
    }
    else [self layoutButtonsAnimated:YES];
}

- (IBAction)cancel:(id)sender
{
    self.tx = self.txWithFee = self.sweepTx = nil;
    self.request.amount = 0;
    
    if (self.navigationController.topViewController == self.parentViewController) [self reset:sender];
}

#pragma mark - ZNAmountViewControllerDelegate

- (void)amountViewController:(ZNAmountViewController *)amountViewController selectedAmount:(uint64_t)amount
{
    self.request.amount = amount;
    [self confirmRequest];
}

#pragma mark - UIImagePickerControllerDelegate

- (void)imagePickerController:(UIImagePickerController *)reader didFinishPickingMediaWithInfo:(NSDictionary *)info
{
    ZNPaymentRequest *req = self.requests[[self.requestIDs indexOfObject:QR_ID]];
    
    for (id result in info[ZBarReaderControllerResults]) {
        NSString *s = (id)[result data];
        
        req.data = [s dataUsingEncoding:NSUTF8StringEncoding];
        req.label = @"scan QR code";
        
        if (! req.isValid && ! [s isValidBitcoinPrivateKey]) {
            [(id)self.zbarController.cameraOverlayView setImage:[UIImage imageNamed:@"cameraguide-red.png"]];

            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 0.5*NSEC_PER_SEC), dispatch_get_main_queue(), ^{
                [(id)self.zbarController.cameraOverlayView setImage:[UIImage imageNamed:@"cameraguide.png"]];
                
                if ([s hasPrefix:@"bitcoin:"] || [self.request.paymentAddress hasPrefix:@"1"]) {
                    [[[UIAlertView alloc] initWithTitle:@"not a valid bitcoin address"
                      message:req.paymentAddress delegate:nil cancelButtonTitle:@"ok" otherButtonTitles:nil]
                     show];
                }
                else {
                    [[[UIAlertView alloc] initWithTitle:@"not a bitcoin QR code" message:nil delegate:nil
                      cancelButtonTitle:@"ok" otherButtonTitles:nil] show];
                }
            });
        }
        else {
            [(id)self.zbarController.cameraOverlayView setImage:[UIImage imageNamed:@"cameraguide-green.png"]];
            
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 0.5*NSEC_PER_SEC), dispatch_get_main_queue(), ^{
                [reader dismissViewControllerAnimated:YES completion:^{
                    [(id)self.zbarController.cameraOverlayView setImage:[UIImage imageNamed:@"cameraguide.png"]];
                }];

                if (req.paymentAddress) {
                    self.request = req;
                    [self confirmRequest];
                }
                else [self confirmSweep:s];
            });
        }
        
        break;
    }
}

#pragma mark - UIAlertViewDelegate

- (void)alertView:(UIAlertView *)alertView clickedButtonAtIndex:(NSInteger)buttonIndex
{
    if (buttonIndex == alertView.cancelButtonIndex) {
        [self cancel:nil];
        return;
    }
    
    ZNWallet *w = [ZNWallet sharedInstance];
    
    if (self.sweepTx) {
        [w publishTransaction:self.sweepTx completion:^(NSError *error) {
            [self reset:nil];
            
            if (error) {
                [[[UIAlertView alloc] initWithTitle:@"couldn't sweep balance" message:error.localizedDescription
                  delegate:nil cancelButtonTitle:@"ok" otherButtonTitles:nil] show];
                return;
            }
            
            MBProgressHUD *hud = [MBProgressHUD showHUDAddedTo:self.view animated:YES];
            
            hud.mode = MBProgressHUDModeText;
            hud.labelText = @"swept!";
            hud.labelFont = [UIFont fontWithName:@"HelveticaNeue-Medium" size:17.0];
            [hud hide:YES afterDelay:2.0];
        }];
        
        return;
    }
    else if (! self.tx) return;

    NSString *title = [alertView buttonTitleAtIndex:buttonIndex];
    
    if ([title hasPrefix:@"+ "] || [title isEqual:@"no fee"]) {
        if ([title hasPrefix:@"+ "]) self.tx = self.txWithFee;
        
        if (! self.tx) {
            [[[UIAlertView alloc] initWithTitle:@"insufficient funds" message:nil delegate:nil cancelButtonTitle:@"ok"
              otherButtonTitles:nil] show];
            [self cancel:nil];
            return;
        }

        [self confirmTransaction];
        return;
    }
    
    NSLog(@"signing transaction");
    [w signTransaction:self.tx];
    
    if (! [self.tx isSigned]) {
        [[[UIAlertView alloc] initWithTitle:@"couldn't make payment" message:@"error signing bitcoin transaction"
          delegate:nil cancelButtonTitle:@"ok" otherButtonTitles:nil] show];
        [self reset:nil];
        return;
    }

    NSLog(@"signed transaction:\n%@", [self.tx toHex]);
    
    if (! self.request || [self.requests indexOfObject:self.request] >= self.requestIDs.count) {
        [[[UIAlertView alloc] initWithTitle:@"couldn't make payment" message:@"inconsistent UI state" delegate:nil
          cancelButtonTitle:@"ok" otherButtonTitles:nil] show];
        [self reset:nil];
        return;
    }
    
    NSString *reqID = self.requestIDs[[self.requests indexOfObject:self.request]];

    if ([reqID isEqual:QR_ID] || [reqID isEqual:CLIPBOARD_ID] || [reqID isEqual:URL_ID]) {
        //TODO: check for duplicate transactions
        [w publishTransaction:self.tx completion:^(NSError *error) {
            if (error) {
                [[[UIAlertView alloc] initWithTitle:@"couldn't make payment" message:error.localizedDescription
                  delegate:nil cancelButtonTitle:@"ok" otherButtonTitles:nil] show];
                [self cancel:nil];
                return;
            }
            
            if (! [reqID isEqual:QR_ID]) {
                [self.requestIDs removeObject:reqID];
                [self.requests removeObject:self.request];
                
                if ([reqID isEqual:CLIPBOARD_ID]) [[UIPasteboard generalPasteboard] setString:@""];
            }
            
            MBProgressHUD *hud = [MBProgressHUD showHUDAddedTo:self.view animated:YES];

            hud.mode = MBProgressHUDModeText;
            hud.labelText = @"sent!";
            hud.labelFont = [UIFont fontWithName:@"HelveticaNeue-Medium" size:17.0];
            [hud hide:YES afterDelay:2.0];
            
            [self reset:nil];
        }];
    }
//    else {
//        NSLog(@"sending signed request to %@", self.requestIDs[self.selectedIndex]);
//        
//        NSError *error = nil;
//        
//        [self.session sendData:[[tx toHex] dataUsingEncoding:NSUTF8StringEncoding]
//         toPeers:@[self.requestIDs[self.selectedIndex]] withDataMode:GKSendDataReliable error:&error];
//    
//        if (error) {
//            [[[UIAlertView alloc] initWithTitle:@"couldn't make payment" message:error.localizedDescription
//             delegate:nil cancelButtonTitle:@"ok" otherButtonTitles:nil] show];
//        }
//    
//        [self.requestIDs removeObjectAtIndex:self.selectedIndex];
//        [self.requests removeObjectAtIndex:self.selectedIndex];
//    }
}

//#pragma mark - GKSessionDelegate
//
//// Indicates a state change for the given peer.
//- (void)session:(GKSession *)session peer:(NSString *)peerID didChangeState:(GKPeerConnectionState)state
//{
//    NSLog(@"%@ didChangeState:%@", peerID, state == GKPeerStateAvailable ? @"available" :
//          state == GKPeerStateUnavailable ? @"unavailable" :
//          state == GKPeerStateConnecting ? @"connecting" :
//          state == GKPeerStateConnected ? @"connected" :
//          state == GKPeerStateDisconnected ? @"disconnected" : @"unkown");
//    
//    if (state == GKPeerStateAvailable) {
//        if (! [self.requestIDs containsObject:peerID]) {
//            [self.requestIDs addObject:peerID];
//            [self.requests addObject:[ZNPaymentRequest new]];
//            
//            [session connectToPeer:peerID withTimeout:CONNECT_TIMEOUT];
//            
//            [self layoutButtonsAnimated:YES];
//        }
//    }
//    else if (state == GKPeerStateUnavailable || state == GKPeerStateDisconnected) {
//        if ([self.requestIDs containsObject:peerID]) {
//            NSUInteger idx = [self.requestIDs indexOfObject:peerID];
//            
//            [self.requestIDs removeObjectAtIndex:idx];
//            [self.requests removeObjectAtIndex:idx];
//            [self layoutButtonsAnimated:YES];
//        }
//    }
//}
//
//// Indicates a connection request was received from another peer.
////
//// Accept by calling -acceptConnectionFromPeer:
//// Deny by calling -denyConnectionFromPeer:
//- (void)session:(GKSession *)session didReceiveConnectionRequestFromPeer:(NSString *)peerID
//{
//    NSAssert(FALSE, @"%s:%d %s: received connection request (not in client mode)", __FILE__, __LINE__,  __func__);
//    return;
//    
//    
//    [session denyConnectionFromPeer:peerID];
//}
//
//// Indicates a connection error occurred with a peer, including connection request failures or timeouts.
//- (void)session:(GKSession *)session connectionWithPeerFailed:(NSString *)peerID withError:(NSError *)error
//{
//    [[[UIAlertView alloc] initWithTitle:@"couldn't make payment" message:error.localizedDescription delegate:nil
//                      cancelButtonTitle:@"ok" otherButtonTitles:nil] show];
//    
//    if (self.selectedIndex != NSNotFound && [self.requestIDs[self.selectedIndex] isEqual:peerID]) {
//        self.selectedIndex = NSNotFound;
//    }
//    
//    if ([self.requestIDs containsObject:peerID]) {
//        NSUInteger idx = [self.requestIDs indexOfObject:peerID];
//        
//        [self.requestIDs removeObjectAtIndex:idx];
//        [self.requests removeObjectAtIndex:idx];
//        [self layoutButtonsAnimated:YES];
//    }
//}
//
//// Indicates an error occurred with the session such as failing to make available.
//- (void)session:(GKSession *)session didFailWithError:(NSError *)error
//{
//    if (self.selectedIndex != NSNotFound && ! [self.requestIDs[self.selectedIndex] isEqual:CLIPBOARD_ID] &&
//        ! [self.requestIDs[self.selectedIndex] isEqual:QR_ID]) {
//        self.selectedIndex = NSNotFound;
//    }
//    
//    NSIndexSet *indexes =
//        [self.requestIDs indexesOfObjectsPassingTest:^BOOL(id obj, NSUInteger idx, BOOL *stop) {
//            return ! [obj isEqual:CLIPBOARD_ID] && ! [obj isEqual:QR_ID];
//        }];
//    
//    [self.requestIDs removeObjectsAtIndexes:indexes];
//    [self.requests removeObjectsAtIndexes:indexes];
//    
//    [self layoutButtonsAnimated:YES];
//    
//    //[[[UIAlertView alloc] initWithTitle:@"couldn't make payment" message:error.localizedDescription delegate:nil
//    //                  cancelButtonTitle:@"ok" otherButtonTitles:nil] show];
//}
//
//- (void)receiveData:(NSData *)data fromPeer:(NSString *)peer inSession:(GKSession *)session context:(void *)context
//{
//    NSUInteger idx = [self.requestIDs indexOfObject:peer];
//    
//    if (idx == NSNotFound) {
//        NSAssert(FALSE, @"%s:%d %s: idx = NSNotFound", __FILE__, __LINE__,  __func__);
//        return;
//    }
//    
//    ZNPaymentRequest *req = self.requests[idx];
//    
//    [req setData:data];
//    
//    if (! req.valid) {
//        [[[UIAlertView alloc] initWithTitle:@"couldn't validate payment request"
//          message:@"The payment reqeust did not contain a valid merchant signature" delegate:self
//          cancelButtonTitle:@"ok" otherButtonTitles:nil] show];
//        
//        if (self.selectedIndex == idx) {
//            self.selectedIndex = NSNotFound;
//        }
//        
//        [self.requestIDs removeObjectAtIndex:idx];
//        [self.requests removeObjectAtIndex:idx];
//        [self layoutButtonsAnimated:YES];
//        
//        return;
//    }
//    
//    NSLog(@"got payment reqeust for %@", peer);
//    NSLog(@"%@", [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding]);
//    
//    if (self.selectedIndex == idx) [self confirmRequest:req];
//}

@end
