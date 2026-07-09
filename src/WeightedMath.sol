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
    error ZeroDivisor();

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

    function mulUp(uint256 a, uint256 b) internal pure returns (uint256) {
        uint256 product = a * b;
        if (a != 0 && product / a != b) revert MulOverflow();

        if (product == 0) {
            return 0;
        }

        return ((product - 1) / _ONE) + 1;
    }

    function divDown(uint256 a, uint256 b) internal pure returns (uint256) {
        if (b == 0) revert ZeroDivisor();
        if (a == 0) return 0;
        uint256 aInflated = a * _ONE;
        if (aInflated / a != _ONE) revert MulOverflow();
        return aInflated / b;
    }

    function divUp(uint256 a, uint256 b) internal pure returns (uint256) {
        if (b == 0) revert ZeroDivisor();
        if (a == 0) return 0;
        uint256 aInflated = a * _ONE;
        if (aInflated / a != _ONE) revert MulOverflow();
        return ((aInflated - 1) / b) + 1;
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
            uint256 maxError = add(mulUp(raw, _MAX_POW_RELATIVE_ERROR), 1);

            if (raw < maxError) {
                return 0;
            } else {
                return sub(raw, maxError);
            }
        }
    }

    function powUp(uint256 x, uint256 y) internal pure returns (uint256) {
        if (y == _ONE) {
            return x;
        } else if (y == _TWO) {
            return mulUp(x, x);
        } else if (y == _FOUR) {
            uint256 square = mulUp(x, x);
            return mulUp(square, square);
        } else {
            uint256 raw = LogExpMath.pow(x, y);
            uint256 maxError = add(mulUp(raw, _MAX_POW_RELATIVE_ERROR), 1);

            return add(raw, maxError);
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

    function _calculateOutGivenIn(
        uint256 balanceIn,
        uint256 weightIn,
        uint256 balanceOut,
        uint256 weightOut,
        uint256 amountIn
    ) internal pure returns (uint256) {
        require(amountIn <= mulDown(balanceIn, _MAX_IN_RATIO), "MAX_IN_RATIO");

        uint256 denominator = add(balanceIn, amountIn);
        uint256 base = divUp(balanceIn, denominator);
        uint256 exponent = divDown(weightIn, weightOut);
        uint256 power = powUp(base, exponent);

        return mulDown(balanceOut, sub(_ONE, power));
    }

    function _calculateInGivenOut(
        uint256 balanceIn,
        uint256 weightIn,
        uint256 balanceOut,
        uint256 weightOut,
        uint256 amountOut
    ) internal pure returns (uint256) {
        /**********************************************************************************************
        // inGivenOut                                                                                //
        // aO = amountOut                                                                            //
        // bO = balanceOut                                                                           //
        // bI = balanceIn              /  /            bO             \    (wO / wI)      \          //
        // aI = amountIn    aI = bI * |  | --------------------------  | ^            - 1  |         //
        // wI = weightIn               \  \       ( bO - aO )         /                   /          //
        // wO = weightOut                                                                            //
        **********************************************************************************************/
        require(amountOut <= mulDown(balanceOut, _MAX_OUT_RATIO), "MAX_OUT_RATIO");

        uint256 base = divUp(balanceOut, sub(balanceOut, amountOut));
        uint256 exponent = divUp(weightOut, weightIn);
        uint256 power = powUp(base, exponent);

        uint256 ratio = sub(power, _ONE);

        return mulUp(balanceIn, ratio);
    }

    function _calcBptOutGivenExactTokensIn(
        uint256[] memory balances,
        uint256[] memory normalizedWeights,
        uint256[] memory amountsIn,
        uint256 bptTotalSupply,
        uint256 swapFeePercentage
    ) internal pure returns (uint256) {
        uint256[] memory balanceRatioWithFee = new uint256[](amountsIn.length);
        uint256 invariantRatioWithFees = 0;
        for (uint256 i = 0; i < amountsIn.length; i++) {
            balanceRatioWithFee[i] = divDown(add(balances[i], amountsIn[i]), balances[i]);
            invariantRatioWithFees = add(
                invariantRatioWithFees, mulDown((balanceRatioWithFee[i]), normalizedWeights[i])
            );
        }
        uint256 invariantRatio = _computeJoinExactTokensInInvariantRatio(
            balances, normalizedWeights, amountsIn, balanceRatioWithFee, invariantRatioWithFees, swapFeePercentage
        );
        uint256 bptOut = (invariantRatio > _ONE) ? mulDown(bptTotalSupply, sub(invariantRatio, _ONE)) : 0;
        return bptOut;
    }

    function _computeJoinExactTokensInInvariantRatio(
        uint256[] memory balances,
        uint256[] memory normalizedWeights,
        uint256[] memory amountsIn,
        uint256[] memory balanceRatiosWithFee,
        uint256 invariantRatioWithFees,
        uint256 swapFeePercentage
    ) internal pure returns (uint256 invariantRatio) {
        invariantRatio = _ONE;

        for (uint256 i = 0; i < balances.length; i++) {
            uint256 amountInWithoutFee;

            if (balanceRatiosWithFee[i] > invariantRatioWithFees) {
                uint256 nonTaxableAmount = mulDown(balances[i], sub(invariantRatioWithFees, _ONE));
                uint256 taxableAmount = sub(amountsIn[i], nonTaxableAmount);
                amountInWithoutFee = add(nonTaxableAmount, mulDown(taxableAmount, sub(_ONE, swapFeePercentage)));
            } else {
                amountInWithoutFee = amountsIn[i];
            }

            uint256 balanceRatio = divDown(add(balances[i], amountInWithoutFee), balances[i]);
            invariantRatio = mulDown(invariantRatio, powDown(balanceRatio, normalizedWeights[i]));
        }
    }
}
