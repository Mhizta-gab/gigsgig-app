// This validator mints an nft for both taskers and workers as identification on Gigsgig platform
use cardano/transaction.{OutputReference, Transaction, find_input}
use cardano/assets.{PolicyId, from_lovelace}
use aiken/primitive/bytearray.{starts_with}
use aiken/collection/dict
use mocktail.{mocktail_tx, mint, mock_policy_id, mock_tx_hash, mock_utxo_ref, mock_script_address, complete, tx_in}


pub type MintType {
    MintTasker
    MintWorker
}

fn token_name_prefix1() -> ByteArray {
    "GigsTasker"
}

fn token_name_prefix2() -> ByteArray {
    "GigsWorker"
}


// Validator conditions
// 1. The minting transaction must mint exactly 1 token
// 2. The minting transaction must contain the input UTXO param
// 2. The token name must match the predefined names for taskers and workers

validator mint_user(input_utxo: OutputReference) {
    mint(
        redeemer: MintType,
        policy_id: PolicyId,
        tx: Transaction
    ) {
        let Transaction {inputs, mint, ..}  = tx
        expect Some(_own_input) = find_input(inputs, input_utxo)
        expect [Pair(asset_name , amount)] =
          mint 
            |> assets.tokens(policy_id)
            |> dict.to_pairs()

        let valid_amount = amount == 1

        when redeemer is {
            MintTasker -> {
                let valid_token_name = starts_with(asset_name, token_name_prefix1())
                valid_token_name && valid_amount
            }
            MintWorker -> {
                let valid_token_name = starts_with(asset_name, token_name_prefix2())
                valid_token_name && valid_amount
            }
        }
    }

    else(_) {
        fail
    }
}


// TESTING

pub fn token_name(token_type: MintType) -> ByteArray {
    when token_type is {
        MintTasker -> "GigsTasker00001"
        MintWorker -> "GigsWorker00001"
    }
}

pub fn minting_tx(tk: MintType) -> Transaction {
    mocktail_tx()
        |> tx_in(
            True, 
            mock_tx_hash(0),
            0,
            from_lovelace(1_000_000),
            mock_script_address(0, None),
        )
        |> mint(
            True,
            1,
            mock_policy_id(0),
            token_name(tk)
        )
        |> complete()
}

test mint_tasker_nft() {
    let ref = mock_utxo_ref(0, 0)
    let redeemer = MintTasker
    let policy_id = mock_policy_id(0)

    mint_user.mint(ref, redeemer, policy_id, minting_tx(redeemer))
}

test mint_worker_nft() {
    let ref = mock_utxo_ref(0, 0)
    let redeemer = MintWorker
    let policy_id = mock_policy_id(0)

    mint_user.mint(ref, redeemer, policy_id, minting_tx(redeemer))
}