/*
 Copyright (C) 2012-2014 Soomla Inc.

 Licensed under the Apache License, Version 2.0 (the "License");
 you may not use this file except in compliance with the License.
 You may obtain a copy of the License at

 http://www.apache.org/licenses/LICENSE-2.0

 Unless required by applicable law or agreed to in writing, software
 distributed under the License is distributed on an "AS IS" BASIS,
 WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 See the License for the specific language governing permissions and
 limitations under the License.
 */

#import "SoomlaStore.h"
#import "StoreConfig.h"
#import "StorageManager.h"
#import "StoreInfo.h"
#import "StoreEventHandling.h"
#import "VirtualGood.h"
#import "VirtualCategory.h"
#import "VirtualCurrency.h"
#import "VirtualCurrencyPack.h"
#import "VirtualCurrencyStorage.h"
#import "VirtualGoodStorage.h"
#import "InsufficientFundsException.h"
#import "NotEnoughGoodsException.h"
#import "VirtualItemNotFoundException.h"
#import "MarketItem.h"
#import "SoomlaUtils.h"
#import "PurchaseWithMarket.h"

#import "SoomlaVerification.h"

@implementation SoomlaStore

@synthesize initialized;

static NSString* TAG = @"SOOMLA SoomlaStore";

- (BOOL)checkInit {
    if (!self.initialized) {
        LogDebug(TAG, @"You can't perform any of SoomlaStore's actions before it was initialized. Initialize it once when your game loads.");
        return NO;
    }

    return YES;
}

+ (SoomlaStore*)getInstance{
    static SoomlaStore* _instance = nil;

    @synchronized( self ) {
        if( _instance == nil ) {
            _instance = [[SoomlaStore alloc] init];
            _instance.customVerificationClass = nil;
        }
    }

    return _instance;
}


- (BOOL)initializeWithStoreAssets:(id<IStoreAssets>)storeAssets {
    LogDebug(TAG, @"SoomlaStore Initializing ...");

    [StorageManager getInstance];
    [[StoreInfo getInstance] initializeWithIStoreAssets:storeAssets];

    if ([SKPaymentQueue canMakePayments]) {
        [[SKPaymentQueue defaultQueue] addTransactionObserver:self];
        [StoreEventHandling postBillingSupported];
    } else {
        [StoreEventHandling postBillingNotSupported];
    }
  
    verifiers = [[NSMutableDictionary alloc] init];
  
    [self refreshMarketItemsDetails];

    self.initialized = YES;
    [StoreEventHandling postSoomlaStoreInitialized];

    return YES;
}

static NSString* developerPayload = NULL;
- (BOOL)buyInMarketWithMarketItem:(MarketItem*)marketItem andPayload:(NSString*)payload{
    if (![self checkInit]) return NO;

    if ([SKPaymentQueue canMakePayments]) {
        // See if there is a completed purchase in the transaction queue.
        // This can happen if server side verification request fails.
        for (SKPaymentTransaction *transaction in [SKPaymentQueue defaultQueue].transactions) {
            if ([transaction.payment.productIdentifier isEqualToString:marketItem.productId]) {
                if (transaction.transactionState == SKPaymentTransactionStatePurchased) {
                    [self completeTransaction:transaction];
                    return YES;
                }
            }
        }
        
        
        SKMutablePayment *payment = [[SKMutablePayment alloc] init] ;
        payment.productIdentifier = marketItem.productId;
        payment.quantity = 1;
        developerPayload = payload;
        [[SKPaymentQueue defaultQueue] addPayment:payment];

        @try {
            PurchasableVirtualItem* pvi = [[StoreInfo getInstance] purchasableItemWithProductId:marketItem.productId];
            [StoreEventHandling postMarketPurchaseStarted:pvi];
        }
        @catch (NSException *exception) {
            LogError(TAG, ([NSString stringWithFormat:@"Couldn't find a purchasable item with productId: %@", marketItem.productId]));
        }
    } else {
        LogError(TAG, @"Can't make purchases. Parental control is probably enabled.");
        return NO;
    }

    return YES;
}

- (void) refreshInventory {
    [self restoreTransactions];
    [self refreshMarketItemsDetails];
}

- (void)restoreTransactions {
    if(![self checkInit]) return;

    LogDebug(TAG, @"Sending restore transaction request");
    if ([SKPaymentQueue canMakePayments]) {
        [[SKPaymentQueue defaultQueue] restoreCompletedTransactions];
    }

    [StoreEventHandling postRestoreTransactionsStarted];
}

- (BOOL)transactionsAlreadyRestored {
    
    // Defaults to NO
    return [[NSUserDefaults standardUserDefaults] boolForKey:@"RESTORED"];
}

- (BOOL)isInitialized {
    return self.initialized;
}

#pragma mark -
#pragma mark SKPaymentTransactionObserver methods

- (void)paymentQueue:(SKPaymentQueue *)queue updatedTransactions:(NSArray *)transactions
{
    for (SKPaymentTransaction *transaction in transactions)
    {
        LogDebug(TAG, ([NSString stringWithFormat:@"Updated transaction: %@ %ld", transaction.payment.productIdentifier, transaction.transactionState]));

        switch (transaction.transactionState)
        {
            case SKPaymentTransactionStatePurchased:
                [self completeTransaction:transaction];
                break;
            case SKPaymentTransactionStateFailed:
                [self failedTransaction:transaction];
                break;
            case SKPaymentTransactionStateRestored:
                [self restoreTransaction:transaction];
                break;
            case SKPaymentTransactionStateDeferred:
                [self deferTransaction:transaction];
                break;
                
            default:
                break;
        }
    }
}

- (void)finalizeTransaction:(SKPaymentTransaction *)transaction forPurchasable:(PurchasableVirtualItem*)pvi {
    if ([StoreInfo isItemNonConsumable:pvi]){
        int balance = [[[StorageManager getInstance] virtualItemStorage:pvi] balanceForItem:pvi];
        if (balance == 1){
            // Remove the transaction from the payment queue.
            [[SKPaymentQueue defaultQueue] finishTransaction: transaction];
            return;
        }
    }

    float version = [[[UIDevice currentDevice] systemVersion] floatValue];

    NSURL* receiptUrl = [NSURL URLWithString:@"file:///"];
    if (version >= 7) {
        receiptUrl = [[NSBundle mainBundle] appStoreReceiptURL];
    }

    [StoreEventHandling postMarketPurchase:pvi withReceiptUrl:receiptUrl andPurchaseToken:transaction.transactionIdentifier andPayload:developerPayload];
    [pvi giveAmount:1];
    [StoreEventHandling postItemPurchased:pvi withPayload:developerPayload];
    developerPayload = NULL;

    // Remove the transaction from the payment queue.
    [[SKPaymentQueue defaultQueue] finishTransaction: transaction];
}

- (void)purchaseVerified:(NSNotification*)notification{

    NSDictionary* userInfo = notification.userInfo;
    PurchasableVirtualItem* purchasable = [userInfo objectForKey:DICT_ELEMENT_PURCHASABLE];
    BOOL verified = [(NSNumber*)[userInfo objectForKey:DICT_ELEMENT_VERIFIED] boolValue];
    SKPaymentTransaction* transaction = [userInfo objectForKey:DICT_ELEMENT_TRANSACTION];

    SoomlaVerification *verifier = (SoomlaVerification *)[verifiers objectForKey:transaction.transactionIdentifier];
  
    if (verifier)
    {
      [[NSNotificationCenter defaultCenter] removeObserver:self name:EVENT_MARKET_PURCHASE_VERIF object:verifier];
      [[NSNotificationCenter defaultCenter] removeObserver:self name:EVENT_UNEXPECTED_ERROR_IN_STORE object:verifier];
  
      [verifiers removeObjectForKey:transaction.transactionIdentifier];
    }
  
    if (verified) {
        [self finalizeTransaction:transaction forPurchasable:purchasable];
    } else {
        LogError(TAG, @"Failed to verify transaction receipt. The user will not get what he just bought.");
        [[SKPaymentQueue defaultQueue] finishTransaction: transaction];
        [StoreEventHandling postUnexpectedError:ERR_VERIFICATION_FAIL forObject:self];
    }
}

- (void)unexpectedVerificationError:(NSNotification*)notification{
  
    // if there was an error, stop listening
    [[NSNotificationCenter defaultCenter] removeObserver:self name:EVENT_MARKET_PURCHASE_VERIF object:nil];
    [[NSNotificationCenter defaultCenter] removeObserver:self name:EVENT_UNEXPECTED_ERROR_IN_STORE object:nil];
  
    [verifiers removeAllObjects];
}

- (void)givePurchasedItem:(SKPaymentTransaction *)transaction
{
    @try {
        PurchasableVirtualItem* pvi = [[StoreInfo getInstance] purchasableItemWithProductId:transaction.payment.productIdentifier];

        if (VERIFY_PURCHASES) {
            SoomlaVerification *verifier = nil;
          
            if (self.customVerificationClass) {
                id vObject = [self.customVerificationClass alloc];
                if (vObject &&
                    [vObject respondsToSelector:@selector(initWithTransaction:andPurchasable:)] &&
                    [vObject respondsToSelector:@selector(verifyData)]) {
                    verifier = [vObject initWithTransaction:transaction andPurchasable:pvi];
                } else {
                    LogError(TAG, @"Custom verification object is misconfigured!");
                }
            } else {
                verifier = [[SoomlaVerification alloc] initWithTransaction:transaction andPurchasable:pvi];
            }
            
            if (verifier) {
                [verifiers setObject:verifier forKey:transaction.transactionIdentifier];
              
                [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(purchaseVerified:) name:EVENT_MARKET_PURCHASE_VERIF object:verifier];
                [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(unexpectedVerificationError:) name:EVENT_UNEXPECTED_ERROR_IN_STORE object:verifier];
                
                [verifier verifyData];
            } else {
                LogError(TAG, @"Could not create a valid verification object! Validating purchase.");
                [self finalizeTransaction:transaction forPurchasable:pvi];
            }
        } else {
            [self finalizeTransaction:transaction forPurchasable:pvi];
        }

    } @catch (VirtualItemNotFoundException* e) {
        LogError(TAG, ([NSString stringWithFormat:@"An error occured when handling copmleted purchase for PurchasableVirtualItem with productId: %@"
                        @". It's unexpected so an unexpected error is being emitted.", transaction.payment.productIdentifier]));
        [StoreEventHandling postUnexpectedError:ERR_PURCHASE_FAIL forObject:self];
    }
}

- (void) completeTransaction: (SKPaymentTransaction *)transaction
{
    LogDebug(TAG, ([NSString stringWithFormat:@"Transaction completed for product: %@", transaction.payment.productIdentifier]));
    [self givePurchasedItem:transaction];
}

- (void) restoreTransaction: (SKPaymentTransaction *)transaction
{
    LogDebug(TAG, ([NSString stringWithFormat:@"Restore transaction for product: %@", transaction.payment.productIdentifier]));
    [self givePurchasedItem:transaction];
}

- (void) deferTransaction: (SKPaymentTransaction *)transaction
{
    LogDebug(TAG, ([NSString stringWithFormat:@"Defer transaction for product: %@", transaction.payment.productIdentifier]));

    @try {
        PurchasableVirtualItem* pvi = [[StoreInfo getInstance] purchasableItemWithProductId:transaction.payment.productIdentifier];
        
        [StoreEventHandling postMarketPurchaseDeferred:pvi];
    }
    @catch (VirtualItemNotFoundException* e) {
        LogError(TAG, ([NSString stringWithFormat:@"Couldn't find the DEFERRED VirtualCurrencyPack OR MarketItem with productId: %@"
                        @". It's unexpected so an unexpected error is being emitted.", transaction.payment.productIdentifier]));
        [StoreEventHandling postUnexpectedError:ERR_GENERAL forObject:self];
    }
}

- (void) failedTransaction: (SKPaymentTransaction *)transaction
{
    if (transaction.error.code != SKErrorPaymentCancelled) {
        LogError(TAG, ([NSString stringWithFormat:@"An error occured for product id \"%@\" with code \"%ld\" and description \"%@\"", transaction.payment.productIdentifier, (long)transaction.error.code, transaction.error.localizedDescription]));

        [StoreEventHandling postUnexpectedError:ERR_PURCHASE_FAIL forObject:self];
    }
    else{

        @try {
            PurchasableVirtualItem* pvi = [[StoreInfo getInstance] purchasableItemWithProductId:transaction.payment.productIdentifier];

            [StoreEventHandling postMarketPurchaseCancelled:pvi];
        }
        @catch (VirtualItemNotFoundException* e) {
            LogError(TAG, ([NSString stringWithFormat:@"Couldn't find the CANCELLED VirtualCurrencyPack OR MarketItem with productId: %@"
                            @". It's unexpected so an unexpected error is being emitted.", transaction.payment.productIdentifier]));
            [StoreEventHandling postUnexpectedError:ERR_GENERAL forObject:self];
        }

    }
    [[SKPaymentQueue defaultQueue] finishTransaction: transaction];
}

- (void)paymentQueueRestoreCompletedTransactionsFinished:(SKPaymentQueue *)queue {
    NSUserDefaults* defaults = [NSUserDefaults standardUserDefaults];
    [defaults setBool:YES forKey:@"RESTORED"];
    [defaults synchronize];
    
    [StoreEventHandling postRestoreTransactionsFinished:YES];
}

- (void)paymentQueue:(SKPaymentQueue *)queue restoreCompletedTransactionsFailedWithError:(NSError *)error {
    [StoreEventHandling postRestoreTransactionsFinished:NO];
}


- (void)refreshMarketItemsDetails {
    SKProductsRequest *productsRequest = [[SKProductsRequest alloc] initWithProductIdentifiers:[[NSSet alloc] initWithArray:[[StoreInfo getInstance] allProductIds]]];
    productsRequest.delegate = self;
    [productsRequest start];
    [StoreEventHandling postMarketItemsRefreshStarted];
}

- (void)productsRequest:(SKProductsRequest *)request didReceiveResponse:(SKProductsResponse *)response
{
    NSMutableArray* marketItems = [NSMutableArray array];
    NSArray *products = response.products;
    for(SKProduct* product in products) {
        NSString* title = (product.localizedTitle == nil) ? @"" : product.localizedTitle;
        NSString* description = (product.localizedDescription == nil) ? @"" : product.localizedDescription;
        NSDecimalNumber* price = product.price;
        NSLocale* locale = product.priceLocale;
        NSString* productId = product.productIdentifier;
        LogDebug(TAG, ([NSString stringWithFormat:@"title: %@  price: %@  productId: %@  desc: %@",title,[price descriptionWithLocale:locale],productId,description]));

        @try {
            PurchasableVirtualItem* pvi = [[StoreInfo getInstance] purchasableItemWithProductId:productId];

            PurchaseType* purchaseType = pvi.purchaseType;
            if ([purchaseType isKindOfClass:[PurchaseWithMarket class]]) {
                MarketItem* mi = ((PurchaseWithMarket*)purchaseType).marketItem;
                [mi setMarketInformation:[MarketItem priceWithCurrencySymbol:locale andPrice:price andBackupPrice:mi.price]
                          andTitle:title
                          andDescription:description
                          andCurrencyCode:[locale objectForKey:NSLocaleCurrencyCode]
                          andPriceMicros:(product.price.floatValue * 1000000)];

                [marketItems addObject:mi];
            }
        }
        @catch (VirtualItemNotFoundException* e) {
            LogError(TAG, ([NSString stringWithFormat:@"Couldn't find the PurchasableVirtualItem with productId: %@"
                            @". It's unexpected so an unexpected error is being emitted.", productId]));
            [StoreEventHandling postUnexpectedError:ERR_GENERAL forObject:self];
        }
    }

    for (NSString *invalidProductId in response.invalidProductIdentifiers)
    {
        LogError(TAG, ([NSString stringWithFormat: @"Invalid product id (when trying to fetch item details): %@" , invalidProductId]));
    }

    NSUInteger idsCount = [[[StoreInfo getInstance] allProductIds] count];
    NSUInteger productsCount = [products count];
    if (idsCount != productsCount)
    {
        LogError(TAG, ([NSString stringWithFormat: @"Expecting %d products but only fetched %d from iTunes Store" , (int)idsCount, (int)productsCount]));
    }

    [StoreEventHandling postMarketItemsRefreshFinished:marketItems];
}


@end
