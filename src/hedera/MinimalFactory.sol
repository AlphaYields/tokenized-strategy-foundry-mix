// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.18;

/// Minimal Yearn-compatible fee config source for TokenizedStrategy on Hedera.
/// TokenizedStrategy only ever calls protocol_fee_config(); this returns "no protocol fee".
contract MinimalFactory {
    address public governance;
    uint16 public feeBps;
    address public feeRecipient;

    constructor(address _gov) { governance = _gov; feeRecipient = _gov; feeBps = 0; }

    function protocol_fee_config() external view returns (uint16, address) {
        return (feeBps, feeRecipient);
    }

    function setFeeConfig(uint16 _bps, address _recipient) external {
        require(msg.sender == governance, "!gov");
        require(_bps <= 5000, "range");
        feeBps = _bps; feeRecipient = _recipient;
    }
}
