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
        // Im depositing htese exact 
        uint256[] memory balanceRatioWithFee = new uint256[](amountsIn.length);
        uint256 invariantRatioWithFees = 0; // weighted sum sort of . // not with fees; just a convention to name the fees..
        for (uint256 i = 0; i < amountsIn.length; i++) {
            balanceRatioWithFee[i] = divDown(add(balances[i], amountsIn[i]), balances[i]);
            // balanceRatioWithFee[i] = (balance[i] + amountIn[i]) / balance[i]
            invariantRatioWithFees =add(invariantRatioWithFees, mulDown((balanceRatioWithFee[i]), normalizedWeights[i]));
             //   invariantRatioWithFees += balanceRatioWithFee[i] × normalizedWeights[i]
            // Invariant (I) = ∏ balance_i ^ weight_i - naive weighted average
        }
        // LOOP 2 - Fee decsion, Flipped Comparision.
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
                //nonTaxableAmount = balance*(invariantRatioWithFees-1)
                uint256 taxableAmount = sub(amountsIn[i], nonTaxableAmount);
                // taxableAmount=amountIn-nonTaxableAmount
                // taxableAmountMinusFee=taxableAmount*(1-swapFeePercentage)
                // amountInWithoutFee=taxableAmountMinusFee+nonTaxableAmount
                amountInWithoutFee = add(nonTaxableAmount, mulDown(taxableAmount, sub(_ONE, swapFeePercentage)));
            } else {
                amountInWithoutFee = amountsIn[i];
            }

            uint256 balanceRatio = divDown(add(balances[i], amountInWithoutFee), balances[i]);
            // balanceRatio = (balance[i] + amountInWithFee[i]) / balance[i]
            invariantRatio = mulDown(invariantRatio, powDown(balanceRatio, normalizedWeights[i]));
            // invariantRatio ×= balanceRatio ^ normalizedWeight[i]
        }
        // deposit many get BPT
    }
    /*
    Pool: ETH = 100, USDC = 100, both weight 0.5. Fee = 0.3% (swapFeePercentage = 0.003).
    Deposit: 20 ETH, 0 USDC.
    From the earlier step, we already have:
    balanceRatiosWithFee[ETH]  = 1.20
    balanceRatiosWithFee[USDC] = 1.00
    invariantRatioWithFees     = 1.10   (the naive weighted average)
    Token 0 — ETH (balanceRatiosWithFee[ETH] = 1.20 > invariantRatioWithFees = 1.10 → taxable branch):
    nonTaxableAmount = balances[ETH] * (invariantRatioWithFees - 1)
                     = 100 * (1.10 - 1.0)
                     = 100 * 0.10
                     = 10
    Intuition: "if ETH had only grown by the average pool growth rate (10%), that'd be 10 ETH deposited — completely proportional, no fee." So the first 10 ETH of your 20 ETH deposit is fee-free.
    taxableAmount = amountsIn[ETH] - nonTaxableAmount
                  = 20 - 10
                  = 10
    The remaining 10 ETH is the "excess" — the part beyond what proportional scaling would explain. This is the implicit-swap portion.
    amountInWithoutFee = nonTaxableAmount + taxableAmount * (1 - swapFeePercentage)
                       = 10 + 10 * (1 - 0.003)
                       = 10 + 10 * 0.997
                       = 10 + 9.97
                       = 19.97
    So out of your 20 ETH deposit, only 19.97 counts toward invariant growth — the other 0.03 ETH (0.3% of the taxable 10) was effectively taken as a fee.
    balanceRatio[ETH] = (100 + 19.97) / 100 = 1.1997
    Token 1 — USDC (balanceRatiosWithFee[USDC] = 1.00, not > 1.10 → non-taxable branch):
    amountInWithoutFee = amountsIn[USDC] = 0
    balanceRatio[USDC] = (100 + 0) / 100 = 1.00
    No fee logic runs at all — you deposited nothing here, ratio stays at 1.0 (unchanged).
    Combining into the true invariant ratio:
    invariantRatio = 1.0
    invariantRatio *= balanceRatio[ETH]^weight[ETH]   = 1.0 * 1.1997^0.5  ≈ 1.0 * 1.0953 = 1.0953
    invariantRatio *= balanceRatio[USDC]^weight[USDC] = 1.0953 * 1.00^0.5 = 1.0953 * 1.0   = 1.0953
    So invariantRatio ≈ 1.0953 — noticeably lower than the naive 1.10 we computed before applying the fee. That gap (1.10 - 1.0953 ≈ 0.0047) is the invariant growth that got shaved off because of the fee on the imbalanced portion.
    Feeding this into the final BPT calc:
    bptOut = 1000 * (1.0953 - 1.0) = 1000 * 0.0953 ≈ 95.3 BPT
        */

    function _calculateTokenInGiveExactBptOut(
        uint256 balance,
        uint256 normalizedWeight,
        uint256 bptAmountOut,
        uint256 bptTotalSupply,
        uint256 swapFeePercentage
    ) internal pure returns (uint256) {
        // deposit one ; get exact bpt
        // invariantRatio = (Total BPT + BPT minted) / Total BPT
        uint256 invariantRatio = divUp(add(bptTotalSupply, bptAmountOut), bptTotalSupply);
        //balanceRatio = invariantRatio ^ (1 / weight)
        require(invariantRatio <= _MAX_INVARIANT_RATIO, "MAX_OUT_BPT_FOR_TOKEN_IN");
        uint256 balanceRatio = powUp(invariantRatio, divUp(_ONE, normalizedWeight));
        uint256 amountInAfterFee = mulUp(balance, sub(balanceRatio, _ONE));
        // amountIn = balance × (balanceRatio - 1)
        //  this is feeadjusted deposit needed

        uint256 nonTaxableAmount = mulDown(balance, sub(invariantRatio, _ONE));
        uint256 taxableAmount = sub(amountInAfterFee, nonTaxableAmount);
        uint256 taxableAmountPlusFees = divUp(taxableAmount, sub(_ONE, swapFeePercentage));
        return add(nonTaxableAmount, taxableAmountPlusFees);
    }

    function _calculateTokenOutGivenExactBptIn(
        uint256 balance,
        uint256 normalizedWeight,
        uint256 bptAmountIn,
        uint256 bptTotalSupply,
        uint256 swapFeePercentage
    ) internal pure returns (uint256) {
        // single token exit(burn bpt,get one token)
        uint256 invariantRatio = divDown(sub(bptTotalSupply, bptAmountIn), bptTotalSupply);
        // tells what percent of pool invariant remains after this process -> invariantRatio = (Total BPT - BPT User Burns) / Total BPT
        require(invariantRatio >= _MIN_INVARIANT_RATIO, "MIN_BPT_IN_FOR_TOKEN_OUT");
        // balanceRatio = invariantRatio ^ (1 / normalizedWeight)
        uint256 balanceRatio = powDown(invariantRatio, divUp(_ONE, normalizedWeight));
        uint256 amountOutBeforeFee = mulDown(balance, sub(_ONE, balanceRatio));
        // amountOutBeforeFee = balance × (1 - balanceRatio)
        // The difference between current balance and what the balance "should be " after the exit
        uint256 nonTaxableAmount = mulDown(balance, sub(_ONE, invariantRatio));
        // nonTaxableAmount = balance(1-invariantRatio)
        uint256 taxableAmount = sub(amountOutBeforeFee, nonTaxableAmount);
        // taxableAmount = amountOutBeforeFee - nonTaxableAmount
        uint256 taxableAmountMinusFees = mulDown(taxableAmount, sub(_ONE, swapFeePercentage));

        return add(nonTaxableAmount, taxableAmountMinusFees);
    }

    function _calcBptInGivenExactTokensOut(
        uint256[] memory balances,
        uint256[] memory normalizedWeights,
        uint256[] memory amountsOut,
        uint256 bptTotalSupply,
        uint256 swapFeePercentage
    ) internal pure returns (uint256) {
        // BPT in, so we round up overall — never let the user burn less than they should.

        uint256[] memory balanceRatiosWithoutFee = new uint256[](amountsOut.length);
        uint256 invariantRatioWithoutFees = 0;

        for (uint256 i = 0; i < balances.length; i++) {
            balanceRatiosWithoutFee[i] = divUp(sub(balances[i], amountsOut[i]), balances[i]);
            // for each token -> balanceRatiosWithoutFee[i] = (balance[i] - amountOut[i]) / balance[i]
            invariantRatioWithoutFees =
                add(invariantRatioWithoutFees, mulUp(balanceRatiosWithoutFee[i], normalizedWeights[i]));
            // invariantRatioWithoutFees += balanceRatiosWithoutFee[i] × normalizedWeights[i]
        }

        uint256 invariantRatio = _computeExitExactTokensOutInvariantRatio(
            balances,
            normalizedWeights,
            amountsOut,
            balanceRatiosWithoutFee,
            invariantRatioWithoutFees,
            swapFeePercentage
        );

        return mulUp(bptTotalSupply, sub(_ONE, invariantRatio));
    }

    function _computeExitExactTokensOutInvariantRatio(
        uint256[] memory balances,
        uint256[] memory normalizedWeights,
        uint256[] memory amountsOut,
        uint256[] memory balanceRatiosWithoutFee,
        uint256 invariantRatioWithoutFees,
        uint256 swapFeePercentage
    ) internal pure returns (uint256 invariantRatio) {
        invariantRatio = _ONE;

        for (uint256 i = 0; i < balances.length; i++) {
            uint256 amountOutWithFee;

            if (balanceRatiosWithoutFee[i] < invariantRatioWithoutFees) {
                // this token was over-withdrawn relative to the pool average
                uint256 nonTaxableAmount = mulDown(balances[i], sub(_ONE, invariantRatioWithoutFees));
                // non taxableAmount = balance*(1- invariantRatioWithoutFees)
                uint256 taxableAmount = sub(amountsOut[i], nonTaxableAmount);
                // taxableAmount = amountOut - nonTaxableAmount
                amountOutWithFee = add(nonTaxableAmount, divUp(taxableAmount, sub(_ONE, swapFeePercentage)));
            } else {
                // this token wasn't over-withdrawn — no fee at all
                amountOutWithFee = amountsOut[i];
            }

            uint256 balanceRatio = divDown(sub(balances[i], amountOutWithFee), balances[i]);
            invariantRatio = mulDown(invariantRatio, powDown(balanceRatio, normalizedWeights[i]));
        }
    }
function _calcBptOutGivenExactTokenIn(
    uint256 balance,
    uint256 normalizedWeight,
    uint256 amountIn,
    uint256 bptTotalSupply,
    uint256 swapFeePercentage
) internal pure returns (uint256) {
    // BPT out, so round down overall.
    uint256 amountInWithoutFee;
    {
        uint256 balanceRatioWithFee = divDown(add(balance, amountIn), balance);
        // NOTE: this assumes all weights sum to 1e18 exactly.
        uint256 invariantRatioWithFees = add(
            mulDown(balanceRatioWithFee, normalizedWeight),
            sub(_ONE, normalizedWeight) // normalizedWeight.complement()
        );

        if (balanceRatioWithFee > invariantRatioWithFees) {
            uint256 nonTaxableAmount = invariantRatioWithFees > _ONE
                ? mulDown(balance, sub(invariantRatioWithFees, _ONE))
                : 0;
            uint256 taxableAmount = sub(amountIn, nonTaxableAmount);
            uint256 swapFee = mulUp(taxableAmount, swapFeePercentage);
            amountInWithoutFee = add(nonTaxableAmount, sub(taxableAmount, swapFee));
        } else {
            amountInWithoutFee = amountIn;
            if (amountInWithoutFee == 0) {
                return 0;
            }
        }
    }

    uint256 balanceRatio = divDown(add(balance, amountInWithoutFee), balance);
    uint256 invariantRatio = powDown(balanceRatio, normalizedWeight);

    return (invariantRatio > _ONE) ? mulDown(bptTotalSupply, sub(invariantRatio, _ONE)) : 0;
}
    
}
