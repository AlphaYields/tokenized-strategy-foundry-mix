// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.18;

import {BaseStrategy, ERC20} from "@tokenized-strategy/BaseStrategy.sol";

/*
  HbarxLoopStrategy — HBARX/WHBAR looping on Bonzo Lend (Hedera), built on the
  audited Yearn V3 TokenizedStrategy.

  All ERC-4626 accounting, share maths, fee handling, access control and the
  emergency path live in TokenizedStrategy (audited upstream, deployed verbatim).
  This file contains ONLY the strategy logic, which is the entire custom surface:

    _deployFunds     supply HBARX to Bonzo
    _freeFunds       withdraw HBARX from Bonzo
    _harvestAndReport report NAV = collateral + idle - debt

  Hedera notes:
   - Every external address must be the target's EVM ALIAS. Calling a Hedera contract
     at its long-zero address (0x00..<num>) from inside a contract returns success with
     EMPTY return data, so abi.decode reverts. Direct RPC calls succeed at either form,
     so this only appears in-contract.
   - HTS tokens are reached through their ERC-20 facade; contracts receive unlimited
     auto-association (HIP-904), so no explicit associate() is required.
   - Loop iterations are bounded to stay inside the child-transaction limit.
*/

interface ILendingPool {
    function deposit(address asset, uint256 amount, address onBehalfOf, uint16 ref) external;
    function withdraw(address asset, uint256 amount, address to) external returns (uint256);
    function borrow(address asset, uint256 amount, uint256 rateMode, uint16 ref, address onBehalfOf) external;
    function repay(address asset, uint256 amount, uint256 rateMode, address onBehalfOf) external returns (uint256);
    function setUserUseReserveAsCollateral(address asset, bool use) external;
}

interface IPair {
    function getReserves() external view returns (uint112, uint112, uint32);
    function swap(uint256 a0Out, uint256 a1Out, address to, bytes calldata data) external;
    function token0() external view returns (address);
}

contract HbarxLoopStrategy is BaseStrategy {
    ILendingPool public immutable pool;
    IPair public immutable pair;          // EVM alias, never long-zero
    ERC20 public immutable whbar;         // borrowed asset
    ERC20 public immutable aHbarx;        // Bonzo collateral receipt
    ERC20 public immutable debtWhbar;     // Bonzo variable debt

    uint256 public constant VARIABLE_RATE = 2;
    uint8 public constant MAX_LOOPS = 5;
    uint16 public swapFeeNum = 997;       // 0.30% pool fee, of 1000

    event Levered(uint8 loops, uint256 supplied, uint256 borrowed);
    event Deleveraged(uint8 loops, uint256 repaid);

    constructor(
        address _asset, string memory _name,
        address _pool, address _pair, address _whbar, address _aHbarx, address _debtWhbar
    ) BaseStrategy(_asset, _name) {
        pool = ILendingPool(_pool);
        pair = IPair(_pair);
        whbar = ERC20(_whbar);
        aHbarx = ERC20(_aHbarx);
        debtWhbar = ERC20(_debtWhbar);
        // NOTE: HTS token approve() reverts if called during construction - the contract
        // is not yet associated with the token (association happens on first receipt under
        // HIP-904). Approvals are therefore deferred to initApprovals(), called post-deploy.
    }

    /// Grant the lending pool spending rights. Idempotent; callable by anyone.
    function initApprovals() external {
        require(asset.approve(address(pool), type(uint256).max), "approve asset");
        require(whbar.approve(address(pool), type(uint256).max), "approve whbar");
    }

    // ------------------------------------------------ required by BaseStrategy
    function _deployFunds(uint256 _amount) internal override {
        if (_amount > 0) pool.deposit(address(asset), _amount, address(this), 0);
    }

    function _freeFunds(uint256 _amount) internal override {
        uint256 idle = asset.balanceOf(address(this));
        if (idle >= _amount) return;
        uint256 need = _amount - idle;
        uint256 coll = aHbarx.balanceOf(address(this));
        if (need > coll) need = coll;
        if (need > 0) pool.withdraw(address(asset), need, address(this));
    }

    /// NAV in HBARX: collateral + idle, less WHBAR debt valued at the AMM mid-price.
    function _harvestAndReport() internal override returns (uint256) {
        uint256 gross = asset.balanceOf(address(this)) + aHbarx.balanceOf(address(this));
        uint256 debt = debtWhbar.balanceOf(address(this));
        if (debt == 0) return gross;
        uint256 debtInAsset = _whbarToAsset(debt);
        return gross > debtInAsset ? gross - debtInAsset : 0;
    }

    // ------------------------------------------------------------- leverage
    /// Supply idle HBARX, borrow `borrowPerLoop` WHBAR, swap to HBARX, repeat.
    /// Sizing is decided off-chain, so no price oracle is needed.
    function leverUp(uint8 loops, uint256 borrowPerLoop, uint16 slippageBps)
        external onlyManagement
    {
        require(loops > 0 && loops <= MAX_LOOPS, "loops");
        require(borrowPerLoop > 0 && slippageBps <= 2000, "params");
        uint256 supplied;
        uint256 borrowed;
        for (uint8 i = 0; i < loops; i++) {
            uint256 idle = asset.balanceOf(address(this));
            if (idle > 0) { pool.deposit(address(asset), idle, address(this), 0); supplied += idle; }

            uint256 beforeW = whbar.balanceOf(address(this));
            pool.borrow(address(whbar), borrowPerLoop, VARIABLE_RATE, 0, address(this));
            uint256 gotW = whbar.balanceOf(address(this)) - beforeW;
            if (gotW == 0) break;
            borrowed += gotW;

            uint256 expected = quoteWhbarToAsset(gotW);
            _swap(address(whbar), gotW, (expected * (10000 - slippageBps)) / 10000);
        }
        emit Levered(loops, supplied, borrowed);
    }

    /// Withdraw collateral, swap to WHBAR, repay. Repeat.
    function deleverage(uint8 loops, uint256 withdrawPerLoop, uint16 slippageBps)
        external onlyManagement
    {
        require(loops > 0 && loops <= MAX_LOOPS, "loops");
        require(slippageBps <= 2000, "params");
        uint256 repaid;
        for (uint8 i = 0; i < loops; i++) {
            uint256 debt = debtWhbar.balanceOf(address(this));
            if (debt == 0) break;
            uint256 coll = aHbarx.balanceOf(address(this));
            if (coll == 0) break;
            uint256 pull = withdrawPerLoop > coll ? coll : withdrawPerLoop;
            pool.withdraw(address(asset), pull, address(this));

            uint256 haveX = asset.balanceOf(address(this));
            if (haveX == 0) break;
            uint256 expected = quoteAssetToWhbar(haveX);
            uint256 gotW = _swap(address(asset), haveX, (expected * (10000 - slippageBps)) / 10000);
            uint256 amt = gotW > debt ? debt : gotW;
            pool.repay(address(whbar), amt, VARIABLE_RATE, address(this));
            repaid += amt;
        }
        emit Deleveraged(loops, repaid);
    }

    function enableCollateral() external onlyManagement {
        pool.setUserUseReserveAsCollateral(address(asset), true);
    }

    function setSwapFeeNum(uint16 v) external onlyManagement {
        require(v >= 950 && v <= 1000, "range");
        swapFeeNum = v;
    }

    // ------------------------------------------------------------------ swaps
    function _reserves() internal view returns (uint256 rW, uint256 rA) {
        (uint112 r0, uint112 r1, ) = pair.getReserves();
        return pair.token0() == address(whbar) ? (uint256(r0), uint256(r1)) : (uint256(r1), uint256(r0));
    }

    function _out(uint256 amtIn, uint256 rIn, uint256 rOut) internal view returns (uint256) {
        uint256 inFee = amtIn * swapFeeNum;
        return (inFee * rOut) / (rIn * 1000 + inFee);
    }

    function quoteWhbarToAsset(uint256 a) public view returns (uint256) { (uint256 w, uint256 x) = _reserves(); return _out(a, w, x); }
    function quoteAssetToWhbar(uint256 a) public view returns (uint256) { (uint256 w, uint256 x) = _reserves(); return _out(a, x, w); }

    function _whbarToAsset(uint256 amt) internal view returns (uint256) {
        (uint256 w, uint256 x) = _reserves();
        return w == 0 ? 0 : (amt * x) / w;   // mid-price, no fee
    }

    function _swap(address tokenIn, uint256 amtIn, uint256 minOut) internal returns (uint256 out) {
        bool inIsWhbar = tokenIn == address(whbar);
        (uint256 rW, uint256 rA) = _reserves();
        out = inIsWhbar ? _out(amtIn, rW, rA) : _out(amtIn, rA, rW);
        require(out >= minOut && out > 0, "slippage");
        require(ERC20(tokenIn).transfer(address(pair), amtIn), "xfer");
        bool token0IsWhbar = pair.token0() == address(whbar);
        (uint256 a0, uint256 a1) = inIsWhbar
            ? (token0IsWhbar ? (uint256(0), out) : (out, uint256(0)))
            : (token0IsWhbar ? (out, uint256(0)) : (uint256(0), out));
        ERC20 outTok = inIsWhbar ? asset : whbar;
        uint256 before = outTok.balanceOf(address(this));
        pair.swap(a0, a1, address(this), "");
        out = outTok.balanceOf(address(this)) - before;
        require(out >= minOut, "out short");
    }

    // ------------------------------------------------------------------ views
    function position() external view returns (uint256 collateral, uint256 debt, uint256 idle) {
        return (aHbarx.balanceOf(address(this)), debtWhbar.balanceOf(address(this)), asset.balanceOf(address(this)));
    }
}
