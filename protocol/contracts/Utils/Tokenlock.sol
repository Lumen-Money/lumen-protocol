pragma solidity ^0.8.20;

import "./Owned.sol";

contract Tokenlock is Owned {
    /// @notice Indicates if token is locked
    uint8 internal isLocked = 0;

    event Freezed();
    event UnFreezed();

    modifier validLock() {
        require(isLocked == 0, "Token is locked");
        _;
    }

    function freeze() public onlyOwner {
        isLocked = 1;

        emit Freezed();
    }

    function unfreeze() public onlyOwner {
        isLocked = 0;

        emit UnFreezed();
    }
}
