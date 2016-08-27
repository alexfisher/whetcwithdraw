// The contract that allows DTH to withdraw funds that the white hat
// group has managed to retrieve.
//
// There are 2 ways to use the contract:
// 1. withdraw()
// 2. proxyWithdraw()
//
// For a description of each method, take a look at the docstrings.
//
// License: BSD3

contract DAOBalanceSnapShot {
    function balanceOf(address _dth) constant returns(uint);
    function totalSupply() constant returns(uint );
}

contract AuthorizedAddresses {
    function getRepresentedDTH(address _authorizedAddress) constant returns(address _dth);
}

contract Owned {
    /// Prevents methods from perfoming any value transfer
    modifier noEther() {if (msg.value > 0) throw; _}
    /// Allows only the owner to call a function
    modifier onlyOwner { if (msg.sender != owner) throw; _ }

    address owner;

    function Owned() { owner = msg.sender;}



    function changeOwner(address _newOwner) onlyOwner {
        owner = _newOwner;
    }

    function getOwner() noEther constant returns (address) {
        return owner;
    }
}

contract WhitehatWithdraw is Owned {
    uint constant WithdrawType_DIRECT = 1;
    uint constant WithdrawType_PROXY = 2;
    uint constant WithdrawType_PROXY_AUTHORIZED = 3;

    DAOBalanceSnapShot daoBalance;
    AuthorizedAddresses authorizedAddresses;
    mapping (address => uint) paidOut;
    mapping (address => bool) certifiedDepositors;
    mapping (bytes32 => bool) usedSignatures;
    mapping (address => bool) blacklist;
    uint totalFunds;
    uint deployTime;
    uint closingTime;
    address whg_donation;
    address escape;
    address remainingBeneficary;

    event Withdraw(address indexed dth, address indexed beneficiary, uint256  amount, uint256 percentageWHG, uint256 withdrawType);
    event CertifiedDepositorsChanged(address indexed _depositor, bool _allowed);
    event BlacklistChanged(address indexed _dth, bool _blocked);
    event Deposit(uint amount);
    event EscapeCalled(uint amount);
    event RemainingClaimed(uint amount);

    function WhitehatWithdraw(address _whg_donation, address _daoBalanceSnapshotAddress, address _authorizedAddressesAddress, address _escapeAddress, address _remainingBeneficiary) {
        whg_donation = _whg_donation;
        daoBalance = DAOBalanceSnapShot(_daoBalanceSnapshotAddress);
        authorizedAddresses = AuthorizedAddresses(_authorizedAddressesAddress);
        escape = _escapeAddress;
        remainingBeneficary = _remainingBeneficiary;

        totalFunds = msg.value;
        deployTime = now;
        closingTime = 24 weeks;

        // both the owner and the whitehat multisig can perform deposits to this contract
        certifiedDepositors[0x1ac729d2db43103faf213cb9371d6b42ea7a830f] = true;
        certifiedDepositors[msg.sender] = true;
    }

    /// Calculates the remaining funds available for a DTH to withdraw
    ///
    /// @param _dth          The address of the DAO Token Holder for whom
    ///                      to get the funds remaining for withdrawal
    /// @return              The amount of funds remaining for withdrawal
    function calculateWithdraw(address _dth) constant noEther returns(uint) {
        uint tokens = daoBalance.balanceOf(_dth);

        uint acumulatedReward = tokens * totalFunds / daoBalance.totalSupply();
        if (acumulatedReward < paidOut[_dth]) {
            return 0;
        }

        return acumulatedReward - paidOut[_dth];
    }

    /// The core of the withdraw functionality. It is called by all other withdraw functions
    ///
    /// @param _dth           The address of the DAO token holder for whom the
    ///                       withdrawal is going to happen
    /// @param _beneficiary   The address that will receive the _percentage of
    ///                       the funds corresponding to the _dth.
    /// @param _percentageWHG The percentage of the funds that will be donated to the
    ///                       White Hat Group. It should be a number ranging from 0
    ///                       to 100. Anything not claimed by the DTH will be going
    ///                       as a donation to the Whitehat Group.
    /// @param _withdrawType  method used to withdraw (1) Direct (2) Proxy (3) bot (4) owner
    function commonWithdraw(address _dth, address _beneficiary, uint _percentageWHG, uint _withdrawType) internal {

        if (blacklist[_dth]) {
            throw;
        }

        if (_percentageWHG > 100) {
            throw;
        }

        uint toPay = calculateWithdraw(_dth);
        if (toPay == 0) {
            return;
        }

        if (toPay > this.balance) {
            toPay = this.balance;
        }

        uint portionWhg = toPay * _percentageWHG / 100;
        uint portionDth = toPay - portionWhg;
        paidOut[_dth] += toPay;

        // re-entrancy is not possible due to the use of send() which limits
        // the forwarded gas thanks to the gas stipend
        if ( !whg_donation.send(portionWhg) ||  !_beneficiary.send(portionDth) ) {
            throw;
        }

        Withdraw(_dth, _beneficiary,  toPay, _percentageWHG, _withdrawType);
    }

    /// The simple withdraw function, where the message sender is considered as
    /// the DAO token holder whose ratio needs to be retrieved.
    function withdraw(address _beneficiary, uint _percentageWHG ) noEther {
        commonWithdraw(msg.sender, _beneficiary, _percentageWHG, WithdrawType_DIRECT);
    }

    /// The proxy withdraw function. Anyone can call this for someone else as long
    /// as he includes signed data retrieved by using web3.eth.sign(address, hash).
    /// The DAO token holder whose ratio needs to be retrieved is determined by
    /// performing ecrecover on the signed data.
    ///
    /// This function will also allow people to use the ETH chain to give an
    /// approval for withdrawal in the ETC chain without having to sync the
    /// ETC chain. The only requirement is that the account that gives the
    /// approval needs to be an end-user account. Multisig wallets can't do that.
    function proxyWithdraw(address _beneficiary, uint _percentageWHG, uint8 _v, bytes32 _r, bytes32 _s) noEther {
        if (usedSignatures[_r]) {
            throw;
        }
        bytes32 _hash = sha3("Withdraw DAOETC to ", _beneficiary, _percentageWHG);
        address _dth = ecrecover(_hash, _v, _r, _s);
        usedSignatures[_r] = true;
        commonWithdraw(_dth, _beneficiary, _percentageWHG, WithdrawType_PROXY);
        address representedDth = authorizedAddresses.getRepresentedDTH(_dth);
        if (representedDth != 0x0) {
            commonWithdraw(representedDth, _beneficiary, _percentageWHG, WithdrawType_PROXY_AUTHORIZED);
        }
    }

    /// This is the only way to send money to the contract, adding to the total
    /// amount of ETH to be refunded.
    ///
    /// Only people who are considered certified depositors like the whitehat ETC multisig
    /// or addresses owned by exchanges should be able to deposit more ETC for withdrals.
    /// If you need to become a certified depositor please contact Bity SA.
    function deposit() returns (bool) {
        if (!certifiedDepositors[msg.sender]) {
            throw;
        }
        totalFunds += msg.value;
        Deposit(msg.value);
        return true;
    }

    /// Last Resort call, to allow for a reaction if something bad happens to
    /// the contract or if some security issue is uncovered.
    function escapeHatch() noEther onlyOwner returns (bool) {
        uint total = this.balance;
        if (!escape.send(total)) {
            throw;
        }
        EscapeCalled(total);
    }

    /// Allows the claiming of the remaining funds after a given amount of time
    /// Amount is set to 6 months for now but may still change in the future.
    function claimRemaining() noEther returns (bool) {
        if (now < deployTime + closingTime) {
            throw;
        }
        uint total = this.balance;
        if (!remainingBeneficary.send(total)) {
            throw;
        }
        RemainingClaimed(total);
    }

    /// Allows the option to extend (but not shorten!) the closingTime of the
    /// contract to more than 6 months, perhaps even to infinity if that is
    /// deemed as the best choice for the DAO Token holders.
    function extendClosingTime(uint _additionalSeconds) noEther onlyOwner {
        closingTime += _additionalSeconds;
    }

    function () { //no donations
        throw;
    }

    function getPaidOut(address _account) noEther constant returns (uint) {
        return paidOut[_account];
    }

    function getMyBalance(address _account) noEther constant returns (uint) {
        return daoBalance.balanceOf(_account);
    }

    function getTotalFunds() noEther constant returns (uint) {
        return totalFunds;
    }

    function getWHGDonationAddress() noEther constant returns (address) {
        return whg_donation;
    }

    function isCertifiedDepositor(address _depositor) noEther constant returns (bool) {
        return certifiedDepositors[_depositor];
    }

    function changeCertifiedDepositors(address _depositor, bool _allowed) onlyOwner noEther external returns (bool _success) {
        certifiedDepositors[_depositor] = _allowed;
        CertifiedDepositorsChanged(_depositor, _allowed);
        return true;
    }

    function isBlacklisted(address _dth) noEther constant returns (bool) {
        return blacklist[_dth];
    }

    function changeBlacklist(address _dth, bool _blocked) onlyOwner noEther external returns (bool _success) {
        blacklist[_dth] = _blocked;
        BlacklistChanged(_dth, _blocked);
        return true;
    }
}
