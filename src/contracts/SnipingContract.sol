// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "./interfaces/IWETH.sol";
import "./interfaces/IRouter.sol";
import "./interfaces/IFactory.sol";
import "./interfaces/IPair.sol";
import "./HoneypotChecker.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/interfaces/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

contract SnipingContract is HoneypotChecker {
    using SafeERC20 for IERC20;

    IFactory public factory;

    mapping(uint256 => Purchase) public noncePurchases;

    struct Purchase {
        bool processed; // true if the purchase has been executed
        address[] path; // complete path of the purchase transaction
        uint256 baseTokenAmount; // original token amount sold to buy the targeted token
        uint256 targetTokenAmount; // target token amount bought
        uint256 buyFees; // buy fees calculated from the honeypot check
        uint256 sellFees; // sell fees calculated from the honeypot check
    }

    struct PurchaseParams {
        address router;
        bool checkHoneyPot;
        address[] path;
        address[] wallets;
        uint256 minimumLiqBaseToken;
        uint256 slippage;
        uint256 maxFees;
    }

    constructor() Ownable(msg.sender) {}

    // get liquidity of the targeted token in base token
    function getLiquidity(IRouter router, address baseToken, address targetedToken) public view returns (uint256) {
        address pair = IFactory(router.factory()).getPair(baseToken, targetedToken);
        (uint256 token0Amount, uint256 token1Amount,) = IPair(pair).getReserves();
        return IPair(pair).token0() == baseToken ? token0Amount : token1Amount;
    }

    function getPurchaseData(uint256 nonce) external view returns (Purchase memory) {
        return noncePurchases[nonce];
    }

    function spamBuy(uint256 nonce, uint256 amount, PurchaseParams calldata params)
        external
        onlyOwner
        returns (uint256, uint256)
    {
        address tokenAddress = params.path[params.path.length - 1];

        require(!noncePurchases[nonce].processed, "Already processed");
        require(params.wallets.length >= 1, "Empty wallets list");
        require(
            getLiquidity(IRouter(params.router), params.path[params.path.length - 2], tokenAddress)
                >= params.minimumLiqBaseToken,
            "Not enough liquidity"
        );
        uint256 baseTokenAmount = params.path[0] == IRouter(params.router).WETH()
            ? address(this).balance
            : IERC20(params.path[0]).balanceOf(address(this));
        require(baseTokenAmount >= amount, "Not enough base token");

        uint256 honeypotCheckAmount = (amount * INPUT_AMOUNT) / DECIMALS; // allocate a bit of the input amount to the honeypot check

        (bool isHoneyPot, uint256 buyFees, uint256 sellFees) = (false, 0, 0);
        if (params.checkHoneyPot) {
            (isHoneyPot, buyFees, sellFees) =
                isHoneypot(params.path, honeypotCheckAmount, params.maxFees, params.router);

            require(!isHoneyPot, "Honey pot");
        }

        uint256 balanceBefore = IERC20(tokenAddress).balanceOf(address(this));

        _swap(amount - honeypotCheckAmount, params.path, params.slippage, IRouter(params.router));

        uint256 purchasedAmount = IERC20(tokenAddress).balanceOf(address(this)) - balanceBefore;

        noncePurchases[nonce] = Purchase(true, params.path, amount, purchasedAmount, buyFees, sellFees);
        uint256 sharedTokensAmount = purchasedAmount / params.wallets.length;

        for (uint256 i = 0; i < params.wallets.length; i++) {
            IERC20(tokenAddress).safeTransfer(params.wallets[i], sharedTokensAmount);
        }

        return (buyFees, sellFees);
    }
}
