## Deploying the smart contract.

This guide explains how to deploy the SaintDurbin contract, single recipient version.

### 0. Prepare EVM wallets

You'll need an emergency operator wallet, and an emergency drain target wallet. You probably want both to be very, very secure, although the emergency operator needs to run fairly often to do executeTransfer and such, so it still needs to be accessible.

Simple example with cast:
```
$ cast wallet new
Successfully created new keypair.
Address:     0xEe453A12f277CD0DfE374EFDD6d5ec68144fe327
Private key: 0x90bfdaf84317da5c9b9e5344a02744769a7493578505ea5f09e6dae05767d0eb
```

For both wallets, you will (eventually) need free tao on the accounts to pay for gas fees.

You can get the ss58 via:
```
cd scripts
npm install
node convert-h160-to-public-key.js 0xEe453A12f277CD0DfE374EFDD6d5ec68144fe327
```

Then just transfer some tao (1 tao is plenty) to each wallet's ss58 (from the conversion script's output).

### 1. Prepare a coldkey

Make sure you have btcli installed, then...
```bash
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

This key is not used for anything in particular, it's really just a temp ss58 address to get a public key to set in the contract (which is subsequently changed after it's actually deployed).

### 2. Set Environment Variables

Create a `.env` file or export the following environment variables:

```bash
# Emergency operator, EVM address, e.g. the `0xEe453A12f277CD0DfE374EFDD6d5ec68144fe327` value from the example.
export EMERGENCY_OPERATOR=0x8...

# The address the emergency drain is sent to, if triggered.
# This is from converting the EVM wallet Address field to a public key,
# e.g.: `cd scripts && node convert-h160-to-public-key.js 0xEe453A12f277CD0DfE374EFDD6d5ec68144fe327
export DRAIN_SS58_ADDRESS=0xd...

# The emergency drain EVM wallet address,
# e.g. `0xEe453A12f277CD0DfE374EFDD6d5ec68144fe327` in the cast wallet example
export DRAIN_ADDRESS=0xE...

# Validator hotkey (MUST be an active validator with >= 1000 TAO stake),
# this is a public key e.g. from using the python script above to convert vali ss58 to public key.
export VALIDATOR_HOTKEY=0x5...

# Validator UID (MUST match the validator hotkey and have permit!)
export VALIDATOR_UID=1

# Contract's SS58 public key, this is the temp new coldkey's public key.
# This is changed immediately after contract is deployed.
export CONTRACT_SS58_KEY=0xa...

# Network UID
export NETUID=64

# Recipient (this is a bittensor coldkey public key).
export RECIPIENT=0x0

# RPC URL for deployment
export RPC_URL=https://lite.chain.opentensor.ai
export BITTENSOR_RPC_URL=https://lite.chain.opentensor.ai

# Private key for deployment, for example the private key of the emergency operator.
export PRIVATE_KEY=...
```

### 3. Deploy the Contract

*If you haven't yet, install forge and then forge-std library.*

*NOTE: You must have free tao (not alpha) on the coldkey associated with $PRIVATE_KEY here! For example, use the `convert-h160-to-ss58.js` in the scripts directory to convert this EVM address to an SS58 and transfer some tao there!*

Load your environment variables, e.g. `source .env`

```bash
forge script \
  script/DeploySaintDurbin.s.sol:DeploySaintDurbin \
  --rpc-url $RPC_URL \
  --private-key $PRIVATE_KEY \
  --broadcast \
  --skip-simulation \
  --legacy \
  --gas-limit 3000000
```

If deployment was successful, you will see (along with other outputs):
`Contract Address: 0xc4...`

This is your smart contract address, and you can get the ss58 using `convert-h160-to-ss58.js` again.

Now, you will need to set the public key in the smart contract:
```
export DEPLOYED_ADDRESS=0x... # replace with the Contract Address output from the deployment.
cd scripts
node convert-h160-to-public-key.js $DEPLOYED_ADDRESS
## That should be use for the public key next.
export SS58_PUBLIC_KEY="0xf7..."
```

Now, use cast to actually call the `setThisSs58PublicKey` method with the updated `SS58_PUBLIC_KEY`
```
cast send $CONTRACT "setThisSs58PublicKey(bytes32)" $SS58_PUBLIC_KEY --private-key $PRIVATE_KEY
```

### 4. Perform a one-time principal stake transfer to the contract and set initial principal

```bash
cd scripts
node convert-h160-to-ss58.js $DEPLOYED_ADDRESS
## output will look like:
# Contract Address: 0xC0
# SS58 Address is: 5F..
```

*Before you do this, make sure the wallet you are doing the stake transfer from has stake ON THE SAME VALIDATOR USED BY SMART CONTRACT!!!"

```
btcli stake transfer --wallet_name wallet-that-has-stake-on-subnet
```
Destination coldkey is the smart contract's ss58

Now, call the `updatePrincipalLocked()` method one time.

```
cast send $DEPLOYED_ADDRESS \
  "updatePrincipalLocked()" \
  --rpc-url $RPC_URL \
  --private-key $PRIVATE_KEY \
  --legacy
```

## Perform regular stake transfers

*NOTE: you will need to wait 24 hours after the contract creation to attempt the first stake transfer.*

*Important! You must calculate stake of the validator before calling executeTransfer!*

There is a script at `scripts/get_total_validator_alpha_stake.py` which you can use to get the total validator stake (in alpha terms) for the subnet, which is required to execute the executeTransfer call (used in emission estimation).

The output of this script is rao, and that's the unit that should be used in the execute transfer as well.

```
python scripts/get_total_validator_alpha_stake.py --validator-hotkey ... --netuid ...
```

Then, you can do an executeTransfer, e.g.:
```bash
cast send $DEPLOYED_ADDRESS \
  "executeTransfer(uint256)" \
  42980569426125 \
  --rpc-url $RPC_URL \
  --private-key $PRIVATE_KEY \
  --legacy
```

This can only run ~once per day (but based on blocks, so not exactly 24 hours).

## Adding principal to the smart contract

To add funds to the smart contract, e.g. sending owner emissions into it, first make sure the origin wallet's stake is on the same validator hotkey as the smart contract's validator hotkey. If not, use `btcli stake move` to move it first.

The safest order of operations here would be:
1. Perform a regular executeTransfer call on the smart contract
2. Perform a stake transfer (e.g. `btcli stake transfer`) from the wallet you are depositing funds into the ss58 address of the smart contract
3. Call `updatePrincipalLocked()` immediately after (once block from 2 is finalized) to ensure the new principal is accounted for and not distributed. This isn't strictly speaking necessary, but it's *probably* safer than using the estimation fallback etc.

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

`PRIVATE_KEY` being the EVM private key of the emergency operator.
`RPC_URL` being https://lite.chain.opentensor.ai
`0x0000000000000000000000000000000000000805` is a fixed constant for the transferStake extrinsic
`0xa644b83acd6e268583e80a9b3c0cf8d357db0ec9307dc3bc25e13a433d367148` is the public key of the emergency drain wallet
`0x5063a3000daa02d892617cda479bc20bb8acf430a8cb167e653c5395b9d4f834` is the public key of the validator the stake is staked to (in this case, chutes primary validator)
5015424592216 is the amount, in rao

You can get the exact amount via:
```bash
$ cast call --rpc-url $RPC_URL \
  0x0000000000000000000000000000000000000805 \
  "getStake(bytes32,bytes32,uint256)" \
  0x5063a3000daa02d892617cda479bc20bb8acf430a8cb167e653c5395b9d4f834 \
  0xd397ff117410a0a84376c7324fd471b95768cf81a48c15267e99c8adfa876e2c \
  64

# outputs something like 0x0000000000000000000000000000000000000000000000000000048fbe99e958
$ cast --to-dec 0x0000000000000000000000000000000000000000000000000000048fbe99e958
# outputs something like 5015424592216, rao
```
