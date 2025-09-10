#!/usr/bin/env node

// Standalone script to generate SS58 public key from an EVM address
// Usage: node generate-ss58-key.js <eth-address> [nonce]

import { getAddress } from "ethers";
import { convertH160ToPublicKeyHex } from "./address-utils.js";

// Main execution
async function main() {
  const args = process.argv.slice(1);

  if (args.length === 0) {
    console.error("Usage: node convert-h160-to-public-key.js <eth-address> ");
    console.error("Examples:");
    console.error(
      "  node convert-h160-to-public-key.js 0x123...abc           # Convert existing address"
    );
    process.exit(1);
  }

  let ethAddress = getAddress(args[1]);

  console.log(`Contract Address: ${ethAddress}`);

  const ss58PublicKeyHex = await convertH160ToPublicKeyHex(ethAddress);
  console.log(`SS58 Public Key (bytes32): ${ss58PublicKeyHex}`);
}

main().catch((error) => {
  console.error("Error:", error);
  process.exit(1);
});
