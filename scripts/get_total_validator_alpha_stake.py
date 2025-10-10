import asyncio
from bittensor_cli.src.bittensor.subtensor_interface import SubtensorInterface

async def get_stake(validator_hotkey: str, netuid: int):
    subtensor = SubtensorInterface("finney")
    block_hash = await subtensor.substrate.get_chain_head()
    metagraph = await subtensor.get_mechagraph_info(
        netuid, 0, block_hash=block_hash
    )
    for uid in range(len(metagraph["hotkeys"])):
        hotkey = metagraph["hotkeys"][uid]
        if hotkey == validator_hotkey:
            print(f"Total stake of {validator_hotkey=} on {netuid=} = {metagraph['total_stake'][uid].rao}")
            return
    print(f"Failed to find {validator_hotkey=} on {netuid=} metagraph!")

async def main():
    from argparse import ArgumentParser
    parser = ArgumentParser()
    parser.add_argument("--validator-hotkey", default="5DUEMEBMP64qHfR8YKRBtNS338uegXdAqq4sDZN95Mi64MUV", type=str, help="Validator hotkey ss58 to check stake of.")
    parser.add_argument("--netuid", default=64, type=int, help="Subnet netuid to check stake on.")
    args = parser.parse_args()
    await get_stake(validator_hotkey=args.validator_hotkey, netuid=args.netuid)

asyncio.run(main())
