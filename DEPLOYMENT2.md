# SaintDurbin Deployment Guide

This guide explains how to deploy the SaintDurbin contract with the correct SS58 public key configuration.

## Pre-Deployment Steps

### 0. Prepare EVM wallets

You'll need an emergency operator wallet, and an emergency drain target wallet. You probably want both to be very, very secure, although the emergency operator needs to run fairly often to do executeTransfer and such, so it still needs to be accessible.

Simple example with cast:
```
$ cast wallet new
Successfully created new keypair.
Address:     0xEe453A12f277CD0DfE374EFDD6d5ec68144fe327
Private key: 0x90bfdaf84317da5c9b9e5344a02744769a7493578505ea5f09e6dae05767d0eb
```

### 1. Prepare coldkey

Install the btcli, to create coldkey.

```bash
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/opentensor/bittensor/master/scripts/install.sh)"
btcli wallet new-coldkey
```

You can convert regular ss58s to public keys (expected in the env, not ss58s), e.g.:
```python
import sys
from substrateinterface import Keypair
keypair = Keypair(ss58_address=sys.argv[1])
hex_address = keypair.public_key.hex()
hex_address = "0x" + hex_address
print(f"{ss58_address=} {hex_address=}")
```

### 2. Set Environment Variables

Create a `.env` file or export the following environment variables:

```bash
# Emergency operator, EVM address
export EMERGENCY_OPERATOR=0x86...

# Drain destination address
export DRAIN_SS58_ADDRESS=0xd39...
export DRAIN_ADDRESS=0x0...

# Validator hotkey (MUST be an active validator with >= 1000 TAO stake)
export VALIDATOR_HOTKEY=0x50...

# Validator UID (MUST match the validator hotkey and have permit)
export VALIDATOR_UID=1

# Contract's SS58 public key
export CONTRACT_SS58_KEY=0xa6...

# Network UID
export NETUID=64

# Named recipients
export RECIPIENT_SAM=0x3
export RECIPIENT_WSL=0x5
export RECIPIENT_PAPER=0x5
export RECIPIENT_FLORIAN=0x6

# Remaining 12 recipients
export RECIPIENT_4=0x8...
export RECIPIENT_5=0x8...
export RECIPIENT_6=0x8...
export RECIPIENT_7=0x8...
export RECIPIENT_8=0x8...
export RECIPIENT_9=0x8...
export RECIPIENT_10=0x8...
export RECIPIENT_11=0x8...
export RECIPIENT_12=0x8...
export RECIPIENT_13=0x8...
export RECIPIENT_14=0x8...
export RECIPIENT_15=0x8...

# RPC URL for deployment
export RPC_URL=https://lite.chain.opentensor.ai
export BITTENSOR_RPC_URL=https://lite.chain.opentensor.ai

# Private key for deployment (without 0x prefix)
#export PRIVATE_KEY=
```

Note:
Since the precompile can't get the original caller, we'll just use any coldkey address as the contract adddress. Once  the contract is actually deployed, you'll have a contract address which you can map to a public key and then call the setThisSs58PublicKey method.

### 3. Deploy the Contract

```bash
forge script script/DeploySaintDurbin.s.sol:DeploySaintDurbin \
  --rpc-url $RPC_URL \
  --private-key $PRIVATE_KEY \
  --broadcast \
  --verify
```

That will give you the deployed contract address, which you should set in your env: e.g. `export DEPLOYED_ADDRESS=0xd9...`

Then, set the public key in the contract:
```
cd scripts
node convert-h160-to-public-key.js $DEPLOYED_ADDRESS
## That should be use for the public key next.
export SS58_PUBLIC_KEY="0xf77..."
cast send $CONTRACT "setThisSs58PublicKey(bytes32)" $SS58_PUBLIC_KEY --private-key $PRIVATE_KEY
```

You'll also need to map the contract address to an ss58 so you can send tao (not alpha!) to pay for gas fees.
```
node convert-h160-to-ss58.js $DEPLOYED_ADDRESS
```

### 4. Send coldkey_swap extrinsic

You need to perform a coldkey swap, from a wallet that has the stake on the same validator used in the smart contract, so the contract will "own" the stake.

*_note: I think this whole section may be fake news actually.. I think you can simply do a stake transfer after the contract is deployed to the contract ss58 and it would be owned._*

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
btcli wallet swap-coldkey --new-coldkey 5FB...
```

After 5 days, the coldkey swap will be executed. All funds will be transferred to contract.

### 5 Run the regular task like executeTransfer, aggregateStake according difference frequency. It is also important to query the data stakedBalance, principleLocked, we can know the status of contract.

For executeTransfer, we need to know the totalHotkeyAlpha before calling it, e.g.:
```python
from substrateinterface import SubstrateInterface
substrate = SubstrateInterface(
    url="wss://entrypoint-finney.opentensor.ai:443"
)
hotkey = "5Dt7HZ7Zpw4DppPxFM7Ke3Cm7sDAWhsZXmM5ZAmE7dSVJbcQ"
netuid = 64
result = substrate.query(
    module='SubtensorModule',
    storage_function='TotalHotkeyAlpha',
    params=[hotkey, netuid]
)
print(f"TotalHotkeyAlpha: {result.value}")
```

Then, you can do an executeTransfer, e.g.:
```bash
cast send $DEPLOYED_ADDRESS "executeTransfer(uint256)" 408350439527591 --rpc-url $RPC_URL --private-key $PRIVATE_KEY --legacy
```

For aggregateStake, we need to iterate all uids in subnet and get how many stake from current contract address. Based on the data, we can decide if to run aggregateStake.

## Important Notes

1. **SS58 Key Generation**: The `CONTRACT_SS58_KEY` MUST be generated from the contract's deployment address using the Blake2b-256 hash of `"evm:" + contract_address`. This is how the Bittensor precompiles identify the contract. (scripts do this)

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

## Example commands

### trigger drain (not execute, just trigger with 24 hour delay)
```
cast send $DEPLOYED_ADDRESS "requestEmergencyDrain()" --rpc-url $RPC_URL --private-key $PRIVATE_KEY --legacy
```

### execute drain (24+ hours after emergency drain requested)
```
cast send $DEPLOYED_ADDRESS "executeEmergencyDrain()" --rpc-url $RPC_URL --private-key $PRIVATE_KEY --legacy
```

### execute transfer
```
cast send $DEPLOYED_ADDRESS "executeTransfer(uint256)" 408350439527591 --rpc-url $RPC_URL --private-key $PRIVATE_KEY --legacy
```

### after an emergency drain has fully executed, transfer stake to a normal bittensor wallet
```
cast send \
  --private-key $PRIVATE_KEY \
  --rpc-url $RPC_URL \
  --gas-limit 1000000 \
  0x0000000000000000000000000000000000000805 \
  "transferStake(bytes32,bytes32,uint256,uint256,uint256)" \
  0xa644b83acd6e268583e80a9b3c0cf8d357db0ec9307dc3bc25e13a433d367148 \
  0x5063a3000daa02d892617cda479bc20bb8acf430a8cb167e653c5395b9d4f834 \
  64 \
  64 \
  5015424592216
```

PRIVATE_KEY being the EVM private key of the emergency operator.
RPC_URL being https://lite.chain.opentensor.ai
`0x0000000000000000000000000000000000000805` is a fixed constant for the transferStake extrinsic
`0xa644b83acd6e268583e80a9b3c0cf8d357db0ec9307dc3bc25e13a433d367148` is the public key of the emergency drain wallet
`0x5063a3000daa02d892617cda479bc20bb8acf430a8cb167e653c5395b9d4f834` is the public key of the validator the stake is staked to (in this case, chutes primary validator)
5015424592216 is the amount, in rao

You can get the exact amount via:
```bash
$ cast call   --rpc-url $RPC_URL   0x0000000000000000000000000000000000000805   "getStake(bytes32,bytes32,uint256)"  0x5063a3000daa02d892617cda479bc20bb8acf430a8cb167e653c5395b9d4f834  0xd397ff117410a0a84376c7324fd471b95768cf81a48c15267e99c8adfa876e2c   64
0x0000000000000000000000000000000000000000000000000000048fbe99e958
$ cast --to-dec 0x0000000000000000000000000000000000000000000000000000048fbe99e958
5015424592216
```
