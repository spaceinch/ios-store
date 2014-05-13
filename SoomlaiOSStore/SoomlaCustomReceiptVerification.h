//
//  SoomlaCustomReceiptVerification.h
//  LoveOfMoney
//
//  Created by Andrew Ross on 5/10/14.
//
//

#import <Foundation/Foundation.h>
#import <StoreKit/StoreKit.h>

@class PurchasableVirtualItem;

@interface SoomlaCustomReceiptVerification : NSObject

- (id)initWithTransaction:(SKPaymentTransaction*)t andPurchasable:(PurchasableVirtualItem*)pvi;
- (void)verifyReceipt;

@end
