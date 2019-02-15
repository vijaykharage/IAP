# IAP
An IAP code found somewhere.


import RxSwift
import RxCocoa
import StoreKit
import Kvitto
import Crashlytics

enum RestorePurchaseStatus {
    case loading
    case finished
    case failed(error: Error)
}

enum ProductsStatus {
    case pending
    case loading
    case loaded(subscription: SKProduct, proVersion: SKProduct)
    case failed(error: Error)
}

enum TransactionStatus {
    case pending
    case purchasing
    case purchased
    case failed(error: Error?)
    case deferred
}

enum PurchaseStatus {
    case noPurchases
    case purchasedProVersion
    case activeSubscription(expDate: Date)
    case expiredSubscription(expDate: Date)
    case purchasedProVersionAndSubscription(expDate: Date)
    
    var givesAccessToProTools: Bool {
        switch self {
        case .purchasedProVersion, .activeSubscription, .purchasedProVersionAndSubscription: return true
        default: return false
        }
    }
    
    var proVersionPurchased: Bool {
        switch self {
        case .purchasedProVersion, .purchasedProVersionAndSubscription: return true
        default: return false
        }
    }
}

enum PurchaseError: LocalizedError {
    case noMatchingProductFound
    
    var errorDescription: String? {
        switch self {
        case .noMatchingProductFound:
            return "Can't find SKProduct with matching identifier"
        }
    }
}

fileprivate enum InAppPurchaseSimulationMode: String {
    case subscription
    case proVersion = "pro_version"
    case both
    
    var status: PurchaseStatus {
        switch self {
        case .subscription:
            return .activeSubscription(expDate: Date(timeIntervalSinceNow: 60 * 60 * 24))
        case .proVersion:
            return .purchasedProVersion
        case .both:
            return .purchasedProVersionAndSubscription(expDate: Date(timeIntervalSinceNow: 60 * 60 * 24))
        }
    }
}

fileprivate enum InAppID: String, CaseIterable {
    case subscription = "com.eehelper.pro_subscription"
    case proVersion = "com.eehelper.pro_version"
}

fileprivate let inAppPurchasesIdentifiers = Set(InAppID.allCases.map { $0.rawValue })

class InAppPurchaseManager: NSObject {
    static let shared = InAppPurchaseManager()
    
    let inAppPurchaseStatus: BehaviorRelay<PurchaseStatus> = BehaviorRelay(value: .noPurchases)
    let purchaseRestorationEvents: PublishRelay<RestorePurchaseStatus> = PublishRelay()
    let productsEvents: BehaviorRelay<ProductsStatus> = BehaviorRelay(value: .pending)
    let transactionEvents: BehaviorRelay<TransactionStatus> = BehaviorRelay(value: .pending)
    
    func loadProducts() {
        productsEvents.accept(.loading)
        
        let request = SKProductsRequest(productIdentifiers: inAppPurchasesIdentifiers)
        request.delegate = self
        request.start()
    }
    
    func purchase(_ product: SKProduct) {
        let payment = SKPayment(product: product)
        SKPaymentQueue.default().add(payment)
    }
    
    func restorePurchase() {
        purchaseRestorationEvents.accept(.loading)
        SKPaymentQueue.default().restoreCompletedTransactions()
    }
    
    // MARK: - Private
    private override init() {
        super.init()
        inAppPurchaseStatus.accept(readReceipt())
        SKPaymentQueue.default().add(self)
    }
    
    private func readReceipt() -> PurchaseStatus {
        if let value = ProcessInfo.processInfo.environment["IN_APP_PURCHASE"],
            let mode = InAppPurchaseSimulationMode(rawValue: value) {
            return mode.status
        }
        
        guard
            let url = Bundle.main.appStoreReceiptURL,
            let receipt = Receipt(contentsOfURL: url)
        else {
            return .noPurchases
        }
        
        let proVersionReceipt = receipt.inAppPurchaseReceipts?
            .filter({ $0.productIdentifier == InAppID.proVersion.rawValue })
            .first
        
        let subscriptionLatestExpDate = receipt.inAppPurchaseReceipts?
            .filter({ $0.productIdentifier == InAppID.subscription.rawValue })
            .compactMap({ $0.subscriptionExpirationDate })
            .sorted(by: { $0 > $1 })
            .first
        
        switch (proVersionReceipt, subscriptionLatestExpDate) {
        case (nil, nil): return .noPurchases
        case (.some, nil): return .purchasedProVersion
        case (nil, .some(let date)):
            return date > Date() ? .activeSubscription(expDate: date) : .expiredSubscription(expDate: date)
        case (.some, .some(let date)):
            return date > Date() ? .purchasedProVersionAndSubscription(expDate: date) : .purchasedProVersion
        }
    }
}

extension InAppPurchaseManager: SKProductsRequestDelegate {
    func productsRequest(_ request: SKProductsRequest, didReceive response: SKProductsResponse) {
        let products = response.products
        guard
            let subscription = products.first(where: { $0.productIdentifier == InAppID.subscription.rawValue }),
            let nonconsumable = products.first(where: { $0.productIdentifier == InAppID.proVersion.rawValue })
        else {
            Crashlytics.sharedInstance().recordError(PurchaseError.noMatchingProductFound)
            productsEvents.accept(.failed(error: PurchaseError.noMatchingProductFound))
            return
        }
        productsEvents.accept(.loaded(subscription: subscription, proVersion: nonconsumable))
    }
    
    func request(_ request: SKRequest, didFailWithError error: Error) {
        productsEvents.accept(.failed(error: error))
    }
    
    func paymentQueue(_ queue: SKPaymentQueue, updatedTransactions transactions: [SKPaymentTransaction]) {
        for transaction in transactions where inAppPurchasesIdentifiers.contains(transaction.payment.productIdentifier) {
            switch transaction.transactionState {
            case .purchasing:
                transactionEvents.accept(.purchasing)
            case .purchased, .restored:
                transactionEvents.accept(.purchased)
                queue.finishTransaction(transaction)
            case .failed:
                transactionEvents.accept(.failed(error: transaction.error))
                queue.finishTransaction(transaction)
            case .deferred:
                transactionEvents.accept(.deferred)
            }
        }
        inAppPurchaseStatus.accept(readReceipt())
    }
}

extension InAppPurchaseManager: SKPaymentTransactionObserver {
    func paymentQueueRestoreCompletedTransactionsFinished(_ queue: SKPaymentQueue) {
        purchaseRestorationEvents.accept(.finished)
    }
    
    func paymentQueue(_ queue: SKPaymentQueue, restoreCompletedTransactionsFailedWithError error: Error) {
        purchaseRestorationEvents.accept(.failed(error: error))
    }
}
