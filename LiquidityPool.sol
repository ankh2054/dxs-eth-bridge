// SPDX-License-Identifier: No License (None)

pragma solidity ^0.8.0;

interface IErc20Min {
    function approve(address spender, uint256 amount) external returns (bool);

    function transfer(address to, uint256 amount) external returns (bool);

    function transferFrom(
        address from,
        address to,
        uint256 amount
    ) external returns (bool);
}

contract LiquidityProvider {
    constructor(address token, uint8 decimals) {
        require(
            IErc20Min(token).approve(
                msg.sender,
                999_999_999_999_999_999 * 10**decimals
            ), // quiet large amount
            "Not approved yet"
        );
    }
}

contract Treasury {
    address private _owner;

    constructor() {
        _owner = msg.sender;
    }

    function sendTo(
        address token,
        address addressTo,
        uint256 amount
    ) public {
        require(_owner == msg.sender);
        require(IErc20Min(token).transfer(addressTo, amount));
    }
}

contract LiquidityPool {
    event DepositReceived(
        address withdrawAddress,
        address depositAddress,
        uint8 tokenType,
        uint256 amountCents
    );
    event Withdrawn(
        address withdrawAddress,
        address depositAddress,
        uint8 tokenType,
        bytes32 bsvTxId,
        uint256 amountCents
    );
    event AccountCreated(
        address withdrawAddress,
        address depositAddress,
        uint8 tokenType
    );
    event OwnershipTransferred(
        address indexed previousOwner,
        address indexed newOwner
    );
    event TokenAdded(uint8 tokenType, address contractAddress, uint8 decimals);

    struct Account {
        uint256 withdrawPeriodStarted;
        uint256 availableCents;
        address depositAddress;
        uint256 balanceCents;
        uint256 withdrawLimitCents;
    }

    struct Token {
        address pointer;
        uint8 decimals;
    }

    uint256 private _ownershipTransferStarted;
    address private _ownerAddress;
    address private _nextOwnerAddress;

    address private _usdtToken;
    address private _usdcToken;
    address private _daiToken;
    address private _treasury;
    uint256 private _withdrawResetTimeout;
    uint256 private _maxWithdrawAmountCents;

    mapping(bytes32 => Account) private _accounts;
    mapping(uint8 => Token) private _tokens;

    modifier onlyOwner() {
        require(msg.sender == _ownerAddress, "Caller is not current owner!");
        _;
    }

    constructor(
        address nextOwner,
        uint256 withdrawResetTimeoutSeconds,
        uint256 maxWithdrawAmountCents
    ) {
        _ownerAddress = msg.sender;
        _nextOwnerAddress = nextOwner;
        _withdrawResetTimeout = withdrawResetTimeoutSeconds;
        _maxWithdrawAmountCents = maxWithdrawAmountCents;

        _treasury = address(new Treasury());
    }

    function addToken(
        uint8 tokenType,
        address contractAddress,
        uint8 decimals
    ) public onlyOwner {
        require(_tokens[tokenType].decimals == 0, "Known token");

        _tokens[tokenType].pointer = contractAddress;
        _tokens[tokenType].decimals = decimals;

        emit TokenAdded(tokenType, contractAddress, decimals);
    }

    function transferOwnershipStart() public onlyOwner {
        _ownershipTransferStarted = block.timestamp;
    }

    function transferOwnershipComplete(address nextOwner) public {
        assert(_ownershipTransferStarted > 0);
        require(msg.sender == _nextOwnerAddress, "Caller is not next owner!");
        require(
            block.timestamp - _ownershipTransferStarted < 1 minutes,
            "operation timeout"
        );

        address oldOwner = _ownerAddress;

        _ownerAddress = _nextOwnerAddress;
        _nextOwnerAddress = nextOwner;

        emit OwnershipTransferred(oldOwner, _ownerAddress);
    }

    function getAccountInfo(address withdrawAddress, uint8 tokenType)
        public
        view
        returns (
            uint256 availableCents,
            uint256 withdrawPeriodStarted,
            uint256 withdrawLimitCents
        )
    {
        Account memory account = getAccount(withdrawAddress, tokenType);
        return (
            account.availableCents,
            account.withdrawPeriodStarted,
            account.withdrawLimitCents
        );
    }

    function getDepositAddress(address withdrawAddress, uint8 tokenType)
        public
        view
        returns (address)
    {
        return
            address(
                uint160(
                    uint256(
                        keccak256(
                            abi.encodePacked(
                                bytes1(0xff),
                                address(this),
                                getSalt(withdrawAddress, tokenType),
                                keccak256(
                                    abi.encodePacked(
                                        type(LiquidityProvider).creationCode,
                                        abi.encode(
                                            _tokens[tokenType].pointer,
                                            _tokens[tokenType].decimals
                                        )
                                    )
                                )
                            )
                        )
                    )
                )
            );
    }

    function collect(
        address withdrawAddress,
        uint8 tokenType,
        uint256 amountCents
    ) public onlyOwner {
        require(_tokens[tokenType].decimals > 0, "Unknown token");

        Account storage account = getAccount(withdrawAddress, tokenType);

        bool newAccount = account.depositAddress == address(0);

        if (newAccount) {
            createAccount(withdrawAddress, tokenType);
        }

        require(amountCents > 0, "Amount must bee > 0");
        require(_tokens[tokenType].decimals > 0, "Unknown");

        bool collected = IErc20Min(_tokens[tokenType].pointer).transferFrom(
            account.depositAddress,
            _treasury,
            centsToToken(amountCents, tokenType)
        );

        require(collected, "Failed to collect tokens");

        uint256 balance = account.balanceCents + amountCents;

        if (balance > account.withdrawLimitCents) {
            if (account.withdrawLimitCents < _maxWithdrawAmountCents) {
                account.withdrawLimitCents = min(
                    max(account.withdrawLimitCents, balance),
                    _maxWithdrawAmountCents
                );
            }
        }

        if (account.withdrawLimitCents < _maxWithdrawAmountCents) {
            account.balanceCents = balance;
        }

        emit DepositReceived(
            withdrawAddress,
            account.depositAddress,
            tokenType,
            amountCents
        );
    }

    function withdraw(
        address withdrawAddress,
        uint8 tokenType,
        uint256 amountCents,
        bytes32 bsvTxId
    ) public onlyOwner {
        require(_tokens[tokenType].decimals > 0, "Unknown token");

        Account storage account = getAccount(withdrawAddress, tokenType);

        uint256 available = account.availableCents;

        if (
            block.timestamp - account.withdrawPeriodStarted >=
            _withdrawResetTimeout
        ) {
            account.withdrawPeriodStarted = block.timestamp;

            available = account.withdrawLimitCents;
        }

        uint256 withdrawAmountCents = min(amountCents, available);

        require(
            withdrawAmountCents > 0,
            "Not enough available amount for current period"
        );

        Treasury(_treasury).sendTo(
            _tokens[tokenType].pointer,
            withdrawAddress,
            centsToToken(withdrawAmountCents, tokenType)
        );

        account.availableCents = available - withdrawAmountCents;

        if (account.withdrawLimitCents < _maxWithdrawAmountCents) {
            if (account.balanceCents > withdrawAmountCents) {
                account.balanceCents =
                    account.balanceCents -
                    withdrawAmountCents;
            } else {
                account.balanceCents = 0;
            }
        }

        emit Withdrawn(
            withdrawAddress,
            account.depositAddress,
            tokenType,
            bsvTxId,
            withdrawAmountCents
        );
    }

    function getAccount(address withdrawAddress, uint8 tokenType)
        private
        view
        returns (Account storage account)
    {
        account = _accounts[
            keccak256(abi.encodePacked(withdrawAddress, tokenType))
        ];
    }

    function createAccount(address withdrawAddress, uint8 tokenType)
        private
        returns (Account storage account)
    {
        account = getAccount(withdrawAddress, tokenType);

        require(account.depositAddress == address(0), "Existig account");

        LiquidityProvider wallet = new LiquidityProvider{
            salt: getSalt(withdrawAddress, tokenType)
        }(_tokens[tokenType].pointer, _tokens[tokenType].decimals);

        account.depositAddress = address(wallet);
        account.withdrawPeriodStarted = block.timestamp;

        emit AccountCreated(withdrawAddress, account.depositAddress, tokenType);
    }

    function centsToToken(uint256 cents, uint8 tokenType)
        private
        view
        returns (uint256)
    {
        return cents * (10**(_tokens[tokenType].decimals - 2));
    }

    function getSalt(address withdrawAddress, uint8 tokenType)
        private
        pure
        returns (bytes32)
    {
        return keccak256(abi.encodePacked(withdrawAddress, tokenType));
    }

    function max(uint256 a, uint256 b) private pure returns (uint256) {
        return a >= b ? a : b;
    }

    function min(uint256 a, uint256 b) private pure returns (uint256) {
        return a < b ? a : b;
    }
}
