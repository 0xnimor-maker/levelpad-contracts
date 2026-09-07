// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;
library DevTax {
    struct Split { uint16 creator; uint16 burn; uint16 dividend; uint16 liquidity; }
    function validate(Split memory s) internal pure {
        require(uint256(s.creator) + s.burn + s.dividend + s.liquidity == 10000, "InvalidTaxSplit");
    }
    function validateV1(Split memory s, uint16 presaleBps) internal pure {
        validate(s);
        require(presaleBps == 5000, "FixedPresaleRatio");
        require(s.burn == 0 && s.liquidity == 0, "V2AllocationDisabled");
    }
}
interface IDevTaxProcessor {
    function processing() external view returns(bool);
    function previewFee(uint256 nominal) external view returns(uint256);
    function accrueFees(uint256 nominal, uint256 paid) external;
}
