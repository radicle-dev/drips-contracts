// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.8.13;

/// @notice A drips receiver
struct DripsReceiver {
    /// @notice The user ID.
    uint256 userId;
    /// @notice The drips configuration.
    DripsConfig config;
}

/// @notice Describes a drips configuration.
/// It's constructed from `amtPerSec`, `start` and `duration` as
/// `amtPerSec << 64 | start << 32 | duration`.
/// `amtPerSec` is the amount per second being dripped. Must never be zero.
/// It must have additional `Drips._AMT_PER_SEC_EXTRA_DECIMALS` decimals and can have fractions.
/// To achieve that its value must be multiplied by `Drips._AMT_PER_SEC_MULTIPLIER`.
/// `start` is the timestamp when dripping should start.
/// If zero, use the timestamp when drips are configured.
/// `duration` is the duration of dripping.
/// If zero, drip until balance runs out.
type DripsConfig is uint256;

using DripsConfigImpl for DripsConfig global;

library DripsConfigImpl {
    /// @notice Create a new DripsConfig.
    /// @param _amtPerSec The amount per second being dripped. Must never be zero.
    /// It must have additional `Drips._AMT_PER_SEC_EXTRA_DECIMALS` decimals and can have fractions.
    /// To achieve that the passed value must be multiplied by `Drips._AMT_PER_SEC_MULTIPLIER`.
    /// @param _start The timestamp when dripping should start.
    /// If zero, use the timestamp when drips are configured.
    /// @param _duration The duration of dripping.
    /// If zero, drip until balance runs out.
    function create(
        uint192 _amtPerSec,
        uint32 _start,
        uint32 _duration
    ) internal pure returns (DripsConfig) {
        uint256 config = _amtPerSec;
        config = (config << 32) | _start;
        config = (config << 32) | _duration;
        return DripsConfig.wrap(config);
    }

    /// @notice Extracts amtPerSec from a `DripsConfig`
    function amtPerSec(DripsConfig config) internal pure returns (uint192) {
        return uint192(DripsConfig.unwrap(config) >> 64);
    }

    /// @notice Extracts start from a `DripsConfig`
    function start(DripsConfig config) internal pure returns (uint32) {
        return uint32(DripsConfig.unwrap(config) >> 32);
    }

    /// @notice Extracts duration from a `DripsConfig`
    function duration(DripsConfig config) internal pure returns (uint32) {
        return uint32(DripsConfig.unwrap(config));
    }

    /// @notice Compares two `DripsConfig`s.
    /// First compares their `amtPerSec`s, then their `start`s and then their `duration`s.
    function lt(DripsConfig config, DripsConfig otherConfig) internal pure returns (bool) {
        return DripsConfig.unwrap(config) < DripsConfig.unwrap(otherConfig);
    }
}

abstract contract Drips {
    /// @notice Maximum number of drips receivers of a single user.
    /// Limits cost of changes in drips configuration.
    uint8 internal constant _MAX_DRIPS_RECEIVERS = 100;
    /// @notice The additional decimals for all amtPerSec values.
    uint8 internal constant _AMT_PER_SEC_EXTRA_DECIMALS = 18;
    /// @notice The multiplier for all amtPerSec values. It's `10 ** _AMT_PER_SEC_EXTRA_DECIMALS`.
    uint256 internal constant _AMT_PER_SEC_MULTIPLIER = 1_000_000_000_000_000_000;
    /// @notice On every timestamp `T`, which is a multiple of `cycleSecs`, the receivers
    /// gain access to drips received during `T - cycleSecs` to `T - 1`.
    /// Always higher than 1.
    uint32 internal immutable _cycleSecs;
    /// @notice The storage slot holding a single `DripsStorage` structure.
    bytes32 private immutable _dripsStorageSlot;

    /// @notice Emitted when the drips configuration of a user is updated.
    /// @param userId The user ID.
    /// @param assetId The used asset ID
    /// @param receiversHash The drips receivers list hash
    /// @param balance The new drips balance. These funds will be dripped to the receivers.
    event DripsSet(
        uint256 indexed userId,
        uint256 indexed assetId,
        bytes32 indexed receiversHash,
        uint128 balance
    );

    /// @notice Emitted when a user is seen in a drips receivers list.
    /// @param receiversHash The drips receivers list hash
    /// @param userId The user ID.
    /// @param config The drips configuration.
    event DripsReceiverSeen(
        bytes32 indexed receiversHash,
        uint256 indexed userId,
        DripsConfig config
    );

    /// @notice Emitted when drips are received and are ready to be split.
    /// @param userId The user ID
    /// @param assetId The used asset ID
    /// @param amt The received amount.
    /// @param receivableCycles The number of cycles which still can be received.
    event ReceivedDrips(
        uint256 indexed userId,
        uint256 indexed assetId,
        uint128 amt,
        uint32 receivableCycles
    );

    struct DripsStorage {
        /// @notice User drips states.
        /// The keys are the asset ID and the user ID.
        mapping(uint256 => mapping(uint256 => DripsState)) states;
    }

    struct DripsState {
        /// @notice Drips receivers list hash, see `hashDrips`.
        bytes32 dripsHash;
        /// @notice The next cycle to be received
        uint32 nextReceivableCycle;
        /// @notice The time when drips have been configured for the last time
        uint32 updateTime;
        /// @notice The end time of drips without duration
        uint32 defaultEnd;
        /// @notice The balance when drips have been configured for the last time
        uint128 balance;
        /// @notice The changes of received amounts on specific cycle.
        /// The keys are cycles, each cycle `C` becomes receivable on timestamp `C * cycleSecs`.
        /// Values for cycles before `nextReceivableCycle` are guaranteed to be zeroed.
        /// This means that the value of `amtDeltas[nextReceivableCycle].thisCycle` is always
        /// relative to 0 or in other words it's an absolute value independent from other cycles.
        mapping(uint32 => AmtDelta) amtDeltas;
    }

    struct AmtDelta {
        /// @notice Amount delta applied on this cycle
        int128 thisCycle;
        /// @notice Amount delta applied on the next cycle
        int128 nextCycle;
    }

    /// @param cycleSecs The length of cycleSecs to be used in the contract instance.
    /// Low value makes funds more available by shortening the average time of funds being frozen
    /// between being taken from the users' drips balances and being receivable by their receivers.
    /// High value makes receiving cheaper by making it process less cycles for a given time range.
    /// Must be higher than 1.
    /// @param dripsStorageSlot The storage slot to holding a single `DripsStorage` structure.
    constructor(uint32 cycleSecs, bytes32 dripsStorageSlot) {
        require(cycleSecs > 1, "Cycle length too low");
        _cycleSecs = cycleSecs;
        _dripsStorageSlot = dripsStorageSlot;
    }

    /// @notice Counts cycles from which drips can be received.
    /// This function can be used to detect that there are
    /// too many cycles to analyze in a single transaction.
    /// @param userId The user ID
    /// @param assetId The used asset ID
    /// @return cycles The number of cycles which can be flushed
    function _receivableDripsCycles(uint256 userId, uint256 assetId)
        internal
        view
        returns (uint32 cycles)
    {
        uint32 nextReceivableCycle = _dripsStorage().states[assetId][userId].nextReceivableCycle;
        // The currently running cycle is not receivable yet
        uint32 currCycle = _cycleOf(_currTimestamp());
        if (nextReceivableCycle == 0 || nextReceivableCycle > currCycle) return 0;
        return currCycle - nextReceivableCycle;
    }

    /// @notice Calculate effects of calling `receiveDrips` with the given parameters.
    /// @param userId The user ID
    /// @param assetId The used asset ID
    /// @param maxCycles The maximum number of received drips cycles.
    /// If too low, receiving will be cheap, but may not cover many cycles.
    /// If too high, receiving may become too expensive to fit in a single transaction.
    /// @return receivableAmt The amount which would be received
    /// @return receivableCycles The number of cycles which would still be receivable after the call
    function _receivableDrips(
        uint256 userId,
        uint256 assetId,
        uint32 maxCycles
    ) internal view returns (uint128 receivableAmt, uint32 receivableCycles) {
        uint32 allReceivableCycles = _receivableDripsCycles(userId, assetId);
        uint32 receivedCycles = maxCycles < allReceivableCycles ? maxCycles : allReceivableCycles;
        receivableCycles = allReceivableCycles - receivedCycles;
        DripsState storage state = _dripsStorage().states[assetId][userId];
        uint32 receivedCycle = state.nextReceivableCycle;
        int128 cycleAmt = 0;
        for (uint256 i = 0; i < receivedCycles; i++) {
            cycleAmt += state.amtDeltas[receivedCycle].thisCycle;
            receivableAmt += uint128(cycleAmt);
            cycleAmt += state.amtDeltas[receivedCycle].nextCycle;
            receivedCycle++;
        }
    }

    /// @notice Receive drips from unreceived cycles of the user.
    /// Received drips cycles won't need to be analyzed ever again.
    /// Calling this function does not receive but makes the funds ready to be split and received.
    /// @param userId The user ID
    /// @param assetId The used asset ID
    /// @param maxCycles The maximum number of received drips cycles.
    /// If too low, receiving will be cheap, but may not cover many cycles.
    /// If too high, receiving may become too expensive to fit in a single transaction.
    /// @return receivedAmt The received amount
    /// @return receivableCycles The number of cycles which still can be received
    function _receiveDrips(
        uint256 userId,
        uint256 assetId,
        uint32 maxCycles
    ) internal returns (uint128 receivedAmt, uint32 receivableCycles) {
        receivableCycles = _receivableDripsCycles(userId, assetId);
        uint32 cycles = maxCycles < receivableCycles ? maxCycles : receivableCycles;
        receivableCycles -= cycles;
        if (cycles > 0) {
            DripsState storage state = _dripsStorage().states[assetId][userId];
            uint32 cycle = state.nextReceivableCycle;
            int128 cycleAmt = 0;
            for (uint256 i = 0; i < cycles; i++) {
                cycleAmt += state.amtDeltas[cycle].thisCycle;
                receivedAmt += uint128(cycleAmt);
                cycleAmt += state.amtDeltas[cycle].nextCycle;
                delete state.amtDeltas[cycle];
                cycle++;
            }
            // The next cycle delta must be relative to the last received cycle, which got zeroed.
            // In other words the next cycle delta must be an absolute value.
            if (cycleAmt != 0) state.amtDeltas[cycle].thisCycle += cycleAmt;
            state.nextReceivableCycle = cycle;
        }
        emit ReceivedDrips(userId, assetId, receivedAmt, receivableCycles);
    }

    /// @notice Current user drips state.
    /// @param userId The user ID
    /// @param assetId The used asset ID
    /// @return dripsHash The current drips receivers list hash, see `hashDrips`
    /// @return updateTime The time when drips have been configured for the last time
    /// @return balance The balance when drips have been configured for the last time
    function _dripsState(uint256 userId, uint256 assetId)
        internal
        view
        returns (
            bytes32 dripsHash,
            uint32 updateTime,
            uint128 balance,
            uint32 defaultEnd
        )
    {
        DripsState storage state = _dripsStorage().states[assetId][userId];
        return (state.dripsHash, state.updateTime, state.balance, state.defaultEnd);
    }

    /// @notice User drips balance at a given timestamp
    /// @param userId The user ID
    /// @param assetId The used asset ID
    /// @param receivers The current drips receivers list
    /// @param timestamp The timestamps for which balance should be calculated.
    /// It can't be lower than the timestamp of the last call to `setDrips`.
    /// If it's bigger than `block.timestamp`, then it's a prediction assuming
    /// that `setDrips` won't be called before `timestamp`.
    /// @return balance The user balance on `timestamp`
    function _balanceAt(
        uint256 userId,
        uint256 assetId,
        DripsReceiver[] memory receivers,
        uint32 timestamp
    ) internal view returns (uint128 balance) {
        DripsState storage state = _dripsStorage().states[assetId][userId];
        require(timestamp >= state.updateTime, "Timestamp before last drips update");
        require(_hashDrips(receivers) == state.dripsHash, "Invalid current drips list");
        return _balanceAt(state.balance, state.updateTime, state.defaultEnd, receivers, timestamp);
    }

    /// @notice Sets the user's drips configuration.
    /// @param userId The user ID
    /// @param assetId The used asset ID
    /// @param currReceivers The list of the drips receivers set in the last drips update
    /// of the user.
    /// If this is the first update, pass an empty array.
    /// @param balanceDelta The drips balance change being applied.
    /// Positive when adding funds to the drips balance, negative to removing them.
    /// @param newReceivers The list of the drips receivers of the user to be set.
    /// Must be sorted, deduplicated and without 0 amtPerSecs.
    /// @return newBalance The new drips balance of the user.
    /// @return realBalanceDelta The actually applied drips balance change.
    function _setDrips(
        uint256 userId,
        uint256 assetId,
        DripsReceiver[] memory currReceivers,
        int128 balanceDelta,
        DripsReceiver[] memory newReceivers
    ) internal returns (uint128 newBalance, int128 realBalanceDelta) {
        DripsState storage state = _dripsStorage().states[assetId][userId];
        bytes32 currDripsHash = _hashDrips(currReceivers);
        require(currDripsHash == state.dripsHash, "Invalid current drips list");
        uint32 lastUpdate = state.updateTime;
        uint32 currDefaultEnd = state.defaultEnd;
        uint128 lastBalance = state.balance;
        {
            uint128 currBalance = _balanceAt(
                lastBalance,
                lastUpdate,
                currDefaultEnd,
                currReceivers,
                _currTimestamp()
            );
            int136 balance = int128(currBalance) + int136(balanceDelta);
            if (balance < 0) balance = 0;
            newBalance = uint128(uint136(balance));
            realBalanceDelta = int128(balance - int128(currBalance));
        }
        uint32 newDefaultEnd = _calcDefaultEnd(newBalance, newReceivers);
        _updateReceiverStates(
            _dripsStorage().states[assetId],
            currReceivers,
            lastUpdate,
            currDefaultEnd,
            newReceivers,
            newDefaultEnd
        );
        state.updateTime = _currTimestamp();
        state.defaultEnd = newDefaultEnd;
        state.balance = newBalance;
        bytes32 newDripsHash = _hashDrips(newReceivers);
        emit DripsSet(userId, assetId, newDripsHash, newBalance);
        if (newDripsHash != currDripsHash) {
            state.dripsHash = newDripsHash;
            for (uint256 i = 0; i < newReceivers.length; i++) {
                DripsReceiver memory receiver = newReceivers[i];
                emit DripsReceiverSeen(newDripsHash, receiver.userId, receiver.config);
            }
        }
    }

    function _addDefaultEnd(
        uint256[] memory defaultEnds,
        uint256 idx,
        uint192 amtPerSec,
        uint32 start
    ) private pure {
        defaultEnds[idx] = (uint256(amtPerSec) << 32) | start;
    }

    function _getDefaultEnd(uint256[] memory defaultEnds, uint256 idx)
        private
        pure
        returns (uint256 amtPerSec, uint256 start)
    {
        uint256 val;
        // solhint-disable-next-line no-inline-assembly
        assembly ("memory-safe") {
            val := mload(add(32, add(defaultEnds, shl(5, idx))))
        }
        return (val >> 32, uint32(val));
    }

    /// @notice Calculates the end time of drips without duration.
    /// @param balance The balance when drips have started
    /// @param receivers The list of drips receivers.
    /// Must be sorted, deduplicated and without 0 amtPerSecs.
    /// @return defaultEnd The end time of drips without duration.
    function _calcDefaultEnd(uint128 balance, DripsReceiver[] memory receivers)
        internal
        view
        returns (uint32 defaultEnd)
    {
        require(receivers.length <= _MAX_DRIPS_RECEIVERS, "Too many drips receivers");
        uint256[] memory defaultEnds = new uint256[](receivers.length);
        uint256 defaultEndsLen = 0;
        uint256 spent = 0;
        for (uint256 i = 0; i < receivers.length; i++) {
            DripsReceiver memory receiver = receivers[i];
            uint192 amtPerSec = receiver.config.amtPerSec();
            require(amtPerSec != 0, "Drips receiver amtPerSec is zero");
            if (i > 0) require(_isOrdered(receivers[i - 1], receiver), "Receivers not sorted");
            // Default drips end doesn't matter here, the end time is ignored when
            // the duration is zero and if it's non-zero the default end is not used anyway
            (uint32 start, uint32 end) = _dripsRangeInFuture(receiver, _currTimestamp(), 0);
            if (receiver.config.duration() == 0) {
                _addDefaultEnd(defaultEnds, defaultEndsLen++, amtPerSec, start);
            } else {
                spent += _drippedAmt(amtPerSec, start, end);
            }
        }
        require(balance >= spent, "Insufficient balance");
        balance -= uint128(spent);
        return _calcDefaultEnd(defaultEnds, defaultEndsLen, balance);
    }

    /// @notice Calculates the end time of drips without duration.
    /// @param defaultEnds The list of default ends
    /// @param balance The balance when drips have started
    /// @return defaultEnd The end time of drips without duration.
    function _calcDefaultEnd(
        uint256[] memory defaultEnds,
        uint256 defaultEndsLen,
        uint128 balance
    ) private view returns (uint32 defaultEnd) {
        unchecked {
            uint32 minEnd = _currTimestamp();
            uint32 maxEnd = type(uint32).max;
            if (defaultEndsLen == 0 || balance == 0) return minEnd;
            if (_isBalanceEnough(defaultEnds, defaultEndsLen, balance, maxEnd)) return maxEnd;
            uint256 enoughEnd = minEnd;
            uint256 notEnoughEnd = maxEnd;
            while (true) {
                uint256 end = (enoughEnd + notEnoughEnd) / 2;
                if (end == enoughEnd) return uint32(end);
                if (_isBalanceEnough(defaultEnds, defaultEndsLen, balance, end)) {
                    enoughEnd = end;
                } else {
                    notEnoughEnd = end;
                }
            }
        }
    }

    /// @notice Check if a given balance is enough to cover default drips until the given time.
    /// @param defaultEnds The list of default ends
    /// @param defaultEndsLen The length of `defaultEnds`
    /// @param balance The balance when drips have started
    /// @param end The time until which the drips are checked to be covered
    /// @return isEnough `true` if the balance is enough, `false` otherwise
    function _isBalanceEnough(
        uint256[] memory defaultEnds,
        uint256 defaultEndsLen,
        uint256 balance,
        uint256 end
    ) private view returns (bool isEnough) {
        unchecked {
            uint256 spent = 0;
            for (uint256 i = 0; i < defaultEndsLen; i++) {
                (uint256 amtPerSec, uint256 start) = _getDefaultEnd(defaultEnds, i);
                if (end <= start) continue;
                spent += _drippedAmt(amtPerSec, start, end);
                if (spent > balance) return false;
            }
            return true;
        }
    }

    /// @notice Calculates the drips balance at a given timestamp.
    /// @param lastBalance The balance when drips have started
    /// @param lastUpdate The timestamp when drips have started.
    /// @param defaultEnd The end time of drips without duration
    /// @param receivers The list of drips receivers.
    /// @param timestamp The timestamps for which balance should be calculated.
    /// It can't be lower than `lastUpdate`.
    /// If it's bigger than `block.timestamp`, then it's a prediction assuming
    /// that `setDrips` won't be called before `timestamp`.
    /// @return balance The user balance on `timestamp`
    function _balanceAt(
        uint128 lastBalance,
        uint32 lastUpdate,
        uint32 defaultEnd,
        DripsReceiver[] memory receivers,
        uint32 timestamp
    ) private view returns (uint128 balance) {
        balance = lastBalance;
        for (uint256 i = 0; i < receivers.length; i++) {
            DripsReceiver memory receiver = receivers[i];
            (uint32 start, uint32 end) = _dripsRange({
                receiver: receiver,
                updateTime: lastUpdate,
                defaultEnd: defaultEnd,
                startCap: lastUpdate,
                endCap: timestamp
            });
            balance -= uint128(_drippedAmt(receiver.config.amtPerSec(), start, end));
        }
    }

    /// @notice Calculates the hash of the drips configuration.
    /// It's used to verify if drips configuration is the previously set one.
    /// @param receivers The list of the drips receivers.
    /// Must be sorted, deduplicated and without 0 amtPerSecs.
    /// If the drips have never been updated, pass an empty array.
    /// @return dripsConfigurationHash The hash of the drips configuration
    function _hashDrips(DripsReceiver[] memory receivers)
        internal
        pure
        returns (bytes32 dripsConfigurationHash)
    {
        if (receivers.length == 0) return bytes32(0);
        return keccak256(abi.encode(receivers));
    }

    /// @notice Applies the effects of the change of the drips on the receivers' drips states.
    /// @param states The drips states for the used asset.
    /// @param currReceivers The list of the drips receivers set in the last drips update
    /// of the user.
    /// If this is the first update, pass an empty array.
    /// @param lastUpdate the last time the sender updated the drips.
    /// If this is the first update, pass zero.
    /// @param currDefaultEnd Time when drips without duration
    /// were supposed to end according to the last drips update.
    /// @param newReceivers  The list of the drips receivers of the user to be set.
    /// Must be sorted, deduplicated and without 0 amtPerSecs.
    /// @param newDefaultEnd Time when drips without duration
    /// will end according to the new drips configuration.
    function _updateReceiverStates(
        mapping(uint256 => DripsState) storage states,
        DripsReceiver[] memory currReceivers,
        uint32 lastUpdate,
        uint32 currDefaultEnd,
        DripsReceiver[] memory newReceivers,
        uint32 newDefaultEnd
    ) private {
        uint256 currIdx = 0;
        uint256 newIdx = 0;
        while (true) {
            bool pickCurr = currIdx < currReceivers.length;
            DripsReceiver memory currRecv;
            if (pickCurr) currRecv = currReceivers[currIdx];

            bool pickNew = newIdx < newReceivers.length;
            DripsReceiver memory newRecv;
            if (pickNew) newRecv = newReceivers[newIdx];

            // Limit picking both curr and new to situations when they differ only by time
            if (
                pickCurr &&
                pickNew &&
                (currRecv.userId != newRecv.userId ||
                    currRecv.config.amtPerSec() != newRecv.config.amtPerSec())
            ) {
                pickCurr = _isOrdered(currRecv, newRecv);
                pickNew = !pickCurr;
            }

            if (pickCurr && pickNew) {
                // Shift the existing drip to fulfil the new configuration
                DripsState storage state = states[currRecv.userId];
                (uint32 currStart, uint32 currEnd) = _dripsRangeInFuture(
                    currRecv,
                    lastUpdate,
                    currDefaultEnd
                );
                (uint32 newStart, uint32 newEnd) = _dripsRangeInFuture(
                    newRecv,
                    _currTimestamp(),
                    newDefaultEnd
                );
                {
                    int256 amtPerSec = int256(uint256(currRecv.config.amtPerSec()));
                    // Move the start and end times if updated
                    _addDeltaRange(state, currStart, newStart, -amtPerSec);
                    _addDeltaRange(state, currEnd, newEnd, amtPerSec);
                }
                // Ensure that the user receives the updated cycles
                uint32 currStartCycle = _cycleOf(currStart);
                uint32 newStartCycle = _cycleOf(newStart);
                if (currStartCycle > newStartCycle && state.nextReceivableCycle > newStartCycle) {
                    state.nextReceivableCycle = newStartCycle;
                }
            } else if (pickCurr) {
                // Remove an existing drip
                DripsState storage state = states[currRecv.userId];
                (uint32 start, uint32 end) = _dripsRangeInFuture(
                    currRecv,
                    lastUpdate,
                    currDefaultEnd
                );
                int256 amtPerSec = int256(uint256(currRecv.config.amtPerSec()));
                _addDeltaRange(state, start, end, -amtPerSec);
            } else if (pickNew) {
                // Create a new drip
                DripsState storage state = states[newRecv.userId];
                (uint32 start, uint32 end) = _dripsRangeInFuture(
                    newRecv,
                    _currTimestamp(),
                    newDefaultEnd
                );
                int256 amtPerSec = int256(uint256(newRecv.config.amtPerSec()));
                _addDeltaRange(state, start, end, amtPerSec);
                // Ensure that the user receives the updated cycles
                uint32 startCycle = _cycleOf(start);
                if (state.nextReceivableCycle == 0 || state.nextReceivableCycle > startCycle) {
                    state.nextReceivableCycle = startCycle;
                }
            } else {
                break;
            }

            if (pickCurr) currIdx++;
            if (pickNew) newIdx++;
        }
    }

    /// @notice Calculates the time range in the future in which a receiver will be dripped to.
    /// @param receiver The drips receiver
    /// @param defaultEnd The end time of drips without duration
    function _dripsRangeInFuture(
        DripsReceiver memory receiver,
        uint32 updateTime,
        uint32 defaultEnd
    ) private view returns (uint32 start, uint32 end) {
        return _dripsRange(receiver, updateTime, defaultEnd, _currTimestamp(), type(uint32).max);
    }

    /// @notice Calculates the time range in which a receiver is to be dripped to.
    /// This range is capped to provide a view on drips through a specific time window.
    /// @param receiver The drips receiver
    /// @param updateTime The time when drips are configured
    /// @param defaultEnd The end time of drips without duration
    /// @param startCap The timestamp the drips range start should be capped to
    /// @param endCap The timestamp the drips range end should be capped to
    function _dripsRange(
        DripsReceiver memory receiver,
        uint32 updateTime,
        uint32 defaultEnd,
        uint32 startCap,
        uint32 endCap
    ) private pure returns (uint32 start, uint32 end_) {
        start = receiver.config.start();
        if (start == 0) start = updateTime;
        uint40 end = uint40(start) + receiver.config.duration();
        if (end == start) end = defaultEnd;
        if (start < startCap) start = startCap;
        if (end > endCap) end = endCap;
        if (end < start) end = start;
        return (start, uint32(end));
    }

    /// @notice Adds funds received by a user in a given time range
    /// @param state The user state
    /// @param start The timestamp from which the delta takes effect
    /// @param end The timestamp until which the delta takes effect
    /// @param amtPerSec The dripping rate
    function _addDeltaRange(
        DripsState storage state,
        uint32 start,
        uint32 end,
        int256 amtPerSec
    ) private {
        if (start == end) return;
        mapping(uint32 => AmtDelta) storage amtDeltas = state.amtDeltas;
        _addDelta(amtDeltas, start, amtPerSec);
        _addDelta(amtDeltas, end, -amtPerSec);
    }

    /// @notice Adds delta of funds received by a user at a given time
    /// @param amtDeltas The user amount deltas
    /// @param timestamp The timestamp when the deltas need to be added
    /// @param amtPerSec The dripping rate
    function _addDelta(
        mapping(uint32 => AmtDelta) storage amtDeltas,
        uint256 timestamp,
        int256 amtPerSec
    ) private {
        unchecked {
            AmtDelta storage amtDelta = amtDeltas[_cycleOf(uint32(timestamp))];
            int256 thisCycleDelta = amtDelta.thisCycle;
            int256 nextCycleDelta = amtDelta.nextCycle;

            // In order to set a delta on a specific timestamp it must be introduced in two cycles.
            // The cycle delta is split proportionally based on how much this cycle is affected.
            // The next cycle has the rest of the delta applied, so the update is fully completed.
            // These formulas follow the logic from `_drippedAmt`, see it for more details.
            int256 amtPerSecMultiplier = int256(_AMT_PER_SEC_MULTIPLIER);
            int256 amtPerCycle = (int256(uint256(_cycleSecs)) * amtPerSec) / amtPerSecMultiplier;
            // The part of `amtPerCycle` which is NOT dripped in this cycle
            int256 amtNextCycle = (int256(timestamp % _cycleSecs) * amtPerSec) /
                amtPerSecMultiplier;
            thisCycleDelta += amtPerCycle - amtNextCycle;
            nextCycleDelta += amtNextCycle;
            require(
                int128(thisCycleDelta) == thisCycleDelta &&
                    int128(nextCycleDelta) == nextCycleDelta,
                "AmtDelta underflow or overflow"
            );

            amtDelta.thisCycle = int128(thisCycleDelta);
            amtDelta.nextCycle = int128(nextCycleDelta);
        }
    }

    /// @notice Checks if two receivers fulfil the sortedness requirement of the receivers list.
    /// @param prev The previous receiver
    /// @param prev The next receiver
    function _isOrdered(DripsReceiver memory prev, DripsReceiver memory next)
        private
        pure
        returns (bool)
    {
        if (prev.userId != next.userId) return prev.userId < next.userId;
        return prev.config.lt(next.config);
    }

    /// @notice Calculates the amount dripped over a time range.
    /// The amount dripped in the `N`th second of each cycle is:
    /// `(N + 1) * amtPerSec / AMT_PER_SEC_MULTIPLIER - N * amtPerSec / AMT_PER_SEC_MULTIPLIER`.
    /// For a range of `N`s from `0` to `M` the sum of the dripped amounts is calculated as:
    /// `M * amtPerSec / AMT_PER_SEC_MULTIPLIER` assuming that `M <= cycleSecs`.
    /// For an arbitrary time range across multiple cycles the amount is calculated as the sum of
    /// the amount dripped in the start cycle, each of the full cycles in between and the end cycle.
    /// This algorithm has the following properties:
    /// - During every second full units are dripped, there are no partially dripped units.
    /// - Undripped fractions are dripped when they add up into full units.
    /// - Undripped fractions don't add up across cycle end boundaries.
    /// - Some seconds drip more units and some less.
    /// - Every `N`th second of each cycle drips the same amount.
    /// - Every full cycle drips the same amount.
    /// - The amount dripped in a given second is independent from the dripping start and end.
    /// - Dripping over time ranges `A:B` and then `B:C` is equivalent to dripping over `A:C`.
    /// - Different drips existing in the system don't interfere with each other.
    /// @param amtPerSec The dripping rate
    /// @param start The dripping start time
    /// @param end The dripping end time
    /// @param amt The dripped amount
    function _drippedAmt(
        uint256 amtPerSec,
        uint256 start,
        uint256 end
    ) private view returns (uint256 amt) {
        // This function is written in Yul because it can be called thousands of times
        // per transaction and it needs to be optimized as much as possible.
        // As of Solidity 0.8.13, rewriting it in unchecked Solidity triples its gas cost.
        uint256 cycleSecs = _cycleSecs;
        // solhint-disable-next-line no-inline-assembly
        assembly {
            let endedCycles := sub(div(end, cycleSecs), div(start, cycleSecs))
            let amtPerCycle := div(mul(cycleSecs, amtPerSec), _AMT_PER_SEC_MULTIPLIER)
            amt := mul(endedCycles, amtPerCycle)
            let amtEnd := div(mul(mod(end, cycleSecs), amtPerSec), _AMT_PER_SEC_MULTIPLIER)
            amt := add(amt, amtEnd)
            let amtStart := div(mul(mod(start, cycleSecs), amtPerSec), _AMT_PER_SEC_MULTIPLIER)
            amt := sub(amt, amtStart)
        }
    }

    /// @notice Calculates the cycle containing the given timestamp.
    /// @param timestamp The timestamp.
    /// @return cycle The cycle containing the timestamp.
    function _cycleOf(uint32 timestamp) private view returns (uint32 cycle) {
        unchecked {
            return timestamp / _cycleSecs + 1;
        }
    }

    /// @notice The current timestamp, casted to the library's internal representation.
    /// @return timestamp The current timestamp
    function _currTimestamp() private view returns (uint32 timestamp) {
        return uint32(block.timestamp);
    }

    /// @notice Returns the Drips storage.
    /// @return dripsStorage The storage.
    function _dripsStorage() private view returns (DripsStorage storage dripsStorage) {
        bytes32 slot = _dripsStorageSlot;
        // solhint-disable-next-line no-inline-assembly
        assembly {
            dripsStorage.slot := slot
        }
    }
}
