// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.8.13;

/// @notice A drips receiver
struct DripsReceiver {
    /// @notice The user ID.
    uint256 userId;
    /// @notice The amount per second being dripped. Must never be zero.
    uint128 amtPerSec;
    /// @notice The timestamp when dripping should start.
    /// If zero, use the timestamp when drips are configured.
    uint32 start;
    /// @notice The duration of dripping.
    /// If zero, drip until balance runs out.
    uint32 duration;
}

library Drips {
    /// @notice Maximum number of drips receivers of a single user.
    /// Limits cost of changes in drips configuration.
    uint8 internal constant MAX_DRIPS_RECEIVERS = 100;

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
    /// @param amtPerSec The amount per second being dripped. Must never be zero.
    /// @param start The timestamp when dripping should start.
    /// If zero, use the timestamp when drips are configured.
    /// @param duration The duration of dripping.
    /// If zero, drip until balance runs out.
    event DripsReceiverSeen(
        bytes32 indexed receiversHash,
        uint256 indexed userId,
        uint128 amtPerSec,
        uint32 start,
        uint32 duration
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

    struct Storage {
        /// @notice User drips states.
        /// The keys are the asset ID and the user ID.
        mapping(uint256 => mapping(uint256 => DripsState)) dripsStates;
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

    /// @notice Counts cycles from which drips can be received.
    /// This function can be used to detect that there are
    /// too many cycles to analyze in a single transaction.
    /// @param s The drips storage
    /// @param cycleSecs The cycle length in seconds.
    /// Must be the same in all calls working on a single storage instance. Must be higher than 1.
    /// @param userId The user ID
    /// @param assetId The used asset ID
    /// @return cycles The number of cycles which can be flushed
    function receivableDripsCycles(
        Storage storage s,
        uint32 cycleSecs,
        uint256 userId,
        uint256 assetId
    ) internal view returns (uint32 cycles) {
        uint32 nextReceivableCycle = s.dripsStates[assetId][userId].nextReceivableCycle;
        // The currently running cycle is not receivable yet
        uint32 currCycle = _cycleOf(_currTimestamp(), cycleSecs);
        if (nextReceivableCycle == 0 || nextReceivableCycle > currCycle) return 0;
        return currCycle - nextReceivableCycle;
    }

    /// @notice Calculate effects of calling `receiveDrips` with the given parameters.
    /// @param s The drips storage
    /// @param cycleSecs The cycle length in seconds.
    /// Must be the same in all calls working on a single storage instance. Must be higher than 1.
    /// @param userId The user ID
    /// @param assetId The used asset ID
    /// @param maxCycles The maximum number of received drips cycles.
    /// If too low, receiving will be cheap, but may not cover many cycles.
    /// If too high, receiving may become too expensive to fit in a single transaction.
    /// @return receivableAmt The amount which would be received
    /// @return receivableCycles The number of cycles which would still be receivable after the call
    function receivableDrips(
        Storage storage s,
        uint32 cycleSecs,
        uint256 userId,
        uint256 assetId,
        uint32 maxCycles
    ) internal view returns (uint128 receivableAmt, uint32 receivableCycles) {
        uint32 allReceivableCycles = receivableDripsCycles(s, cycleSecs, userId, assetId);
        uint32 receivedCycles = maxCycles < allReceivableCycles ? maxCycles : allReceivableCycles;
        receivableCycles = allReceivableCycles - receivedCycles;
        DripsState storage state = s.dripsStates[assetId][userId];
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
    /// @param s The drips storage
    /// @param cycleSecs The cycle length in seconds.
    /// Must be the same in all calls working on a single storage instance. Must be higher than 1.
    /// @param userId The user ID
    /// @param assetId The used asset ID
    /// @param maxCycles The maximum number of received drips cycles.
    /// If too low, receiving will be cheap, but may not cover many cycles.
    /// If too high, receiving may become too expensive to fit in a single transaction.
    /// @return receivedAmt The received amount
    /// @return receivableCycles The number of cycles which still can be received
    function receiveDrips(
        Storage storage s,
        uint32 cycleSecs,
        uint256 userId,
        uint256 assetId,
        uint32 maxCycles
    ) internal returns (uint128 receivedAmt, uint32 receivableCycles) {
        receivableCycles = receivableDripsCycles(s, cycleSecs, userId, assetId);
        uint32 cycles = maxCycles < receivableCycles ? maxCycles : receivableCycles;
        receivableCycles -= cycles;
        if (cycles > 0) {
            DripsState storage state = s.dripsStates[assetId][userId];
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

    /// @notice Current user drips hash, see `hashDrips`.
    /// @param s The drips storage
    /// @param userId The user ID
    /// @param assetId The used asset ID
    /// @return dripsHash The current drips receivers list hash
    /// @return updateTime The time when drips have been configured for the last time
    /// @return balance The balance when drips have been configured for the last time
    function dripsState(
        Storage storage s,
        uint256 userId,
        uint256 assetId
    )
        internal
        view
        returns (
            bytes32 dripsHash,
            uint32 updateTime,
            uint128 balance,
            uint32 defaultEnd
        )
    {
        DripsState storage state = s.dripsStates[assetId][userId];
        return (state.dripsHash, state.updateTime, state.balance, state.defaultEnd);
    }

    /// @notice Sets the user's drips configuration.
    /// @param s The drips storage
    /// @param cycleSecs The cycle length in seconds.
    /// Must be the same in all calls working on a single storage instance. Must be higher than 1.
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
    /// Pass it as `lastBalance` when updating that user for the next time.
    /// @return realBalanceDelta The actually applied drips balance change.
    function setDrips(
        Storage storage s,
        uint32 cycleSecs,
        uint256 userId,
        uint256 assetId,
        DripsReceiver[] memory currReceivers,
        int128 balanceDelta,
        DripsReceiver[] memory newReceivers
    ) internal returns (uint128 newBalance, int128 realBalanceDelta) {
        DripsState storage state = s.dripsStates[assetId][userId];
        bytes32 currDripsHash = hashDrips(currReceivers);
        require(currDripsHash == state.dripsHash, "Invalid current drips list");
        uint32 lastUpdate = state.updateTime;
        uint32 currDefaultEnd = state.defaultEnd;
        uint128 lastBalance = state.balance;
        {
            uint128 currBalance = _currBalance(
                lastBalance,
                lastUpdate,
                currDefaultEnd,
                currReceivers
            );
            int136 balance = int128(currBalance) + int136(balanceDelta);
            if (balance < 0) balance = 0;
            newBalance = uint128(uint136(balance));
            realBalanceDelta = int128(balance - int128(currBalance));
        }
        uint32 newDefaultEnd = _defaultEnd(newBalance, newReceivers);
        _updateReceiverStates(
            s.dripsStates[assetId],
            cycleSecs,
            currReceivers,
            lastUpdate,
            currDefaultEnd,
            newReceivers,
            newDefaultEnd
        );
        state.updateTime = _currTimestamp();
        state.defaultEnd = newDefaultEnd;
        state.balance = newBalance;
        bytes32 newDripsHash = hashDrips(newReceivers);
        if (newDripsHash != currDripsHash) {
            state.dripsHash = newDripsHash;
            for (uint256 i = 0; i < newReceivers.length; i++) {
                DripsReceiver memory receiver = newReceivers[i];
                emit DripsReceiverSeen(
                    newDripsHash,
                    receiver.userId,
                    receiver.amtPerSec,
                    receiver.start,
                    receiver.duration
                );
            }
        }
        emit DripsSet(userId, assetId, newDripsHash, newBalance);
    }

    /// @notice Calculates the end time of drips without duration.
    /// @param balance The balance when drips have started
    /// @param receivers The list of drips receivers.
    /// Must be sorted, deduplicated and without 0 amtPerSecs.
    /// @return defaultEndTime The end time of drips without duration.
    function _defaultEnd(uint128 balance, DripsReceiver[] memory receivers)
        private
        view
        returns (uint32 defaultEndTime)
    {
        require(receivers.length <= MAX_DRIPS_RECEIVERS, "Too many drips receivers");
        // Default ends found among receivers
        uint256[] memory defaultEnds = new uint256[](receivers.length);
        uint256 length = 0;
        // The total amount per second in the current timestamp of receivers with the default end
        uint136 currAmtPerSec = 0;

        for (uint256 i = 0; i < receivers.length; i++) {
            DripsReceiver memory receiver = receivers[i];
            require(receiver.amtPerSec != 0, "Drips receiver amtPerSec is zero");
            if (i > 0) require(_isOrdered(receivers[i - 1], receiver), "Receivers not sorted");
            // Default drips end doesn't matter here, the end time is ignored when
            // the duration is zero and if it's non-zero the default end is not used anyway
            (uint32 start, uint32 end) = _dripsRangeInFuture(receiver, _currTimestamp(), 0);
            if (receiver.duration == 0) {
                if (start == _currTimestamp()) currAmtPerSec += receiver.amtPerSec;
                else defaultEnds.push(length++, start, receiver.amtPerSec);
            } else {
                uint192 spent = (end - start) * receiver.amtPerSec;
                require(balance >= spent, "Insufficient balance");
                balance -= uint128(spent);
            }
        }
        return _receiversDefaultEnd(defaultEnds, length, currAmtPerSec, balance);
    }

    /// @notice Calculates the end time of drips without duration.
    /// @param defaultEnds The list of default ends.
    /// Must not contain entries with start time equal to the current timestamp.
    /// @param length The length of the list
    /// @param currAmtPerSec The total amount per second in the current timestamp
    /// @param balance The balance available for drips without duration
    /// @return end_ The end time of drips without duration
    function _receiversDefaultEnd(
        uint256[] memory defaultEnds,
        uint256 length,
        uint136 currAmtPerSec,
        uint128 balance
    ) private view returns (uint32 end_) {
        defaultEnds.heapify(length);
        uint32 lastStart = _currTimestamp();
        uint136 end = type(uint32).max;
        if (currAmtPerSec != 0) end = lastStart + (balance / currAmtPerSec);
        while (length > 0) {
            uint32 start = defaultEnds.peekStart();
            if (start >= end) break;
            balance -= uint128(currAmtPerSec * (start - lastStart));
            lastStart = start;
            uint136 amtPerSec;
            (length, amtPerSec) = defaultEnds.popAmtPerSec(length);
            currAmtPerSec += amtPerSec;
            end = start + (balance / currAmtPerSec);
        }
        if (end > type(uint32).max) end = type(uint32).max;
        return uint32(end);
    }

    /// @notice Calculates the current drips balance.
    /// @param lastBalance The balance when drips have started
    /// @param lastUpdate The timestamp when drips have started.
    /// @param defaultEnd The end time of drips without duration
    /// @param receivers The list of drips receivers.
    /// @return balance The current drips balance.
    function _currBalance(
        uint128 lastBalance,
        uint32 lastUpdate,
        uint32 defaultEnd,
        DripsReceiver[] memory receivers
    ) private view returns (uint128 balance) {
        balance = lastBalance;
        for (uint256 i = 0; i < receivers.length; i++) {
            DripsReceiver memory receiver = receivers[i];
            (uint32 start, uint32 end) = _dripsRangeInPast(receiver, lastUpdate, defaultEnd);
            balance -= (end - start) * receiver.amtPerSec;
        }
    }

    /// @notice Calculates the hash of the drips configuration.
    /// It's used to verify if drips configuration is the previously set one.
    /// @param receivers The list of the drips receivers.
    /// Must be sorted, deduplicated and without 0 amtPerSecs.
    /// If the drips have never been updated, pass an empty array.
    /// @return dripsConfigurationHash The hash of the drips configuration
    function hashDrips(DripsReceiver[] memory receivers)
        internal
        pure
        returns (bytes32 dripsConfigurationHash)
    {
        if (receivers.length == 0) return bytes32(0);
        return keccak256(abi.encode(receivers));
    }

    /// @notice Applies the effects of the change of the drips on the receivers' drips states.
    /// @param states The drips states for a single asset, the key is the user ID
    /// @param cycleSecs_ The cycle length in seconds.
    /// Must be the same in all calls working on a single storage instance. Must be higher than 1.
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
        uint32 cycleSecs_,
        DripsReceiver[] memory currReceivers,
        uint32 lastUpdate,
        uint32 currDefaultEnd,
        DripsReceiver[] memory newReceivers,
        uint32 newDefaultEnd
    ) private {
        // A copy shallow in the stack, prevents "stack too deep" errors
        uint32 cycleSecs = cycleSecs_;
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
                (currRecv.userId != newRecv.userId || currRecv.amtPerSec != newRecv.amtPerSec)
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
                _moveDeltaRange(
                    state.amtDeltas,
                    cycleSecs,
                    currStart,
                    currEnd,
                    newStart,
                    newEnd,
                    currRecv.amtPerSec
                );
                // Ensure that the user receives the updated cycles
                uint32 startCycle = _cycleOf(newStart, cycleSecs);
                if (state.nextReceivableCycle > startCycle) {
                    state.nextReceivableCycle = startCycle;
                }
            } else if (pickCurr) {
                // Remove an existing drip
                mapping(uint32 => AmtDelta) storage deltas = states[currRecv.userId].amtDeltas;
                (uint32 start, uint32 end) = _dripsRangeInFuture(
                    currRecv,
                    lastUpdate,
                    currDefaultEnd
                );
                _clearDeltaRange(deltas, cycleSecs, start, end, currRecv.amtPerSec);
            } else if (pickNew) {
                // Create a new drip
                DripsState storage state = states[newRecv.userId];
                (uint32 start, uint32 end) = _dripsRangeInFuture(
                    newRecv,
                    _currTimestamp(),
                    newDefaultEnd
                );
                _setDeltaRange(state.amtDeltas, cycleSecs, start, end, newRecv.amtPerSec);
                // Ensure that the user receives the updated cycles
                uint32 startCycle = _cycleOf(start, cycleSecs);
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

    /// @notice Calculates the time range in the past in which a receiver has been dripped to.
    /// @param receiver The drips receiver
    /// @param updateTime The time when drips are configured
    /// @param defaultEnd The end time of drips without duration
    function _dripsRangeInPast(
        DripsReceiver memory receiver,
        uint32 updateTime,
        uint32 defaultEnd
    ) private view returns (uint32 start, uint32 end) {
        return _dripsRange(receiver, updateTime, defaultEnd, updateTime, _currTimestamp());
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
        start = updateTime;
        if (receiver.start != 0) start = receiver.start;
        uint40 end = defaultEnd;
        if (receiver.duration != 0) end = uint40(start) + receiver.duration;
        if (start < startCap) start = startCap;
        if (end > endCap) end = endCap;
        if (end < start) end = start;
        return (start, uint32(end));
    }

    /// @notice Changes amt delta to move a time range of received funds by a user
    /// @param amtDeltas The user deltas
    /// @param cycleSecs The cycle length in seconds.
    /// Must be the same in all calls working on a single storage instance. Must be higher than 1.
    /// @param currStart The timestamp from which the delta currently takes effect
    /// @param currEnd The timestamp until which the delta currently takes effect
    /// @param newStart The timestamp from which the delta will start taking effect
    /// @param newEnd The timestamp until which the delta will start taking effect
    /// @param amtPerSec The receiving rate
    function _moveDeltaRange(
        mapping(uint32 => AmtDelta) storage amtDeltas,
        uint32 cycleSecs,
        uint32 currStart,
        uint32 currEnd,
        uint32 newStart,
        uint32 newEnd,
        uint128 amtPerSec
    ) private {
        _clearDeltaRange(amtDeltas, cycleSecs, currStart, newStart, amtPerSec);
        _setDeltaRange(amtDeltas, cycleSecs, currEnd, newEnd, amtPerSec);
    }

    /// @notice Clears amt delta of received funds by a user in a given time range
    /// @param amtDeltas The user deltas
    /// @param cycleSecs The cycle length in seconds.
    /// Must be the same in all calls working on a single storage instance. Must be higher than 1.
    /// @param start The timestamp from which the delta takes effect
    /// @param end The timestamp until which the delta takes effect
    /// @param amtPerSec The receiving rate
    function _clearDeltaRange(
        mapping(uint32 => AmtDelta) storage amtDeltas,
        uint32 cycleSecs,
        uint32 start,
        uint32 end,
        uint128 amtPerSec
    ) private {
        // start and end are swapped
        _setDeltaRange(amtDeltas, cycleSecs, end, start, amtPerSec);
    }

    /// @notice Sets amt delta of received funds by a user in a given time range
    /// @param amtDeltas The user deltas
    /// @param cycleSecs The cycle length in seconds.
    /// Must be the same in all calls working on a single storage instance. Must be higher than 1.
    /// @param start The timestamp from which the delta takes effect
    /// @param end The timestamp until which the delta takes effect
    /// @param amtPerSec The receiving rate
    function _setDeltaRange(
        mapping(uint32 => AmtDelta) storage amtDeltas,
        uint32 cycleSecs,
        uint32 start,
        uint32 end,
        uint128 amtPerSec
    ) private {
        if (start == end) return;
        _setDelta(amtDeltas, cycleSecs, start, int128(amtPerSec));
        _setDelta(amtDeltas, cycleSecs, end, -int128(amtPerSec));
    }

    /// @notice Sets amt delta of received funds by a user on a given timestamp
    /// @param amtDeltas The user deltas
    /// @param cycleSecs The cycle length in seconds.
    /// Must be the same in all calls working on a single storage instance. Must be higher than 1.
    /// @param timestamp The timestamp from which the delta takes effect
    /// @param amtPerSecDelta Change of the per-second receiving rate
    function _setDelta(
        mapping(uint32 => AmtDelta) storage amtDeltas,
        uint32 cycleSecs,
        uint32 timestamp,
        int128 amtPerSecDelta
    ) private {
        // In order to set a delta on a specific timestamp it must be introduced in two cycles.
        // The cycle delta is split proportionally based on how much this cycle is affected.
        // The next cycle has the rest of the delta applied, so the update is fully completed.
        uint32 thisCycle = _cycleOf(timestamp, cycleSecs);
        uint32 nextCycleSecs = timestamp % cycleSecs;
        uint32 thisCycleSecs = cycleSecs - nextCycleSecs;
        AmtDelta storage amtDelta = amtDeltas[thisCycle];
        amtDelta.thisCycle += int128(uint128(thisCycleSecs)) * amtPerSecDelta;
        amtDelta.nextCycle += int128(uint128(nextCycleSecs)) * amtPerSecDelta;
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
        if (prev.amtPerSec != next.amtPerSec) return prev.amtPerSec < next.amtPerSec;
        if (prev.start != next.start) return prev.start < next.start;
        return prev.duration < next.duration;
    }

    /// @notice Calculates the cycle containing the given timestamp.
    /// @param timestamp The timestamp.
    /// @param cycleSecs The cycle length in seconds.
    /// @return cycle The cycle containing the timestamp.
    function _cycleOf(uint32 timestamp, uint32 cycleSecs) internal pure returns (uint32 cycle) {
        return timestamp / cycleSecs + 1;
    }

    /// @notice The current timestamp, casted to the library's internal representation.
    /// @return timestamp The current timestamp
    function _currTimestamp() private view returns (uint32 timestamp) {
        return uint32(block.timestamp);
    }
}

using DefaultEndsHeap for uint256[];

/// @notice A heap of default ends used for calculating drips default ends.
library DefaultEndsHeap {
    /// @notice Add a default end to the list, does not maintain the heap property.
    /// @param defaults The list of default ends. Must have enough capacity to hold another element.
    /// @param length The current length of the list.
    /// @param start The start time of the added default end.
    /// @param amtPerSec The amount per second of the added default end.
    function push(
        uint256[] memory defaults,
        uint256 length,
        uint32 start,
        uint128 amtPerSec
    ) internal pure {
        unchecked {
            _arrayStore(defaults, length, uint256(start) << 128 | amtPerSec);
        }
    }

    /// @notice Turn a list of default ends into a binary heap allowing peeking and popping.
    /// The heap is ordered by the defaults' start times from the lowest to the hightest.
    /// @param defaults The list of default ends.
    /// @param length The current length of the list.
    function heapify(uint256[] memory defaults, uint256 length) internal pure {
        unchecked {
            // All the childless elements of the heap are already valid one element heaps.
            // Remove and insert each element which has children to gradually build a valid heap.
            for (uint256 i = length / 2; i-- > 0; ) {
                _siftDown(defaults, length, i, _arrayLoad(defaults, i));
            }
        }
    }

    /// @notice Peek the lowest start time in the heap of default ends.
    /// @param defaults The binary heap of default ends. Must not be empty.
    /// @return start The lowest start time.
    function peekStart(uint256[] memory defaults) internal pure returns (uint32 start) {
        unchecked {
            return uint32(_arrayLoad(defaults, 0) >> 128);
        }
    }

    /// @notice Pop the lowest start time in the heap of default ends.
    /// If there are multiple elements describing that start time, removes them all.
    /// @param defaults The binary heap of default ends.
    /// @param length The current length of the binary heap.
    /// @return newLength The length of the binary heap after popping.
    /// @return amtPerSec The total amount per second of the popped start time.
    function popAmtPerSec(uint256[] memory defaults, uint256 length)
        internal
        pure
        returns (uint256 newLength, uint136 amtPerSec)
    {
        unchecked {
            uint256 defaultEnd = _arrayLoad(defaults, 0);
            amtPerSec = uint128(defaultEnd);
            // The highest value with start time equal to the popped value
            uint256 defaultEndNoAmtPerSec = defaultEnd | type(uint128).max;
            while (--length > 0) {
                // Remove the lowest element and fill its place with the last element of the heap
                _siftDown(defaults, length, 0, _arrayLoad(defaults, length));
                defaultEnd = _arrayLoad(defaults, 0);
                if (defaultEnd > defaultEndNoAmtPerSec) break;
                amtPerSec += uint128(defaultEnd);
            }
            return (length, amtPerSec);
        }
    }

    /// @notice Insert an item into an empty space in the heap of default ends.
    /// Makes sure that the space and all items below it still form a valid heap.
    /// @param defaults The binary heap of default ends.
    /// @param length The current length of the binary heap.
    /// @param empty The index of the space considered empty. It will be overwritten.
    /// @param inserted The inserted item.
    function _siftDown(
        uint256[] memory defaults,
        uint256 length,
        uint256 empty,
        uint256 inserted
    ) private pure {
        unchecked {
            // The lowest value with start time equal to the inserted value
            uint256 insertedNoAmtPerSec = inserted ^ uint128(inserted);
            while (true) {
                uint256 child = empty * 2 + 1;
                // Empty has no children
                if (child >= length) break;
                uint256 childVal = _arrayLoad(defaults, child);
                uint256 otherChild = child + 1;
                // Empty has 2 children
                if (otherChild < length) {
                    uint256 otherChildVal = _arrayLoad(defaults, otherChild);
                    // Pick the smaller child
                    if (otherChildVal < childVal) {
                        child = otherChild;
                        childVal = otherChildVal;
                    }
                }
                // No child is smaller than the inserted value
                if (childVal >= insertedNoAmtPerSec) break;
                // Move the smaller child one level up
                // and keep looking for the right space for the inserted value
                _arrayStore(defaults, empty, childVal);
                empty = child;
            }
            _arrayStore(defaults, empty, inserted);
        }
    }

    function _arrayLoad(uint256[] memory array, uint256 idx) private pure returns (uint256 val) {
        /// @solidity memory-safe-assembly
        assembly {
            val := mload(add(32, add(array, shl(5, idx))))
        }
    }

    function _arrayStore(
        uint256[] memory array,
        uint256 idx,
        uint256 val
    ) private pure {
        /// @solidity memory-safe-assembly
        assembly {
            mstore(add(32, add(array, shl(5, idx))), val)
        }
    }
}
