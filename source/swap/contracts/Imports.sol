pragma solidity 0.5.13;

import "wjm-airswap-tokens/contracts/FungibleToken.sol";
import "wjm-airswap-tokens/contracts/OMGToken.sol";
import "wjm-airswap-tokens/contracts/NonFungibleToken.sol";
import "wjm-airswap-tokens/contracts/AdaptedKittyERC721.sol";
import "wjm-airswap-tokens/contracts/MintableERC1155Token.sol";
import "wjm-airswap-types/contracts/Types.sol";
import "wjm-airswap-transfers/contracts/TransferHandlerRegistry.sol";
import "wjm-airswap-transfers/contracts/handlers/ERC20TransferHandler.sol";
import "wjm-airswap-transfers/contracts/handlers/ERC721TransferHandler.sol";
import "wjm-airswap-transfers/contracts/handlers/ERC1155TransferHandler.sol";
import "wjm-airswap-transfers/contracts/handlers/KittyCoreTransferHandler.sol";
import "@gnosis.pm/mock-contract/contracts/MockContract.sol";

contract Imports {}
