// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.8.13;

import {DSTest} from "ds-test/test.sol";
import {DefaultEndsHeap} from "../Drips.sol";
import {RandomUtils} from "./RandomUtils.t.sol";

using DefaultEndsHeap for uint256[];

contract DefaultEndsHeapTest is DSTest, RandomUtils {
    struct DefaultEnd {
        uint32 start;
        uint128 amtPerSec;
    }

    mapping(uint32 => uint256) internal amtPerSecs;

    function runTest(DefaultEnd[] memory input) internal {
        // Prepare the list of default ends
        uint256[] memory defaultEnds = new uint256[](input.length);
        uint256 length = 0;
        uint256 totalAmtPerSec = 0;
        uint256 gasUsed = 0;

        // Fill up the list of default ends
        for (uint256 i = 0; i < input.length; i++) {
            uint32 start = input[i].start;
            uint128 amtPerSec = input[i].amtPerSec;
            gasUsed += gasleft();
            defaultEnds.push(length++, start, amtPerSec);
            gasUsed -= gasleft();
            totalAmtPerSec += amtPerSec;
            amtPerSecs[start] += amtPerSec;
        }

        // Build the heap
        gasUsed += gasleft();
        defaultEnds.heapify(length);
        gasUsed -= gasleft();

        // Drain the heap
        uint32 prevStart;
        bool prevStartSet = false;
        while (length > 0) {
            gasUsed += gasleft();
            uint32 start = defaultEnds.peekStart();
            gasUsed -= gasleft();
            if (prevStartSet) assertLt(prevStart, start, "Starts not sorted");
            prevStart = start;
            prevStartSet = true;
            uint136 amtPerSec;
            gasUsed += gasleft();
            (length, amtPerSec) = defaultEnds.popAmtPerSec(length);
            gasUsed -= gasleft();
            assertEq(amtPerSec, amtPerSecs[start], "Invalid amtPerSec");
            amtPerSecs[start] = 0;
            totalAmtPerSec -= amtPerSec;
        }
        assertEq(totalAmtPerSec, 0, "Some amtPerSecs skipped");
        // To print the results run tests with DappTools parameter `--verbose 2`
        emit log_named_uint("Gas used", gasUsed);
    }

    function generateRandomInput(uint256 length) internal returns (DefaultEnd[] memory input) {
        input = new DefaultEnd[](length);
        for (uint256 i = 0; i < length; i++) {
            input[i].start = randomUint32();
            input[i].amtPerSec = randomUint128();
        }
    }

    function generateSortedInput(uint256 length) internal returns (DefaultEnd[] memory input) {
        input = new DefaultEnd[](length);
        for (uint32 i = 0; i < length; i++) {
            input[i].start = i;
            input[i].amtPerSec = randomUint128();
        }
    }

    function generateRevSortedInput(uint256 length) internal returns (DefaultEnd[] memory input) {
        input = new DefaultEnd[](length);
        for (uint256 i = 0; i < length; i++) {
            input[i].start = uint32(length - i);
            input[i].amtPerSec = randomUint128();
        }
    }

    function generateConstantInput(uint256 length) internal returns (DefaultEnd[] memory input) {
        input = new DefaultEnd[](length);
        for (uint256 i = 0; i < length; i++) {
            input[i].start = 1;
            input[i].amtPerSec = randomUint128();
        }
    }

    function testEmpty() public {
        DefaultEnd[] memory input = new DefaultEnd[](0);
        runTest(input);
    }

    function testSingle() public {
        DefaultEnd[] memory input = new DefaultEnd[](1);
        input[0] = DefaultEnd(1, 2);
        runTest(input);
    }

    function testFullLayerMinusOne() public {
        setSeed(bytes32(uint256(1)));
        runTest(generateRandomInput(2));
    }

    function testFullLayer() public {
        setSeed(bytes32(uint256(1)));
        runTest(generateRandomInput(3));
    }

    function testFullLayerPlusOne() public {
        setSeed(bytes32(uint256(1)));
        runTest(generateRandomInput(4));
    }

    function testOverflowingAmtPerSec() public {
        DefaultEnd[] memory input = new DefaultEnd[](2);
        input[0] = DefaultEnd(1, type(uint128).max);
        input[0] = DefaultEnd(2, 1);
        runTest(input);
    }

    function testFuzzySize(bytes32 seed) public {
        setSeed(seed);
        runTest(generateRandomInput(random(100)));
    }

    function test10Random() public {
        setSeed(bytes32(uint256(1)));
        runTest(generateRandomInput(10));
    }

    function test100Random() public {
        setSeed(bytes32(uint256(1)));
        runTest(generateRandomInput(100));
    }

    function test10Sorted() public {
        setSeed(bytes32(uint256(1)));
        runTest(generateSortedInput(10));
    }

    function test100Sorted() public {
        setSeed(bytes32(uint256(1)));
        runTest(generateSortedInput(100));
    }

    function test10RevSorted() public {
        setSeed(bytes32(uint256(1)));
        runTest(generateRevSortedInput(10));
    }

    function test100RevSorted() public {
        setSeed(bytes32(uint256(1)));
        runTest(generateRevSortedInput(100));
    }

    function test10ConstantInput() public {
        setSeed(bytes32(uint256(1)));
        runTest(generateConstantInput(10));
    }

    function test100ConstantInput() public {
        setSeed(bytes32(uint256(1)));
        runTest(generateConstantInput(100));
    }

    function test200Random() public {
        setSeed(bytes32(uint256(1)));
        runTest(generateRandomInput(200));
    }

    function test200Sorted() public {
        setSeed(bytes32(uint256(1)));
        runTest(generateSortedInput(200));
    }

    function test200RevSorted() public {
        setSeed(bytes32(uint256(1)));
        runTest(generateRevSortedInput(200));
    }

    function test200ConstantInput() public {
        setSeed(bytes32(uint256(1)));
        runTest(generateConstantInput(200));
    }
}
