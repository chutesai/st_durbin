// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.20;

import {IStaking, ISTAKING_ADDRESS} from "./interfaces/IStakingV2.sol";
import {IMetagraph, IMETAGRAPH_ADDRESS} from "./interfaces/IMetagraph.sol";

/**
 * @title SaintDurbin
 * @notice Patron Saint of Bittensor - With Manual Validator Switching
 * @dev Distributes staking rewards to recipients while preserving the principal amount
 * @dev Validator switching must be done manually by emergency operator
 */
contract SaintDurbin {
    // ========== Constants ==========
    uint256 constant MIN_BLOCK_INTERVAL = 7200; // ~24 hours at 12s blocks
    uint256 constant EXISTENTIAL_AMOUNT = 1e9; // 1 TAO in rao (9 decimals)
    uint256 constant BASIS_POINTS = 10000;
    uint256 constant EMERGENCY_TIMELOCK = 86400; // 24 hours timelock for emergency drain
    uint256 constant MIN_UID_COUNT_FOR_SWITCH = 6; // current validator and top 5 validators

    // ========== State Variables ==========

    // Core configuration
    IStaking public immutable staking;
    IMetagraph public immutable metagraph;
    bytes32 public currentValidatorHotkey; // Mutable - can change if validator loses permit
    uint16 public currentValidatorUid; // Track the UID of current validator
    bytes32 public thisSs58PublicKey;
    uint16 public immutable netuid;
    bool public ss58PublicKeySet; // Track if SS58 key has been set

    // Recipients
    struct Recipient {
        bytes32 coldkey;
        uint256 proportion; // Basis points (out of 10,000)
    }

    Recipient[] public recipients;

    // Tracking
    uint256 public principalLocked;
    uint256 public lastTransferBlock;
    uint256 public lastPaymentAmount;

    // Emergency drain
    address public immutable emergencyOperator;
    address public immutable drainAddress;
    bytes32 public immutable drainSs58Address;
    uint256 public emergencyDrainRequestedAt;

    // Reentrancy protection
    bool private locked;

    // Enhanced principal tracking
    uint256 public cumulativeBalanceIncrease;
    uint256 public lastBalanceCheckBlock;

    // ========== Events ==========
    event StakeTransferred(uint256 totalAmount, uint256 newBalance);
    event RecipientTransfer(
        bytes32 indexed coldkey,
        uint256 amount,
        uint256 proportion
    );
    event PrincipalDetected(uint256 amount, uint256 totalPrincipal);
    event EmergencyDrainExecuted(bytes32 indexed drainAddress, uint256 amount);
    event TransferFailed(
        bytes32 indexed coldkey,
        uint256 amount,
        string reason
    );
    event EmergencyDrainRequested(uint256 executionTime);
    event EmergencyDrainCancelled();
    event ValidatorSwitched(
        bytes32 indexed oldHotkey,
        bytes32 indexed newHotkey,
        uint16 newUid,
        string reason
    );
    event ValidatorCheckFailed(string reason);
    event StakeAggregated(
        bytes32 indexed hotkey,
        bytes32 indexed currentValidatorHotkey,
        uint256 amount
    );
    event SS58PublicKeySet(bytes32 indexed newKey);
    event PrincipalUpdated(uint256 newPrincipal);
    event PrincipalUpdatedAfterAggregation(
        uint256 amount,
        uint256 newPrincipal
    );

    // ========== Custom Errors ==========
    error NotEmergencyOperator();
    error InvalidAddress();
    error InvalidHotkey();
    error InvalidProportion();
    error ProportionsMismatch();
    error TransferTooSoon();
    error NoBalance();
    error ReentrancyGuard();
    error TimelockNotExpired();
    error NoPendingRequest();
    error NoValidValidatorFound();
    error StakeMoveFailure();
    error NotEmergencyOperatorOrDrainAddress();
    error SS58KeyAlreadySet();
    error TotalHotkeyAlphaInvalid();

    // ========== Modifiers ==========
    modifier onlyEmergencyOperator() {
        if (msg.sender != emergencyOperator) revert NotEmergencyOperator();
        _;
    }

    modifier emergencyOperatorOrDrainAddress() {
        bool valid = (msg.sender == drainAddress ||
            msg.sender == emergencyOperator);
        if (!valid) revert NotEmergencyOperatorOrDrainAddress();
        _;
    }

    modifier nonReentrant() {
        if (locked) revert ReentrancyGuard();
        locked = true;
        _;
        locked = false;
    }

    // ========== Constructor ==========
    constructor(
        address _emergencyOperator,
        address _drainAddress,
        bytes32 _drainSs58Address,
        bytes32 _validatorHotkey,
        uint16 _validatorUid,
        bytes32 _thisSs58PublicKey,
        uint16 _netuid,
        bytes32[] memory _recipientColdkeys,
        uint256[] memory _proportions
    ) {
        if (_emergencyOperator == address(0)) revert InvalidAddress();
        if (_drainAddress == address(0)) revert InvalidAddress();
        if (_drainSs58Address == bytes32(0)) revert InvalidAddress();
        if (_validatorHotkey == bytes32(0)) revert InvalidHotkey();
        if (_thisSs58PublicKey == bytes32(0)) revert InvalidAddress();
        if (_recipientColdkeys.length != _proportions.length)
            revert ProportionsMismatch();
        if (_recipientColdkeys.length != 16) revert ProportionsMismatch();

        emergencyOperator = _emergencyOperator;
        drainSs58Address = _drainSs58Address;
        currentValidatorHotkey = _validatorHotkey;
        currentValidatorUid = _validatorUid;
        thisSs58PublicKey = _thisSs58PublicKey;
        // Will do the coldkey swap, so the init value just a placeholder
        // ss58PublicKeySet = true; // Mark as set since we're setting it in constructor
        netuid = _netuid;
        staking = IStaking(ISTAKING_ADDRESS);
        metagraph = IMetagraph(IMETAGRAPH_ADDRESS);
        drainAddress = _drainAddress;

        // Validate proportions sum to 10000
        uint256 totalProportions = 0;
        for (uint256 i = 0; i < _proportions.length; i++) {
            if (_recipientColdkeys[i] == bytes32(0)) revert InvalidAddress();
            if (_proportions[i] == 0) revert InvalidProportion();
            totalProportions += _proportions[i];

            recipients.push(
                Recipient({
                    coldkey: _recipientColdkeys[i],
                    proportion: _proportions[i]
                })
            );
        }
        if (totalProportions != BASIS_POINTS) revert ProportionsMismatch();

        // Initialize tracking
        lastTransferBlock = block.number;

        // Get initial balance and set as principal
        principalLocked = 0; //_getStakedBalanceHotkey(currentValidatorHotkey);
    }

    // ========== Core Functions ==========

    /**
     * @notice Set the SS58 public key as this contract's Ss58 address
     * It will be called after the swap coldkey
     * @param _thisSs58PublicKey The new SS58 public key to set
     */
    function setThisSs58PublicKey(
        bytes32 _thisSs58PublicKey
    ) external onlyEmergencyOperator {
        if (ss58PublicKeySet) revert SS58KeyAlreadySet();
        if (_thisSs58PublicKey == bytes32(0)) revert InvalidAddress();

        thisSs58PublicKey = _thisSs58PublicKey;
        ss58PublicKeySet = true;
        emit SS58PublicKeySet(_thisSs58PublicKey);
    }

     /**
     * @notice Update the principalLocked amount without any transfers/etc. Useful
     * primarily for initial principalLocked setting since on deployment the staked
     * amount will be zero (until coldkey swap).
     */
    function updatePrincipalLocked () external onlyEmergencyOperator {
        principalLocked = _getStakedBalanceHotkey(currentValidatorHotkey);
        emit PrincipalUpdated(principalLocked);
    }

    /**
     * @notice Execute daily yield distribution to all recipients
     * @dev Can be called by anyone when conditions are met
     * @dev Does NOT automatically check validator status
     */
    function executeTransfer(
        uint256 totalHotkeyAlpha
    ) external onlyEmergencyOperator nonReentrant {
        if (!canExecuteTransfer()) revert TransferTooSoon();

        if (totalHotkeyAlpha == 0) revert TotalHotkeyAlphaInvalid();

        // Alpha of hotkey and coldkey in subnet
        uint256 currentBalance = _getStakedBalanceHotkey(
            currentValidatorHotkey
        );

        // If current balance is less than principal locked, means the hotkey didn't get any yield
        // Or stake is moved to other account
        if (currentBalance <= principalLocked) {
            lastTransferBlock = block.number;
            principalLocked = currentBalance;
            lastPaymentAmount = 0;
            return;
        }

        require(
            totalHotkeyAlpha >= currentBalance,
            "Total staked balance is less than current validator hotkey"
        );

        uint256 emission = _getEmission(netuid, currentValidatorUid);

        uint256 rewardEstimate = (emission * currentBalance) / totalHotkeyAlpha;

        uint256 yieldEstimate = (rewardEstimate *
            (block.number - lastTransferBlock)) / 360;

        uint256 increasedBalance = currentBalance - principalLocked;

        uint256 availableYield;
        if (yieldEstimate > increasedBalance) {
            availableYield = increasedBalance;
        } else {
            availableYield = yieldEstimate;
        }

        if (availableYield < EXISTENTIAL_AMOUNT) {
            lastTransferBlock = block.number;
            lastPaymentAmount = 0;
            return;
        }

        // Calculate and execute transfers
        uint256 totalTransferred = 0;
        uint256 remainingYield = availableYield;

        uint256 recipientsLength = recipients.length;

        // Gas optimization - cache recipients length
        for (uint256 i = 0; i < recipientsLength; i++) {
            uint256 recipientAmount;

            // Improved precision handling for last recipient
            if (i == recipientsLength - 1) {
                // Give remaining amount to last recipient to avoid dust
                recipientAmount = remainingYield;
            } else {
                recipientAmount =
                    (availableYield * recipients[i].proportion) /
                    BASIS_POINTS;
                remainingYield -= recipientAmount;
            }

            if (recipientAmount > 0) {
                (bool success, ) = address(staking).call(
                    abi.encodeWithSelector(
                        IStaking.transferStake.selector,
                        recipients[i].coldkey,
                        currentValidatorHotkey,
                        netuid,
                        netuid,
                        recipientAmount
                    )
                );
                if (success) {
                    totalTransferred += recipientAmount;
                    emit RecipientTransfer(
                        recipients[i].coldkey,
                        recipientAmount,
                        recipients[i].proportion
                    );
                } else {
                    emit TransferFailed(
                        recipients[i].coldkey,
                        recipientAmount,
                        "Transfer failed"
                    );
                }
            }
        }

        // Update tracking - get balance BEFORE updating state to prevent reentrancy issues
        uint256 newBalance = _getStakedBalanceHotkey(currentValidatorHotkey);
        principalLocked = newBalance;
        lastTransferBlock = block.number;
        lastPaymentAmount = totalTransferred;

        emit StakeTransferred(totalTransferred, newBalance);
    }

    /**
     * @notice Aggregate stake from other validators to the current validator
     * @dev Moves stake from first found validator to current validator and updates principal
     * @dev Can be called by anyone to consolidate stake
     */
    function aggregateStake() external nonReentrant {
        // Find validators with stake and move to current validator
        uint16 uidCount = 0;
        (bool success, bytes memory returnData) = address(metagraph).staticcall(
            abi.encodeWithSelector(IMetagraph.getUidCount.selector, netuid)
        );
        if (!success) {
            emit ValidatorCheckFailed("Failed to get UID count");
            return;
        }

        uidCount = abi.decode(returnData, (uint16));
        if (uidCount == 0) {
            emit ValidatorCheckFailed("Failed to get UID count");
            return;
        }

        for (uint16 uid = 0; uid < uidCount; uid++) {
            if (uid == currentValidatorUid) continue;

            (success, returnData) = address(metagraph).staticcall(
                abi.encodeWithSelector(
                    IMetagraph.getHotkey.selector,
                    netuid,
                    uid
                )
            );
            if (!success) continue;
            bytes32 hotkey = abi.decode(returnData, (bytes32));

            uint256 stake = _getStakedBalanceHotkey(hotkey);
            if (stake == 0) continue;

            // Get balance before move
            uint256 balanceBefore = _getStakedBalanceHotkey(
                currentValidatorHotkey
            );

            (success, ) = address(staking).call(
                abi.encodeWithSelector(
                    IStaking.moveStake.selector,
                    hotkey,
                    currentValidatorHotkey,
                    netuid,
                    netuid,
                    stake
                )
            );
            if (success) {
                // Get balance after move
                uint256 balanceAfter = _getStakedBalanceHotkey(
                    currentValidatorHotkey
                );
                uint256 actualMoved = balanceAfter - balanceBefore;

                // Update principal to include the moved stake
                principalLocked += actualMoved;

                emit StakeAggregated(
                    hotkey,
                    currentValidatorHotkey,
                    actualMoved
                );
                emit PrincipalUpdatedAfterAggregation(
                    actualMoved,
                    principalLocked
                );
            } else {
                revert StakeMoveFailure();
            }
            break; // Only move from one validator per call
        }
    }

    /**
     * @notice Check current validator status and switch if necessary
     * @dev Internal function that checks metagraph and moves stake if needed
     */
    function _checkAndSwitchValidator() internal {
        _switchToNewValidator("Requested by emergency operator or wallet");
        return;
    }

    /**
     * @notice Switch to a new validator
     * @param reason The reason for switching
     */
    function _switchToNewValidator(string memory reason) internal {
        bytes32 oldHotkey = currentValidatorHotkey;

        // Find best validator based on expected yield (emission * dividends / stake)
        uint16 uidCount = 0;
        (bool success, bytes memory returnData) = address(metagraph).staticcall(
            abi.encodeWithSelector(IMetagraph.getUidCount.selector, netuid)
        );
        if (!success) {
            emit ValidatorCheckFailed("Failed to get UID count");
            return;
        }

        uidCount = abi.decode(returnData, (uint16));
        if (uidCount < MIN_UID_COUNT_FOR_SWITCH) {
            emit ValidatorCheckFailed("Not enough UIDs to choose for switch");
            return;
        }

        // Find validator with best expected yield
        uint16 bestUid = 0;
        bytes32 bestHotkey = bytes32(0);
        uint256 bestYieldScore = 0; // emission * dividends / stake
        bool foundValid = false;

        for (uint16 uid = 0; uid < uidCount; uid++) {
            if (uid == currentValidatorUid) continue;
            (success, returnData) = address(metagraph).staticcall(
                abi.encodeWithSelector(
                    IMetagraph.getValidatorStatus.selector,
                    netuid,
                    uid
                )
            );
            if (!success) continue;
            bool isValidator = abi.decode(returnData, (bool));
            if (!isValidator) continue;

            (success, returnData) = address(metagraph).staticcall(
                abi.encodeWithSelector(
                    IMetagraph.getIsActive.selector,
                    netuid,
                    uid
                )
            );
            if (!success) continue;
            bool isActive = abi.decode(returnData, (bool));
            if (!isActive) continue;

            // Get emission
            (success, returnData) = address(metagraph).staticcall(
                abi.encodeWithSelector(
                    IMetagraph.getEmission.selector,
                    netuid,
                    uid
                )
            );
            if (!success) continue;
            uint64 emission = abi.decode(returnData, (uint64));
            if (emission == 0) continue;

            // Get stake
            (success, returnData) = address(metagraph).staticcall(
                abi.encodeWithSelector(
                    IMetagraph.getStake.selector,
                    netuid,
                    uid
                )
            );
            if (!success) continue;
            uint64 stake = abi.decode(returnData, (uint64));
            if (stake == 0) continue;
            // Get dividends (validator take)
            (success, returnData) = address(metagraph).staticcall(
                abi.encodeWithSelector(
                    IMetagraph.getDividends.selector,
                    netuid,
                    uid
                )
            );
            if (!success) continue;
            uint64 dividends = abi.decode(returnData, (uint64));
            // Calculate yield score: (emission * dividends) / stake
            // This represents expected return per unit of stake

            // dividends is in basis points (0-65535 where 65535 = 100%)
            uint256 yieldScore = (uint256(emission) * uint256(dividends)) /
                uint256(stake);

            if (yieldScore > bestYieldScore) {
                bestYieldScore = yieldScore;
                bestUid = uid;
                // Get hotkey for best validator
                (success, returnData) = address(metagraph).staticcall(
                    abi.encodeWithSelector(
                        IMetagraph.getHotkey.selector,
                        netuid,
                        uid
                    )
                );
                if (!success) continue;
                bestHotkey = abi.decode(returnData, (bytes32));
                foundValid = true;
            }
        }
        if (!foundValid || bestHotkey == bytes32(0)) {
            emit ValidatorCheckFailed("No valid validator found");
            return;
        }
        // Get balance before move
        uint256 balanceBefore = _getStakedBalanceHotkey(currentValidatorHotkey);

        // Move stake to new validator
        uint256 currentStake = balanceBefore;
        if (currentStake > 0) {
            (success, ) = address(staking).call(
                abi.encodeWithSelector(
                    IStaking.moveStake.selector,
                    currentValidatorHotkey,
                    bestHotkey,
                    netuid,
                    netuid,
                    currentStake
                )
            );
            if (!success) {
                emit ValidatorCheckFailed(
                    "Failed to move stake to new validator"
                );
                return;
            }
        }

        uint256 balanceAfter = _getStakedBalanceHotkey(bestHotkey);
        currentValidatorHotkey = bestHotkey;
        currentValidatorUid = bestUid;
        emit ValidatorSwitched(oldHotkey, bestHotkey, bestUid, reason);
    }

    /**
     * @notice Manually trigger validator check and switch
     * @dev Can only be called by emergency operator or drain address
     */
    function checkAndSwitchValidator()
        external
        emergencyOperatorOrDrainAddress
    {
        _checkAndSwitchValidator();
    }

    /**
     * @notice Request emergency drain with timelock (emergency operator or drain address)
     * @dev Added timelock mechanism for emergency drain
     */
    function requestEmergencyDrain() external onlyEmergencyOperator {
        emergencyDrainRequestedAt = block.timestamp;
        emit EmergencyDrainRequested(block.timestamp + EMERGENCY_TIMELOCK);
    }

    /**
     * @notice Execute emergency drain after timelock expires
     * @dev Can only be executed by emergency operator after timelock period
     */
    function executeEmergencyDrain()
        external
        onlyEmergencyOperator
        nonReentrant
    {
        if (emergencyDrainRequestedAt <= 0) revert NoPendingRequest();
        if (block.timestamp < emergencyDrainRequestedAt + EMERGENCY_TIMELOCK)
            revert TimelockNotExpired();

        uint256 balance = _getStakedBalanceHotkey(currentValidatorHotkey);
        if (balance == 0) revert NoBalance();

        // Reset the request timestamp BEFORE external call to prevent reentrancy
        emergencyDrainRequestedAt = 0;

        (bool success, ) = address(staking).call(
            abi.encodeWithSelector(
                IStaking.transferStake.selector,
                drainSs58Address,
                currentValidatorHotkey,
                netuid,
                netuid,
                balance
            )
        );
        if (success) {
            emit EmergencyDrainExecuted(drainSs58Address, balance);
        } else {
            // Restore the request timestamp on failure
            emergencyDrainRequestedAt = block.timestamp - EMERGENCY_TIMELOCK;
            revert StakeMoveFailure();
        }
    }

    /**
     * @notice Cancel pending emergency drain request
     * @dev Can be called by emergency operator or drain address
     */
    function cancelEmergencyDrain() external emergencyOperatorOrDrainAddress {
        if (emergencyDrainRequestedAt <= 0) revert NoPendingRequest();

        emergencyDrainRequestedAt = 0;
        emit EmergencyDrainCancelled();
    }

    // ========== View Functions ==========

    /**
     * @notice Get the current staked balance
     * @return The total staked balance
     */
    function getStakedBalance() public view returns (uint256) {
        return _getStakedBalanceHotkey(currentValidatorHotkey);
    }

    /**
     * @notice Internal helper to get staked balance
     */
    function _getStakedBalanceHotkey(
        bytes32 hotkey
    ) internal view returns (uint256) {
        (bool success, bytes memory returnData) = address(staking).staticcall(
            abi.encodeWithSelector(
                IStaking.getStake.selector,
                hotkey,
                thisSs58PublicKey,
                netuid
            )
        );
        require(success, "Precompile call failed: getStake");
        return abi.decode(returnData, (uint256));
    }
    /**
     * @notice Internal helper to get emission
     */
    function _getEmission(
        uint256 _netuid,
        uint256 uid
    ) internal view returns (uint256) {
        (bool success, bytes memory returnData) = address(metagraph).staticcall(
            abi.encodeWithSelector(IMetagraph.getEmission.selector, _netuid, uid)
        );
        require(success, "Precompile call failed: getEmission");
        uint64 result = abi.decode(returnData, (uint64));
        return uint256(result);
    }

    /**
     * @notice Check if transfer can be executed
     * @return True if transfer conditions are met
     */
    function canExecuteTransfer() public view returns (bool) {
        return block.number >= lastTransferBlock + MIN_BLOCK_INTERVAL;
    }

    /**
     * @notice Get blocks until next transfer is allowed
     * @return Number of blocks remaining
     */
    function blocksUntilNextTransfer() external view returns (uint256) {
        uint256 nextTransferBlock = lastTransferBlock + MIN_BLOCK_INTERVAL;
        if (block.number >= nextTransferBlock) {
            return 0;
        }
        return nextTransferBlock - block.number;
    }

    /**
     * @notice Get available rewards for distribution
     * @return The available yield amount
     */
    function getAvailableRewards() external view returns (uint256) {
        uint256 currentBalance = _getStakedBalanceHotkey(
            currentValidatorHotkey
        );
        if (currentBalance <= principalLocked) {
            return 0;
        }
        return currentBalance - principalLocked;
    }

    /**
     * @notice Get current validator info
     * @return hotkey The current validator hotkey
     * @return uid The current validator UID
     * @return isValid Whether the current validator still has a permit
     */
    function getCurrentValidatorInfo()
        external
        view
        returns (bytes32 hotkey, uint16 uid, bool isValid)
    {
        hotkey = currentValidatorHotkey;
        uid = currentValidatorUid;
        (bool success, bytes memory returnData) = address(metagraph).staticcall(
            abi.encodeWithSelector(
                IMetagraph.getValidatorStatus.selector,
                netuid,
                currentValidatorUid
            )
        );
        if (success) {
            isValid = abi.decode(returnData, (bool));
        } else {
            isValid = false;
        }
    }

    /**
     * @notice Get the number of recipients
     * @return The total number of recipients
     */
    function getRecipientCount() external view returns (uint256) {
        return recipients.length;
    }

    /**
     * @notice Get recipient details by index
     * @param index The recipient index
     * @return coldkey The recipient's coldkey
     * @return proportion The recipient's proportion in basis points
     */
    function getRecipient(
        uint256 index
    ) external view returns (bytes32 coldkey, uint256 proportion) {
        require(index < recipients.length, "Invalid index");
        Recipient memory recipient = recipients[index];
        return (recipient.coldkey, recipient.proportion);
    }

    /**
     * @notice Get all recipients in a single call
     * @dev Gas-efficient way to retrieve all recipients
     * @return coldkeys Array of recipient coldkeys
     * @return proportions Array of recipient proportions
     */
    function getAllRecipients()
        external
        view
        returns (bytes32[] memory coldkeys, uint256[] memory proportions)
    {
        uint256 length = recipients.length;
        coldkeys = new bytes32[](length);
        proportions = new uint256[](length);

        for (uint256 i = 0; i < length; i++) {
            coldkeys[i] = recipients[i].coldkey;
            proportions[i] = recipients[i].proportion;
        }

        return (coldkeys, proportions);
    }

    /**
     * @notice Check if emergency drain is pending
     * @return isPending True if emergency drain is pending
     * @return timeRemaining Seconds until drain can be executed (0 if executable)
     */
    function getEmergencyDrainStatus()
        external
        view
        returns (bool isPending, uint256 timeRemaining)
    {
        isPending = emergencyDrainRequestedAt > 0;
        if (
            isPending &&
            block.timestamp < emergencyDrainRequestedAt + EMERGENCY_TIMELOCK
        ) {
            timeRemaining =
                (emergencyDrainRequestedAt + EMERGENCY_TIMELOCK) -
                block.timestamp;
        } else {
            timeRemaining = 0;
        }
    }
}
