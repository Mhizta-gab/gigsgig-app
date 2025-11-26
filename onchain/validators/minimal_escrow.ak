use aiken/collection/list
use aiken/collection/dict
use aiken/crypto.{VerificationKeyHash}
use aiken/interval.{Finite}
use aiken/primitive/bytearray.{starts_with}
use cardano/address
use cardano/assets.{PolicyId, from_lovelace, lovelace_of, tokens}
use cardano/transaction.{Input, OutputReference, Transaction}
use mocktail.{
  complete, invalid_before, invalid_hereafter, mock_pub_key_address,
  mock_pub_key_hash, mock_utxo_ref, mocktail_tx, set_fee, tx_out, tx_in,
  mock_policy_id,
}

// =============================================================================
// TYPES
// =============================================================================

/// Simplified datum - only essentials
pub type TaskDatum {
  task_id: Int,
  payment_amount: Int,
  worker: Option<VerificationKeyHash>,
  deadline: Int,  // POSIX timestamp in milliseconds
}

/// Three simple actions
pub type TaskAction {
  Cancel      // Tasker cancels/refunds (before assignment or after deadline)
  Complete    // Both parties agree - release payment (requires both NFTs)
  Claim       // Worker claims alone after timeout (requires worker NFT)
}

pub type TaskRedeemer {
  task_id: Int,
  action: TaskAction,
}

// =============================================================================
// CONSTANTS
// =============================================================================

const platform_fee_percentage: Int = 5
const grace_period_ms: Int = 7 * 24 * 60 * 60 * 1000  // 7 days

fn tasker_token_prefix() -> ByteArray {
  "GigsTasker"
}

fn worker_token_prefix() -> ByteArray {
  "GigsWorker"
}

// =============================================================================
// HELPER FUNCTIONS
// =============================================================================

fn calculate_platform_fee(payment_amount: Int) -> Int {
  payment_amount * platform_fee_percentage / 100
}

fn calculate_worker_payment(payment_amount: Int) -> Int {
  payment_amount - calculate_platform_fee(payment_amount)
}

fn must_be_signed_by(
  signer: VerificationKeyHash,
  signatories: List<VerificationKeyHash>,
) -> Bool {
  list.has(signatories, signer)
}

fn get_current_time(transaction: Transaction) -> Int {
  when transaction.validity_range.lower_bound.bound_type is {
    Finite(time) -> time
    _ -> fail @"Invalid transaction validity range"
  }
}

fn is_past_deadline(current_time: Int, deadline: Int) -> Bool {
  current_time >= deadline
}

fn is_past_claim_timeout(current_time: Int, deadline: Int) -> Bool {
  current_time >= deadline + grace_period_ms
}

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

fn validate_payment_distribution(
  transaction: Transaction,
  worker_pkh: VerificationKeyHash,
  platform_pkh: VerificationKeyHash,
  payment_amount: Int,
) -> Bool {
  let worker_payment = calculate_worker_payment(payment_amount)
  let platform_fee = calculate_platform_fee(payment_amount)
  
  let worker_paid = validate_payment_to_address(transaction, worker_pkh, worker_payment)
  let platform_paid = validate_payment_to_address(transaction, platform_pkh, platform_fee)
  
  worker_paid && platform_paid
}

// =============================================================================
// IDENTITY VERIFICATION (NFT CHECKS)
// =============================================================================

fn has_identity_token(
  inputs: List<Input>,
  pkh: VerificationKeyHash,
  policy_id: PolicyId,
  token_prefix: ByteArray,
) -> Bool {
  list.any(
    inputs,
    fn(input) {
      let belongs_to_user =
        when input.output.address.payment_credential is {
          address.VerificationKey(vkh) -> vkh == pkh
          _ -> False
        }
      
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

/// Cancel: Tasker gets refund (no NFT check - just their own money)
fn validate_cancel(
  datum: TaskDatum,
  tasker_pkh: VerificationKeyHash,
  transaction: Transaction,
) -> Bool {
  let current_time = get_current_time(transaction)
  
  // Must be signed by tasker
  must_be_signed_by(tasker_pkh, transaction.extra_signatories) &&
  // Either no worker assigned OR deadline passed
  (datum.worker == None || is_past_deadline(current_time, datum.deadline)) &&
  // Refund full amount to tasker
  validate_payment_to_address(transaction, tasker_pkh, datum.payment_amount)
}

/// Complete: Both parties agree to pay worker (CHECK BOTH NFTs)
fn validate_complete(
  datum: TaskDatum,
  tasker_pkh: VerificationKeyHash,
  platform_pkh: VerificationKeyHash,
  identity_policy_id: PolicyId,
  transaction: Transaction,
) -> Bool {
  expect Some(worker_pkh) = datum.worker
  
  // CRITICAL: Check both NFTs when money is distributed
  verify_tasker_identity(transaction, tasker_pkh, identity_policy_id) &&
  verify_worker_identity(transaction, worker_pkh, identity_policy_id) &&
  // Both must sign
  must_be_signed_by(tasker_pkh, transaction.extra_signatories) &&
  must_be_signed_by(worker_pkh, transaction.extra_signatories) &&
  // Distribute payment correctly
  validate_payment_distribution(transaction, worker_pkh, platform_pkh, datum.payment_amount)
}

/// Claim: Worker claims alone after timeout (CHECK WORKER NFT)
fn validate_claim(
  datum: TaskDatum,
  platform_pkh: VerificationKeyHash,
  identity_policy_id: PolicyId,
  transaction: Transaction,
) -> Bool {
  expect Some(worker_pkh) = datum.worker
  let current_time = get_current_time(transaction)
  
  // CRITICAL: Check worker NFT when claiming alone
  verify_worker_identity(transaction, worker_pkh, identity_policy_id) &&
  // Only worker signs (tasker may have ghosted)
  must_be_signed_by(worker_pkh, transaction.extra_signatories) &&
  // Must be past deadline + grace period
  is_past_claim_timeout(current_time, datum.deadline) &&
  // Distribute payment correctly
  validate_payment_distribution(transaction, worker_pkh, platform_pkh, datum.payment_amount)
}

// =============================================================================
// MAIN VALIDATOR
// =============================================================================

/// Simplified escrow validator with strategic NFT checks
/// 
/// Parameters:
/// - tasker_pkh: The tasker who created this task (unique per task)
/// - platform_pkh: Platform's address for receiving fees
/// - identity_policy_id: Links to the identity minting validator
/// 
/// NFT Check Strategy:
/// - Cancel: NO check (tasker's own money, cheap refund)
/// - Complete: CHECK BOTH (money being distributed)
/// - Claim: CHECK WORKER (worker claiming alone)
validator gigs_escrow(
  tasker_pkh: VerificationKeyHash,
  platform_pkh: VerificationKeyHash,
  identity_policy_id: PolicyId,
) {
  spend(
    datum: Option<TaskDatum>,
    redeemer: TaskRedeemer,
    _utxo_ref: OutputReference,
    transaction: Transaction,
  ) {
    expect Some(datum) = datum
    expect datum.task_id == redeemer.task_id
    
    when redeemer.action is {
      Cancel -> 
        validate_cancel(datum, tasker_pkh, transaction)
      
      Complete -> 
        validate_complete(datum, tasker_pkh, platform_pkh, identity_policy_id, transaction)
      
      Claim -> 
        validate_claim(datum, platform_pkh, identity_policy_id, transaction)
    }
  }

  else(_) {
    fail @"Invalid script purpose"
  }
}

// =============================================================================
// TEST HELPERS
// =============================================================================

fn create_test_datum(
  task_id: Int,
  payment_amount: Int,
  worker: Option<VerificationKeyHash>,
) -> TaskDatum {
  let current_time = 1_700_000_000_000
  TaskDatum {
    task_id,
    payment_amount,
    worker,
    deadline: current_time + 30 * 24 * 60 * 60 * 1000,
  }
}

fn create_identity_nft_value(
  policy_id: PolicyId,
  token_name: ByteArray,
  ada_amount: Int,
) -> assets.Value {
  from_lovelace(ada_amount)
    |> assets.add(policy_id, token_name, 1)
}

fn create_simple_tx(
  signatories: List<VerificationKeyHash>,
  outputs_ada: List<Int>,
) -> Transaction {
  let lower_bound = 1_700_000_000_000
  let upper_bound = lower_bound + 10_000

  let mut_tx =
    mocktail_tx()
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

fn create_tx_with_both_nfts(
  signatories: List<VerificationKeyHash>,
  worker_payment: Int,
  platform_fee: Int,
  policy_id: PolicyId,
) -> Transaction {
  let lower_bound = 1_700_000_000_000
  let upper_bound = lower_bound + 10_000

  let tasker_nft = create_identity_nft_value(policy_id, "GigsTasker00001", 2_000_000)
  let worker_nft = create_identity_nft_value(policy_id, "GigsWorker00001", 2_000_000)

  let tx =
    mocktail_tx()
      |> tx_in(True, #"00", 0, tasker_nft, mock_pub_key_address(0, None))
      |> tx_in(True, #"01", 0, worker_nft, mock_pub_key_address(1, None))
      |> tx_out(True, mock_pub_key_address(1, None), from_lovelace(worker_payment))
      |> tx_out(True, mock_pub_key_address(5, None), from_lovelace(platform_fee))
      |> invalid_before(True, lower_bound)
      |> invalid_hereafter(True, upper_bound)
      |> complete()
      |> set_fee(True, 2_000_000)

  Transaction { ..tx, extra_signatories: signatories }
}

fn create_tx_with_worker_nft(
  signatories: List<VerificationKeyHash>,
  worker_payment: Int,
  platform_fee: Int,
  policy_id: PolicyId,
) -> Transaction {
  let lower_bound = 1_700_000_000_000
  let upper_bound = lower_bound + 10_000

  let worker_nft = create_identity_nft_value(policy_id, "GigsWorker00001", 2_000_000)

  let tx =
    mocktail_tx()
      |> tx_in(True, #"01", 0, worker_nft, mock_pub_key_address(1, None))
      |> tx_out(True, mock_pub_key_address(1, None), from_lovelace(worker_payment))
      |> tx_out(True, mock_pub_key_address(5, None), from_lovelace(platform_fee))
      |> invalid_before(True, lower_bound)
      |> invalid_hereafter(True, upper_bound)
      |> complete()
      |> set_fee(True, 2_000_000)

  Transaction { ..tx, extra_signatories: signatories }
}

// =============================================================================
// TESTS - CANCEL ACTION
// =============================================================================

test cancel_unassigned_task_success() {
  let policy_id = mock_policy_id(0)
  let tasker_pkh = mock_pub_key_hash(0)
  let platform_pkh = mock_pub_key_hash(5)
  
  let tx = create_simple_tx([tasker_pkh], [50_000_000])
  let datum = Some(create_test_datum(1, 50_000_000, None))
  let redeemer = TaskRedeemer { task_id: 1, action: Cancel }

  gigs_escrow.spend(tasker_pkh, platform_pkh, policy_id, datum, redeemer, mock_utxo_ref(0, 0), tx)
}

test cancel_after_deadline_success() {
  let policy_id = mock_policy_id(0)
  let tasker_pkh = mock_pub_key_hash(0)
  let platform_pkh = mock_pub_key_hash(5)
  let worker_pkh = mock_pub_key_hash(1)
  let past_deadline = 1_700_000_000_000 + 31 * 24 * 60 * 60 * 1000
  
  let tx =
    mocktail_tx()
      |> tx_out(True, mock_pub_key_address(0, None), from_lovelace(50_000_000))
      |> invalid_before(True, past_deadline)
      |> invalid_hereafter(True, past_deadline + 10_000)
      |> complete()
      |> set_fee(True, 2_000_000)
      |> fn(t) { Transaction { ..t, extra_signatories: [tasker_pkh] } }

  let datum = Some(create_test_datum(1, 50_000_000, Some(worker_pkh)))
  let redeemer = TaskRedeemer { task_id: 1, action: Cancel }

  gigs_escrow.spend(tasker_pkh, platform_pkh, policy_id, datum, redeemer, mock_utxo_ref(0, 0), tx)
}

test cancel_fail_no_signature() fail {
  let policy_id = mock_policy_id(0)
  let tasker_pkh = mock_pub_key_hash(0)
  let platform_pkh = mock_pub_key_hash(5)
  
  let tx = create_simple_tx([mock_pub_key_hash(9)], [50_000_000])
  let datum = Some(create_test_datum(1, 50_000_000, None))
  let redeemer = TaskRedeemer { task_id: 1, action: Cancel }

  gigs_escrow.spend(tasker_pkh, platform_pkh, policy_id, datum, redeemer, mock_utxo_ref(0, 0), tx)
}

test cancel_fail_assigned_before_deadline() fail {
  let policy_id = mock_policy_id(0)
  let tasker_pkh = mock_pub_key_hash(0)
  let platform_pkh = mock_pub_key_hash(5)
  let worker_pkh = mock_pub_key_hash(1)
  
  let tx = create_simple_tx([tasker_pkh], [50_000_000])
  let datum = Some(create_test_datum(1, 50_000_000, Some(worker_pkh)))
  let redeemer = TaskRedeemer { task_id: 1, action: Cancel }

  gigs_escrow.spend(tasker_pkh, platform_pkh, policy_id, datum, redeemer, mock_utxo_ref(0, 0), tx)
}

// =============================================================================
// TESTS - COMPLETE ACTION
// =============================================================================

test complete_with_both_nfts_success() {
  let policy_id = mock_policy_id(0)
  let tasker_pkh = mock_pub_key_hash(0)
  let platform_pkh = mock_pub_key_hash(5)
  let worker_pkh = mock_pub_key_hash(1)
  let payment = 50_000_000
  let worker_payment = calculate_worker_payment(payment)
  let platform_fee = calculate_platform_fee(payment)
  
  let tx = create_tx_with_both_nfts(
    [tasker_pkh, worker_pkh],
    worker_payment,
    platform_fee,
    policy_id,
  )

  let datum = Some(create_test_datum(1, payment, Some(worker_pkh)))
  let redeemer = TaskRedeemer { task_id: 1, action: Complete }

  gigs_escrow.spend(tasker_pkh, platform_pkh, policy_id, datum, redeemer, mock_utxo_ref(0, 0), tx)
}

test complete_fail_no_tasker_nft() fail {
  let policy_id = mock_policy_id(0)
  let tasker_pkh = mock_pub_key_hash(0)
  let platform_pkh = mock_pub_key_hash(5)
  let worker_pkh = mock_pub_key_hash(1)
  let payment = 50_000_000
  let worker_payment = calculate_worker_payment(payment)
  let platform_fee = calculate_platform_fee(payment)
  
  // Only worker NFT, no tasker NFT
  let tx = create_tx_with_worker_nft(
    [tasker_pkh, worker_pkh],
    worker_payment,
    platform_fee,
    policy_id,
  )

  let datum = Some(create_test_datum(1, payment, Some(worker_pkh)))
  let redeemer = TaskRedeemer { task_id: 1, action: Complete }

  gigs_escrow.spend(tasker_pkh, platform_pkh, policy_id, datum, redeemer, mock_utxo_ref(0, 0), tx)
}

test complete_fail_no_worker_signature() fail {
  let policy_id = mock_policy_id(0)
  let tasker_pkh = mock_pub_key_hash(0)
  let platform_pkh = mock_pub_key_hash(5)
  let worker_pkh = mock_pub_key_hash(1)
  let payment = 50_000_000
  let worker_payment = calculate_worker_payment(payment)
  let platform_fee = calculate_platform_fee(payment)
  
  let tx = create_tx_with_both_nfts(
    [tasker_pkh],  // Only tasker signature
    worker_payment,
    platform_fee,
    policy_id,
  )

  let datum = Some(create_test_datum(1, payment, Some(worker_pkh)))
  let redeemer = TaskRedeemer { task_id: 1, action: Complete }

  gigs_escrow.spend(tasker_pkh, platform_pkh, policy_id, datum, redeemer, mock_utxo_ref(0, 0), tx)
}

test complete_fail_no_worker_assigned() fail {
  let policy_id = mock_policy_id(0)
  let tasker_pkh = mock_pub_key_hash(0)
  let platform_pkh = mock_pub_key_hash(5)
  let payment = 50_000_000
  let worker_payment = calculate_worker_payment(payment)
  let platform_fee = calculate_platform_fee(payment)
  
  let tx = create_tx_with_both_nfts(
    [tasker_pkh],
    worker_payment,
    platform_fee,
    policy_id,
  )

  let datum = Some(create_test_datum(1, payment, None))  // No worker
  let redeemer = TaskRedeemer { task_id: 1, action: Complete }

  gigs_escrow.spend(tasker_pkh, platform_pkh, policy_id, datum, redeemer, mock_utxo_ref(0, 0), tx)
}

// =============================================================================
// TESTS - CLAIM ACTION
// =============================================================================

test claim_after_timeout_success() {
  let policy_id = mock_policy_id(0)
  let tasker_pkh = mock_pub_key_hash(0)
  let platform_pkh = mock_pub_key_hash(5)
  let worker_pkh = mock_pub_key_hash(1)
  let payment = 50_000_000
  let worker_payment = calculate_worker_payment(payment)
  let platform_fee = calculate_platform_fee(payment)
  let past_timeout = 1_700_000_000_000 + 38 * 24 * 60 * 60 * 1000  // Past deadline + grace
  
  let tx =
    mocktail_tx()
      |> tx_in(
          True,
          #"01",
          0,
          create_identity_nft_value(policy_id, "GigsWorker00001", 2_000_000),
          mock_pub_key_address(1, None),
        )
      |> tx_out(True, mock_pub_key_address(1, None), from_lovelace(worker_payment))
      |> tx_out(True, mock_pub_key_address(5, None), from_lovelace(platform_fee))
      |> invalid_before(True, past_timeout)
      |> invalid_hereafter(True, past_timeout + 10_000)
      |> complete()
      |> set_fee(True, 2_000_000)
      |> fn(t) { Transaction { ..t, extra_signatories: [worker_pkh] } }

  let datum = Some(create_test_datum(1, payment, Some(worker_pkh)))
  let redeemer = TaskRedeemer { task_id: 1, action: Claim }

  gigs_escrow.spend(tasker_pkh, platform_pkh, policy_id, datum, redeemer, mock_utxo_ref(0, 0), tx)
}

test claim_fail_before_timeout() fail {
  let policy_id = mock_policy_id(0)
  let tasker_pkh = mock_pub_key_hash(0)
  let platform_pkh = mock_pub_key_hash(5)
  let worker_pkh = mock_pub_key_hash(1)
  let payment = 50_000_000
  let worker_payment = calculate_worker_payment(payment)
  let platform_fee = calculate_platform_fee(payment)
  let before_timeout = 1_700_000_000_000 + 20 * 24 * 60 * 60 * 1000  // Only 20 days
  
  let tx =
    mocktail_tx()
      |> tx_in(
          True,
          #"01",
          0,
          create_identity_nft_value(policy_id, "GigsWorker00001", 2_000_000),
          mock_pub_key_address(1, None),
        )
      |> tx_out(True, mock_pub_key_address(1, None), from_lovelace(worker_payment))
      |> tx_out(True, mock_pub_key_address(5, None), from_lovelace(platform_fee))
      |> invalid_before(True, before_timeout)
      |> invalid_hereafter(True, before_timeout + 10_000)
      |> complete()
      |> set_fee(True, 2_000_000)
      |> fn(t) { Transaction { ..t, extra_signatories: [worker_pkh] } }

  let datum = Some(create_test_datum(1, payment, Some(worker_pkh)))
  let redeemer = TaskRedeemer { task_id: 1, action: Claim }

  gigs_escrow.spend(tasker_pkh, platform_pkh, policy_id, datum, redeemer, mock_utxo_ref(0, 0), tx)
}

test claim_fail_no_worker_nft() fail {
  let policy_id = mock_policy_id(0)
  let tasker_pkh = mock_pub_key_hash(0)
  let platform_pkh = mock_pub_key_hash(5)
  let worker_pkh = mock_pub_key_hash(1)
  let payment = 50_000_000
  let worker_payment = calculate_worker_payment(payment)
  let platform_fee = calculate_platform_fee(payment)
  let past_timeout = 1_700_000_000_000 + 38 * 24 * 60 * 60 * 1000
  
  // No NFT in inputs
  let tx =
    mocktail_tx()
      |> tx_out(True, mock_pub_key_address(1, None), from_lovelace(worker_payment))
      |> tx_out(True, mock_pub_key_address(5, None), from_lovelace(platform_fee))
      |> invalid_before(True, past_timeout)
      |> invalid_hereafter(True, past_timeout + 10_000)
      |> complete()
      |> set_fee(True, 2_000_000)
      |> fn(t) { Transaction { ..t, extra_signatories: [worker_pkh] } }

  let datum = Some(create_test_datum(1, payment, Some(worker_pkh)))
  let redeemer = TaskRedeemer { task_id: 1, action: Claim }

  gigs_escrow.spend(tasker_pkh, platform_pkh, policy_id, datum, redeemer, mock_utxo_ref(0, 0), tx)
}

// =============================================================================
// TESTS - SECURITY
// =============================================================================

test wrong_task_id_fail() fail {
  let policy_id = mock_policy_id(0)
  let tasker_pkh = mock_pub_key_hash(0)
  let platform_pkh = mock_pub_key_hash(5)
  
  let tx = create_simple_tx([tasker_pkh], [50_000_000])
  let datum = Some(create_test_datum(1, 50_000_000, None))
  let redeemer = TaskRedeemer { task_id: 999, action: Cancel }

  gigs_escrow.spend(tasker_pkh, platform_pkh, policy_id, datum, redeemer, mock_utxo_ref(0, 0), tx)
}

test wrong_tasker_parameter_fail() fail {
  let policy_id = mock_policy_id(0)
  let correct_tasker = mock_pub_key_hash(0)
  let wrong_tasker = mock_pub_key_hash(9)
  let platform_pkh = mock_pub_key_hash(5)
  
  let tx = create_simple_tx([correct_tasker], [50_000_000])
  let datum = Some(create_test_datum(1, 50_000_000, None))
  let redeemer = TaskRedeemer { task_id: 1, action: Cancel }

  gigs_escrow.spend(wrong_tasker, platform_pkh, policy_id, datum, redeemer, mock_utxo_ref(0, 0), tx)
}