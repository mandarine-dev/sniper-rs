// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "./interfaces/IWETH.sol";
import "./interfaces/IRouter.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/interfaces/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

abstract contract HoneypotChecker is Ownable {
    using SafeERC20 for IERC20;

    uint256 MAX_INT = 2 ** 256 - 1;

    uint constant DECIMALS = 1000000;
    uint constant INPUT_AMOUNT = 1000; // input amount of token in % of the amount used to buy (IN DECIMALS %)

    struct CheckerResponse {
        uint256 buyGas;
        uint256 sellGas;
        uint256 estimatedBuy;
        uint256 exactBuy;
        uint256 estimatedSell;
        uint256 exactSell;
    }

    receive() external payable {}

    function withdrawFund(address token, uint amount) external onlyOwner {
        // token = address(0) to withdraw eth
        if (token == address(0)) {
            (bool sent, ) = payable(owner()).call{value: amount}("");
            require(sent);
        } else {
            IERC20(token).safeTransfer(owner(), amount);
        }
    }

    function _swap(
        uint256 amountIn,
        address[] memory path,
        uint slippage,
        IRouter router
    ) internal returns (uint256) {
        uint256 usedGas = gasleft();
        uint minAmountOut = (router.getAmountsOut(amountIn, path)[1] *
            (DECIMALS - slippage)) / DECIMALS;

        if (path[0] == router.WETH()) {
            router.swapExactETHForTokensSupportingFeeOnTransferTokens{
                value: amountIn
            }(minAmountOut, path, address(this), block.timestamp + 100);
        } else if (path[path.length - 1] == router.WETH()) {
            router.swapExactTokensForETHSupportingFeeOnTransferTokens(
                amountIn,
                minAmountOut,
                path,
                address(this),
                block.timestamp + 100
            );
        } else {
            router.swapExactTokensForTokensSupportingFeeOnTransferTokens(
                amountIn,
                minAmountOut,
                path,
                address(this),
                block.timestamp + 100
            );
        }

        usedGas = usedGas - gasleft();

        return usedGas;
    }

    function _check(
        uint256 checkAmount,
        address[] calldata path,
        address router
    ) external returns (CheckerResponse memory) {
        require(path.length == 2);

        IRouter routerInt = IRouter(router);

        IERC20 baseToken = IERC20(path[0]);
        IERC20 targetToken = IERC20(path[1]);

        address[] memory routePath = new address[](2);

        // approve tokens
        if (address(baseToken) != routerInt.WETH())
            baseToken.forceApprove(router, MAX_INT);

        targetToken.forceApprove(router, MAX_INT);

        uint estimatedBuy = routerInt.getAmountsOut(checkAmount, path)[1];
        uint balanceBefore = targetToken.balanceOf(address(this));

        // execute swap (buying targeted token with base token)

        uint buyGas = _swap(checkAmount, path, DECIMALS / 10, routerInt);

        uint exactBuy = targetToken.balanceOf(address(this)) - balanceBefore;

        //swap Path
        routePath[0] = path[1];
        routePath[1] = path[0];

        uint estimatedSell = routerInt.getAmountsOut(exactBuy, routePath)[1];
        balanceBefore = address(baseToken) == routerInt.WETH()
            ? address(this).balance
            : baseToken.balanceOf(address(this));

        // execute swap (selling targeted token for base token)

        uint sellGas = _swap(exactBuy, routePath, DECIMALS / 10, routerInt);

        uint exactSell = balanceBefore = address(baseToken) == routerInt.WETH()
            ? address(this).balance - balanceBefore
            : baseToken.balanceOf(address(this)) - balanceBefore;

        // return result

        CheckerResponse memory response = CheckerResponse(
            buyGas,
            sellGas,
            estimatedBuy,
            exactBuy,
            estimatedSell,
            exactSell
        );

        return response;
    }

    function calculateTaxFee(
        uint estimatedPrice,
        uint exactPrice
    ) internal pure returns (uint) {
        uint result = (((estimatedPrice - exactPrice) * DECIMALS) /
            estimatedPrice);

        return result <= 0 ? 0 : result;
    }

    function isHoneypot(
        address[] calldata path,
        uint checkAmount,
        uint maxFees, // maxFees = DECIMALS constant to tolerate up to 100% fees
        address router
    ) public returns (bool, uint, uint) {
        // call the _check function by call to catch any error (and not reverting the whole tx)
        (bool success, bytes memory data) = address(this).call(
            abi.encodeWithSignature(
                "_check(uint256,address[],address)",
                checkAmount,
                path,
                router
            )
        );
        CheckerResponse memory response = abi.decode(data, (CheckerResponse));

        if (success) {
            // successfully checked the contract, now compute the fees

            uint buyFees = calculateTaxFee(
                response.estimatedBuy,
                response.exactBuy
            );
            uint sellFees = calculateTaxFee(
                response.estimatedSell,
                response.exactSell
            );

            if (buyFees + sellFees > maxFees) {
                return (true, buyFees, sellFees);
            }

            // At this point, fees are sufficiently low and check's execution hasn't been reverted, return false
            return (false, buyFees, sellFees);
        } else {
            // if the check is reverted, the token isn't safe to get in
            return (true, 0, 0);
        }
    }
}
