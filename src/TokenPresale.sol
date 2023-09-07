// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.17;

import "lib/universal-router/contracts/interfaces/IUniversalRouter.sol";
import "lib/universal-router/contracts/libraries/Constants.sol";
import "lib/universal-router/contracts/libraries/Commands.sol";
import "lib/universal-router/permit2/src/Permit2.sol";
import "lib/universal-router/permit2/src/interfaces/ISignatureTransfer.sol";

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

///TODO Increase Test coverage

contract TokenPresale is Ownable {
    // sell users HUB tokens based on a rate vs USDC. 1 HUB = 0.5 USDC
    // Users are able to purchase HUB in various currencies
    // User balances are kept in a mapping and HUB becomes claimable after launch
    // Deposited currencies are swapped for ETH via the uniswap UR and stored in a balance var.
    // Profits are only withdrawable by the contact owner

    uint256 public balance;

    // How many token units a buyer gets per wei.
    // The rate is the conversion between wei and the smallest and indivisible token unit.
    // So, if you are using a rate of 1 with a ERC20Detailed token with 3 decimals called TOK
    // 1 wei will give you 1 unit, or 0.001 TOK.
    /// @notice The below rate works out to about 1.2HUB / 1USDC
    uint256 private _rate; // rate is 2e3 => 1 wei = 0.0000000000000002 HUB 

    // Amount of wei raised
    uint256 private _weiRaised;

    address public constant UNIVERSAL_ROUTER_ADDRESS = 0xEf1c6E67703c7BD7107eed8303Fbe6EC2554BF6B;
    address public constant PERMIT2_ADDRESS = 0x000000000022D473030F116dDEE9F6B43aC78BA3;
    address public constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;

    IUniversalRouter public universalRouter;
    Permit2 public immutable permit2;

    struct Token {
        address tokenAddress;
        uint24 poolFee;
        bool approved;
    }

    mapping(address => uint256) public userHubBalance;
    mapping(address => Token) private approvedTokens;

    /*------EVENTS------*/

    event HubBought(address indexed buyer, uint256 indexed amount, uint256 indexed hubBought);

    /*------CONSTRUCTOR------*/

    constructor() {
        universalRouter = IUniversalRouter(UNIVERSAL_ROUTER_ADDRESS);
        permit2 = Permit2(PERMIT2_ADDRESS);
        _rate = 2e3;
    }

    /*------STATE CHANGING FUNCTIONS------*/

    /// @notice Allows a user to purchase HUB using approve on _purchaseToken.
    /// @param _purchaseToken the address of the ERC20 token used to buy HUB
    /// @param _amount the the _amount of _purchaseToken that the user is willing to spend
    /// @param _slippage the minimum _amount of eth that _purchaseToken will be swapped for. Called off-chain using uniswap quoter
    function buyHubWithApproval(address _purchaseToken, uint256 _amount, uint256 _slippage) public returns(uint256) {
        require(_amount > 0, "Cannot Buy 0");

        Token memory token = approvedTokens[_purchaseToken];
        
        require(token.approved == true, "Not Approved Token");
        require(token.tokenAddress != address(0), "Address 0");
        IERC20 token_ = IERC20(token.tokenAddress );
        require(token_.balanceOf(msg.sender) >= _amount, "Insufficient Balance");

        token_.transferFrom(msg.sender, address(this), _amount);

        uint256 wethOut = _swapExactInputSingle(_amount, token.tokenAddress, token.poolFee, _slippage, block.timestamp + 60);
        uint256 hubBought =  _getHub(wethOut);
        userHubBalance[msg.sender] += hubBought;

        emit HubBought(msg.sender, _amount, hubBought);

        return (hubBought);
    }

    /// @notice Allows a user to purchase HUB using permit2. This lets a 3rd party pay for gas.
    /// @param _purchaseToken the address of the ERC20 token used to buy HUB
    /// @param _amount the the _amount of _purchaseToken that the user is willing to spend
    /// @param _slippage the minimum _amount of eth that _purchaseToken will be swapped for. Called off-chain using uniswap quoter
    function buyHubWithPermit(
            address _purchaseToken,
            address _sender,
            uint256 _amount,
            uint256 _slippage,
            uint256 _nonce,
            uint256 _deadline,
            bytes calldata _signature
        ) public returns(uint256) {    
        
        require(_sender != address(0), "Address 0");
        require(_amount > 0, "Cannot Buy 0");

        Token memory token = approvedTokens[_purchaseToken];

        require(token.approved == true, "Not Approved Token");
        require(token.tokenAddress != address(0), "Address 0");
        IERC20 token_ = IERC20(token.tokenAddress );
        require(token_.balanceOf(_sender) >= _amount, "Insufficient Balance");

        // Transfer tokens from _sender to ourselves.
        permit2.permitTransferFrom(
            // The permit message.
            ISignatureTransfer.PermitTransferFrom({
                permitted: ISignatureTransfer.TokenPermissions({
                    token: _purchaseToken,
                    amount: _amount
                }),
                nonce: _nonce,
                deadline: _deadline
            }),
            // The transfer recipient and amount.
            ISignatureTransfer.SignatureTransferDetails({
                to: address(this),
                requestedAmount: _amount
            }),
            // The owner of the tokens, which must also be
            // the signer of the message, otherwise this call
            // will fail.
            _sender,
            // The packed signature that was the result of signing
            // the EIP712 hash of `permit`.
            _signature
        );

        // Approve PERMIT2 contract to transfer funds to the universal router
        // permit2.approve(_purchaseToken, address(universalRouter), uint160(_amount), uint48(_deadline));

        uint256 wethOut = _swapExactInputSingle(_amount, token.tokenAddress, token.poolFee, _slippage, _deadline);
        uint256 hubBought =  _getHub(wethOut);
        userHubBalance[_sender] += hubBought;
        
        emit HubBought(_sender, _amount, hubBought);

        return (hubBought);
    }

    function approveToken(address _tokenAddress, uint24 _poolFee) public onlyOwner {
        approvedTokens[_tokenAddress] = Token({
            tokenAddress: _tokenAddress,
            poolFee: _poolFee,
            approved: true
        });

        IERC20(_tokenAddress).approve(PERMIT2_ADDRESS, type(uint256).max);
        permit2.approve(_tokenAddress, address(universalRouter), type(uint160).max, type(uint48).max);
    }

     /*------INTERNAL FUNCTIONS------*/

    /// @notice swapExactInputSingle swaps a fixed amount of _token for a maximum possible amount of WETH
    /// @dev The calling address must approve this contract to spend at least `amountIn` worth of _token for this function to succeed.
    /// @param _amountIn The exact amount of _token that will be swapped for WETH.
    /// @param _token The address of the token to be swapped.
    /// @param _amountOutMinimum The minimum amount of _token to receive after the swap.
    /// @param _deadline The timestamp after which the transaction becomes invalid.
    function _swapExactInputSingle(
        uint256 _amountIn,
        address _token,
        uint24 _poolFee,
        uint256 _amountOutMinimum,
        uint256 _deadline
    ) internal returns(uint256) {
        // Build uniswap commands
        bytes memory commands = abi.encodePacked(bytes1(uint8(Commands.V3_SWAP_EXACT_IN)));
        // Create path for the swap
        bytes memory path = abi.encodePacked(_token, _poolFee, WETH);
        // Create input parameters for execution with commands
        bytes[] memory inputs = new bytes[](1); 
        inputs[0] = abi.encode(Constants.MSG_SENDER, _amountIn, _amountOutMinimum, path, true); 

        uint256 wethBalanceBefore = IERC20(WETH).balanceOf(address(this));
        // Execute the swap
        universalRouter.execute(commands, inputs, _deadline);

        uint256 wethBalanceAfter = IERC20(WETH).balanceOf(address(this));
        // Calculate amount of Weth swapped
        uint256 wethOut = wethBalanceAfter - wethBalanceBefore;
        //Update contract weth balance
        balance += wethOut;

        return wethOut;
    }

    function _getHub(uint256 _weiAmount) internal view returns(uint256) {
        return _weiAmount * _rate;
    }

    /*------VIEW FUNCTIONS------*/
    function getHubQuote(uint256 _weiAmount) public view returns(uint256 hubQuote){
        hubQuote = _getHub(_weiAmount);
    }

    function rate() public view returns(uint256 rate_){
        rate_ = _rate;
    }

}
