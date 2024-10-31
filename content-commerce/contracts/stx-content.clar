;; Content Monetization Contract
;; Allows content creators to monetize their content through subscriptions and one-time purchases
;; Implements features like revenue sharing, content access control, and subscription management

;; Error codes
(define-constant ERR-UNAUTHORIZED-ACCESS (err u1))
(define-constant ERR-INVALID-PRICING-PARAMETERS (err u2))
(define-constant ERR-DUPLICATE-PURCHASE (err u3))
(define-constant ERR-CONTENT-NOT-FOUND (err u4))
(define-constant ERR-INSUFFICIENT-STX-BALANCE (err u5))
(define-constant ERR-SUBSCRIPTION-EXPIRED (err u6))
(define-constant ERR-INVALID-SUBSCRIPTION-DURATION (err u7))

;; Data variables
(define-data-var platform-administrator principal tx-sender)
(define-data-var platform-commission-rate uint u50) ;; 5% platform fee (base 1000)

;; Data maps
(define-map digital-content-registry
    { digital-content-id: uint }
    {
        content-creator: principal,
        content-price-stx: uint,
        creator-revenue-percentage: uint,
        content-metadata-uri: (string-utf8 256),
        subscription-enabled: bool,
        subscription-period-blocks: uint
    }
)

(define-map user-content-purchases
    { content-buyer: principal, digital-content-id: uint }
    {
        transaction-timestamp: uint,
        subscription-end-block: uint,
        purchase-status-active: bool
    }
)

(define-map creator-earnings-ledger
    { content-creator: principal }
    { available-balance: uint }
)

;; Private functions
(define-private (calculate-revenue-distribution (total-price uint))
    (let
        (
            (platform-fee-amount (/ (* total-price (var-get platform-commission-rate)) u1000))
        )
        {
            platform-commission: platform-fee-amount,
            creator-earnings: (- total-price platform-fee-amount)
        }
    )
)

;; Fixed execute-stx-transfer function to match stx-transfer? expectations
(define-private (execute-stx-transfer (amount uint) (recipient principal))
    (stx-transfer? amount tx-sender recipient)
)

(define-private (verify-subscription-status (subscriber-address principal) (digital-content-id uint))
    (match (map-get? user-content-purchases { content-buyer: subscriber-address, digital-content-id: digital-content-id })
        purchase-record (and
            (get purchase-status-active purchase-record)
            (<= block-height (get subscription-end-block purchase-record))
        )
        false
    )
)

;; Public functions
(define-public (register-digital-content (digital-content-id uint) 
                                       (content-price-stx uint) 
                                       (creator-revenue-percentage uint) 
                                       (content-metadata-uri (string-utf8 256)) 
                                       (subscription-enabled bool) 
                                       (subscription-period-blocks uint))
    (begin
        (asserts! (> content-price-stx u0) ERR-INVALID-PRICING-PARAMETERS)
        (asserts! (and (>= creator-revenue-percentage u0) (<= creator-revenue-percentage u1000)) ERR-INVALID-PRICING-PARAMETERS)
        (asserts! (or (not subscription-enabled) (> subscription-period-blocks u0)) ERR-INVALID-SUBSCRIPTION-DURATION)
        
        (map-set digital-content-registry
            { digital-content-id: digital-content-id }
            {
                content-creator: tx-sender,
                content-price-stx: content-price-stx,
                creator-revenue-percentage: creator-revenue-percentage,
                content-metadata-uri: content-metadata-uri,
                subscription-enabled: subscription-enabled,
                subscription-period-blocks: subscription-period-blocks
            }
        )
        (ok true)
    )
)

(define-public (initiate-content-purchase (digital-content-id uint))
    (let
        (
            (content-details (unwrap! (map-get? digital-content-registry { digital-content-id: digital-content-id }) ERR-CONTENT-NOT-FOUND))
            (revenue-distribution (calculate-revenue-distribution (get content-price-stx content-details)))
            (content-creator-address (get content-creator content-details))
            (current-block-height block-height)
        )
        
        (asserts! (not (verify-subscription-status tx-sender digital-content-id)) ERR-DUPLICATE-PURCHASE)
        
        ;; Process payment using updated transfer function
        (try! (execute-stx-transfer (get content-price-stx content-details) (as-contract tx-sender)))
        
        ;; Update creator earnings
        (map-set creator-earnings-ledger
            { content-creator: content-creator-address }
            {
                available-balance: (+ (default-to u0 
                    (get available-balance (map-get? creator-earnings-ledger { content-creator: content-creator-address })))
                    (get creator-earnings revenue-distribution))
            }
        )
        
        ;; Record purchase
        (map-set user-content-purchases
            { content-buyer: tx-sender, digital-content-id: digital-content-id }
            {
                transaction-timestamp: current-block-height,
                subscription-end-block: (if (get subscription-enabled content-details)
                    (+ current-block-height (get subscription-period-blocks content-details))
                    u0),
                purchase-status-active: true
            }
        )
        
        (ok true)
    )
)

(define-public (withdraw-creator-earnings)
    (let
        (
            (creator-earnings-record (unwrap! (map-get? creator-earnings-ledger { content-creator: tx-sender }) ERR-CONTENT-NOT-FOUND))
            (withdrawal-amount (get available-balance creator-earnings-record))
        )
        
        (asserts! (> withdrawal-amount u0) ERR-INSUFFICIENT-STX-BALANCE)
        
        ;; Reset balance before transfer to prevent reentrancy
        (map-set creator-earnings-ledger
            { content-creator: tx-sender }
            { available-balance: u0 }
        )
        
        ;; Use updated transfer function
        (try! (execute-stx-transfer withdrawal-amount tx-sender))
        (ok true)
    )
)

(define-public (terminate-subscription (digital-content-id uint))
    (let
        (
            (subscription-record (unwrap! (map-get? user-content-purchases 
                { content-buyer: tx-sender, digital-content-id: digital-content-id }) ERR-CONTENT-NOT-FOUND))
        )
        
        (asserts! (get purchase-status-active subscription-record) ERR-CONTENT-NOT-FOUND)
        
        (map-set user-content-purchases
            { content-buyer: tx-sender, digital-content-id: digital-content-id }
            {
                transaction-timestamp: (get transaction-timestamp subscription-record),
                subscription-end-block: block-height,
                purchase-status-active: false
            }
        )
        (ok true)
    )
)

;; Read-only functions
(define-read-only (get-digital-content-info (digital-content-id uint))
    (map-get? digital-content-registry { digital-content-id: digital-content-id })
)

(define-read-only (get-user-purchase-info (content-buyer principal) (digital-content-id uint))
    (map-get? user-content-purchases { content-buyer: content-buyer, digital-content-id: digital-content-id })
)

(define-read-only (get-creator-current-balance (content-creator principal))
    (default-to u0 (get available-balance (map-get? creator-earnings-ledger { content-creator: content-creator })))
)

(define-read-only (verify-content-access (content-buyer principal) (digital-content-id uint))
    (match (map-get? user-content-purchases { content-buyer: content-buyer, digital-content-id: digital-content-id })
        purchase-record (ok (verify-subscription-status content-buyer digital-content-id))
        ERR-CONTENT-NOT-FOUND
    )
)

;; Administrative functions
(define-public (update-platform-commission (new-commission-rate uint))
    (begin
        (asserts! (is-eq tx-sender (var-get platform-administrator)) ERR-UNAUTHORIZED-ACCESS)
        (asserts! (<= new-commission-rate u1000) ERR-INVALID-PRICING-PARAMETERS)
        (var-set platform-commission-rate new-commission-rate)
        (ok true)
    )
)

(define-public (transfer-platform-administration (new-administrator principal))
    (begin
        (asserts! (is-eq tx-sender (var-get platform-administrator)) ERR-UNAUTHORIZED-ACCESS)
        (var-set platform-administrator new-administrator)
        (ok true)
    )
)