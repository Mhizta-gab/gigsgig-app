use aiken/collection/list
use aiken/collection/dict
use aiken/crypto.{VerificationKeyHash}
use aiken/interval.{Finite}
use aiken/primitive/bytearray.{starts_with}
use cardano/address
use cardano/assets.{PolicyId, Value, from_lovelace, lovelace_of, tokens, add}
use cardano/transaction.{Input, Output, OutputReference, Transaction}
use mocktail.{
  complete, invalid_before, invalid_hereafter, mock_pub_key_address,
  mock_pub_key_hash, mock_utxo_ref, mocktail_tx, set_fee, tx_out, tx_in,
  mock_policy_id,
}

// =============================================================================
// TYPES
// =============================================================================

/// Task status in the lifecycle
pub type TaskStatus {
  Open        // Posted, awaiting worker assignment
  Assigned    // Worker assigned, work in progress
  Completed   // Worker marked complete, awaiting approval
}

/// Main datum for task escrow
pub type TaskDatum {
  task_id: Int,                                // Unique task identifier
  worker: Option<VerificationKeyHash>,         // Assigned worker (None = unassigned)
  payment_amount: Int,                         // Payment in lovelace
  deadline: Int,                               // POSIX timestamp (milliseconds)
  status: TaskStatus,                          // Current state
  created_at: Int,                             // Creation timestamp
  identity_policy_id: PolicyId,                // Policy ID for identity NFTs
}

/// Actions for task escrow
pub type TaskAction {
  CancelTask                                          // Tasker cancels before assignment
  AssignWorker { worker: VerificationKeyHash }       // Tasker assigns worker
  MarkComplete                                        // Worker marks complete
  ReleasePay                                          // Tasker approves and pays
  TimeoutRefund                                       // Auto-refund if deadline passed
  TimeoutRelease                                      // Auto-pay after grace period
}

/// Redeemer wraps action with task_id
pub type TaskRedeemer {
  task_id: Int,
  action: TaskAction,
}

// =============================================================================
// CONSTANTS
// =============================================================================

/// Platform fee percentage (5%)
const platform_fee_percentage: Int = 5

/// Grace period after completion (7 days in milliseconds)
const grace_period_ms: Int = 7 * 24 * 60 * 60 * 1000

/// Minimum task payment (5 ADA)
pub const min_payment: Int = 5_000_000

// Platform address is now passed as a validator parameter (see validator definition below)

/// Identity token name prefixes
fn tasker_token_prefix() -> ByteArray {
  "GigsTasker"
}

fn worker_token_prefix() -> ByteArray {
  "GigsWorker"
}

// =============================================================================
// HELPER FUNCTIONS
// =============================================================================

/// Calculate platform fee (5% of payment)
fn calculate_platform_fee(payment_amount: Int) -> Int {
  payment_amount * platform_fee_percentage / 100
}

/// Calculate worker payment (95% of payment)
fn calculate_worker_payment(payment_amount: Int) -> Int {
  payment_amount - calculate_platform_fee(payment_amount)
}

/// Check if public key hash signed the transaction
fn must_be_signed_by(
  signer: VerificationKeyHash,
  signatories: List<VerificationKeyHash>,
) -> Bool {
  list.has(signatories, signer)
}

/// Get current time from transaction validity range
fn get_current_time(transaction: Transaction) -> Int {
  when transaction.validity_range.lower_bound.bound_type is {
    Finite(time) -> time
    _ -> fail @"Invalid transaction validity range"
  }
}

/// Check if deadline has passed
fn is_past_deadline(current_time: Int, deadline: Int) -> Bool {
  current_time >= deadline
}

/// Check if grace period has passed after completion
fn is_grace_period_passed(current_time: Int, deadline: Int) -> Bool {
  current_time >= deadline + grace_period_ms
}

/// Validate payment to address with minimum amount
fn validate_payment_to_address(
  transaction: Transaction,
  recipient: VerificationKeyHash,
  min_amount: Int,
) -> Bool {
  list.any(
    transaction.outputs,
    fn(output) {
      let pays_to_recipient =
        when output.address.payment_credential is {
          address.VerificationKey(vkh) -> vkh == recipient
          _ -> False
        }
      let has_sufficient_value = lovelace_of(output.value) >= min_amount
      pays_to_recipient && has_sufficient_value
    },
  )
}

/// Validate payment distribution (worker + platform)
fn validate_payment_distribution(
  transaction: Transaction,
  worker_pkh: VerificationKeyHash,
  platform_pkh: VerificationKeyHash,
  payment_amount: Int,
) -> Bool {
  let worker_payment = calculate_worker_payment(payment_amount)
  let platform_fee = calculate_platform_fee(payment_amount)
  
  // Check worker receives correct amount
  let worker_paid = validate_payment_to_address(transaction, worker_pkh, worker_payment)
  
  // Check platform receives fee
  let platform_paid = validate_payment_to_address(transaction, platform_pkh, platform_fee)
  
  worker_paid && platform_paid
}

/// Validate output exists with minimum Ada
fn validate_output_exists(transaction: Transaction, min_ada: Int) -> Bool {
  list.any(
    transaction.outputs,
    fn(output) { lovelace_of(output.value) >= min_ada },
  )
}

/// Check if an address holds a token with specific prefix
fn has_identity_token(
  inputs: List<Input>,
  pkh: VerificationKeyHash,
  policy_id: PolicyId,
  token_prefix: ByteArray,
) -> Bool {
  list.any(
    inputs,
    fn(input) {
      // Check if input belongs to the user
      let belongs_to_user =
        when input.output.address.payment_credential is {
          address.VerificationKey(vkh) -> vkh == pkh
          _ -> False
        }
      
      // Check if input contains identity token
      let has_token =
        if belongs_to_user {
          let token_pairs = 
            input.output.value
              |> tokens(policy_id)
              |> dict.to_pairs()
          
          list.any(
            token_pairs,
            fn(pair) {
              let Pair(token_name, amount) = pair
              starts_with(token_name, token_prefix) && amount > 0
            },
          )
        } else {
          False
        }
      
      belongs_to_user && has_token
    },
  )
}

/// Verify tasker has GigsTasker NFT
fn verify_tasker_identity(
  transaction: Transaction,
  tasker_pkh: VerificationKeyHash,
  policy_id: PolicyId,
) -> Bool {
  has_identity_token(
    transaction.inputs,
    tasker_pkh,
    policy_id,
    tasker_token_prefix(),
  )
}

/// Verify worker has GigsWorker NFT
fn verify_worker_identity(
  transaction: Transaction,
  worker_pkh: VerificationKeyHash,
  policy_id: PolicyId,
) -> Bool {
  has_identity_token(
    transaction.inputs,
    worker_pkh,
    policy_id,
    worker_token_prefix(),
  )
}

// =============================================================================
// VALIDATION FUNCTIONS
// =============================================================================

/// Validate task cancellation
fn validate_cancel_task(
  datum: TaskDatum,
  tasker_pkh: VerificationKeyHash,
  transaction: Transaction,
) -> Bool {
  // Must be signed by tasker
  must_be_signed_by(tasker_pkh, transaction.extra_signatories) &&
  // Tasker must have identity NFT
  verify_tasker_identity(transaction, tasker_pkh, datum.identity_policy_id) &&
  // Task must be Open (not assigned yet)
  datum.status == Open &&
  // Refund to tasker
  validate_payment_to_address(transaction, tasker_pkh, datum.payment_amount)
}

/// Validate worker assignment
fn validate_assign_worker(
  datum: TaskDatum,
  tasker_pkh: VerificationKeyHash,
  worker_pkh: VerificationKeyHash,
  transaction: Transaction,
) -> Bool {
  // Must be signed by tasker
  must_be_signed_by(tasker_pkh, transaction.extra_signatories) &&
  // Tasker must have identity NFT
  verify_tasker_identity(transaction, tasker_pkh, datum.identity_policy_id) &&
  // Worker must have identity NFT
  verify_worker_identity(transaction, worker_pkh, datum.identity_policy_id) &&
  // Current status must be Open
  datum.status == Open &&
  // Worker field must be None
  datum.worker == None &&
  // Output with updated state exists (simplified - just check output exists)
  validate_output_exists(transaction, datum.payment_amount)
}

/// Validate mark complete
fn validate_mark_complete(datum: TaskDatum, transaction: Transaction) -> Bool {
  expect Some(worker_pkh) = datum.worker
  
  // Must be signed by worker
  must_be_signed_by(worker_pkh, transaction.extra_signatories) &&
  // Worker must have identity NFT
  verify_worker_identity(transaction, worker_pkh, datum.identity_policy_id) &&
  // Current status must be Assigned
  datum.status == Assigned &&
  // Output exists to continue escrow
  validate_output_exists(transaction, datum.payment_amount)
}

/// Validate payment release
fn validate_release_pay(
  datum: TaskDatum,
  tasker_pkh: VerificationKeyHash,
  platform_pkh: VerificationKeyHash,
  transaction: Transaction,
) -> Bool {
  expect Some(worker_pkh) = datum.worker
  
  // Must be signed by tasker
  must_be_signed_by(tasker_pkh, transaction.extra_signatories) &&
  // Tasker must have identity NFT
  verify_tasker_identity(transaction, tasker_pkh, datum.identity_policy_id) &&
  // Current status must be Completed
  datum.status == Completed &&
  // Validate payment distribution (95% worker, 5% platform)
  validate_payment_distribution(transaction, worker_pkh, platform_pkh, datum.payment_amount)
}

/// Validate timeout refund
fn validate_timeout_refund(
  datum: TaskDatum,
  tasker_pkh: VerificationKeyHash,
  transaction: Transaction,
) -> Bool {
  let current_time = get_current_time(transaction)
  
  // Status must be Assigned (work not completed)
  datum.status == Assigned &&
  // Deadline must have passed
  is_past_deadline(current_time, datum.deadline) &&
  // Refund to tasker (no identity check needed for timeout)
  validate_payment_to_address(transaction, tasker_pkh, datum.payment_amount)
}

/// Validate timeout release
fn validate_timeout_release(
  datum: TaskDatum,
  platform_pkh: VerificationKeyHash,
  transaction: Transaction,
) -> Bool {
  expect Some(worker_pkh) = datum.worker
  let current_time = get_current_time(transaction)
  
  // Status must be Completed
  datum.status == Completed &&
  // Grace period must have passed
  is_grace_period_passed(current_time, datum.deadline) &&
  // Validate payment distribution (no identity check needed for timeout)
  validate_payment_distribution(transaction, worker_pkh, platform_pkh, datum.payment_amount)
}

// =============================================================================
// MAIN VALIDATOR
// =============================================================================

/// Parameterized validator with tasker's verification key hash and platform address
/// 
/// Parameters:
/// - tasker_pkh: Ensures each escrow UTXO is uniquely bound to its tasker,
///   preventing cross-task attacks and ensuring proper authorization
/// - platform_pkh: The platform's payment credential for receiving fees,
///   set once during deployment and immutable thereafter
validator gigs_escrow(tasker_pkh: VerificationKeyHash, platform_pkh: VerificationKeyHash) {
  spend(
    datum: Option<TaskDatum>,
    redeemer: TaskRedeemer,
    _utxo_ref: OutputReference,
    transaction: Transaction,
  ) {
    expect Some(datum) = datum
    
    // Verify task_id matches
    expect datum.task_id == redeemer.task_id
    
    // Route to appropriate validation
    when redeemer.action is {
      CancelTask -> validate_cancel_task(datum, tasker_pkh, transaction)
      
      AssignWorker { worker } -> 
        validate_assign_worker(datum, tasker_pkh, worker, transaction)
      
      MarkComplete -> 
        validate_mark_complete(datum, transaction)
      
      ReleasePay -> 
        validate_release_pay(datum, tasker_pkh, platform_pkh, transaction)
      
      TimeoutRefund -> 
        validate_timeout_refund(datum, tasker_pkh, transaction)
      
      TimeoutRelease -> 
        validate_timeout_release(datum, platform_pkh, transaction)
    }
  }

  else(_) {
    fail @"Invalid script purpose"
  }
}

// =============================================================================
// TEST HELPERS
// =============================================================================

/// Create base task datum for testing
fn create_test_task_datum(
  task_id: Int,
  payment_amount: Int,
  status: TaskStatus,
  worker: Option<VerificationKeyHash>,
  policy_id: PolicyId,
) -> TaskDatum {
  let current_time = 1_700_000_000_000
  TaskDatum {
    task_id,
    worker,
    payment_amount,
    deadline: current_time + 30 * 24 * 60 * 60 * 1000, // 30 days
    status,
    created_at: current_time,
    identity_policy_id: policy_id,
  }
}

/// Create value with identity NFT
fn create_identity_nft_value(
  policy_id: PolicyId,
  token_name: ByteArray,
  ada_amount: Int,
) -> Value {
  from_lovelace(ada_amount)
    |> add(policy_id, token_name, 1)
}

/// Create transaction with identity NFTs for tasker
fn create_tx_with_tasker_identity(
  signatories: List<VerificationKeyHash>,
  outputs_ada: List<Int>,
  policy_id: PolicyId,
) -> Transaction {
  let lower_bound = 1_700_000_000_000
  let upper_bound = lower_bound + 10_000

  // Create tasker's identity NFT input
  let tasker_nft_value = create_identity_nft_value(policy_id, "GigsTasker00001", 2_000_000)

  let mut_tx =
    mocktail_tx()
      |> tx_in(
          True,
          #"00",
          0,
          tasker_nft_value,
          mock_pub_key_address(0, None), // tasker address
        )
      |> invalid_before(True, lower_bound)
      |> invalid_hereafter(True, upper_bound)

  let tx_with_outputs =
    list.foldr(
      outputs_ada,
      mut_tx,
      fn(ada_amount, tx_acc) {
        tx_acc
          |> tx_out(
              True,
              mock_pub_key_address(0, None),
              from_lovelace(ada_amount),
            )
      },
    )

  let completed_tx = tx_with_outputs |> complete()
  let tx_with_fee = completed_tx |> set_fee(True, 2_000_000)

  Transaction { ..tx_with_fee, extra_signatories: signatories }
}

/// Create transaction with identity NFTs for both tasker and worker
fn create_tx_with_both_identities(
  signatories: List<VerificationKeyHash>,
  outputs_ada: List<Int>,
  policy_id: PolicyId,
) -> Transaction {
  let lower_bound = 1_700_000_000_000
  let upper_bound = lower_bound + 10_000

  // Create tasker's identity NFT input
  let tasker_nft_value = create_identity_nft_value(policy_id, "GigsTasker00001", 2_000_000)
  
  // Create worker's identity NFT input
  let worker_nft_value = create_identity_nft_value(policy_id, "GigsWorker00001", 2_000_000)

  let mut_tx =
    mocktail_tx()
      |> tx_in(
          True,
          #"00",
          0,
          tasker_nft_value,
          mock_pub_key_address(0, None), // tasker address
        )
      |> tx_in(
          True,
          #"01",
          0,
          worker_nft_value,
          mock_pub_key_address(1, None), // worker address
        )
      |> invalid_before(True, lower_bound)
      |> invalid_hereafter(True, upper_bound)

  let tx_with_outputs =
    list.foldr(
      outputs_ada,
      mut_tx,
      fn(ada_amount, tx_acc) {
        tx_acc
          |> tx_out(
              True,
              mock_pub_key_address(0, None),
              from_lovelace(ada_amount),
            )
      },
    )

  let completed_tx = tx_with_outputs |> complete()
  let tx_with_fee = completed_tx |> set_fee(True, 2_000_000)

  Transaction { ..tx_with_fee, extra_signatories: signatories }
}

/// Create transaction with worker identity NFT
fn create_tx_with_worker_identity(
  signatories: List<VerificationKeyHash>,
  outputs_ada: List<Int>,
  policy_id: PolicyId,
) -> Transaction {
  let lower_bound = 1_700_000_000_000
  let upper_bound = lower_bound + 10_000

  // Create worker's identity NFT input
  let worker_nft_value = create_identity_nft_value(policy_id, "GigsWorker00001", 2_000_000)

  let mut_tx =
    mocktail_tx()
      |> tx_in(
          True,
          #"01",
          0,
          worker_nft_value,
          mock_pub_key_address(1, None), // worker address
        )
      |> invalid_before(True, lower_bound)
      |> invalid_hereafter(True, upper_bound)

  let tx_with_outputs =
    list.foldr(
      outputs_ada,
      mut_tx,
      fn(ada_amount, tx_acc) {
        tx_acc
          |> tx_out(
              True,
              mock_pub_key_address(1, None),
              from_lovelace(ada_amount),
            )
      },
    )

  let completed_tx = tx_with_outputs |> complete()
  let tx_with_fee = completed_tx |> set_fee(True, 2_000_000)

  Transaction { ..tx_with_fee, extra_signatories: signatories }
}

// =============================================================================
// TESTS
// =============================================================================

/// Test: Cancel task successfully with tasker identity NFT
test cancel_task_success() {
  let policy_id = mock_policy_id(0)
  let tasker_pkh = mock_pub_key_hash(0)
  let platform_pkh = mock_pub_key_hash(5)
  
  let tx = create_tx_with_tasker_identity(
    [tasker_pkh], // tasker signature
    [50_000_000], // refund output
    policy_id,
  )

  let datum = Some(create_test_task_datum(1, 50_000_000, Open, None, policy_id))
  let redeemer = TaskRedeemer { task_id: 1, action: CancelTask }

  gigs_escrow.spend(tasker_pkh, platform_pkh, datum, redeemer, mock_utxo_ref(0, 0), tx)
}

/// Test: Cancel task fails without tasker identity NFT
test cancel_task_fail_no_identity() fail {
  let policy_id = mock_policy_id(0)
  let tasker_pkh = mock_pub_key_hash(0)
  let platform_pkh = mock_pub_key_hash(5)
  
  // Transaction without identity NFT
  let tx =
    mocktail_tx()
      |> tx_in(
          True,
          #"00",
          0,
          from_lovelace(2_000_000),
          mock_pub_key_address(0, None),
        )
      |> tx_out(
          True,
          mock_pub_key_address(0, None),
          from_lovelace(50_000_000),
        )
      |> invalid_before(True, 1_700_000_000_000)
      |> invalid_hereafter(True, 1_700_000_010_000)
      |> complete()
      |> set_fee(True, 2_000_000)
  
  let tx_with_sig = Transaction { ..tx, extra_signatories: [tasker_pkh] }

  let datum = Some(create_test_task_datum(1, 50_000_000, Open, None, policy_id))
  let redeemer = TaskRedeemer { task_id: 1, action: CancelTask }

  gigs_escrow.spend(tasker_pkh, platform_pkh, datum, redeemer, mock_utxo_ref(0, 0), tx_with_sig)
}

/// Test: Cancel task fails when already assigned
test cancel_task_fail_already_assigned() fail {
  let policy_id = mock_policy_id(0)
  let tasker_pkh = mock_pub_key_hash(0)
  let platform_pkh = mock_pub_key_hash(5)
  
  let tx = create_tx_with_tasker_identity(
    [tasker_pkh],
    [50_000_000],
    policy_id,
  )

  let datum = Some(create_test_task_datum(1, 50_000_000, Assigned, Some(mock_pub_key_hash(1)), policy_id))
  let redeemer = TaskRedeemer { task_id: 1, action: CancelTask }

  gigs_escrow.spend(tasker_pkh, platform_pkh, datum, redeemer, mock_utxo_ref(0, 0), tx)
}

/// Test: Assign worker successfully with both identities
test assign_worker_success() {
  let policy_id = mock_policy_id(0)
  let tasker_pkh = mock_pub_key_hash(0)
  let platform_pkh = mock_pub_key_hash(5)
  let worker_pkh = mock_pub_key_hash(1)
  
  let tx = create_tx_with_both_identities(
    [tasker_pkh], // tasker signature
    [50_000_000], // continuation output
    policy_id,
  )

  let datum = Some(create_test_task_datum(1, 50_000_000, Open, None, policy_id))
  let redeemer = TaskRedeemer { task_id: 1, action: AssignWorker { worker: worker_pkh } }

  gigs_escrow.spend(tasker_pkh, platform_pkh, datum, redeemer, mock_utxo_ref(0, 0), tx)
}

/// Test: Assign worker fails without worker identity NFT
test assign_worker_fail_no_worker_identity() fail {
  let policy_id = mock_policy_id(0)
  let tasker_pkh = mock_pub_key_hash(0)
  let platform_pkh = mock_pub_key_hash(5)
  let worker_pkh = mock_pub_key_hash(1)
  
  // Only tasker identity, no worker identity
  let tx = create_tx_with_tasker_identity(
    [tasker_pkh],
    [50_000_000],
    policy_id,
  )

  let datum = Some(create_test_task_datum(1, 50_000_000, Open, None, policy_id))
  let redeemer = TaskRedeemer { task_id: 1, action: AssignWorker { worker: worker_pkh } }

  gigs_escrow.spend(tasker_pkh, platform_pkh, datum, redeemer, mock_utxo_ref(0, 0), tx)
}

/// Test: Assign worker fails when not tasker
test assign_worker_fail_not_tasker() fail {
  let policy_id = mock_policy_id(0)
  let tasker_pkh = mock_pub_key_hash(0)
  let platform_pkh = mock_pub_key_hash(5)
  let worker_pkh = mock_pub_key_hash(1)
  
  let tx = create_tx_with_both_identities(
    [mock_pub_key_hash(5)], // wrong signature
    [50_000_000],
    policy_id,
  )

  let datum = Some(create_test_task_datum(1, 50_000_000, Open, None, policy_id))
  let redeemer = TaskRedeemer { task_id: 1, action: AssignWorker { worker: worker_pkh } }

  gigs_escrow.spend(tasker_pkh, platform_pkh, datum, redeemer, mock_utxo_ref(0, 0), tx)
}

/// Test: Mark complete successfully with worker identity
test mark_complete_success() {
  let policy_id = mock_policy_id(0)
  let tasker_pkh = mock_pub_key_hash(0)
  let platform_pkh = mock_pub_key_hash(5)
  let worker_pkh = mock_pub_key_hash(1)
  
  let tx = create_tx_with_worker_identity(
    [worker_pkh], // worker signature
    [50_000_000], // continuation output
    policy_id,
  )

  let datum = Some(create_test_task_datum(1, 50_000_000, Assigned, Some(worker_pkh), policy_id))
  let redeemer = TaskRedeemer { task_id: 1, action: MarkComplete }

  gigs_escrow.spend(tasker_pkh, platform_pkh, datum, redeemer, mock_utxo_ref(0, 0), tx)
}

/// Test: Mark complete fails without worker identity NFT
test mark_complete_fail_no_identity() fail {
  let policy_id = mock_policy_id(0)
  let tasker_pkh = mock_pub_key_hash(0)
  let platform_pkh = mock_pub_key_hash(5)
  let worker_pkh = mock_pub_key_hash(1)
  
  // Transaction without identity NFT
  let tx =
    mocktail_tx()
      |> tx_in(
          True,
          #"01",
          0,
          from_lovelace(2_000_000),
          mock_pub_key_address(1, None),
        )
      |> tx_out(
          True,
          mock_pub_key_address(1, None),
          from_lovelace(50_000_000),
        )
      |> invalid_before(True, 1_700_000_000_000)
      |> invalid_hereafter(True, 1_700_000_010_000)
      |> complete()
      |> set_fee(True, 2_000_000)
  
  let tx_with_sig = Transaction { ..tx, extra_signatories: [worker_pkh] }

  let datum = Some(create_test_task_datum(1, 50_000_000, Assigned, Some(worker_pkh), policy_id))
  let redeemer = TaskRedeemer { task_id: 1, action: MarkComplete }

  gigs_escrow.spend(tasker_pkh, platform_pkh, datum, redeemer, mock_utxo_ref(0, 0), tx_with_sig)
}

/// Test: Release payment successfully with tasker identity
test release_pay_success() {
  let policy_id = mock_policy_id(0)
  let tasker_pkh = mock_pub_key_hash(0)
  let platform_pkh = mock_pub_key_hash(5)
  let worker_pkh = mock_pub_key_hash(1)
  let payment = 50_000_000
  let worker_payment = calculate_worker_payment(payment)
  let platform_fee = calculate_platform_fee(payment)
  
  let lower_bound = 1_700_000_000_000
  let upper_bound = lower_bound + 10_000
  
  // Create tasker's identity NFT input
  let tasker_nft_value = create_identity_nft_value(policy_id, "GigsTasker00001", 2_000_000)
  
  let tx =
    mocktail_tx()
      |> tx_in(
          True,
          #"00",
          0,
          tasker_nft_value,
          mock_pub_key_address(0, None),
        )
      |> tx_out(True, mock_pub_key_address(1, None), from_lovelace(worker_payment)) // worker payment
      |> tx_out(True, mock_pub_key_address(5, None), from_lovelace(platform_fee))   // platform fee
      |> tx_out(True, mock_pub_key_address(0, None), from_lovelace(2_000_000))      // tasker change with NFT
      |> invalid_before(True, lower_bound)
      |> invalid_hereafter(True, upper_bound)
      |> complete()
      |> set_fee(True, 2_000_000)
  
  let tx_with_signatories = Transaction { ..tx, extra_signatories: [tasker_pkh] }

  let datum = Some(create_test_task_datum(1, payment, Completed, Some(worker_pkh), policy_id))
  let redeemer = TaskRedeemer { task_id: 1, action: ReleasePay }

  gigs_escrow.spend(tasker_pkh, platform_pkh, datum, redeemer, mock_utxo_ref(0, 0), tx_with_signatories)
}

/// Test: Release payment fails without tasker identity
test release_pay_fail_no_identity() fail {
  let policy_id = mock_policy_id(0)
  let tasker_pkh = mock_pub_key_hash(0)
  let platform_pkh = mock_pub_key_hash(5)
  let worker_pkh = mock_pub_key_hash(1)
  let payment = 50_000_000
  let worker_payment = calculate_worker_payment(payment)
  let platform_fee = calculate_platform_fee(payment)
  
  let lower_bound = 1_700_000_000_000
  let upper_bound = lower_bound + 10_000
  
  let tx =
    mocktail_tx()
      |> tx_in(
          True,
          #"00",
          0,
          from_lovelace(2_000_000), // No identity NFT
          mock_pub_key_address(0, None),
        )
      |> tx_out(True, mock_pub_key_address(1, None), from_lovelace(worker_payment))
      |> tx_out(True, mock_pub_key_address(5, None), from_lovelace(platform_fee))
      |> invalid_before(True, lower_bound)
      |> invalid_hereafter(True, upper_bound)
      |> complete()
      |> set_fee(True, 2_000_000)
  
  let tx_with_signatories = Transaction { ..tx, extra_signatories: [tasker_pkh] }

  let datum = Some(create_test_task_datum(1, payment, Completed, Some(worker_pkh), policy_id))
  let redeemer = TaskRedeemer { task_id: 1, action: ReleasePay }

  gigs_escrow.spend(tasker_pkh, platform_pkh, datum, redeemer, mock_utxo_ref(0, 0), tx_with_signatories)
}

/// Test: Timeout refund successfully (no identity check needed)
test timeout_refund_success() {
  let policy_id = mock_policy_id(0)
  let tasker_pkh = mock_pub_key_hash(0)
  let platform_pkh = mock_pub_key_hash(5)
  let worker_pkh = mock_pub_key_hash(1)
  let payment = 50_000_000
  let past_deadline = 1_700_000_000_000 + 31 * 24 * 60 * 60 * 1000 // 31 days (past deadline)
  
  let tx =
    mocktail_tx()
      |> tx_out(True, mock_pub_key_address(0, None), from_lovelace(payment)) // refund to tasker
      |> invalid_before(True, past_deadline)
      |> invalid_hereafter(True, past_deadline + 10_000)
      |> complete()
      |> set_fee(True, 2_000_000)
  
  let tx_with_signatories =
    Transaction { ..tx, extra_signatories: [] } // No signature needed for timeout

  let datum = Some(create_test_task_datum(1, payment, Assigned, Some(worker_pkh), policy_id))
  let redeemer = TaskRedeemer { task_id: 1, action: TimeoutRefund }

  gigs_escrow.spend(tasker_pkh, platform_pkh, datum, redeemer, mock_utxo_ref(0, 0), tx_with_signatories)
}

/// Test: Timeout refund fails before deadline
test timeout_refund_fail_before_deadline() fail {
  let policy_id = mock_policy_id(0)
  let tasker_pkh = mock_pub_key_hash(0)
  let platform_pkh = mock_pub_key_hash(5)
  let worker_pkh = mock_pub_key_hash(1)
  let payment = 50_000_000
  let before_deadline = 1_700_000_000_000 + 10 * 24 * 60 * 60 * 1000 // 10 days (before deadline)
  
  let tx =
    mocktail_tx()
      |> tx_out(True, mock_pub_key_address(0, None), from_lovelace(payment))
      |> invalid_before(True, before_deadline)
      |> invalid_hereafter(True, before_deadline + 10_000)
      |> complete()
      |> set_fee(True, 2_000_000)
  
  let tx_with_signatories =
    Transaction { ..tx, extra_signatories: [] }

  let datum = Some(create_test_task_datum(1, payment, Assigned, Some(worker_pkh), policy_id))
  let redeemer = TaskRedeemer { task_id: 1, action: TimeoutRefund }

  gigs_escrow.spend(tasker_pkh, platform_pkh, datum, redeemer, mock_utxo_ref(0, 0), tx_with_signatories)
}

/// Test: Timeout release successfully (no identity check needed)
test timeout_release_success() {
  let policy_id = mock_policy_id(0)
  let tasker_pkh = mock_pub_key_hash(0)
  let platform_pkh = mock_pub_key_hash(5)
  let worker_pkh = mock_pub_key_hash(1)
  let payment = 50_000_000
  let worker_payment = calculate_worker_payment(payment)
  let platform_fee = calculate_platform_fee(payment)
  let past_grace_period = 1_700_000_000_000 + 38 * 24 * 60 * 60 * 1000 // 38 days (past grace period)
  
  let tx =
    mocktail_tx()
      |> tx_out(True, mock_pub_key_address(1, None), from_lovelace(worker_payment)) // worker payment
      |> tx_out(True, mock_pub_key_address(5, None), from_lovelace(platform_fee))   // platform fee
      |> invalid_before(True, past_grace_period)
      |> invalid_hereafter(True, past_grace_period + 10_000)
      |> complete()
      |> set_fee(True, 2_000_000)
  
  let tx_with_signatories =
    Transaction { ..tx, extra_signatories: [] } // No signature needed

  let datum = Some(create_test_task_datum(1, payment, Completed, Some(worker_pkh), policy_id))
  let redeemer = TaskRedeemer { task_id: 1, action: TimeoutRelease }

  gigs_escrow.spend(tasker_pkh, platform_pkh, datum, redeemer, mock_utxo_ref(0, 0), tx_with_signatories)
}

/// Test: Timeout release fails during grace period
test timeout_release_fail_during_grace_period() fail {
  let policy_id = mock_policy_id(0)
  let tasker_pkh = mock_pub_key_hash(0)
  let platform_pkh = mock_pub_key_hash(5)
  let worker_pkh = mock_pub_key_hash(1)
  let payment = 50_000_000
  let worker_payment = calculate_worker_payment(payment)
  let platform_fee = calculate_platform_fee(payment)
  let during_grace = 1_700_000_000_000 + 33 * 24 * 60 * 60 * 1000 // 33 days (still in grace period)
  
  let tx =
    mocktail_tx()
      |> tx_out(True, mock_pub_key_address(1, None), from_lovelace(worker_payment))
      |> tx_out(True, mock_pub_key_address(5, None), from_lovelace(platform_fee))
      |> invalid_before(True, during_grace)
      |> invalid_hereafter(True, during_grace + 10_000)
      |> complete()
      |> set_fee(True, 2_000_000)
  
  let tx_with_signatories =
    Transaction { ..tx, extra_signatories: [] }

  let datum = Some(create_test_task_datum(1, payment, Completed, Some(worker_pkh), policy_id))
  let redeemer = TaskRedeemer { task_id: 1, action: TimeoutRelease }

  gigs_escrow.spend(tasker_pkh, platform_pkh, datum, redeemer, mock_utxo_ref(0, 0), tx_with_signatories)
}

/// Test: Wrong task ID fails
test wrong_task_id_fail() fail {
  let policy_id = mock_policy_id(0)
  let tasker_pkh = mock_pub_key_hash(0)
  let platform_pkh = mock_pub_key_hash(5)
  
  let tx = create_tx_with_tasker_identity(
    [tasker_pkh],
    [50_000_000],
    policy_id,
  )

  let datum = Some(create_test_task_datum(1, 50_000_000, Open, None, policy_id))
  let redeemer = TaskRedeemer { task_id: 2, action: CancelTask } // Wrong ID

  gigs_escrow.spend(tasker_pkh, platform_pkh, datum, redeemer, mock_utxo_ref(0, 0), tx)
}

/// Test: Parameterized validator prevents cross-task attacks
test wrong_tasker_parameter_fail() fail {
  let policy_id = mock_policy_id(0)
  let platform_pkh = mock_pub_key_hash(5)
  let correct_tasker = mock_pub_key_hash(0)
  let wrong_tasker = mock_pub_key_hash(6)
  
  // Transaction has correct tasker's signature and identity
  let tx = create_tx_with_tasker_identity(
    [correct_tasker],
    [50_000_000],
    policy_id,
  )

  let datum = Some(create_test_task_datum(1, 50_000_000, Open, None, policy_id))
  let redeemer = TaskRedeemer { task_id: 1, action: CancelTask }

  // But validator is parameterized with wrong tasker
  gigs_escrow.spend(wrong_tasker, platform_pkh, datum, redeemer, mock_utxo_ref(0, 0), tx)
}