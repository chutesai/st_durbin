# SaintDurbin Deployment Guide

This guide explains how to deploy the SaintDurbin contract with the correct SS58 public key configuration.

## Pre-Deployment Steps

### 1. Prepare coldkey and hotkey

Install the btcli, to create both coldkey and hotkey.

```bash
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/opentensor/bittensor/master/scripts/install.sh)"
btcli wallet new-coldkey
btcli wallet new-hotkey
```

Register neuron, creating the coldkey and hotkey relation

```bash
btcli subnets register --netuid 1
```

### 2. Set Environment Variables

Create a `.env` file or export the following environment variables:

```bash
# Contract configuration
export CONTRACT_SS58_KEY="0x..."  # From step 1
export EMERGENCY_OPERATOR="0x..."  # EVM address of emergency operator
export DRAIN_SS58_ADDRESS="0x..."  # SS58 public key for emergency drain
export VALIDATOR_HOTKEY="0x..."    # Initial validator's SS58 hotkey
export VALIDATOR_UID=123           # Initial validator's UID
export NETUID=1                    # Subnet ID

# Recipients (SS58 public keys)
export RECIPIENT_SAM="0x..."
export RECIPIENT_WSL="0x..."
export RECIPIENT_PAPER="0x..."
export RECIPIENT_FLORIAN="0x..."
export RECIPIENT_4="0x..."
# ... continue for all 16 recipients
export RECIPIENT_15="0x..."
```

Notes:
Sine the precompile can't get the original caller. The SS58 public key will be used a coldkey for following contract operations like moveStake. But as a new deployed contract, there is no fund, no connected hotkey. The initial value of thisSs58PublicKey can be set as the coldkey's public key. Later, we will use the coldkey to send coldkey_swap extrinsic to change it as deployed contract's public key.

### 3. Deploy the Contract

```bash
# Deploy using Foundry
forge script script/DeploySaintDurbin.s.sol:DeploySaintDurbin \
  --rpc-url $RPC_URL \
  --private-key $PRIVATE_KEY \
  --broadcast \
  --verify
```

Then just update the initial principal locked manually.
```bash
cast send $DEPLOYED_ADDRESS "updatePrincipalLocked()" --rpc-url $RPC_URL --private-key $PRIVATE_KEY --legacy
```

### 4. Send coldkey_swap extrinsic

Get the SS58 address of contract, then use it as new coldkey

```bash
cd scripts
npm install  # Install dependencies if not already done
node convert-h160-to-ss58.js $DEPLOYED_ADDRESS
# output like,
Contract Address: 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2
SS58 Address is: 5FBpj1M73tNRZ8qWW5nGFYnUQgZ5SdrBPw5j2VUebmL6UsZ7
```

Btcli command to send swap-coldkey extrinsic.

```bash
btcli wallet swap-coldkey --new-coldkey 5FBpj1M73tNRZ8qWW5nGFYnUQgZ5SdrBPw5j2VUebmL6UsZ7
```

Duration defined in the rust code.

```bash

pub const InitialColdkeySwapScheduleDuration: BlockNumber = 5 * 24 * 60 * 60 / 12; // 5 days
pub fn schedule_swap_coldkey(
   origin: OriginFor<T>,
   new_coldkey: T::AccountId,
) -> DispatchResultWithPostInfo {

```

After 5 days, the coldkey swap will be executed. All funds will be transferred to contract, also the coldkey/hotkey relations.
Note: the duration could be updated on chain. need to check before sending the extrinsic.

### 5. set the Contract's SS58 Public Key

get the SS58 public key from contract address

```bash
cd scripts
npm install  # Install dependencies if not already done
node convert-h160-to-public-key.js $DEPLOYED_ADDRESS
# output like, a 32 bytes hex string
SS58 Public Key (bytes32): 0xdbb1da614802ea83f7b0fd97279204316cdc1fb62386d44c4fb0b3489a7657c9
```

call setThisSs58PublicKey with correct SS58_PUBLIC_KEY

```bash
   export SS58_PUBLIC_KEY=""
   cast send $CONTRACT "setThisSs58PublicKey(bytes32)" \
   $SS58_PUBLIC_KEY \
     --private-key $EMERGENCY_KEY
```

### 6 Run the regular task like executeTransfer, aggregateStake according difference frequency. It is also important to query the data stakedBalance, principleLocked, we can know the status of contract.

For executeTransfer, we need to know the totalHotkeyAlpha before calling it. the value is from storage

```bash
# parameters are current hotkey and netuid
api.query.SubtensorModule.TotalHotkeyAlpha.getValue
```

For aggregateStake, we need to iterate all uids in subnet and get how many stake from current contract address. Based on the data, we can decide if to run aggregateStake.

## Important Notes

1. **SS58 Key Generation**: The `CONTRACT_SS58_KEY` MUST be generated from the contract's deployment address using the Blake2b-256 hash of `"evm:" + contract_address`. This is how the Bittensor precompiles identify the contract.

2. **Address Types**:

   - `EMERGENCY_OPERATOR`: Standard EVM address (20 bytes)
   - All other addresses: SS58 public keys (32 bytes)

3. **Immutability**: Once deployed, the contract configuration cannot be changed. Double-check all values before deployment.

## Verification

After deployment, verify:

1. The contract's `thisSs58PublicKey` matches your pre-calculated value
2. The contract can successfully call `getStakedBalance()`
3. All recipients are correctly configured

## Troubleshooting

- **"Precompile call failed: getStake"**: Likely means the SS58 key is incorrect. Verify you calculated it from the correct contract address.
- **Invalid recipient addresses**: Ensure all recipient coldkeys are 32-byte SS58 public keys, not EVM addresses.
