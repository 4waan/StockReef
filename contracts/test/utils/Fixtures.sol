// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {SessionCalendar} from "../../src/SessionCalendar.sol";

/// @notice Shared loaders for the generated calendar and the independent golden values.
abstract contract Fixtures is Test {
    string internal constant SESSIONS_PATH = "../tools/calendar/sessions.json";
    string internal constant GOLDEN_PATH = "../tools/golden/golden.json";

    function _sessionsJson() internal view returns (string memory) {
        return vm.readFile(SESSIONS_PATH);
    }

    function _goldenJson() internal view returns (string memory) {
        return vm.readFile(GOLDEN_PATH);
    }

    function _deployCalendar() internal returns (SessionCalendar) {
        string memory json = _sessionsJson();
        uint256[] memory words = vm.parseJsonUintArray(json, ".packed");
        uint256 count = vm.parseJsonUint(json, ".count");
        return new SessionCalendar(words, count);
    }

    function _golden(string memory key) internal view returns (uint256) {
        return vm.parseUint(vm.parseJsonString(_goldenJson(), key));
    }

    /// @dev All session opens and closes straight from sessions.json.
    function _jsonSessions() internal view returns (uint256[] memory opens, uint256[] memory closes) {
        string memory json = _sessionsJson();
        opens = vm.parseJsonUintArray(json, ".opens");
        closes = vm.parseJsonUintArray(json, ".closes");
    }
}
