import sys
from substrateinterface import Keypair

ss58_address = sys.argv[1]
keypair = Keypair(ss58_address=ss58_address)
hex_address = keypair.public_key.hex()
hex_address = "0x" + hex_address
print(f"{ss58_address=} {hex_address=}")
