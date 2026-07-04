// SPDX-License-Identifier:MIT
pragma solidity ^0.8.19;
import "./LogExpMath.sol";
library WeightedMath{
    uint256 internal constant _MAX_IN_RATIO= 3e19;
    uint256 internal constant _MAX_OUT_RATIO= 3e19;
    uint256 internal constant _MAX_INVARIANT_RATIO = 3e18;
    uint256 internal constant _MIN_INVARIANT_RATIO = 0.75e18;
    uint256 internal constant _ONE = 1e18;
    uint256 internal constant _TWO = 2e18;
    uint256 internal constant _FOUR = 4e18;
    uint256 internal constant MAX_POW_RELATIVE_ERROR= 10000; // 10^-14

    error _AddOverflow();
    error _MulOverflow();
    error _ZeroInvariant();
    function add (uint256 a , uint256 b ) internal pure returns(uint256){
        uint256 c = a + b;
        require(c>=a, _Overflow)
    }
    function mulDown(uint256 a , uint256 b ) internal pure returns(uint256){
        uint256 product = a*b;
        require(a ==0 || product/a == b , _MulOverflow());
        return product/_ONE;
    }
    function powDown(uint256 x , uint256 y ) internal pure returns(uint256){
       if (y==ONE){
        return x;
       }
       else if(y==_TWO){
        return mulDown(x,x);
    }
    else if (y== _FOUR){
        uint256 square = muldown(x,x);
        return mulDown(square,square);
    }else{
        uint256 raw  LogExpMath.pow(x,y);
        uint256 maxError = add(mulDown(raw,MAX_POW_RELATIVE_ERROR),1);
        
        if(raw < maxError){
            return 0;
        }
        else{
            return sub ( raw, maxError);
        }
    }
}

   function _calculateInvarint(uint256[] memory normalizedWeights, uint256[] memory balances) internal pure returns(uint256 ){
    uint256 invariant = _ONE;
    for(uint256 i =0; i<normalizedWeights.length; i++){
        invariant = invariant.mulDown(balances[i].powDown(normalizedWeights[i]));

    }
    require(invariant > 0, _ZeroInvariant);
   }
}