;; ChainBridge - Connected. Secure. Seamless.
;; A decentralized cross-chain bridge for messages and asset transfers
;; Features: Message relaying, asset locking, validator consensus

;; ===================================
;; CONSTANTS AND ERROR CODES
;; ===================================

(define-constant ERR-NOT-AUTHORIZED (err u10))
(define-constant ERR-BRIDGE-NOT-FOUND (err u11))
(define-constant ERR-ALREADY-PROCESSED (err u12))
(define-constant ERR-INSUFFICIENT-VALIDATORS (err u13))
(define-constant ERR-INVALID-CHAIN (err u14))
(define-constant ERR-BRIDGE-PAUSED (err u15))

;; Contract constants
(define-constant CONTRACT-OWNER tx-sender)
(define-constant MIN-VALIDATORS u3)
(define-constant BRIDGE-FEE u100000) ;; 0.1 STX bridge fee
(define-constant MAX-MESSAGE-SIZE u256)

;; ===================================
;; DATA VARIABLES
;; ===================================

(define-data-var bridge-active bool true)
(define-data-var message-counter uint u0)
(define-data-var total-messages uint u0)
(define-data-var bridge-revenue uint u0)

;; ===================================
;; TOKEN DEFINITIONS
;; ===================================

;; Wrapped tokens for cross-chain assets
(define-fungible-token bridge-token)

;; ===================================
;; DATA MAPS
;; ===================================

;; Cross-chain messages
(define-map bridge-messages
  uint
  {
    sender: principal,
    target-chain: (string-ascii 32),
    recipient: (string-ascii 64),
    message: (string-ascii 256),
    amount: uint,
    created-at: uint,
    processed: bool,
    validator-confirmations: uint
  }
)

;; Validator network
(define-map validators
  principal
  {
    active: bool,
    total-validations: uint,
    reputation: uint,
    last-activity: uint
  }
)

;; Message validations
(define-map message-validations
  { message-id: uint, validator: principal }
  {
    confirmed: bool,
    timestamp: uint
  }
)

;; Supported chains
(define-map supported-chains
  (string-ascii 32)
  {
    active: bool,
    min-fee: uint,
    total-messages: uint
  }
)

;; User bridge statistics
(define-map user-stats
  principal
  {
    messages-sent: uint,
    total-bridged: uint,
    chains-used: uint,
    last-bridge: uint
  }
)

;; ===================================
;; PRIVATE HELPER FUNCTIONS
;; ===================================

(define-private (is-contract-owner (user principal))
  (is-eq user CONTRACT-OWNER)
)

(define-private (is-validator (user principal))
  (match (map-get? validators user)
    validator-data
    (get active validator-data)
    false
  )
)

(define-private (get-active-validators)
  (fold + (list u1 u1 u1 u1 u1) u0) ;; Simplified - would count active validators in real implementation
)

(define-private (has-validator-confirmed (message-id uint) (validator principal))
  (match (map-get? message-validations { message-id: message-id, validator: validator })
    validation-data
    (get confirmed validation-data)
    false
  )
)

(define-private (is-chain-supported (chain-name (string-ascii 32)))
  (match (map-get? supported-chains chain-name)
    chain-data
    (get active chain-data)
    false
  )
)

;; ===================================
;; READ-ONLY FUNCTIONS
;; ===================================

(define-read-only (get-bridge-info)
  {
    active: (var-get bridge-active),
    total-messages: (var-get total-messages),
    bridge-revenue: (var-get bridge-revenue),
    bridge-fee: BRIDGE-FEE
  }
)

(define-read-only (get-message (message-id uint))
  (map-get? bridge-messages message-id)
)

(define-read-only (get-validator (validator principal))
  (map-get? validators validator)
)

(define-read-only (get-chain-info (chain-name (string-ascii 32)))
  (map-get? supported-chains chain-name)
)

(define-read-only (get-user-stats (user principal))
  (map-get? user-stats user)
)

(define-read-only (get-message-status (message-id uint))
  (match (map-get? bridge-messages message-id)
    message-data
    (if (get processed message-data)
      (some "completed")
      (if (>= (get validator-confirmations message-data) MIN-VALIDATORS)
        (some "ready")
        (some "pending")
      )
    )
    none
  )
)

;; ===================================
;; ADMIN FUNCTIONS
;; ===================================

(define-public (toggle-bridge (active bool))
  (begin
    (asserts! (is-contract-owner tx-sender) ERR-NOT-AUTHORIZED)
    (var-set bridge-active active)
    (print { action: "bridge-toggled", active: active })
    (ok true)
  )
)

(define-public (add-validator (validator principal))
  (begin
    (asserts! (is-contract-owner tx-sender) ERR-NOT-AUTHORIZED)
    
    (map-set validators validator {
      active: true,
      total-validations: u0,
      reputation: u100,
      last-activity: burn-block-height
    })
    
    (print { action: "validator-added", validator: validator })
    (ok true)
  )
)

(define-public (remove-validator (validator principal))
  (let (
    (validator-data (unwrap! (map-get? validators validator) ERR-NOT-AUTHORIZED))
  )
    (asserts! (is-contract-owner tx-sender) ERR-NOT-AUTHORIZED)
    
    (map-set validators validator (merge validator-data { active: false }))
    (print { action: "validator-removed", validator: validator })
    (ok true)
  )
)

(define-public (add-supported-chain (chain-name (string-ascii 32)) (min-fee uint))
  (begin
    (asserts! (is-contract-owner tx-sender) ERR-NOT-AUTHORIZED)
    
    (map-set supported-chains chain-name {
      active: true,
      min-fee: min-fee,
      total-messages: u0
    })
    
    (print { action: "chain-added", chain: chain-name, min-fee: min-fee })
    (ok true)
  )
)

(define-public (withdraw-bridge-fees (amount uint))
  (begin
    (asserts! (is-contract-owner tx-sender) ERR-NOT-AUTHORIZED)
    (asserts! (<= amount (var-get bridge-revenue)) ERR-INSUFFICIENT-VALIDATORS)
    
    (try! (as-contract (stx-transfer? amount tx-sender tx-sender)))
    (var-set bridge-revenue (- (var-get bridge-revenue) amount))
    
    (print { action: "fees-withdrawn", amount: amount })
    (ok true)
  )
)

;; ===================================
;; BRIDGE FUNCTIONS
;; ===================================

(define-public (send-message
  (target-chain (string-ascii 32))
  (recipient (string-ascii 64))
  (message (string-ascii 256))
  (amount uint)
)
  (let (
    (message-id (+ (var-get message-counter) u1))
    (chain-data (unwrap! (map-get? supported-chains target-chain) ERR-INVALID-CHAIN))
    (user-statistics (default-to { messages-sent: u0, total-bridged: u0, chains-used: u0, last-bridge: u0 }
                                 (map-get? user-stats tx-sender)))
    (total-fee (+ BRIDGE-FEE amount))
  )
    (asserts! (var-get bridge-active) ERR-BRIDGE-PAUSED)
    (asserts! (is-chain-supported target-chain) ERR-INVALID-CHAIN)
    
    ;; Transfer bridge fee and amount to contract
    (try! (stx-transfer? total-fee tx-sender (as-contract tx-sender)))
    
    ;; Create bridge message
    (map-set bridge-messages message-id {
      sender: tx-sender,
      target-chain: target-chain,
      recipient: recipient,
      message: message,
      amount: amount,
      created-at: burn-block-height,
      processed: false,
      validator-confirmations: u0
    })
    
    ;; Update chain stats
    (map-set supported-chains target-chain (merge chain-data {
      total-messages: (+ (get total-messages chain-data) u1)
    }))
    
    ;; Update user stats
    (map-set user-stats tx-sender (merge user-statistics {
      messages-sent: (+ (get messages-sent user-statistics) u1),
      total-bridged: (+ (get total-bridged user-statistics) amount),
      chains-used: (+ (get chains-used user-statistics) u1),
      last-bridge: burn-block-height
    }))
    
    ;; Update global stats
    (var-set message-counter message-id)
    (var-set total-messages (+ (var-get total-messages) u1))
    (var-set bridge-revenue (+ (var-get bridge-revenue) BRIDGE-FEE))
    
    (print { action: "message-sent", message-id: message-id, target-chain: target-chain, amount: amount })
    (ok message-id)
  )
)

(define-public (validate-message (message-id uint))
  (let (
    (message-data (unwrap! (map-get? bridge-messages message-id) ERR-BRIDGE-NOT-FOUND))
    (validator-data (unwrap! (map-get? validators tx-sender) ERR-NOT-AUTHORIZED))
  )
    (asserts! (var-get bridge-active) ERR-BRIDGE-PAUSED)
    (asserts! (is-validator tx-sender) ERR-NOT-AUTHORIZED)
    (asserts! (not (get processed message-data)) ERR-ALREADY-PROCESSED)
    (asserts! (not (has-validator-confirmed message-id tx-sender)) ERR-ALREADY-PROCESSED)
    
    ;; Record validation
    (map-set message-validations { message-id: message-id, validator: tx-sender } {
      confirmed: true,
      timestamp: burn-block-height
    })
    
    ;; Update message confirmations
    (map-set bridge-messages message-id (merge message-data {
      validator-confirmations: (+ (get validator-confirmations message-data) u1)
    }))
    
    ;; Update validator stats
    (map-set validators tx-sender (merge validator-data {
      total-validations: (+ (get total-validations validator-data) u1),
      reputation: (+ (get reputation validator-data) u1),
      last-activity: burn-block-height
    }))
    
    (print { action: "message-validated", message-id: message-id, validator: tx-sender })
    (ok true)
  )
)

(define-public (process-message (message-id uint))
  (let (
    (message-data (unwrap! (map-get? bridge-messages message-id) ERR-BRIDGE-NOT-FOUND))
  )
    (asserts! (var-get bridge-active) ERR-BRIDGE-PAUSED)
    (asserts! (not (get processed message-data)) ERR-ALREADY-PROCESSED)
    (asserts! (>= (get validator-confirmations message-data) MIN-VALIDATORS) ERR-INSUFFICIENT-VALIDATORS)
    
    ;; Mark message as processed
    (map-set bridge-messages message-id (merge message-data { processed: true }))
    
    ;; Mint bridge tokens if amount > 0
    (if (> (get amount message-data) u0)
      (try! (ft-mint? bridge-token (get amount message-data) (as-contract tx-sender)))
      true
    )
    
    (print { action: "message-processed", message-id: message-id, amount: (get amount message-data) })
    (ok true)
  )
)

;; ===================================
;; INITIALIZATION
;; ===================================

(begin
  (map-set validators CONTRACT-OWNER { active: true, total-validations: u0, reputation: u100, last-activity: burn-block-height })
  (map-set supported-chains "ethereum" { active: true, min-fee: BRIDGE-FEE, total-messages: u0 })
  (map-set supported-chains "bitcoin" { active: true, min-fee: BRIDGE-FEE, total-messages: u0 })
  (print { action: "chainbridge-initialized", owner: CONTRACT-OWNER })
)