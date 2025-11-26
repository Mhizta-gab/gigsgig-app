// use aiken/collection/list
// use aiken/crypto.{VerificationKeyHash}
// use aiken/interval.{Finite}
// use cardano/address
// use cardano/assets.{PolicyId, from_lovelace, lovelace_of}
// use cardano/transaction.{Output, OutputReference, Transaction}
// use mocktail.{
//   complete, invalid_before, invalid_hereafter, mock_pub_key_address,
//   mock_pub_key_hash, mock_utxo_ref, mocktail_tx, set_fee, tx_out,
//   mock_policy_id,
// }

// // =============================================================================
// // TYPES
// // =============================================================================

// pub type TaskStatus {
//   Open
//   Assigned
//   Completed
// }

// pub type TaskDatum {
//   task_id: Int,
//   worker: Option<VerificationKeyHash>,
//   payment_amount: Int,
//   deadline: Int,
//   status: TaskStatus,
// }

// pub type TaskAction {
//   CancelTask
//   ApplyForTask { worker: VerificationKeyHash }
//   MarkComplete
//   ReleasePay
//   TimeoutRefund
//   TimeoutRelease
// }

// pub type TaskRedeemer {
//   task_id: Int,
//   action: TaskAction,
// }

// // =============================================================================
// // CONSTANTS
// // =============================================================================

// const platform_fee_percentage: Int = 5
// const grace_period_ms: Int = 7 * 24 * 60 * 60 * 1000

// // =============================================================================
// // HELPER FUNCTIONS
// // =============================================================================

// fn calculate_platform_fee(payment_amount: Int) -> Int {
//   payment_amount * platform_fee_percentage / 100
// }

// fn calculate_worker_payment(payment_amount: Int) -> Int {
//   payment_amount - calculate_platform_fee(payment_amount)
// }

// fn must_be_signed_by(
//   signer: VerificationKeyHash,
//   signatories: List<VerificationKeyHash>,
// ) -> Bool {
//   list.has(signatories, signer)
// }

// fn get_current_time(transaction: Transaction) -> Int {
//   when transaction.validity_range.lower_bound.bound_type is {
//     Finite(time) -> time
//     _ -> fail @"Invalid transaction validity range"
//   }
// }

// fn is_past_deadline(current_time: Int, deadline: Int) -> Bool {
//   current_time >= deadline
// }

// fn is_grace_period_passed(current_time: Int, deadline: Int) -> Bool {
//   current_time >= deadline + grace_period_ms
// }

// fn validate_payment_to_address(
//   transaction: Transaction,
//   recipient: VerificationKeyHash,
//   min_amount: Int,
// ) -> Bool {
//   list.any(
//     transaction.outputs,
//     fn(output) {
//       let pays_to_recipient =
//         when output.address.payment_credential is {
//           address.VerificationKey(vkh) -> vkh == recipient
//           _ -> False
//         }
//       let has_sufficient_value = lovelace_of(output.value) >= min_amount
//       pays_to_recipient && has_sufficient_value
//     },
//   )
// }

// fn validate_payment_distribution(
//   transaction: Transaction,
//   worker_pkh: VerificationKeyHash,
//   platform_pkh: VerificationKeyHash,
//   payment_amount: Int,
// ) -> Bool {
//   let worker_payment = calculate_worker_payment(payment_amount)
//   let platform_fee = calculate_platform_fee(payment_amount)
  
//   let worker_paid = validate_payment_to_address(transaction, worker_pkh, worker_payment)
//   let platform_paid = validate_payment_to_address(transaction, platform_pkh, platform_fee)
  
//   worker_paid && platform_paid
// }

// fn validate_output_exists(transaction: Transaction, min_ada: Int) -> Bool {
//   list.any(
//     transaction.outputs,
//     fn(output) { lovelace_of(output.value) >= min_ada },
//   )
// }

// // =============================================================================
// // VALIDATION FUNCTIONS - MINIMAL CHECKS ONLY
// // =============================================================================

// fn validate_cancel_task(
//   datum: TaskDatum,
//   tasker_pkh: VerificationKeyHash,
//   transaction: Transaction,
// ) -> Bool {
//   must_be_signed_by(tasker_pkh, transaction.extra_signatories) &&
//   datum.status == Open &&
//   validate_payment_to_address(transaction, tasker_pkh, datum.payment_amount)
// }

// fn validate_apply_for_task(
//   datum: TaskDatum,
//   worker_pkh: VerificationKeyHash,
//   transaction: Transaction,
// ) -> Bool {
//   must_be_signed_by(worker_pkh, transaction.extra_signatories) &&
//   datum.status == Open &&
//   datum.worker == None &&
//   !is_past_deadline(get_current_time(transaction), datum.deadline) &&
//   validate_output_exists(transaction, datum.payment_amount)
// }

// fn validate_mark_complete(
//   datum: TaskDatum,
//   transaction: Transaction,
// ) -> Bool {
//   expect Some(worker_pkh) = datum.worker
  
//   must_be_signed_by(worker_pkh, transaction.extra_signatories) &&
//   datum.status == Assigned &&
//   validate_output_exists(transaction, datum.payment_amount)
// }

// fn validate_release_pay(
//   datum: TaskDatum,
//   tasker_pkh: VerificationKeyHash,
//   platform_pkh: VerificationKeyHash,
//   transaction: Transaction,
// ) -> Bool {
//   expect Some(worker_pkh) = datum.worker
  
//   must_be_signed_by(tasker_pkh, transaction.extra_signatories) &&
//   datum.status == Completed &&
//   validate_payment_distribution(transaction, worker_pkh, platform_pkh, datum.payment_amount)
// }

// fn validate_timeout_refund(
//   datum: TaskDatum,
//   tasker_pkh: VerificationKeyHash,
//   transaction: Transaction,
// ) -> Bool {
//   let current_time = get_current_time(transaction)
//   let valid_status = datum.status == Open || datum.status == Assigned
  
//   valid_status &&
//   is_past_deadline(current_time, datum.deadline) &&
//   validate_payment_to_address(transaction, tasker_pkh, datum.payment_amount)
// }

// fn validate_timeout_release(
//   datum: TaskDatum,
//   platform_pkh: VerificationKeyHash,
//   transaction: Transaction,
// ) -> Bool {
//   expect Some(worker_pkh) = datum.worker
//   let current_time = get_current_time(transaction)
  
//   datum.status == Completed &&
//   is_grace_period_passed(current_time, datum.deadline) &&
//   validate_payment_distribution(transaction, worker_pkh, platform_pkh, datum.payment_amount)
// }

// // =============================================================================
// // MAIN VALIDATOR - MINIMAL BUT IDENTITY-AWARE
// // =============================================================================

// /// Minimal escrow validator with identity policy reference
// /// 
// /// Parameters:
// /// - tasker_pkh: Unique tasker for this escrow instance
// /// - platform_pkh: Platform's payment address for fees
// /// - identity_policy_id: The official identity NFT policy (links to mint validator)
// /// 
// /// Note: Identity checks are handled OFF-CHAIN for gas efficiency.
// /// The policy ID parameter ensures off-chain knows which NFTs to check.
// /// On-chain only validates money flow and authorization signatures.
// validator gigs_escrow(
//   tasker_pkh: VerificationKeyHash,
//   platform_pkh: VerificationKeyHash,
//   identity_policy_id: PolicyId,  // Links to your minting validator!
// ) {
//   spend(
//     datum: Option<TaskDatum>,
//     redeemer: TaskRedeemer,
//     _utxo_ref: OutputReference,
//     transaction: Transaction,
//   ) {
//     expect Some(datum) = datum
//     expect datum.task_id == redeemer.task_id
    
//     when redeemer.action is {
//       CancelTask -> 
//         validate_cancel_task(datum, tasker_pkh, transaction)
      
//       ApplyForTask { worker } -> 
//         validate_apply_for_task(datum, worker, transaction)
      
//       MarkComplete -> 
//         validate_mark_complete(datum, transaction)
      
//       ReleasePay -> 
//         validate_release_pay(datum, tasker_pkh, platform_pkh, transaction)
      
//       TimeoutRefund -> 
//         validate_timeout_refund(datum, tasker_pkh, transaction)
      
//       TimeoutRelease -> 
//         validate_timeout_release(datum, platform_pkh, transaction)
//     }
//   }

//   else(_) {
//     fail @"Invalid script purpose"
//   }
// }

// // =============================================================================
// // TEST HELPERS
// // =============================================================================

// fn create_test_task_datum(
//   task_id: Int,
//   payment_amount: Int,
//   status: TaskStatus,
//   worker: Option<VerificationKeyHash>,
// ) -> TaskDatum {
//   let current_time = 1_700_000_000_000
//   TaskDatum {
//     task_id,
//     worker,
//     payment_amount,
//     deadline: current_time + 30 * 24 * 60 * 60 * 1000, // 30 days
//     status,
//   }
// }

// fn create_simple_tx(
//   signatories: List<VerificationKeyHash>,
//   outputs_ada: List<Int>,
// ) -> Transaction {
//   let lower_bound = 1_700_000_000_000
//   let upper_bound = lower_bound + 10_000

//   let mut_tx =
//     mocktail_tx()
//       |> invalid_before(True, lower_bound)
//       |> invalid_hereafter(True, upper_bound)

//   let tx_with_outputs =
//     list.foldr(
//       outputs_ada,
//       mut_tx,
//       fn(ada_amount, tx_acc) {
//         tx_acc
//           |> tx_out(
//               True,
//               mock_pub_key_address(0, None),
//               from_lovelace(ada_amount),
//             )
//       },
//     )

//   let completed_tx = tx_with_outputs |> complete()
//   let tx_with_fee = completed_tx |> set_fee(True, 2_000_000)

//   Transaction { ..tx_with_fee, extra_signatories: signatories }
// }

// // =============================================================================
// // TESTS
// // =============================================================================

// /// Test: Cancel task successfully
// test cancel_task_success() {
//   let policy_id = mock_policy_id(0)
//   let tasker_pkh = mock_pub_key_hash(0)
//   let platform_pkh = mock_pub_key_hash(5)
  
//   let tx = create_simple_tx(
//     [tasker_pkh],
//     [50_000_000],
//   )

//   let datum = Some(create_test_task_datum(1, 50_000_000, Open, None))
//   let redeemer = TaskRedeemer { task_id: 1, action: CancelTask }

//   gigs_escrow.spend(tasker_pkh, platform_pkh, policy_id, datum, redeemer, mock_utxo_ref(0, 0), tx)
// }

// /// Test: Cancel task fails without tasker signature
// test cancel_task_fail_no_signature() fail {
//   let policy_id = mock_policy_id(0)
//   let tasker_pkh = mock_pub_key_hash(0)
//   let platform_pkh = mock_pub_key_hash(5)
  
//   let tx = create_simple_tx(
//     [mock_pub_key_hash(5)], // Wrong signature
//     [50_000_000],
//   )

//   let datum = Some(create_test_task_datum(1, 50_000_000, Open, None))
//   let redeemer = TaskRedeemer { task_id: 1, action: CancelTask }

//   gigs_escrow.spend(tasker_pkh, platform_pkh, policy_id, datum, redeemer, mock_utxo_ref(0, 0), tx)
// }

// /// Test: Cancel task fails when already assigned
// test cancel_task_fail_already_assigned() fail {
//   let policy_id = mock_policy_id(0)
//   let tasker_pkh = mock_pub_key_hash(0)
//   let platform_pkh = mock_pub_key_hash(5)
  
//   let tx = create_simple_tx(
//     [tasker_pkh],
//     [50_000_000],
//   )

//   let datum = Some(create_test_task_datum(1, 50_000_000, Assigned, Some(mock_pub_key_hash(1))))
//   let redeemer = TaskRedeemer { task_id: 1, action: CancelTask }

//   gigs_escrow.spend(tasker_pkh, platform_pkh, policy_id, datum, redeemer, mock_utxo_ref(0, 0), tx)
// }

// /// Test: Worker applies for task successfully
// test apply_for_task_success() {
//   let policy_id = mock_policy_id(0)
//   let tasker_pkh = mock_pub_key_hash(0)
//   let platform_pkh = mock_pub_key_hash(5)
//   let worker_pkh = mock_pub_key_hash(1)
  
//   let tx = create_simple_tx(
//     [worker_pkh],
//     [50_000_000],
//   )

//   let datum = Some(create_test_task_datum(1, 50_000_000, Open, None))
//   let redeemer = TaskRedeemer { 
//     task_id: 1, 
//     action: ApplyForTask { worker: worker_pkh }
//   }

//   gigs_escrow.spend(tasker_pkh, platform_pkh, policy_id, datum, redeemer, mock_utxo_ref(0, 0), tx)
// }

// /// Test: Apply for task fails without worker signature
// test apply_for_task_fail_no_signature() fail {
//   let policy_id = mock_policy_id(0)
//   let tasker_pkh = mock_pub_key_hash(0)
//   let platform_pkh = mock_pub_key_hash(5)
//   let worker_pkh = mock_pub_key_hash(1)
  
//   let tx = create_simple_tx(
//     [mock_pub_key_hash(5)], // Wrong signature
//     [50_000_000],
//   )

//   let datum = Some(create_test_task_datum(1, 50_000_000, Open, None))
//   let redeemer = TaskRedeemer { 
//     task_id: 1, 
//     action: ApplyForTask { worker: worker_pkh }
//   }

//   gigs_escrow.spend(tasker_pkh, platform_pkh, policy_id, datum, redeemer, mock_utxo_ref(0, 0), tx)
// }

// /// Test: Apply for task fails when already assigned
// test apply_for_task_fail_already_assigned() fail {
//   let policy_id = mock_policy_id(0)
//   let tasker_pkh = mock_pub_key_hash(0)
//   let platform_pkh = mock_pub_key_hash(5)
//   let worker_pkh = mock_pub_key_hash(1)
  
//   let tx = create_simple_tx(
//     [worker_pkh],
//     [50_000_000],
//   )

//   let datum = Some(create_test_task_datum(1, 50_000_000, Assigned, Some(mock_pub_key_hash(2))))
//   let redeemer = TaskRedeemer { 
//     task_id: 1, 
//     action: ApplyForTask { worker: worker_pkh }
//   }

//   gigs_escrow.spend(tasker_pkh, platform_pkh, policy_id, datum, redeemer, mock_utxo_ref(0, 0), tx)
// }

// /// Test: Apply for task fails after deadline
// test apply_for_task_fail_after_deadline() fail {
//   let policy_id = mock_policy_id(0)
//   let tasker_pkh = mock_pub_key_hash(0)
//   let platform_pkh = mock_pub_key_hash(5)
//   let worker_pkh = mock_pub_key_hash(1)
//   let past_deadline = 1_700_000_000_000 + 31 * 24 * 60 * 60 * 1000 // Past deadline
  
//   let tx =
//     mocktail_tx()
//       |> tx_out(True, mock_pub_key_address(0, None), from_lovelace(50_000_000))
//       |> invalid_before(True, past_deadline)
//       |> invalid_hereafter(True, past_deadline + 10_000)
//       |> complete()
//       |> set_fee(True, 2_000_000)
//       |> fn(t) { Transaction { ..t, extra_signatories: [worker_pkh] } }

//   let datum = Some(create_test_task_datum(1, 50_000_000, Open, None))
//   let redeemer = TaskRedeemer { 
//     task_id: 1, 
//     action: ApplyForTask { worker: worker_pkh }
//   }

//   gigs_escrow.spend(tasker_pkh, platform_pkh, policy_id, datum, redeemer, mock_utxo_ref(0, 0), tx)
// }

// /// Test: Mark complete successfully
// test mark_complete_success() {
//   let policy_id = mock_policy_id(0)
//   let tasker_pkh = mock_pub_key_hash(0)
//   let platform_pkh = mock_pub_key_hash(5)
//   let worker_pkh = mock_pub_key_hash(1)
  
//   let tx = create_simple_tx(
//     [worker_pkh],
//     [50_000_000],
//   )

//   let datum = Some(create_test_task_datum(1, 50_000_000, Assigned, Some(worker_pkh)))
//   let redeemer = TaskRedeemer { task_id: 1, action: MarkComplete }

//   gigs_escrow.spend(tasker_pkh, platform_pkh, policy_id, datum, redeemer, mock_utxo_ref(0, 0), tx)
// }

// /// Test: Mark complete fails without worker signature
// test mark_complete_fail_no_signature() fail {
//   let policy_id = mock_policy_id(0)
//   let tasker_pkh = mock_pub_key_hash(0)
//   let platform_pkh = mock_pub_key_hash(5)
//   let worker_pkh = mock_pub_key_hash(1)
  
//   let tx = create_simple_tx(
//     [mock_pub_key_hash(5)], // Wrong signature
//     [50_000_000],
//   )

//   let datum = Some(create_test_task_datum(1, 50_000_000, Assigned, Some(worker_pkh)))
//   let redeemer = TaskRedeemer { task_id: 1, action: MarkComplete }

//   gigs_escrow.spend(tasker_pkh, platform_pkh, policy_id, datum, redeemer, mock_utxo_ref(0, 0), tx)
// }

// /// Test: Mark complete fails when status is Open
// test mark_complete_fail_not_assigned() fail {
//   let policy_id = mock_policy_id(0)
//   let tasker_pkh = mock_pub_key_hash(0)
//   let platform_pkh = mock_pub_key_hash(5)
//   let worker_pkh = mock_pub_key_hash(1)
  
//   let tx = create_simple_tx(
//     [worker_pkh],
//     [50_000_000],
//   )

//   let datum = Some(create_test_task_datum(1, 50_000_000, Open, None))
//   let redeemer = TaskRedeemer { task_id: 1, action: MarkComplete }

//   gigs_escrow.spend(tasker_pkh, platform_pkh, policy_id, datum, redeemer, mock_utxo_ref(0, 0), tx)
// }

// /// Test: Release payment successfully
// test release_pay_success() {
//   let policy_id = mock_policy_id(0)
//   let tasker_pkh = mock_pub_key_hash(0)
//   let platform_pkh = mock_pub_key_hash(5)
//   let worker_pkh = mock_pub_key_hash(1)
//   let payment = 50_000_000
//   let worker_payment = calculate_worker_payment(payment)
//   let platform_fee = calculate_platform_fee(payment)
  
//   let tx =
//     mocktail_tx()
//       |> tx_out(True, mock_pub_key_address(1, None), from_lovelace(worker_payment))
//       |> tx_out(True, mock_pub_key_address(5, None), from_lovelace(platform_fee))
//       |> invalid_before(True, 1_700_000_000_000)
//       |> invalid_hereafter(True, 1_700_000_010_000)
//       |> complete()
//       |> set_fee(True, 2_000_000)
//       |> fn(t) { Transaction { ..t, extra_signatories: [tasker_pkh] } }

//   let datum = Some(create_test_task_datum(1, payment, Completed, Some(worker_pkh)))
//   let redeemer = TaskRedeemer { task_id: 1, action: ReleasePay }

//   gigs_escrow.spend(tasker_pkh, platform_pkh, policy_id, datum, redeemer, mock_utxo_ref(0, 0), tx)
// }

// /// Test: Release payment fails without tasker signature
// test release_pay_fail_no_signature() fail {
//   let policy_id = mock_policy_id(0)
//   let tasker_pkh = mock_pub_key_hash(0)
//   let platform_pkh = mock_pub_key_hash(5)
//   let worker_pkh = mock_pub_key_hash(1)
//   let payment = 50_000_000
//   let worker_payment = calculate_worker_payment(payment)
//   let platform_fee = calculate_platform_fee(payment)
  
//   let tx =
//     mocktail_tx()
//       |> tx_out(True, mock_pub_key_address(1, None), from_lovelace(worker_payment))
//       |> tx_out(True, mock_pub_key_address(5, None), from_lovelace(platform_fee))
//       |> invalid_before(True, 1_700_000_000_000)
//       |> invalid_hereafter(True, 1_700_000_010_000)
//       |> complete()
//       |> set_fee(True, 2_000_000)
//       |> fn(t) { Transaction { ..t, extra_signatories: [mock_pub_key_hash(9)] } }

//   let datum = Some(create_test_task_datum(1, payment, Completed, Some(worker_pkh)))
//   let redeemer = TaskRedeemer { task_id: 1, action: ReleasePay }

//   gigs_escrow.spend(tasker_pkh, platform_pkh, policy_id, datum, redeemer, mock_utxo_ref(0, 0), tx)
// }

// /// Test: Release payment fails when status is not Completed
// test release_pay_fail_not_completed() fail {
//   let policy_id = mock_policy_id(0)
//   let tasker_pkh = mock_pub_key_hash(0)
//   let platform_pkh = mock_pub_key_hash(5)
//   let worker_pkh = mock_pub_key_hash(1)
//   let payment = 50_000_000
//   let worker_payment = calculate_worker_payment(payment)
//   let platform_fee = calculate_platform_fee(payment)
  
//   let tx =
//     mocktail_tx()
//       |> tx_out(True, mock_pub_key_address(1, None), from_lovelace(worker_payment))
//       |> tx_out(True, mock_pub_key_address(5, None), from_lovelace(platform_fee))
//       |> invalid_before(True, 1_700_000_000_000)
//       |> invalid_hereafter(True, 1_700_000_010_000)
//       |> complete()
//       |> set_fee(True, 2_000_000)
//       |> fn(t) { Transaction { ..t, extra_signatories: [tasker_pkh] } }

//   let datum = Some(create_test_task_datum(1, payment, Assigned, Some(worker_pkh)))
//   let redeemer = TaskRedeemer { task_id: 1, action: ReleasePay }

//   gigs_escrow.spend(tasker_pkh, platform_pkh, policy_id, datum, redeemer, mock_utxo_ref(0, 0), tx)
// }

// /// Test: Timeout refund successfully for Open task
// test timeout_refund_open_success() {
//   let policy_id = mock_policy_id(0)
//   let tasker_pkh = mock_pub_key_hash(0)
//   let platform_pkh = mock_pub_key_hash(5)
//   let payment = 50_000_000
//   let past_deadline = 1_700_000_000_000 + 31 * 24 * 60 * 60 * 1000
  
//   let tx =
//     mocktail_tx()
//       |> tx_out(True, mock_pub_key_address(0, None), from_lovelace(payment))
//       |> invalid_before(True, past_deadline)
//       |> invalid_hereafter(True, past_deadline + 10_000)
//       |> complete()
//       |> set_fee(True, 2_000_000)
//       |> fn(t) { Transaction { ..t, extra_signatories: [] } }

//   let datum = Some(create_test_task_datum(1, payment, Open, None))
//   let redeemer = TaskRedeemer { task_id: 1, action: TimeoutRefund }

//   gigs_escrow.spend(tasker_pkh, platform_pkh, policy_id, datum, redeemer, mock_utxo_ref(0, 0), tx)
// }

// /// Test: Timeout refund successfully for Assigned task
// test timeout_refund_assigned_success() {
//   let policy_id = mock_policy_id(0)
//   let tasker_pkh = mock_pub_key_hash(0)
//   let platform_pkh = mock_pub_key_hash(5)
//   let worker_pkh = mock_pub_key_hash(1)
//   let payment = 50_000_000
//   let past_deadline = 1_700_000_000_000 + 31 * 24 * 60 * 60 * 1000
  
//   let tx =
//     mocktail_tx()
//       |> tx_out(True, mock_pub_key_address(0, None), from_lovelace(payment))
//       |> invalid_before(True, past_deadline)
//       |> invalid_hereafter(True, past_deadline + 10_000)
//       |> complete()
//       |> set_fee(True, 2_000_000)
//       |> fn(t) { Transaction { ..t, extra_signatories: [] } }

//   let datum = Some(create_test_task_datum(1, payment, Assigned, Some(worker_pkh)))
//   let redeemer = TaskRedeemer { task_id: 1, action: TimeoutRefund }

//   gigs_escrow.spend(tasker_pkh, platform_pkh, policy_id, datum, redeemer, mock_utxo_ref(0, 0), tx)
// }

// /// Test: Timeout refund fails before deadline
// test timeout_refund_fail_before_deadline() fail {
//   let policy_id = mock_policy_id(0)
//   let tasker_pkh = mock_pub_key_hash(0)
//   let platform_pkh = mock_pub_key_hash(5)
//   let worker_pkh = mock_pub_key_hash(1)
//   let payment = 50_000_000
//   let before_deadline = 1_700_000_000_000 + 10 * 24 * 60 * 60 * 1000
  
//   let tx =
//     mocktail_tx()
//       |> tx_out(True, mock_pub_key_address(0, None), from_lovelace(payment))
//       |> invalid_before(True, before_deadline)
//       |> invalid_hereafter(True, before_deadline + 10_000)
//       |> complete()
//       |> set_fee(True, 2_000_000)
//       |> fn(t) { Transaction { ..t, extra_signatories: [] } }

//   let datum = Some(create_test_task_datum(1, payment, Assigned, Some(worker_pkh)))
//   let redeemer = TaskRedeemer { task_id: 1, action: TimeoutRefund }

//   gigs_escrow.spend(tasker_pkh, platform_pkh, policy_id, datum, redeemer, mock_utxo_ref(0, 0), tx)
// }

// /// Test: Timeout refund fails when Completed
// test timeout_refund_fail_completed() fail {
//   let policy_id = mock_policy_id(0)
//   let tasker_pkh = mock_pub_key_hash(0)
//   let platform_pkh = mock_pub_key_hash(5)
//   let worker_pkh = mock_pub_key_hash(1)
//   let payment = 50_000_000
//   let past_deadline = 1_700_000_000_000 + 31 * 24 * 60 * 60 * 1000
  
//   let tx =
//     mocktail_tx()
//       |> tx_out(True, mock_pub_key_address(0, None), from_lovelace(payment))
//       |> invalid_before(True, past_deadline)
//       |> invalid_hereafter(True, past_deadline + 10_000)
//       |> complete()
//       |> set_fee(True, 2_000_000)
//       |> fn(t) { Transaction { ..t, extra_signatories: [] } }

//   let datum = Some(create_test_task_datum(1, payment, Completed, Some(worker_pkh)))
//   let redeemer = TaskRedeemer { task_id: 1, action: TimeoutRefund }

//   gigs_escrow.spend(tasker_pkh, platform_pkh, policy_id, datum, redeemer, mock_utxo_ref(0, 0), tx)
// }

// /// Test: Timeout release successfully
// test timeout_release_success() {
//   let policy_id = mock_policy_id(0)
//   let tasker_pkh = mock_pub_key_hash(0)
//   let platform_pkh = mock_pub_key_hash(5)
//   let worker_pkh = mock_pub_key_hash(1)
//   let payment = 50_000_000
//   let worker_payment = calculate_worker_payment(payment)
//   let platform_fee = calculate_platform_fee(payment)
//   let past_grace = 1_700_000_000_000 + 38 * 24 * 60 * 60 * 1000 // 38 days
  
//   let tx =
//     mocktail_tx()
//       |> tx_out(True, mock_pub_key_address(1, None), from_lovelace(worker_payment))
//       |> tx_out(True, mock_pub_key_address(5, None), from_lovelace(platform_fee))
//       |> invalid_before(True, past_grace)
//       |> invalid_hereafter(True, past_grace + 10_000)
//       |> complete()
//       |> set_fee(True, 2_000_000)
//       |> fn(t) { Transaction { ..t, extra_signatories: [] } }

//   let datum = Some(create_test_task_datum(1, payment, Completed, Some(worker_pkh)))
//   let redeemer = TaskRedeemer { task_id: 1, action: TimeoutRelease }

//   gigs_escrow.spend(tasker_pkh, platform_pkh, policy_id, datum, redeemer, mock_utxo_ref(0, 0), tx)
// }

// /// Test: Timeout release fails during grace period
// test timeout_release_fail_grace_period() fail {
//   let policy_id = mock_policy_id(0)
//   let tasker_pkh = mock_pub_key_hash(0)
//   let platform_pkh = mock_pub_key_hash(5)
//   let worker_pkh = mock_pub_key_hash(1)
//   let payment = 50_000_000
//   let worker_payment = calculate_worker_payment(payment)
//   let platform_fee = calculate_platform_fee(payment)
//   let during_grace = 1_700_000_000_000 + 33 * 24 * 60 * 60 * 1000 // 33 days
  
//   let tx =
//     mocktail_tx()
//       |> tx_out(True, mock_pub_key_address(1, None), from_lovelace(worker_payment))
//       |> tx_out(True, mock_pub_key_address(5, None), from_lovelace(platform_fee))
//       |> invalid_before(True, during_grace)
//       |> invalid_hereafter(True, during_grace + 10_000)
//       |> complete()
//       |> set_fee(True, 2_000_000)
//       |> fn(t) { Transaction { ..t, extra_signatories: [] } }

//   let datum = Some(create_test_task_datum(1, payment, Completed, Some(worker_pkh)))
//   let redeemer = TaskRedeemer { task_id: 1, action: TimeoutRelease }

//   gigs_escrow.spend(tasker_pkh, platform_pkh, policy_id, datum, redeemer, mock_utxo_ref(0, 0), tx)
// }

// /// Test: Wrong task ID fails
// test wrong_task_id_fail() fail {
//   let policy_id = mock_policy_id(0)
//   let tasker_pkh = mock_pub_key_hash(0)
//   let platform_pkh = mock_pub_key_hash(5)
  
//   let tx = create_simple_tx([tasker_pkh], [50_000_000])

//   let datum = Some(create_test_task_datum(1, 50_000_000, Open, None))
//   let redeemer = TaskRedeemer { task_id: 99, action: CancelTask }

//   gigs_escrow.spend(tasker_pkh, platform_pkh, policy_id, datum, redeemer, mock_utxo_ref(0, 0), tx)
// }

// /// Test: Parameterization prevents cross-task attacks
// test wrong_tasker_parameter_fail() fail {
//   let policy_id = mock_policy_id(0)
//   let correct_tasker = mock_pub_key_hash(0)
//   let wrong_tasker = mock_pub_key_hash(9)
//   let platform_pkh = mock_pub_key_hash(5)
  
//   let tx = create_simple_tx([correct_tasker], [50_000_000])

//   let datum = Some(create_test_task_datum(1, 50_000_000, Open, None))
//   let redeemer = TaskRedeemer { task_id: 1, action: CancelTask }

//   // Validator parameterized with wrong tasker
//   gigs_escrow.spend(wrong_tasker, platform_pkh, policy_id, datum, redeemer, mock_utxo_ref(0, 0), tx)
// }