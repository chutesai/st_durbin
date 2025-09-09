#!/usr/bin/env node

// Standalone script to generate SS58 public key from an EVM address
// Usage: node generate-ss58-key.js <eth-address> [nonce]

import { blake2AsU8a, encodeAddress } from "@polkadot/util-crypto";
import { hexToU8a } from "@polkadot/util";
import { getAddress } from "ethers";

/**
 * Calculates the Substrate-compatible public key (bytes32) from an EVM H160 address.
 * @param {string} ethAddress - The H160 EVM address (e.g., "0x123...").
 * @returns {Uint8Array} The 32-byte public key.
 */
function convertH160ToPublicKey(ethAddress) {
  const prefix = "evm:";
  const prefixBytes = new TextEncoder().encode(prefix);
  const addressBytes = hexToU8a(
    ethAddress.startsWith("0x") ? ethAddress : `0x${ethAddress}`
  );
  const combined = new Uint8Array(prefixBytes.length + addressBytes.length);

  combined.set(prefixBytes);
  combined.set(addressBytes, prefixBytes.length);

  return blake2AsU8a(combined); // This is a 32-byte hash
}

/**
 * Helper to get the SS58 public key as a hex string
 * @param {string} ethAddress - The H160 EVM address
 * @returns {string} The SS58 public key as a hex string
 */
function convertH160ToPublicKeyHex(ethAddress) {
  const pubKeyBytes = convertH160ToPublicKey(ethAddress);
  return "0x" + Buffer.from(pubKeyBytes).toString("hex");
}

// Main execution
async function main() {
  const args = process.argv.slice(1);

  if (args.length === 0) {
    console.error("Usage: node convert-h160-to-ss58.js <eth-address> ");
    console.error("Examples:");
    console.error(
      "  node convert-h160-to-ss58.js 0x123...abc           # Convert existing address"
    );
    process.exit(1);
  }

  let ethAddress = getAddress(args[1]);

  console.log(`Contract Address: ${ethAddress}`);

  const ss58PublicKeyHex = convertH160ToPublicKeyHex(ethAddress);
  const ss58Address = encodeAddress(ss58PublicKeyHex);
  console.log(`SS58 Address is: ${ss58Address}`);
}

main().catch((error) => {
  console.error("Error:", error);
  process.exit(1);
});
