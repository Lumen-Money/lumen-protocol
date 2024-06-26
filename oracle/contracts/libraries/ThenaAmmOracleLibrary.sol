// SPDX-License-Identifier: BSD-3-Clause
pragma solidity 0.8.20;


struct Observation {
    uint timestamp;
    uint reserve0Cumulative;
    uint reserve1Cumulative;
}

interface IAmmPair {


    function getReserves() external view returns (uint112 reserve0, uint112 reserve1, uint32 blockTimestampLast);

    function observationLength () external view returns (uint256);
    function observations(uint256 idx) external view returns (Observation memory);
    function currentCumulativePrices() external view returns (uint256 reserve0Cumulative, uint256 reserve1Cumulative, uint256 blockTimestamp);
}

library FixedPoint {
    // range: [0, 2**112 - 1]
    // resolution: 1 / 2**112
    struct uq112x112 {
        uint224 _x;
    }

    // returns a uq112x112 which represents the ratio of the numerator to the denominator
    // equivalent to encode(numerator).div(denominator)
    function fraction(uint112 numerator, uint112 denominator) internal pure returns (uq112x112 memory) {
        require(denominator > 0, "FixedPoint: DIV_BY_ZERO");
        return uq112x112((uint224(numerator) << 112) / denominator);
    }

    // decode a uq112x112 into a uint with 18 decimals of precision
    function decode112with18(uq112x112 memory self) internal pure returns (uint256) {
        // we only have 256 - 224 = 32 bits to spare, so scaling up by ~60 bits is dangerous
        // instead, get close to:
        //  (x * 1e18) >> 112
        // without risk of overflowing, e.g.:
        //  (x) / 2 ** (112 - lg(1e18))
        return uint256(self._x) / 5192296858534827;
    }
}

// library with helper methods for oracles that are concerned with computing average prices
library ThenaAmmOracleLibrary {
    using FixedPoint for *;

    // helper function that returns the current block timestamp within the range of uint32, i.e. [0, 2**32 - 1]
    function currentBlockTimestamp() internal view returns (uint32) {
        return uint32(block.timestamp % 2 ** 32);
    }

    // produces the cumulative price using counterfactuals to save gas and avoid a call to sync.
    function currentCumulativePrices(
        address pair
    ) internal view returns (uint256 price0Cumulative, uint256 price1Cumulative, uint256 blockTimestamp) {


        uint256 observationCount = IAmmPair(pair).observationLength();
        Observation memory _observation = IAmmPair(pair).observations(observationCount - 1);

        (uint reserve0Cumulative, uint reserve1Cumulative,) = IAmmPair(pair).currentCumulativePrices();
        if (block.timestamp == _observation.timestamp) {
            _observation = IAmmPair(pair).observations(observationCount - 2);
        }

        uint timeElapsed = block.timestamp - _observation.timestamp;
        uint _reserve0 = (reserve0Cumulative - _observation.reserve0Cumulative) / timeElapsed;
        uint _reserve1 = (reserve1Cumulative - _observation.reserve1Cumulative) / timeElapsed;

        price0Cumulative = _reserve0 * 1e18 / _reserve1;
        price1Cumulative = _reserve1 * 1e18 / _reserve0;
        blockTimestamp = block.timestamp;
    }
}
