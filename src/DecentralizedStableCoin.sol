// SPDX-License-Identifier:MIT
pragma solidity 0.8.19;

import { ERC20Burnable, ERC20 } from "../lib/openzeppelin-contracts/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import { Ownable } from "../lib/openzeppelin-contracts/contracts/access/Ownable.sol";
import { IERC20 } from "../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";

/**
 * @title DecentralizedStableCoin
 * @author Juan Xavier Valverde
 * Type of Collateral: Exogenous
 * Minting (Stability Mechanism): Decentralized (Algorithmic)
 * Value (Relative Stability): Anchored (Pegged to USD)
 * Collateral Type: Crypto
 *
 * This is the contract meant to be owned by DSCEngine. It is a ERC20 token that can be minted and burned by the DSCEngine smart contract.
 */

contract DecentralizedStableCoin is ERC20Burnable, Ownable {
    error DecentralizedStableCoin_AmountMustBeMoreThanZero();
    error DecentralizedStableCoin_BurnAmountExceedsBalance();
    error DecentralizedStableCoin_NotZeroAddress();

    constructor() ERC20("DecentralizedStableCoin", "DSC") {}

    function burn(uint256 _amount) public override onlyOwner {
        uint256 balance = balanceOf(msg.sender);
        if (_amount == 0) revert DecentralizedStableCoin_AmountMustBeMoreThanZero();
        if (balance < _amount) revert DecentralizedStableCoin_BurnAmountExceedsBalance();
        super.burn(_amount);
    }

    function mint(address _to, uint256 _amount) external onlyOwner returns (bool) {
        if (_to == address(0)) revert DecentralizedStableCoin_NotZeroAddress();
        if (_amount == 0) revert DecentralizedStableCoin_AmountMustBeMoreThanZero();
        _mint(_to, _amount);
        return true;
    }
}
