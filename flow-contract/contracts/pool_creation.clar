;; Pool Creation Contract
;; Allows users to create and manage staking pools for ideas or short-term bets

;; Constants
(define-constant CONTRACT-OWNER tx-sender)
(define-constant ERR-UNAUTHORIZED (err u100))
(define-constant ERR-POOL-NOT-FOUND (err u101))
(define-constant ERR-INVALID-AMOUNT (err u102))
(define-constant ERR-POOL-EXPIRED (err u103))
(define-constant ERR-INSUFFICIENT-BALANCE (err u104))
(define-constant ERR-POOL-ALREADY-EXISTS (err u105))
(define-constant ERR-INVALID-DEADLINE (err u106))
(define-constant ERR-INVALID-REWARD-SPLIT (err u107))

;; Pool types
(define-constant POOL-TYPE-IDEA u1)
(define-constant POOL-TYPE-BET u2)

;; Data Variables
(define-data-var next-pool-id uint u1)
(define-data-var contract-fee-percentage uint u250) ;; 2.5% in basis points

;; Pool structure
(define-map pools
  { pool-id: uint }
  {
    creator: principal,
    pool-type: uint,
    title: (string-ascii 100),
    description: (string-ascii 500),
    stake-amount: uint,
    min-contribution: uint,
    max-contribution: uint,
    total-staked: uint,
    participant-count: uint,
    lock-up-period: uint, ;; in blocks
    reward-split: uint, ;; percentage to creator (basis points)
    bet-deadline: uint, ;; block height
    created-at: uint,
    is-active: bool,
    outcome-set: bool,
    winning-outcome: (optional uint)
  }
)

;; Pool participants
(define-map pool-participants
  { pool-id: uint, participant: principal }
  {
    contribution: uint,
    joined-at: uint,
    claimed: bool
  }
)

;; Pool outcomes (for bet pools)
(define-map pool-outcomes
  { pool-id: uint, outcome-id: uint }
  {
    description: (string-ascii 200),
    total-staked: uint,
    participant-count: uint
  }
)

;; Participant outcome choices
(define-map participant-outcomes
  { pool-id: uint, participant: principal }
  { chosen-outcome: uint }
)

;; Read-only functions

;; Get pool information
(define-read-only (get-pool (pool-id uint))
  (map-get? pools { pool-id: pool-id })
)

;; Get participant information
(define-read-only (get-participant-info (pool-id uint) (participant principal))
  (map-get? pool-participants { pool-id: pool-id, participant: participant })
)

;; Get pool outcome information
(define-read-only (get-pool-outcome (pool-id uint) (outcome-id uint))
  (map-get? pool-outcomes { pool-id: pool-id, outcome-id: outcome-id })
)

;; Get participant's chosen outcome
(define-read-only (get-participant-outcome (pool-id uint) (participant principal))
  (map-get? participant-outcomes { pool-id: pool-id, participant: participant })
)

;; Get next pool ID
(define-read-only (get-next-pool-id)
  (var-get next-pool-id)
)

;; Check if pool is expired
(define-read-only (is-pool-expired (pool-id uint))
  (match (get-pool pool-id)
    pool-data 
      (> block-height (get bet-deadline pool-data))
    false
  )
)

;; Public functions

;; Create a new pool
(define-public (create-pool 
  (pool-type uint)
  (title (string-ascii 100))
  (description (string-ascii 500))
  (stake-amount uint)
  (min-contribution uint)
  (max-contribution uint)
  (lock-up-period uint)
  (reward-split uint)
  (bet-deadline uint)
)
  (let 
    (
      (pool-id (var-get next-pool-id))
      (current-block block-height)
    )
    ;; Validation
    (asserts! (> stake-amount u0) ERR-INVALID-AMOUNT)
    (asserts! (> min-contribution u0) ERR-INVALID-AMOUNT)
    (asserts! (>= max-contribution min-contribution) ERR-INVALID-AMOUNT)
    (asserts! (> bet-deadline current-block) ERR-INVALID-DEADLINE)
    (asserts! (<= reward-split u10000) ERR-INVALID-REWARD-SPLIT) ;; Max 100%
    (asserts! (or (is-eq pool-type POOL-TYPE-IDEA) (is-eq pool-type POOL-TYPE-BET)) ERR-INVALID-AMOUNT)
    
    ;; Transfer initial stake from creator
    (try! (stx-transfer? stake-amount tx-sender (as-contract tx-sender)))
    
    ;; Create pool
    (map-set pools
      { pool-id: pool-id }
      {
        creator: tx-sender,
        pool-type: pool-type,
        title: title,
        description: description,
        stake-amount: stake-amount,
        min-contribution: min-contribution,
        max-contribution: max-contribution,
        total-staked: stake-amount,
        participant-count: u1,
        lock-up-period: lock-up-period,
        reward-split: reward-split,
        bet-deadline: bet-deadline,
        created-at: current-block,
        is-active: true,
        outcome-set: false,
        winning-outcome: none
      }
    )
    
    ;; Add creator as first participant
    (map-set pool-participants
      { pool-id: pool-id, participant: tx-sender }
      {
        contribution: stake-amount,
        joined-at: current-block,
        claimed: false
      }
    )
    
    ;; Increment pool ID counter
    (var-set next-pool-id (+ pool-id u1))
    
    ;; Print event
    (print {
      event: "pool-created",
      pool-id: pool-id,
      creator: tx-sender,
      pool-type: pool-type,
      stake-amount: stake-amount
    })
    
    (ok pool-id)
  )
)

;; Join an existing pool
(define-public (join-pool (pool-id uint) (contribution uint))
  (let 
    (
      (pool-data (unwrap! (get-pool pool-id) ERR-POOL-NOT-FOUND))
      (current-participant (map-get? pool-participants { pool-id: pool-id, participant: tx-sender }))
    )
    ;; Validation
    (asserts! (get is-active pool-data) ERR-POOL-EXPIRED)
    (asserts! (<= block-height (get bet-deadline pool-data)) ERR-POOL-EXPIRED)
    (asserts! (>= contribution (get min-contribution pool-data)) ERR-INVALID-AMOUNT)
    (asserts! (<= contribution (get max-contribution pool-data)) ERR-INVALID-AMOUNT)
    (asserts! (is-none current-participant) ERR-POOL-ALREADY-EXISTS)
    
    ;; Transfer contribution
    (try! (stx-transfer? contribution tx-sender (as-contract tx-sender)))
    
    ;; Add participant
    (map-set pool-participants
      { pool-id: pool-id, participant: tx-sender }
      {
        contribution: contribution,
        joined-at: block-height,
        claimed: false
      }
    )
    
    ;; Update pool totals
    (map-set pools
      { pool-id: pool-id }
      (merge pool-data {
        total-staked: (+ (get total-staked pool-data) contribution),
        participant-count: (+ (get participant-count pool-data) u1)
      })
    )
    
    ;; Print event
    (print {
      event: "pool-joined",
      pool-id: pool-id,
      participant: tx-sender,
      contribution: contribution
    })
    
    (ok true)
  )
)

;; Add outcome options for bet pools
(define-public (add-pool-outcome (pool-id uint) (outcome-id uint) (description (string-ascii 200)))
  (let 
    (
      (pool-data (unwrap! (get-pool pool-id) ERR-POOL-NOT-FOUND))
    )
    ;; Only pool creator can add outcomes
    (asserts! (is-eq tx-sender (get creator pool-data)) ERR-UNAUTHORIZED)
    ;; Only for bet pools
    (asserts! (is-eq (get pool-type pool-data) POOL-TYPE-BET) ERR-UNAUTHORIZED)
    ;; Pool must be active
    (asserts! (get is-active pool-data) ERR-POOL-EXPIRED)
    
    ;; Add outcome
    (map-set pool-outcomes
      { pool-id: pool-id, outcome-id: outcome-id }
      {
        description: description,
        total-staked: u0,
        participant-count: u0
      }
    )
    
    (print {
      event: "outcome-added",
      pool-id: pool-id,
      outcome-id: outcome-id,
      description: description
    })
    
    (ok true)
  )
)

;; Choose outcome for bet pools
(define-public (choose-outcome (pool-id uint) (outcome-id uint))
  (let 
    (
      (pool-data (unwrap! (get-pool pool-id) ERR-POOL-NOT-FOUND))
      (participant-data (unwrap! (get-participant-info pool-id tx-sender) ERR-UNAUTHORIZED))
      (outcome-data (unwrap! (get-pool-outcome pool-id outcome-id) ERR-POOL-NOT-FOUND))
    )
    ;; Validation
    (asserts! (is-eq (get pool-type pool-data) POOL-TYPE-BET) ERR-UNAUTHORIZED)
    (asserts! (get is-active pool-data) ERR-POOL-EXPIRED)
    (asserts! (<= block-height (get bet-deadline pool-data)) ERR-POOL-EXPIRED)
    
    ;; Set participant's outcome choice
    (map-set participant-outcomes
      { pool-id: pool-id, participant: tx-sender }
      { chosen-outcome: outcome-id }
    )
    
    ;; Update outcome totals
    (map-set pool-outcomes
      { pool-id: pool-id, outcome-id: outcome-id }
      (merge outcome-data {
        total-staked: (+ (get total-staked outcome-data) (get contribution participant-data)),
        participant-count: (+ (get participant-count outcome-data) u1)
      })
    )
    
    (print {
      event: "outcome-chosen",
      pool-id: pool-id,
      participant: tx-sender,
      outcome-id: outcome-id
    })
    
    (ok true)
  )
)

;; Set winning outcome (only pool creator)
(define-public (set-winning-outcome (pool-id uint) (winning-outcome-id uint))
  (let 
    (
      (pool-data (unwrap! (get-pool pool-id) ERR-POOL-NOT-FOUND))
    )
    ;; Only pool creator can set outcome
    (asserts! (is-eq tx-sender (get creator pool-data)) ERR-UNAUTHORIZED)
    ;; Pool must be expired
    (asserts! (> block-height (get bet-deadline pool-data)) ERR-POOL-EXPIRED)
    ;; Outcome must exist
    (asserts! (is-some (get-pool-outcome pool-id winning-outcome-id)) ERR-POOL-NOT-FOUND)
    
    ;; Update pool with winning outcome
    (map-set pools
      { pool-id: pool-id }
      (merge pool-data {
        outcome-set: true,
        winning-outcome: (some winning-outcome-id),
        is-active: false
      })
    )
    
    (print {
      event: "winning-outcome-set",
      pool-id: pool-id,
      winning-outcome: winning-outcome-id
    })
    
    (ok true)
  )
)

;; Update contract fee (only contract owner)
(define-public (set-contract-fee (new-fee uint))
  (begin
    (asserts! (is-eq tx-sender CONTRACT-OWNER) ERR-UNAUTHORIZED)
    (asserts! (<= new-fee u1000) ERR-INVALID-AMOUNT) ;; Max 10%
    (var-set contract-fee-percentage new-fee)
    (ok true)
  )
)