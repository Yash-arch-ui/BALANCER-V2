// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "./LogExpMath.sol";
library WeightedMath {
    uint256 internal constant _MAX_IN_RATIO = 3e19;
    uint256 internal constant _MAX_OUT_RATIO = 3e19;
    uint256 internal constant _MAX_INVARIANT_RATIO = 3e18;
    uint256 internal constant _MIN_INVARIANT_RATIO = 0.75e18;
    uint256 internal constant _ONE = 1e18;
    uint256 internal constant _TWO = 2e18;
    uint256 internal constant _FOUR = 4e18;
    uint256 internal constant _MAX_POW_RELATIVE_ERROR = 10000; // 10^-14

    error AddOverflow();
    error SubOverflow();
    error MulOverflow();
    error ZeroInvariant();

    function add(uint256 a, uint256 b) internal pure returns (uint256) {
        uint256 c = a + b;
        if (c < a) revert AddOverflow();
        return c;
    }

    function sub(uint256 a, uint256 b) internal pure returns (uint256) {
        if (b > a) revert SubOverflow();
        return a - b;
    }

    function mulDown(uint256 a, uint256 b) internal pure returns (uint256) {
        uint256 product = a * b;
        if (a != 0 && product / a != b) revert MulOverflow();
        return product / _ONE;
    }

    function powDown(uint256 x, uint256 y) internal pure returns (uint256) {
        if (y == _ONE) {
            return x;
        } else if (y == _TWO) {
            return mulDown(x, x);
        } else if (y == _FOUR) {
            uint256 square = mulDown(x, x);
            return mulDown(square, square);
        } else {
            uint256 raw = LogExpMath.pow(x, y);
            uint256 maxError = add(mulDown(raw, _MAX_POW_RELATIVE_ERROR), 1);

            if (raw < maxError) {
                return 0;
            } else {
                return sub(raw, maxError);
            }
        }
    }

    function _calculateInvariant(uint256[] memory normalizedWeights, uint256[] memory balances)
        internal
        pure
        returns (uint256)
    {
        uint256 invariant = _ONE;
        for (uint256 i = 0; i < normalizedWeights.length; i++) {
            invariant = mulDown(invariant, powDown(balances[i], normalizedWeights[i]));
        }
        if (invariant == 0) revert ZeroInvariant();
        return invariant;
    }
}