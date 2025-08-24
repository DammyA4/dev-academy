;; CodeDAO - Decentralized Developer Academy Governance Contract
;; Community-driven coding bootcamp with democratic governance and outcome tracking

(define-fungible-token governance-token)

;; Constants
(define-constant contract-owner tx-sender)
(define-constant err-owner-only (err u100))
(define-constant err-not-member (err u101))
(define-constant err-insufficient-tokens (err u102))
(define-constant err-already-voted (err u103))
(define-constant err-proposal-not-found (err u104))
(define-constant err-invalid-data (err u105))
(define-constant err-cohort-not-found (err u106))
(define-constant err-already-enrolled (err u107))

;; Proposal types
(define-constant PROPOSAL-CURRICULUM u1)
(define-constant PROPOSAL-INSTRUCTOR u2)
(define-constant PROPOSAL-FUNDING u3)
(define-constant PROPOSAL-ADMISSION u4)

;; Data Variables
(define-data-var next-proposal-id uint u1)
(define-data-var next-cohort-id uint u1)
(define-data-var min-tokens-for-proposal uint u1000) ;; Min tokens to create proposal
(define-data-var total-dao-members uint u0)
(define-data-var treasury-balance uint u0)

;; Maps
(define-map dao-members principal {tokens: uint, joined-at: uint, reputation: uint, active: bool})
(define-map instructors principal {approved: bool, rating: uint, cohorts-taught: uint})
(define-map proposals
  uint
  {
    proposer: principal,
    proposal-type: uint,
    title: (string-ascii 64),
    description: (string-ascii 256),
    target: (optional principal), ;; for instructor/student proposals
    amount: uint, ;; for funding proposals
    votes-for: uint,
    votes-against: uint,
    voting-ends: uint,
    executed: bool,
    passed: bool
  })

(define-map votes {proposal-id: uint, voter: principal} {vote: bool, tokens-used: uint})
(define-map cohorts
  uint
  {
    instructor: principal,
    curriculum: (string-ascii 64),
    max-students: uint,
    enrolled-count: uint,
    tuition-cost: uint,
    start-date: uint,
    duration-weeks: uint,
    active: bool
  })

(define-map student-enrollments 
  {cohort-id: uint, student: principal}
  {enrolled-at: uint, progress: uint, completed: bool, final-score: uint, job-placement: bool})

(define-map member-cohorts principal (list 10 uint))
(define-map cohort-students uint (list 50 principal))

;; Public Functions

;; Initialize DAO
(define-public (initialize)
  (begin
    (asserts! (is-eq tx-sender contract-owner) err-owner-only)
    (try! (ft-mint? governance-token u10000 contract-owner))
    (map-set dao-members contract-owner {tokens: u10000, joined-at: block-height, reputation: u100, active: true})
    (var-set total-dao-members u1)
    (ok true)))

;; Join DAO (receive initial governance tokens)
(define-public (join-dao)
  (let ((existing-member (map-get? dao-members tx-sender)))
    (asserts! (is-none existing-member) err-already-enrolled)
    (try! (ft-mint? governance-token u100 tx-sender))
    (map-set dao-members tx-sender {tokens: u100, joined-at: block-height, reputation: u50, active: true})
    (var-set total-dao-members (+ (var-get total-dao-members) u1))
    (print {action: "dao-joined", member: tx-sender, tokens: u100})
    (ok true)))

;; Create governance proposal
(define-public (create-proposal 
  (proposal-type uint) 
  (title (string-ascii 64)) 
  (description (string-ascii 256))
  (target (optional principal))
  (amount uint))
  (let ((proposal-id (var-get next-proposal-id))
        (member-info (unwrap! (map-get? dao-members tx-sender) err-not-member)))
    (asserts! (get active member-info) err-not-member)
    (asserts! (>= (get tokens member-info) (var-get min-tokens-for-proposal)) err-insufficient-tokens)
    (asserts! (<= proposal-type PROPOSAL-ADMISSION) err-invalid-data)
    (asserts! (> (len title) u0) err-invalid-data)
    
    (map-set proposals proposal-id {
      proposer: tx-sender,
      proposal-type: proposal-type,
      title: title,
      description: description,
      target: target,
      amount: amount,
      votes-for: u0,
      votes-against: u0,
      voting-ends: (+ block-height u1008), ;; ~1 week
      executed: false,
      passed: false
    })
    
    (var-set next-proposal-id (+ proposal-id u1))
    (print {action: "proposal-created", proposal-id: proposal-id, proposer: tx-sender, type: proposal-type})
    (ok proposal-id)))

;; Vote on proposal (token-weighted voting)
(define-public (vote-on-proposal (proposal-id uint) (support bool))
  (let ((proposal (unwrap! (map-get? proposals proposal-id) err-proposal-not-found))
        (member-info (unwrap! (map-get? dao-members tx-sender) err-not-member))
        (vote-key {proposal-id: proposal-id, voter: tx-sender}))
    (asserts! (get active member-info) err-not-member)
    (asserts! (< block-height (get voting-ends proposal)) err-proposal-not-found)
    (asserts! (is-none (map-get? votes vote-key)) err-already-voted)
    
    (let ((voting-power (get tokens member-info)))
      ;; Record vote
      (map-set votes vote-key {vote: support, tokens-used: voting-power})
      
      ;; Update proposal vote counts
      (if support
        (map-set proposals proposal-id 
          (merge proposal {votes-for: (+ (get votes-for proposal) voting-power)}))
        (map-set proposals proposal-id 
          (merge proposal {votes-against: (+ (get votes-against proposal) voting-power)})))
      
      (print {action: "voted", proposal-id: proposal-id, voter: tx-sender, support: support, power: voting-power})
      (ok true))))

;; Execute passed proposal
(define-public (execute-proposal (proposal-id uint))
  (let ((proposal (unwrap! (map-get? proposals proposal-id) err-proposal-not-found)))
    (asserts! (> block-height (get voting-ends proposal)) err-proposal-not-found)
    (asserts! (not (get executed proposal)) err-already-voted)
    (asserts! (> (get votes-for proposal) (get votes-against proposal)) err-insufficient-tokens)
    
    ;; Mark as executed and passed
    (map-set proposals proposal-id (merge proposal {executed: true, passed: true}))
    
    ;; Execute based on proposal type
    (if (is-eq (get proposal-type proposal) PROPOSAL-INSTRUCTOR)
      (match (get target proposal)
        instructor (map-set instructors instructor {approved: true, rating: u5, cohorts-taught: u0})
        true)
      true)
    
    (print {action: "proposal-executed", proposal-id: proposal-id, type: (get proposal-type proposal)})
    (ok true)))

;; Create new cohort (approved instructors only)
(define-public (create-cohort 
  (curriculum (string-ascii 64)) 
  (max-students uint) 
  (tuition-cost uint)
  (duration-weeks uint))
  (let ((cohort-id (var-get next-cohort-id))
        (instructor-info (unwrap! (map-get? instructors tx-sender) err-not-member)))
    (asserts! (get approved instructor-info) err-not-member)
    (asserts! (> max-students u0) err-invalid-data)
    (asserts! (> duration-weeks u0) err-invalid-data)
    
    (map-set cohorts cohort-id {
      instructor: tx-sender,
      curriculum: curriculum,
      max-students: max-students,
      enrolled-count: u0,
      tuition-cost: tuition-cost,
      start-date: (+ block-height u144), ;; Start in ~1 day
      duration-weeks: duration-weeks,
      active: true
    })
    
    (var-set next-cohort-id (+ cohort-id u1))
    (print {action: "cohort-created", cohort-id: cohort-id, instructor: tx-sender, curriculum: curriculum})
    (ok cohort-id)))

;; Enroll in cohort
(define-public (enroll-in-cohort (cohort-id uint))
  (let ((cohort (unwrap! (map-get? cohorts cohort-id) err-cohort-not-found))
        (enrollment-key {cohort-id: cohort-id, student: tx-sender}))
    (asserts! (get active cohort) err-cohort-not-found)
    (asserts! (< (get enrolled-count cohort) (get max-students cohort)) err-cohort-not-found)
    (asserts! (is-none (map-get? student-enrollments enrollment-key)) err-already-enrolled)
    
    ;; Record enrollment
    (map-set student-enrollments enrollment-key {
      enrolled-at: block-height,
      progress: u0,
      completed: false,
      final-score: u0,
      job-placement: false
    })
    
    ;; Update cohort enrollment count
    (map-set cohorts cohort-id (merge cohort {enrolled-count: (+ (get enrolled-count cohort) u1)}))
    
    ;; Update tracking maps
    (map-set member-cohorts tx-sender
      (unwrap-panic (as-max-len? (append (get-member-cohorts tx-sender) cohort-id) u10)))
    (map-set cohort-students cohort-id
      (unwrap-panic (as-max-len? (append (get-cohort-students cohort-id) tx-sender) u50)))
    
    ;; Award governance tokens for enrollment
    (try! (ft-mint? governance-token u50 tx-sender))
    (match (map-get? dao-members tx-sender)
      member-info (map-set dao-members tx-sender 
        (merge member-info {tokens: (+ (get tokens member-info) u50)}))
      (map-set dao-members tx-sender {tokens: u50, joined-at: block-height, reputation: u25, active: true}))
    
    (print {action: "enrolled", cohort-id: cohort-id, student: tx-sender, tuition: (get tuition-cost cohort)})
    (ok true)))

;; Update student progress (instructor only)
(define-public (update-student-progress (cohort-id uint) (student principal) (progress uint) (final-score uint))
  (let ((cohort (unwrap! (map-get? cohorts cohort-id) err-cohort-not-found))
        (enrollment-key {cohort-id: cohort-id, student: student})
        (enrollment (unwrap! (map-get? student-enrollments enrollment-key) err-not-member)))
    (asserts! (is-eq tx-sender (get instructor cohort)) err-not-member)
    (asserts! (<= progress u100) err-invalid-data)
    (asserts! (<= final-score u100) err-invalid-data)
    
    (let ((completed (>= progress u100)))
      (map-set student-enrollments enrollment-key (merge enrollment {
        progress: progress,
        final-score: final-score,
        completed: completed
      }))
      
      ;; Award bonus tokens for completion
      (if completed
        (begin
          (try! (ft-mint? governance-token u200 student))
          (match (map-get? dao-members student)
            member-info (map-set dao-members student 
              (merge member-info {
                tokens: (+ (get tokens member-info) u200),
                reputation: (+ (get reputation member-info) u25)
              }))
            true))
        true)
      
      (print {action: "progress-updated", cohort-id: cohort-id, student: student, progress: progress, completed: completed})
      (ok completed))))

;; Record job placement (instructor only)
(define-public (record-job-placement (cohort-id uint) (student principal))
  (let ((cohort (unwrap! (map-get? cohorts cohort-id) err-cohort-not-found))
        (enrollment-key {cohort-id: cohort-id, student: student})
        (enrollment (unwrap! (map-get? student-enrollments enrollment-key) err-not-member)))
    (asserts! (is-eq tx-sender (get instructor cohort)) err-not-member)
    (asserts! (get completed enrollment) err-invalid-data)
    
    (map-set student-enrollments enrollment-key (merge enrollment {job-placement: true}))
    
    ;; Reward both student and instructor for successful placement
    (try! (ft-mint? governance-token u300 student))
    (try! (ft-mint? governance-token u100 tx-sender))
    
    (print {action: "job-placement", cohort-id: cohort-id, student: student, instructor: tx-sender})
    (ok true)))

;; Read-only Functions

;; Get DAO member info
(define-read-only (get-dao-member (member principal))
  (map-get? dao-members member))

;; Get proposal details
(define-read-only (get-proposal (proposal-id uint))
  (map-get? proposals proposal-id))

;; Get cohort details
(define-read-only (get-cohort (cohort-id uint))
  (map-get? cohorts cohort-id))

;; Get student enrollment
(define-read-only (get-enrollment (cohort-id uint) (student principal))
  (map-get? student-enrollments {cohort-id: cohort-id, student: student}))

;; Get member's cohorts
(define-read-only (get-member-cohorts (member principal))
  (default-to (list) (map-get? member-cohorts member)))

;; Get cohort students
(define-read-only (get-cohort-students (cohort-id uint))
  (default-to (list) (map-get? cohort-students cohort-id)))

;; Get instructor info
(define-read-only (get-instructor (instructor principal))
  (map-get? instructors instructor))

;; Calculate cohort success rate
(define-read-only (get-cohort-success-rate (cohort-id uint))
  (let ((students (get-cohort-students cohort-id))
        (total-students (len students)))
    (if (> total-students u0)
      (let ((completion-data (fold calculate-completion-rate students {completed: u0, total: total-students, cohort-id: cohort-id})))
        {
          completion-rate: (if (> (get total completion-data) u0) 
                             (/ (* (get completed completion-data) u100) (get total completion-data)) 
                             u0),
          placement-rate: u0
        })
      {completion-rate: u0, placement-rate: u0})))

;; Helper function for success rate calculation
(define-private (calculate-completion-rate 
  (student principal) 
  (context {completed: uint, total: uint, cohort-id: uint}))
  (match (map-get? student-enrollments {cohort-id: (get cohort-id context), student: student})
    enrollment (if (get completed enrollment)
      {completed: (+ (get completed context) u1), total: (get total context), cohort-id: (get cohort-id context)}
      context)
    context))

;; Get DAO statistics
(define-read-only (get-dao-stats)
  {
    total-members: (var-get total-dao-members),
    total-proposals: (- (var-get next-proposal-id) u1),
    total-cohorts: (- (var-get next-cohort-id) u1),
    treasury-balance: (var-get treasury-balance),
    min-proposal-tokens: (var-get min-tokens-for-proposal)
  })