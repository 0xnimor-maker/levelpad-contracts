// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

library WalletRecipient {
    /// @dev EXTCODECOPY reads the EIP-7702 designation, not its delegated code.
    /// This classifies the address; it does not execute or trust the delegate.
    function isWallet(address recipient) internal view returns (bool) {
        uint256 size = recipient.code.length;
        if (size == 0) return true;
        if (size != 23) return false;
        return bytes3(recipient.code) == hex"ef0100";
    }
}
